// Host tests for sherpa_engine, driven only through the C ABI (sherpa_engine.h) against a real GGUF.
//
//   sherpa_engine_tests --model /opt/models/Qwen3-0.6B-Q4_K_M.gguf [--lora adapter.gguf] [--threads N]
//                       [--filter substring] [--bench-json out.json]
//
// Every test prints PASS/FAIL; a benchmark table (TTFT, prefill/decode tok/s with and without the prefix
// cache and speculation, plus se_bench) is printed at the end - those numbers seed tools/bench budgets.
#include "sherpa_engine.h"

#include <nlohmann/json.hpp>

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <functional>
#include <map>
#include <sstream>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

using json = nlohmann::json;
using Clock = std::chrono::steady_clock;

namespace {

std::string g_model;
std::string g_lora;
std::string g_tmp = "/tmp";
int         g_threads = 4;
std::string g_filter;
std::string g_bench_json;

int g_failed = 0, g_passed = 0;
std::vector<std::string> g_failures;

#define EXPECT(cond)                                                                            \
  do {                                                                                          \
    if (!(cond)) {                                                                              \
      std::fprintf(stderr, "    EXPECT failed: %s (%s:%d)\n", #cond, __FILE__, __LINE__);      \
      throw std::runtime_error(#cond);                                                          \
    }                                                                                           \
  } while (0)
#define EXPECT_EQ(a, b)                                                                         \
  do {                                                                                          \
    const auto _a = (a);                                                                        \
    const auto _b = (b);                                                                        \
    if (!(_a == _b)) {                                                                          \
      std::ostringstream _o;                                                                    \
      _o << #a << " == " << #b << " (" << _a << " vs " << _b << ")";                          \
      std::fprintf(stderr, "    EXPECT failed: %s (%s:%d)\n", _o.str().c_str(), __FILE__, __LINE__); \
      throw std::runtime_error(_o.str());                                                       \
    }                                                                                           \
  } while (0)
#define EXPECT_OK(expr)                                                                         \
  do {                                                                                          \
    const se_status _s = (expr);                                                                \
    if (_s != SE_OK) {                                                                          \
      std::fprintf(stderr, "    %s -> %s: %s (%s:%d)\n", #expr, se_status_name(_s), se_last_error(), __FILE__, __LINE__); \
      throw std::runtime_error(#expr);                                                          \
    }                                                                                           \
  } while (0)

struct Bench {
  std::string name;
  double ttft_ms, prefill_tps, decode_tps, accept;
  int prompt, cached, completion;
};
std::vector<Bench> g_bench;

// ---- event collection ---------------------------------------------------------------------------------
struct Ev {
  int type, index, code;
  uint32_t gen;
  std::string text, id, name;
};

struct Gen {
  std::vector<Ev> events;
  std::string     text, reasoning, final_json, finish_name;
  int             finish = 0, n_finish = 0;
  int             prompt = 0, cached = 0, completion = 0, drafted = 0, accepted = 0;
  double          ttft = 0, prefill_tps = 0, decode_tps = 0, accept_rate = 0;
  std::vector<std::string> errors;
  int count(int type) const {
    int n = 0;
    for (auto & e : events) n += e.type == type;
    return n;
  }
  json final_msg() const { return json::parse(final_json); }
};

void absorb(Gen & g, const se_event & e) {
  Ev c{e.type, e.index, e.code, e.generation_id, std::string(e.text, e.text_len), e.id, e.name};
  switch (e.type) {
    case SE_EVENT_TEXT_DELTA:      g.text += c.text; break;
    case SE_EVENT_REASONING_DELTA: g.reasoning += c.text; break;
    case SE_EVENT_USAGE:
      g.prompt = e.prompt_tokens; g.cached = e.cached_tokens; g.completion = e.completion_tokens;
      break;
    case SE_EVENT_PERF:
      g.ttft = e.ttft_ms; g.prefill_tps = e.prefill_tps; g.decode_tps = e.decode_tps;
      g.accept_rate = e.draft_accept_rate; g.drafted = e.n_drafted; g.accepted = e.n_accepted;
      break;
    case SE_EVENT_ERROR:  g.errors.push_back(se_status_name(e.code) + std::string(": ") + c.text); break;
    case SE_EVENT_FINISH: g.finish = e.code; g.final_json = c.text; g.finish_name = c.name; g.n_finish++; break;
  }
  g.events.push_back(std::move(c));
}

// Polls until FINISH. on_event may return false to stop early (the caller then handles the rest).
Gen drain(se_session * s, int poll_sleep_ms = 0, int max_events = 0,
          const std::function<void(Gen &, const se_event &)> & on_event = nullptr) {
  Gen g;
  const auto deadline = Clock::now() + std::chrono::minutes(5);
  while (g.n_finish == 0) {
    const se_event * evs = nullptr;
    int32_t n = 0;
    EXPECT_OK(se_poll_events(s, 200, max_events, &evs, &n));
    for (int32_t i = 0; i < n; ++i) {
      absorb(g, evs[i]);
      if (on_event) on_event(g, evs[i]);
    }
    if (poll_sleep_ms) std::this_thread::sleep_for(std::chrono::milliseconds(poll_sleep_ms));
    EXPECT(Clock::now() < deadline);
  }
  EXPECT_OK(se_wait(s, 10000));
  return g;
}

Gen run(se_session * s, const json & req, int poll_sleep_ms = 0, int max_events = 0) {
  uint32_t id = 0;
  EXPECT_OK(se_generate_start(s, req.dump().c_str(), &id));
  Gen g = drain(s, poll_sleep_ms, max_events);
  for (auto & e : g.events) EXPECT_EQ(e.gen, id);
  return g;
}

se_session * make_session(se_model * m, std::function<void(se_session_params &)> tweak = nullptr) {
  se_session_params sp;
  se_session_params_init(&sp);
  sp.n_ctx = 4096;
  sp.n_threads = g_threads;
  sp.seed = 42;
  if (tweak) tweak(sp);
  se_session * s = nullptr;
  EXPECT_OK(se_session_create(m, &sp, &s));
  return s;
}

json chat(std::initializer_list<json> msgs) {
  json r;
  r["messages"] = json::array();
  for (auto & m : msgs) r["messages"].push_back(m);
  r["temperature"] = 0.0;
  r["seed"] = 7;
  return r;
}
json msg(const char * role, const std::string & content) { return json{{"role", role}, {"content", content}}; }

const json k_weather_tool = json::parse(R"({"type":"function","function":{"name":"get_weather",
  "description":"Get the current weather for a city",
  "parameters":{"type":"object","properties":{"city":{"type":"string","description":"City name"}},"required":["city"]}}})");

// A long, stable system prompt (rules + tool docs) so the prefix cache and TTFT effects are measurable.
std::string long_system_prompt() {
  std::string s = "You are Sherpa, a careful on-device assistant. Follow these rules:\n";
  for (int i = 1; i <= 40; ++i) {
    s += std::to_string(i) + ". Rule number " + std::to_string(i) +
         ": keep answers short, cite tools you used, never invent file paths, and ask before deleting data.\n";
  }
  return s;
}

int64_t rss_bytes() {
  std::ifstream f("/proc/self/statm");
  long pages_total = 0, pages_rss = 0;
  f >> pages_total >> pages_rss;
  return (int64_t) pages_rss * sysconf(_SC_PAGESIZE);
}

std::string jget(int32_t (*fn)(char *, int32_t)) {
  const int32_t n = fn(nullptr, 0);
  EXPECT(n > 0);
  std::string s((size_t) n + 1, '\0');
  EXPECT_EQ(fn(&s[0], n + 1), n);
  s.resize((size_t) n);
  return s;
}

std::string model_info(const se_model * m) {
  const int32_t n = se_model_info_json(m, nullptr, 0);
  EXPECT(n > 0);
  std::string s((size_t) n + 1, '\0');
  EXPECT_EQ(se_model_info_json(m, &s[0], n + 1), n);
  s.resize((size_t) n);
  return s;
}

std::string session_info(se_session * s) {
  const int32_t n = se_session_info_json(s, nullptr, 0);
  EXPECT(n > 0);
  std::string out((size_t) n + 1, '\0');
  EXPECT_EQ(se_session_info_json(s, &out[0], n + 1), n);
  out.resize((size_t) n);
  return out;
}

void log_cb(int32_t level, const char * msg, void *) {
  if (level >= SE_LOG_ERROR) std::fprintf(stderr, "[engine] %s", msg);
}

// ---- tests ------------------------------------------------------------------------------------------
se_model * g_m = nullptr;

void test_abi_version() {
  EXPECT_EQ(se_abi_version(), SE_ABI_VERSION);
  EXPECT(std::string(se_version_string()).find("0c1e570") != std::string::npos);
  const json sys = json::parse(jget(se_system_info_json));
  EXPECT(sys["devices"].size() >= 1);
  EXPECT(sys["cpu"]["features"].is_object());
  std::printf("    %s\n    cpu: %s, backend features: %s\n", se_version_string(), sys["cpu"].dump().c_str(),
              sys["cpu_backend_features"].dump().c_str());
}

void test_error_paths() {
  se_model * m = nullptr;
  EXPECT_EQ(se_model_load("/nonexistent.gguf", nullptr, &m), SE_ERR_IO);
  EXPECT(m == nullptr);
  EXPECT(std::strlen(se_last_error()) > 0);
  // A file that is not a GGUF: llama.cpp fails, we return an error (no abort).
  const std::string junk = g_tmp + "/sherpa-junk.gguf";
  { std::ofstream(junk) << "definitely not gguf"; }
  EXPECT_EQ(se_model_load(junk.c_str(), nullptr, &m), SE_ERR_MODEL_LOAD);
  // Model-load cancel through the progress callback.
  se_model_params mp;
  se_model_params_init(&mp);
  mp.progress_cb = [](float, void *) -> int32_t { return 0; };
  EXPECT_EQ(se_model_load(g_model.c_str(), &mp, &m), SE_ERR_CANCELLED);
  se_canceller * c = se_canceller_create();
  se_canceller_cancel(c);
  se_model_params_init(&mp);
  mp.cancel = c;
  EXPECT_EQ(se_model_load(g_model.c_str(), &mp, &m), SE_ERR_CANCELLED);
  se_canceller_free(c);

  // Out-of-range token ids would throw std::out_of_range inside llama_token_to_piece (R04 §7).
  const int32_t bad[] = {1, 10000000};
  char buf[64];
  EXPECT_EQ(se_detokenize(g_m, bad, 2, 1, buf, sizeof buf), SE_ERR_INVALID_ARG);
  const int32_t neg[] = {-5};
  EXPECT_EQ(se_detokenize(g_m, neg, 1, 1, buf, sizeof buf), SE_ERR_INVALID_ARG);

  // n_outputs_max below what the session needs would trip GGML_ASSERT in llama_context (R04 §6).
  se_session_params sp;
  se_session_params_init(&sp);
  sp.n_ctx = 512;
  sp.spec_type = SE_SPEC_NGRAM_MOD;
  sp.spec_n_max = 8;
  sp.n_outputs_max = 4;
  se_session * s = nullptr;
  EXPECT_EQ(se_session_create(g_m, &sp, &s), SE_ERR_INVALID_ARG);
  EXPECT(std::string(se_last_error()).find("n_outputs_max") != std::string::npos);
  // Quantized V without flash attention (llama-context.cpp:3840-3848).
  se_session_params_init(&sp);
  sp.n_ctx = 512;
  sp.type_k = SE_KV_Q4_0;
  sp.type_v = SE_KV_Q4_0;
  sp.flash_attn = 0;
  EXPECT_EQ(se_session_create(g_m, &sp, &s), SE_ERR_INVALID_ARG);
  EXPECT(std::string(se_last_error()).find("flash attention") != std::string::npos);
  sp.flash_attn = -1;
  sp.type_k = 12345;
  EXPECT_EQ(se_session_create(g_m, &sp, &s), SE_ERR_INVALID_ARG);
  // struct_size too small.
  se_session_params tiny;
  std::memset(&tiny, 0, sizeof tiny);
  EXPECT_EQ(se_session_create(g_m, &tiny, &s), SE_ERR_ABI);
  // MTP on a model without NextN heads.
  se_session_params_init(&sp);
  sp.spec_type = SE_SPEC_MTP;
  EXPECT_EQ(se_session_create(g_m, &sp, &s), SE_ERR_UNSUPPORTED);

  s = make_session(g_m, [](se_session_params & p) { p.n_ctx = 512; });
  // Malformed requests fail synchronously.
  EXPECT_EQ(se_generate_start(s, "{not json", nullptr), SE_ERR_INVALID_ARG);
  EXPECT_EQ(se_generate_start(s, R"({"messages":[]})", nullptr), SE_ERR_INVALID_ARG);
  EXPECT_EQ(se_generate_start(s, R"({"messages":[{"role":"user","content":"hi"}],"max_tokens":0})", nullptr), SE_ERR_INVALID_ARG);
  EXPECT_EQ(se_generate_start(s, R"({"messages":[{"role":"user","content":"hi"}],"tool_choice":"sometimes"})", nullptr), SE_ERR_INVALID_ARG);
  EXPECT_EQ(se_generate_start(s, nullptr, nullptr), SE_ERR_INVALID_ARG);

  // Busy: one generation per session; maintenance calls are refused while it runs.
  json req = chat({msg("user", "Count from one to fifty in words, separated by commas.")});
  req["max_tokens"] = 200;
  req["enable_thinking"] = false;
  EXPECT_OK(se_generate_start(s, req.dump().c_str(), nullptr));
  EXPECT_EQ(se_generate_start(s, req.dump().c_str(), nullptr), SE_ERR_BUSY);
  EXPECT_EQ(se_session_reset(s), SE_ERR_BUSY);
  EXPECT_EQ(se_state_save(s, (g_tmp + "/busy.state").c_str()), SE_ERR_BUSY);
  EXPECT_EQ(se_session_set_loras(s, nullptr, nullptr, 0), SE_ERR_BUSY);
  EXPECT_EQ(se_wait(s, 0), SE_ERR_TIMEOUT);
  EXPECT(json::parse(session_info(s))["busy"] == true);
  EXPECT_OK(se_cancel(s));
  Gen g = drain(s);
  EXPECT_EQ(g.n_finish, 1);

  // A prompt longer than the context: ERROR(CONTEXT_FULL) + FINISH(error), no abort.
  std::string huge;
  for (int i = 0; i < 400; ++i) huge += "token soup number " + std::to_string(i) + ". ";
  g = run(s, chat({msg("user", huge)}));
  EXPECT_EQ(g.finish, (int) SE_FINISH_ERROR);
  EXPECT_EQ(g.errors.size(), 1u);
  EXPECT(g.errors[0].find("SE_ERR_CONTEXT_FULL") != std::string::npos);
  // The session is still usable afterwards.
  json small = chat({msg("user", "Say OK.")});
  small["enable_thinking"] = false;
  small["max_tokens"] = 8;
  g = run(s, small);
  EXPECT(g.finish == SE_FINISH_STOP || g.finish == SE_FINISH_LENGTH);
  se_session_free(s);
}

void test_model_info() {
  const json info = json::parse(model_info(g_m));
  EXPECT_EQ(info["arch"].get<std::string>(), std::string("qwen3"));
  EXPECT_EQ(info["n_layer"].get<int>(), 28);
  EXPECT_EQ(info["n_head_kv"].get<int>(), 8);
  EXPECT_EQ(info["key_length"].get<int>(), 128);
  EXPECT_EQ(info["n_ctx_train"].get<int>(), 40960);
  EXPECT(info["chat_template"]["present"].get<bool>());
  EXPECT_EQ(info["tool_calls"]["support"].get<std::string>(), std::string("native_grammar"));
  EXPECT(info["tool_calls"]["grammar_lazy"].get<bool>());
  EXPECT(info["thinking"]["supported"].get<bool>());
  EXPECT_EQ(info["kv_bytes_per_token"]["q8_0"].get<int64_t>(), 60928);
  EXPECT_EQ(info["kv_bytes_per_token"]["f16"].get<int64_t>(), 114688);
  std::printf("    arch=%s params=%lld size=%lld tool_calls=%s thinking=%s\n", info["arch"].get<std::string>().c_str(),
              (long long) info["n_params"].get<int64_t>(), (long long) info["size_bytes"].get<int64_t>(),
              info["tool_calls"].dump().c_str(), info["thinking"].dump().c_str());
  // Tokenize / count.
  int32_t toks[64];
  const int32_t n = se_tokenize(g_m, "Hello world", -1, 0, 0, toks, 64);
  EXPECT(n >= 2 && n <= 4);
  EXPECT_EQ(se_tokenize(g_m, "Hello world", -1, 0, 0, toks, 1), n);  // count even if it does not fit
  char text[64];
  const int32_t tl = se_detokenize(g_m, toks, n, 0, text, sizeof text);
  EXPECT_EQ(std::string(text, (size_t) tl), std::string("Hello world"));
  const int32_t im_start = se_tokenize(g_m, "<|im_start|>", -1, 0, 1, toks, 64);
  EXPECT_EQ(im_start, 1);
  json req = chat({msg("system", "You are terse."), msg("user", "Hi!")});
  req["enable_thinking"] = false;
  const int32_t counted = se_count_chat_tokens(g_m, req.dump().c_str());
  EXPECT(counted > 10);
  se_session * s = make_session(g_m, [](se_session_params & p) { p.n_ctx = 1024; });
  req["max_tokens"] = 4;
  const Gen g = run(s, req);
  EXPECT_EQ(g.prompt, counted);  // the engine and the counter render identically
  se_session_free(s);
}

void test_memory_estimate() {
  se_session_params sp;
  se_session_params_init(&sp);
  sp.n_ctx = 4096;
  sp.n_threads = g_threads;
  sp.type_k = SE_KV_Q8_0;
  sp.type_v = SE_KV_Q8_0;
  se_memory_estimate est;
  std::memset(&est, 0, sizeof est);
  est.struct_size = sizeof est;
  const auto t0 = Clock::now();
  EXPECT_OK(se_estimate_memory(g_model.c_str(), nullptr, &sp, &est));
  const double est_ms = std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
  // R04 §6: Qwen3-0.6B, q8_0 K+V, n_ctx 4096 = 238 MiB.
  EXPECT_EQ(est.kv_bytes, (uint64_t) 238 * 1024 * 1024);
  EXPECT_EQ(est.n_ctx, 4096u);
  EXPECT_EQ(est.flash_attn, 1);

  const int64_t rss0 = rss_bytes();
  se_model * m = nullptr;
  EXPECT_OK(se_model_load(g_model.c_str(), nullptr, &m));
  se_session * s = nullptr;
  EXPECT_OK(se_session_create(m, &sp, &s));
  json req = chat({msg("user", "Name three colors.")});
  req["max_tokens"] = 16;
  req["enable_thinking"] = false;
  run(s, req);
  const int64_t rss1 = rss_bytes();
  se_memory_estimate act;
  std::memset(&act, 0, sizeof act);
  act.struct_size = sizeof act;
  EXPECT_OK(se_session_memory(s, &act));
  const double mib = 1024.0 * 1024.0;
  const double ratio_alloc = (double) est.total_bytes / (double) act.total_bytes;
  const double ratio_rss   = (double) est.total_bytes / (double) (rss1 - rss0);
  std::printf("    estimate (%.0f ms dry run): model %.1f (mapped %.1f) + kv %.1f + compute %.1f + output %.1f = %.1f MiB\n",
              est_ms, est.model_bytes / mib, est.model_mapped_bytes / mib, est.kv_bytes / mib, est.compute_bytes / mib,
              est.output_bytes / mib, est.total_bytes / mib);
  std::printf("    actual allocation:        model %.1f (mapped %.1f) + kv %.1f + compute %.1f + output %.1f = %.1f MiB\n",
              act.model_bytes / mib, act.model_mapped_bytes / mib, act.kv_bytes / mib, act.compute_bytes / mib,
              act.output_bytes / mib, act.total_bytes / mib);
  std::printf("    RSS delta after load+session+generation: %.1f MiB; estimate/allocation = %.3f, estimate/RSS = %.3f\n",
              (rss1 - rss0) / mib, ratio_alloc, ratio_rss);
  EXPECT(ratio_alloc > 0.85 && ratio_alloc < 1.15);
  EXPECT(ratio_rss > 0.85 && ratio_rss < 1.15);
  se_session_free(s);
  se_model_free(m);
}

void test_plain_chat() {
  se_session * s = make_session(g_m);
  json req = chat({msg("system", "You are a helpful assistant."), msg("user", "Say hello in one short sentence.")});
  req["enable_thinking"] = false;
  req["max_tokens"] = 64;
  const Gen g = run(s, req);
  EXPECT(g.count(SE_EVENT_TEXT_DELTA) >= 2);
  EXPECT_EQ(g.count(SE_EVENT_REASONING_DELTA), 0);
  EXPECT_EQ(g.finish, (int) SE_FINISH_STOP);
  EXPECT_EQ(g.finish_name, std::string("stop"));
  EXPECT(g.errors.empty());
  EXPECT_EQ(g.count(SE_EVENT_USAGE), 1);
  EXPECT_EQ(g.count(SE_EVENT_PERF), 1);
  EXPECT_EQ(g.events.back().type, (int) SE_EVENT_FINISH);
  const json fin = g.final_msg();
  EXPECT_EQ(fin["role"].get<std::string>(), std::string("assistant"));
  EXPECT_EQ(fin["content"].get<std::string>(), g.text);  // deltas add up to the final message
  EXPECT(g.completion > 0 && g.prompt > 0);
  std::printf("    reply: %s\n", g.text.c_str());
  g_bench.push_back({"plain chat, cold", g.ttft, g.prefill_tps, g.decode_tps, 0, g.prompt, g.cached, g.completion});
  se_session_free(s);
}

void test_tool_call() {
  se_session * s = make_session(g_m);
  json req = chat({msg("user", "What's the weather in Paris right now? Use the tool.")});
  req["tools"] = json::array({k_weather_tool});
  req["tool_choice"] = "auto";
  req["enable_thinking"] = false;
  req["max_tokens"] = 128;
  const Gen g = run(s, req);
  EXPECT(g.errors.empty());
  EXPECT_EQ(g.count(SE_EVENT_TOOL_CALL_START), 1);
  EXPECT(g.count(SE_EVENT_TOOL_CALL_ARGS_DELTA) >= 1);
  EXPECT_EQ(g.count(SE_EVENT_TOOL_CALL_DONE), 1);
  EXPECT_EQ(g.finish, (int) SE_FINISH_TOOL_CALLS);
  std::string start_id, args_stream, done_args, done_id;
  int order = 0, start_at = -1, first_args_at = -1, done_at = -1;
  for (auto & e : g.events) {
    ++order;
    if (e.type == SE_EVENT_TOOL_CALL_START) {
      EXPECT_EQ(e.index, 0);
      EXPECT_EQ(e.name, std::string("get_weather"));
      EXPECT(!e.id.empty());
      start_id = e.id;
      start_at = order;
    } else if (e.type == SE_EVENT_TOOL_CALL_ARGS_DELTA) {
      if (first_args_at < 0) first_args_at = order;
      EXPECT_EQ(e.index, 0);
      args_stream += e.text;
    } else if (e.type == SE_EVENT_TOOL_CALL_DONE) {
      done_args = e.text;
      done_id   = e.id;
      done_at   = order;
      EXPECT_EQ(e.name, std::string("get_weather"));
    }
  }
  EXPECT(start_at < first_args_at && first_args_at < done_at);
  EXPECT_EQ(start_id, done_id);
  EXPECT_EQ(args_stream, done_args);
  const json args = json::parse(done_args);  // valid JSON
  EXPECT(args.contains("city"));
  EXPECT(args["city"].get<std::string>().find("Paris") != std::string::npos);
  const json fin = g.final_msg();
  EXPECT_EQ(fin["tool_calls"].size(), 1u);
  EXPECT_EQ(fin["tool_calls"][0]["function"]["name"].get<std::string>(), std::string("get_weather"));
  std::printf("    tool call %s get_weather(%s)\n", done_id.c_str(), done_args.c_str());

  // Round trip: feed the tool result back; the model answers in text.
  json req2 = req;
  req2["messages"].push_back(fin);
  req2["messages"].push_back(json{{"role", "tool"}, {"tool_call_id", done_id}, {"content", R"({"temp_c":21,"sky":"clear"})"}});
  const Gen g2 = run(s, req2);
  EXPECT(g2.errors.empty());
  EXPECT(g2.finish == SE_FINISH_STOP || g2.finish == SE_FINISH_TOOL_CALLS);
  EXPECT(g2.cached > 0);  // the first turn is reused
  std::printf("    after tool result (%d/%d prompt tokens cached): %s\n", g2.cached, g2.prompt, g2.text.c_str());
  se_session_free(s);
}

void test_reasoning() {
  se_session * s = make_session(g_m);
  json req = chat({msg("user", "What is 17 + 25? Answer with the number.")});
  req["enable_thinking"] = true;
  req["max_tokens"] = 400;
  const Gen on = run(s, req);
  EXPECT(on.count(SE_EVENT_REASONING_DELTA) >= 1);
  EXPECT(!on.reasoning.empty());
  EXPECT(on.reasoning.find("<think>") == std::string::npos);  // tags are stripped by the parser
  const json fin = on.final_msg();
  EXPECT_EQ(fin["reasoning_content"].get<std::string>(), on.reasoning);
  std::printf("    thinking on: %d reasoning deltas (%zu chars), answer: %s\n", on.count(SE_EVENT_REASONING_DELTA),
              on.reasoning.size(), on.text.c_str());
  req["enable_thinking"] = false;
  const Gen off = run(s, req);
  EXPECT_EQ(off.count(SE_EVENT_REASONING_DELTA), 0);
  EXPECT(off.count(SE_EVENT_TEXT_DELTA) >= 1);
  EXPECT(off.text.find("42") != std::string::npos);
  std::printf("    thinking off: %s\n", off.text.c_str());
  se_session_free(s);
}

void test_prefix_cache() {
  const std::string sys = long_system_prompt();
  json a = chat({msg("system", sys), msg("user", "Give me one tip for packing a backpack.")});
  a["enable_thinking"] = false;
  a["max_tokens"] = 48;
  se_session * s = make_session(g_m);
  const Gen ga = run(s, a);
  EXPECT_EQ(ga.cached, 0);
  json b = a;
  b["messages"].push_back(json::parse(ga.final_json));
  b["messages"].push_back(msg("user", "And one tip for staying warm?"));
  const Gen gb = run(s, b);
  // Everything up to the previous assistant header is reused (Qwen3 re-renders the assistant turn without
  // the empty think block, so a few tokens after it differ).
  EXPECT(gb.cached >= ga.prompt - 8);
  EXPECT(gb.cached <= gb.prompt - 1);

  // The same request on a cold session.
  se_session * cold = make_session(g_m);
  const Gen gc = run(cold, b);
  EXPECT_EQ(gc.cached, 0);
  EXPECT_EQ(gc.text, gb.text);  // greedy: cache reuse does not change the output
  EXPECT(gb.ttft < gc.ttft);
  std::printf("    turn 1: %d prompt tokens, ttft %.1f ms | turn 2: %d/%d cached, ttft %.1f ms (cold: %.1f ms)\n",
              ga.prompt, ga.ttft, gb.cached, gb.prompt, gb.ttft, gc.ttft);
  g_bench.push_back({"long prompt, cold", gc.ttft, gc.prefill_tps, gc.decode_tps, 0, gc.prompt, gc.cached, gc.completion});
  g_bench.push_back({"long prompt, prefix cache", gb.ttft, gb.prefill_tps, gb.decode_tps, 0, gb.prompt, gb.cached, gb.completion});

  // cache_prompt = false forces a full prefill.
  json nb = b;
  nb["cache_prompt"] = false;
  const Gen gn = run(s, nb);
  EXPECT_EQ(gn.cached, 0);
  EXPECT_EQ(gn.text, gb.text);
  // se_session_reset drops the cache.
  EXPECT_OK(se_session_reset(s));
  const Gen gr = run(s, a);
  EXPECT_EQ(gr.cached, 0);
  EXPECT_EQ(gr.text, ga.text);
  se_session_free(cold);
  se_session_free(s);
}

void test_state_roundtrip() {
  const std::string path = g_tmp + "/sherpa-test.state";
  json a = chat({msg("system", long_system_prompt()), msg("user", "Name a mountain in Nepal.")});
  a["enable_thinking"] = false;
  a["max_tokens"] = 32;
  se_session * s1 = make_session(g_m);
  const Gen ga = run(s1, a);
  EXPECT_OK(se_state_save(s1, path.c_str()));
  json b = a;
  b["messages"].push_back(json::parse(ga.final_json));
  b["messages"].push_back(msg("user", "How tall is it, roughly?"));
  b["max_tokens"] = 48;
  const Gen uninterrupted = run(s1, b);

  se_session * s2 = make_session(g_m);
  int32_t n = 0;
  EXPECT_OK(se_state_load(s2, path.c_str(), &n));
  EXPECT(n >= ga.prompt);
  const Gen restored = run(s2, b);
  EXPECT_EQ(restored.text, uninterrupted.text);  // bit-identical continuation (greedy)
  EXPECT_EQ(restored.cached, uninterrupted.cached);
  EXPECT(restored.cached > 0);
  std::printf("    state: %d tokens restored, continuation identical (%d cached): %s\n", n, restored.cached,
              restored.text.c_str());

  // Mismatches are refused before llama.cpp sees the bytes; the session stays usable.
  se_session * s3 = make_session(g_m, [](se_session_params & p) { p.type_k = SE_KV_Q8_0; p.type_v = SE_KV_Q8_0; });
  EXPECT_EQ(se_state_load(s3, path.c_str(), &n), SE_ERR_STATE_MISMATCH);
  EXPECT(std::string(se_last_error()).find("type_k") != std::string::npos);
  se_session_free(s3);
  se_model_params mp;
  se_model_params_init(&mp);
  mp.model_id = "sha256:another-model";
  se_model * other = nullptr;
  EXPECT_OK(se_model_load(g_model.c_str(), &mp, &other));
  se_session * s4 = make_session(other);
  EXPECT_EQ(se_state_load(s4, path.c_str(), &n), SE_ERR_STATE_MISMATCH);
  EXPECT(std::string(se_last_error()).find("model_id") != std::string::npos);
  se_session_free(s4);
  se_model_free(other);
  se_session * s5 = make_session(g_m, [](se_session_params & p) { p.n_ctx = 256; });
  EXPECT_EQ(se_state_load(s5, path.c_str(), &n), SE_ERR_STATE_MISMATCH);  // does not fit
  se_session_free(s5);
  // Corrupt file.
  {
    std::fstream f(path, std::ios::in | std::ios::out | std::ios::binary);
    f.seekp(0);
    f.write("XXXX", 4);
  }
  EXPECT_EQ(se_state_load(s2, path.c_str(), &n), SE_ERR_STATE_MISMATCH);
  EXPECT_EQ(se_state_load(s2, "/nonexistent.state", &n), SE_ERR_IO);
  std::remove(path.c_str());
  se_session_free(s1);
  se_session_free(s2);
}

void test_cancel() {
  se_session * s = make_session(g_m);
  json req = chat({msg("user", "Write a very long story about a sherpa crossing the Himalaya. At least 2000 words.")});
  req["enable_thinking"] = false;
  req["max_tokens"] = 3000;
  EXPECT_OK(se_generate_start(s, req.dump().c_str(), nullptr));
  Clock::time_point t_cancel;
  bool cancelled = false;
  const Gen g = drain(s, 0, 0, [&](Gen & gg, const se_event &) {
    if (!cancelled && gg.count(SE_EVENT_TEXT_DELTA) >= 10) {
      cancelled = true;
      t_cancel = Clock::now();
      se_cancel(s);
    }
  });
  const double ms = std::chrono::duration<double, std::milli>(Clock::now() - t_cancel).count();
  EXPECT(cancelled);
  EXPECT_EQ(g.finish, (int) SE_FINISH_CANCELLED);
  EXPECT_EQ(g.finish_name, std::string("cancelled"));
  EXPECT(ms < 200.0);
  EXPECT_EQ(json::parse(g.final_json)["content"].get<std::string>(), g.text);
  std::printf("    cancel during decode -> FINISH(cancelled) in %.1f ms after %d tokens\n", ms, g.completion);

  // Cancel during a long prefill: the abort callback stops llama_decode mid-chunk.
  se_session * s2 = make_session(g_m, [](se_session_params & p) { p.n_batch = 2048; p.n_ubatch = 512; });
  std::string longp = long_system_prompt() + long_system_prompt() + long_system_prompt();
  json r2 = chat({msg("system", longp), msg("user", "Summarise the rules.")});
  r2["enable_thinking"] = false;
  EXPECT_OK(se_generate_start(s2, r2.dump().c_str(), nullptr));
  std::this_thread::sleep_for(std::chrono::milliseconds(150));
  const auto t2 = Clock::now();
  EXPECT_OK(se_cancel(s2));
  const Gen g2 = drain(s2);
  const double ms2 = std::chrono::duration<double, std::milli>(Clock::now() - t2).count();
  EXPECT_EQ(g2.finish, (int) SE_FINISH_CANCELLED);
  EXPECT(ms2 < 200.0);
  std::printf("    cancel during prefill (%d prompt tokens) -> FINISH(cancelled) in %.1f ms\n", g2.prompt, ms2);
  // Work done before the cancel is kept: the next run reuses the decoded prefix.
  r2["max_tokens"] = 4;
  const Gen g3 = run(s2, r2);
  EXPECT(g3.cached > 0);
  std::printf("    after the cancelled prefill, %d/%d prompt tokens were reused\n", g3.cached, g3.prompt);
  se_session_free(s2);
  se_session_free(s);
}

void test_backpressure() {
  // 8-slot ring, consumer takes 1 event every 20 ms: the worker must block, never drop.
  se_session * s = make_session(g_m, [](se_session_params & p) { p.event_capacity = 8; });
  json req = chat({msg("user", "List the planets of the solar system, one per line.")});
  req["enable_thinking"] = false;
  req["max_tokens"] = 64;
  const Gen slow = run(s, req, 20, 1);
  EXPECT_EQ(slow.n_finish, 1);
  EXPECT_EQ(slow.final_msg()["content"].get<std::string>(), slow.text);
  EXPECT_OK(se_session_reset(s));
  const Gen fast = run(s, req);
  EXPECT_EQ(fast.text, slow.text);
  EXPECT_EQ(fast.events.size(), slow.events.size());
  std::printf("    slow consumer received all %zu events (%d tokens)\n", slow.events.size(), slow.completion);

  // Callback delivery (+ queue) sees the same stream.
  std::vector<int> types;
  EXPECT_OK(se_set_event_callback(s, [](const se_event * e, void * u) {
    static_cast<std::vector<int> *>(u)->push_back(e->type);
  }, &types, 1));
  EXPECT_OK(se_session_reset(s));
  const Gen cbq = run(s, req);
  EXPECT_EQ(types.size(), cbq.events.size());
  EXPECT_EQ(cbq.text, fast.text);
  EXPECT_OK(se_set_event_callback(s, nullptr, nullptr, 0));
  se_session_free(s);
}

void test_kv_quant() {
  se_session * s = make_session(g_m, [](se_session_params & p) { p.type_k = SE_KV_Q8_0; p.type_v = SE_KV_Q8_0; });
  const json info = json::parse(session_info(s));
  EXPECT_EQ(info["type_k"].get<std::string>(), std::string("q8_0"));
  EXPECT_EQ(info["flash_attn"].get<int>(), 1);  // forced on by the quantized V cache
  json req = chat({msg("user", "What is the capital of France? One word.")});
  req["enable_thinking"] = false;
  req["max_tokens"] = 16;
  const Gen g = run(s, req);
  EXPECT_EQ(g.finish, (int) SE_FINISH_STOP);
  EXPECT(g.text.find("Paris") != std::string::npos);
  std::printf("    q8_0 KV (flash attention %d): %s | memory: %s\n", info["flash_attn"].get<int>(), g.text.c_str(),
              info["memory"].dump().c_str());
  se_session_free(s);
  // q8_0 K with f16 V works without flash attention (only V must not be quantized then).
  s = make_session(g_m, [](se_session_params & p) { p.type_k = SE_KV_Q8_0; p.flash_attn = 0; });
  const Gen g2 = run(s, req);
  EXPECT_EQ(g2.finish, (int) SE_FINISH_STOP);
  se_session_free(s);
}

void test_speculative() {
  const std::string payload = R"({"city": "Paris", "temp_c": 21, "wind": "NW 12 km/h", "sky": "clear", "humidity": 40})";
  json req = chat({msg("user", "Copy this JSON exactly three times, one copy per line, nothing else:\n" + payload)});
  req["enable_thinking"] = false;
  req["max_tokens"] = 160;
  se_session * base = make_session(g_m);
  const Gen g0 = run(base, req);
  se_session * spec = make_session(g_m, [](se_session_params & p) {
    p.spec_type = SE_SPEC_NGRAM_MOD;
    p.spec_n_max = 16;
    p.spec_n_min = 2;
    p.spec_ngram_n_match = 8;
  });
  const json info = json::parse(session_info(spec));
  EXPECT_EQ(info["n_outputs_max"].get<int>(), 17);
  const Gen g1 = run(spec, req);
  EXPECT_EQ(g1.text, g0.text);  // greedy verification keeps the output identical
  EXPECT(g1.drafted > 0);
  EXPECT(g1.accepted > 0);
  EXPECT(g1.accept_rate > 0.0);
  std::printf("    ngram-mod: drafted %d, accepted %d (%.0f%%); decode %.1f -> %.1f tok/s\n", g1.drafted, g1.accepted,
              100.0 * g1.accept_rate, g0.decode_tps, g1.decode_tps);
  g_bench.push_back({"repetitive JSON, no speculation", g0.ttft, g0.prefill_tps, g0.decode_tps, 0, g0.prompt, g0.cached, g0.completion});
  g_bench.push_back({"repetitive JSON, ngram-mod", g1.ttft, g1.prefill_tps, g1.decode_tps, g1.accept_rate, g1.prompt, g1.cached, g1.completion});

  // Per-request opt-out.
  json off = req;
  off["speculative"] = false;
  EXPECT_OK(se_session_reset(spec));
  const Gen g2 = run(spec, off);
  EXPECT_EQ(g2.drafted, 0);
  EXPECT_EQ(g2.text, g0.text);

  // Prose with few repeats: acceptance stays low and the auto-disable keeps the output identical.
  json prose = chat({msg("user", "Write four sentences about mountain weather.")});
  prose["enable_thinking"] = false;
  prose["max_tokens"] = 96;
  const Gen p0 = run(base, prose);
  EXPECT_OK(se_session_reset(spec));
  const Gen p1 = run(spec, prose);
  EXPECT_EQ(p1.text, p0.text);
  g_bench.push_back({"prose, no speculation", p0.ttft, p0.prefill_tps, p0.decode_tps, 0, p0.prompt, p0.cached, p0.completion});
  g_bench.push_back({"prose, ngram-mod", p1.ttft, p1.prefill_tps, p1.decode_tps, p1.accept_rate, p1.prompt, p1.cached, p1.completion});
  std::printf("    prose: drafted %d accepted %d; info %s\n", p1.drafted, p1.accepted,
              json::parse(session_info(spec))["speculative"].dump().c_str());
  se_session_free(spec);
  se_session_free(base);
}

void test_lora() {
  if (g_lora.empty()) {
    std::printf("    (skipped: no --lora adapter)\n");
    return;
  }
  se_lora * l = nullptr;
  EXPECT_OK(se_lora_load(g_m, g_lora.c_str(), &l));
  se_session * s = make_session(g_m);
  json req = chat({msg("user", "Describe the color blue in one sentence.")});
  req["enable_thinking"] = false;
  req["max_tokens"] = 24;
  const Gen base = run(s, req);
  float scale = 4.0f;
  EXPECT_OK(se_session_set_loras(s, &l, &scale, 1));
  EXPECT_EQ(json::parse(session_info(s))["loras"].size(), 1u);
  const Gen with = run(s, req);
  EXPECT_EQ(with.cached, 0);  // a new adapter set invalidates the prompt cache
  EXPECT(with.text != base.text);
  // Same set again: no invalidation.
  EXPECT_OK(se_session_set_loras(s, &l, &scale, 1));
  const Gen again = run(s, req);
  EXPECT(again.cached > 0);
  EXPECT_EQ(again.text, with.text);
  // Back to the base model, no reload.
  EXPECT_OK(se_session_set_loras(s, nullptr, nullptr, 0));
  const Gen back = run(s, req);
  EXPECT_EQ(back.text, base.text);
  // Freeing the handle while a session uses it is safe; the adapter stays alive until it is replaced.
  EXPECT_OK(se_session_set_loras(s, &l, &scale, 1));
  se_lora_free(l);
  const Gen still = run(s, req);
  EXPECT_EQ(still.text, with.text);
  std::printf("    base: %s\n    lora x4: %s\n", base.text.c_str(), with.text.c_str());
  se_session_free(s);
}

void test_handles_lifetime() {
  // Free the model before its session: the session keeps the weights alive.
  se_model * m = nullptr;
  EXPECT_OK(se_model_load(g_model.c_str(), nullptr, &m));
  se_session * s = make_session(m);
  se_model_free(m);
  json req = chat({msg("user", "Say yes.")});
  req["enable_thinking"] = false;
  req["max_tokens"] = 4;
  EXPECT(!run(s, req).text.empty());
  // Free a session in the middle of a generation: cancels and joins.
  req["max_tokens"] = 500;
  EXPECT_OK(se_generate_start(s, req.dump().c_str(), nullptr));
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  se_session_free(s);
  // vocab-only model: tokenization and counting work, sessions are refused.
  se_model_params mp;
  se_model_params_init(&mp);
  mp.vocab_only = 1;
  EXPECT_OK(se_model_load(g_model.c_str(), &mp, &m));
  EXPECT(se_count_chat_tokens(m, chat({msg("user", "hello")}).dump().c_str()) > 0);
  se_session_params sp;
  se_session_params_init(&sp);
  EXPECT_EQ(se_session_create(m, &sp, &s), SE_ERR_UNSUPPORTED);
  se_model_free(m);
}

void test_bench_api() {
  se_bench_params bp;
  se_bench_params_init(&bp);
  bp.n_threads = g_threads;
  bp.n_prompt = 256;
  bp.n_gen = 32;
  bp.n_reps = 2;
  se_bench_result r;
  std::memset(&r, 0, sizeof r);
  r.struct_size = sizeof r;
  EXPECT_OK(se_bench(g_m, &bp, &r));
  EXPECT(r.pp_tps > 0 && r.tg_tps > 0);
  std::printf("    se_bench: pp256 %.1f tok/s, tg32 %.1f tok/s (%d threads)\n", r.pp_tps, r.tg_tps, r.n_threads);
  g_bench.push_back({"se_bench pp256/tg32", 0, r.pp_tps, r.tg_tps, 0, 256, 0, 32});
  bp.type_k = SE_KV_Q8_0;
  bp.type_v = SE_KV_Q8_0;
  EXPECT_OK(se_bench(g_m, &bp, &r));
  std::printf("    se_bench q8_0 KV: pp256 %.1f tok/s, tg32 %.1f tok/s\n", r.pp_tps, r.tg_tps);
  g_bench.push_back({"se_bench pp256/tg32, q8_0 KV", 0, r.pp_tps, r.tg_tps, 0, 256, 0, 32});
  se_canceller * c = se_canceller_create();
  se_canceller_cancel(c);
  bp.cancel = c;
  EXPECT_EQ(se_bench(g_m, &bp, &r), SE_ERR_CANCELLED);
  se_canceller_free(c);
}

struct Test {
  const char * name;
  void (*fn)();
};

}  // namespace

int main(int argc, char ** argv) {
  for (int i = 1; i < argc; ++i) {
    const std::string a = argv[i];
    auto next = [&] { return i + 1 < argc ? std::string(argv[++i]) : std::string(); };
    if (a == "--model") g_model = next();
    else if (a == "--lora") g_lora = next();
    else if (a == "--threads") g_threads = std::stoi(next());
    else if (a == "--filter") g_filter = next();
    else if (a == "--tmp") g_tmp = next();
    else if (a == "--bench-json") g_bench_json = next();
  }
  if (g_model.empty()) {
    std::fprintf(stderr, "usage: %s --model model.gguf [--lora adapter.gguf] [--threads N] [--filter name]\n", argv[0]);
    return 2;
  }
  se_init_params ip;
  se_init_params_init(&ip);
  ip.log_cb = log_cb;
  ip.log_level = SE_LOG_WARN;
  ip.crash_breadcrumb_path = "/tmp/sherpa-engine-crash.txt";
  if (se_backend_init(&ip) != SE_OK) return 2;

  const auto t_load = Clock::now();
  se_model_params mp;
  se_model_params_init(&mp);
  int progress_calls = 0;
  mp.progress_cb = [](float, void * u) -> int32_t { ++*static_cast<int *>(u); return 1; };
  mp.progress_user = &progress_calls;
  if (se_model_load(g_model.c_str(), &mp, &g_m) != SE_OK) {
    std::fprintf(stderr, "model load failed: %s\n", se_last_error());
    return 2;
  }
  std::printf("model loaded in %.0f ms (%d progress callbacks)\n",
              std::chrono::duration<double, std::milli>(Clock::now() - t_load).count(), progress_calls);

  const Test tests[] = {
      {"abi_version", test_abi_version},       {"error_paths", test_error_paths},
      {"model_info", test_model_info},         {"memory_estimate", test_memory_estimate},
      {"plain_chat", test_plain_chat},         {"tool_call", test_tool_call},
      {"reasoning", test_reasoning},           {"prefix_cache", test_prefix_cache},
      {"state_roundtrip", test_state_roundtrip}, {"cancel", test_cancel},
      {"backpressure", test_backpressure},     {"kv_quant", test_kv_quant},
      {"speculative", test_speculative},       {"lora", test_lora},
      {"handles_lifetime", test_handles_lifetime}, {"bench_api", test_bench_api},
  };
  for (const auto & t : tests) {
    if (!g_filter.empty() && std::string(t.name).find(g_filter) == std::string::npos) continue;
    std::printf("[ RUN  ] %s\n", t.name);
    std::fflush(stdout);
    const auto t0 = Clock::now();
    try {
      t.fn();
      ++g_passed;
      std::printf("[ PASS ] %s (%.0f ms)\n", t.name, std::chrono::duration<double, std::milli>(Clock::now() - t0).count());
    } catch (const std::exception & e) {
      ++g_failed;
      g_failures.push_back(t.name);
      std::printf("[ FAIL ] %s: %s\n", t.name, e.what());
    }
    std::fflush(stdout);
  }
  se_model_free(g_m);

  if (!g_bench.empty()) {
    std::printf("\nBenchmark (host, %d threads; Qwen3-0.6B-Q4_K_M; noisy shared CPU - use for ratios):\n", g_threads);
    std::printf("| %-34s | %8s | %8s | %11s | %10s | %7s | %13s |\n", "scenario", "prompt", "cached", "TTFT ms",
                "prefill t/s", "decode t/s", "draft accept");
    std::printf("|%s|%s|%s|%s|%s|%s|%s|\n", std::string(36, '-').c_str(), std::string(10, '-').c_str(),
                std::string(10, '-').c_str(), std::string(13, '-').c_str(), std::string(12, '-').c_str(),
                std::string(9, '-').c_str(), std::string(15, '-').c_str());
    json bj = json::array();
    for (const auto & b : g_bench) {
      std::printf("| %-34s | %8d | %8d | %11.1f | %10.1f | %7.1f | %12.0f%% |\n", b.name.c_str(), b.prompt, b.cached,
                  b.ttft_ms, b.prefill_tps, b.decode_tps, 100.0 * b.accept);
      bj.push_back({{"scenario", b.name}, {"prompt", b.prompt}, {"cached", b.cached}, {"ttft_ms", b.ttft_ms},
                    {"prefill_tps", b.prefill_tps}, {"decode_tps", b.decode_tps}, {"draft_accept", b.accept}});
    }
    if (!g_bench_json.empty()) std::ofstream(g_bench_json) << bj.dump(2) << "\n";
  }
  std::printf("\n%d passed, %d failed\n", g_passed, g_failed);
  for (auto & f : g_failures) std::printf("  failed: %s\n", f.c_str());
  return g_failed == 0 ? 0 : 1;
}
