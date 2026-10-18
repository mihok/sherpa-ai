// Chat generation: OpenAI-style request -> common_chat_templates_apply -> prompt-cache reuse -> chunked,
// cancellable prefill -> (speculative) decode loop -> incremental common_chat_parse + compute_diffs ->
// typed events. The request mapping follows tools/server/server-common.cpp:1224-1450 (R04 §17).
#include "se_internal.h"

#include <algorithm>
#include <cmath>
#include <string_view>

namespace se {

// =========================================================================================================
// Request parsing (synchronous, so malformed requests fail in se_generate_start)
// =========================================================================================================

namespace {

const common_json * opt(const common_json & j, const char * key) {
  if (!j.contains(key)) return nullptr;
  const common_json & v = j.at(key);
  return v.is_null() ? nullptr : &v;
}

double num(const common_json & j, const char * key, double def) {
  const common_json * v = opt(j, key);
  if (!v) return def;
  if (!v->is_number()) fail(SE_ERR_INVALID_ARG, std::string("'") + key + "' must be a number");
  const double d = v->get<double>();
  if (!std::isfinite(d)) fail(SE_ERR_INVALID_ARG, std::string("'") + key + "' must be finite");
  return d;
}

int64_t integer(const common_json & j, const char * key, int64_t def) {
  const common_json * v = opt(j, key);
  if (!v) return def;
  if (!v->is_number()) fail(SE_ERR_INVALID_ARG, std::string("'") + key + "' must be an integer");
  return v->get<long long>();
}

bool boolean(const common_json & j, const char * key, bool def) {
  const common_json * v = opt(j, key);
  if (!v) return def;
  if (!v->is_boolean()) fail(SE_ERR_INVALID_ARG, std::string("'") + key + "' must be a boolean");
  return v->get<bool>();
}

}  // namespace

ChatRequest parse_chat_request(const ModelImpl & m, const char * json) {
  if (!m.tmpls) fail(SE_ERR_TEMPLATE, "model has no usable chat template: " + m.tmpl_error);
  const common_json body = parse_json_object(json, "request");
  ChatRequest r;
  common_chat_templates_inputs & in = r.inputs;

  const common_json * msgs = opt(body, "messages");
  if (!msgs || !msgs->is_array() || msgs->empty()) fail(SE_ERR_INVALID_ARG, "'messages' must be a non-empty array");
  try {
    in.messages = common_chat_msgs_parse_oaicompat(*msgs);
  } catch (const std::exception & e) {
    fail(SE_ERR_INVALID_ARG, e.what());
  }
  if (const common_json * tools = opt(body, "tools")) {
    try {
      in.tools = common_chat_tools_parse_oaicompat(*tools);
    } catch (const std::exception & e) {
      fail(SE_ERR_INVALID_ARG, e.what());
    }
  }
  in.tool_choice = COMMON_CHAT_TOOL_CHOICE_AUTO;
  if (const common_json * tc = opt(body, "tool_choice")) {
    if (tc->is_string()) {
      try {
        in.tool_choice = common_chat_tool_choice_parse_oaicompat(tc->get<std::string>());
      } catch (const std::exception & e) {
        fail(SE_ERR_INVALID_ARG, e.what());
      }
    } else if (tc->is_object() && tc->contains("function") && tc->at("function").contains("name")) {
      // OpenAI's forced-function form: keep only that tool and require a call.
      const std::string name = tc->at("function").at("name").get<std::string>();
      std::vector<common_chat_tool> keep;
      for (const auto & t : in.tools) if (t.name == name) keep.push_back(t);
      if (keep.empty()) fail(SE_ERR_INVALID_ARG, "tool_choice names unknown tool '" + name + "'");
      in.tools       = keep;
      in.tool_choice = COMMON_CHAT_TOOL_CHOICE_REQUIRED;
    } else {
      fail(SE_ERR_INVALID_ARG, "invalid 'tool_choice'");
    }
  }
  std::map<std::string, bool> caps;
  if (m.tmpls) caps = common_chat_templates_get_caps(m.tmpls.get());
  in.parallel_tool_calls   = boolean(body, "parallel_tool_calls", caps["supports_parallel_tool_calls"]);
  in.add_generation_prompt = boolean(body, "add_generation_prompt", true);
  if (const common_json * c = opt(body, "continue_final_message")) {
    in.continue_final_message = common_chat_continuation_parse(*c);
    if (in.continue_final_message != COMMON_CHAT_CONTINUATION_NONE) in.add_generation_prompt = false;
  }

  // Reasoning: the split into reasoning_content is generated into the PEG parser at *apply* time; setting
  // it only on the parser params has no effect (R04 §12, PROBE-2). DEEPSEEK also streams reasoning deltas.
  in.reasoning_format = COMMON_REASONING_FORMAT_DEEPSEEK;
  if (const common_json * rf = opt(body, "reasoning_format")) {
    try {
      in.reasoning_format = common_reasoning_format_from_name(rf->get<std::string>());
    } catch (const std::exception & e) {
      fail(SE_ERR_INVALID_ARG, e.what());
    }
  }
  in.enable_thinking = boolean(body, "enable_thinking", true);
  if (const common_json * kw = opt(body, "chat_template_kwargs")) {
    if (!kw->is_object()) fail(SE_ERR_INVALID_ARG, "'chat_template_kwargs' must be an object");
    for (const auto & item : kw->items()) {
      in.chat_template_kwargs[item.key()] = item.value().dump();
    }
    auto it = in.chat_template_kwargs.find("enable_thinking");
    if (it != in.chat_template_kwargs.end()) {
      if (it->second == "true") in.enable_thinking = true;
      else if (it->second == "false") in.enable_thinking = false;
      else fail(SE_ERR_INVALID_ARG, "chat_template_kwargs.enable_thinking must be a boolean");
    }
  }
  if (const common_json * re = opt(body, "reasoning_effort")) {
    const std::string effort = re->get<std::string>();
    if (effort == "none") {
      in.enable_thinking = false;
      in.chat_template_kwargs.erase("reasoning_effort");
    } else if (!effort.empty()) {
      in.chat_template_kwargs["reasoning_effort"] = common_json(effort).dump();
    }
  }
  r.reasoning_budget = (int32_t) integer(body, "reasoning_budget_tokens", integer(body, "thinking_budget_tokens", -1));

  // Structured output.
  common_json schema;
  bool has_schema = false;
  if (const common_json * js = opt(body, "json_schema")) {
    schema = *js;
    has_schema = true;
  }
  if (const common_json * rfmt = opt(body, "response_format")) {
    const std::string type = rfmt->value("type", std::string());
    if (type == "json_object") {
      schema = rfmt->contains("schema") ? rfmt->at("schema") : common_json::object();
      has_schema = true;
    } else if (type == "json_schema") {
      const common_json wrapper = rfmt->value("json_schema", common_json::object());
      schema = wrapper.value("schema", common_json::object());
      has_schema = true;
    } else if (!type.empty() && type != "text") {
      fail(SE_ERR_INVALID_ARG, "response_format type must be text, json_object or json_schema");
    }
  }
  if (has_schema) {
    if (schema.is_object() && schema.empty()) schema["type"] = "object";  // "any object", like the server
    in.json_schema = schema.dump();
  }
  if (const common_json * g = opt(body, "grammar")) {
    in.grammar = g->get<std::string>();
  }
  if (!in.grammar.empty() && !in.json_schema.empty()) fail(SE_ERR_INVALID_ARG, "use either 'grammar' or a JSON schema");
  r.tools_active = !in.tools.empty() && in.tool_choice != COMMON_CHAT_TOOL_CHOICE_NONE;
  if (r.tools_active && (!in.grammar.empty() || !in.json_schema.empty())) {
    // common_chat_templates_apply throws "Cannot specify grammar with tools" (common/chat.cpp:1305-1309).
    fail(SE_ERR_INVALID_ARG, "tools cannot be combined with 'grammar' or a JSON schema");
  }
  r.grammar_type = r.tools_active ? COMMON_GRAMMAR_TYPE_TOOL_CALLS
                 : !in.json_schema.empty() ? COMMON_GRAMMAR_TYPE_OUTPUT_FORMAT
                 : !in.grammar.empty() ? COMMON_GRAMMAR_TYPE_USER : COMMON_GRAMMAR_TYPE_NONE;

  // Sampling.
  common_params_sampling & sp = r.sampling;
  sp.no_perf          = true;
  sp.temp             = (float) num(body, "temperature", sp.temp);
  sp.top_k            = (int32_t) integer(body, "top_k", sp.top_k);
  sp.top_p            = (float) num(body, "top_p", sp.top_p);
  sp.min_p            = (float) num(body, "min_p", sp.min_p);
  sp.typ_p            = (float) num(body, "typical_p", sp.typ_p);
  sp.penalty_repeat   = (float) num(body, "repeat_penalty", num(body, "repetition_penalty", sp.penalty_repeat));
  sp.penalty_present  = (float) num(body, "presence_penalty", sp.penalty_present);
  sp.penalty_freq     = (float) num(body, "frequency_penalty", sp.penalty_freq);
  sp.penalty_last_n   = (int32_t) integer(body, "penalty_last_n", sp.penalty_last_n);
  sp.dry_multiplier   = (float) num(body, "dry_multiplier", sp.dry_multiplier);
  sp.dry_base         = (float) num(body, "dry_base", sp.dry_base);
  sp.dry_allowed_length = (int32_t) integer(body, "dry_allowed_length", sp.dry_allowed_length);
  sp.dry_penalty_last_n = (int32_t) integer(body, "dry_penalty_last_n", sp.dry_penalty_last_n);
  sp.xtc_probability  = (float) num(body, "xtc_probability", sp.xtc_probability);
  sp.xtc_threshold    = (float) num(body, "xtc_threshold", sp.xtc_threshold);
  sp.top_n_sigma      = (float) num(body, "top_n_sigma", sp.top_n_sigma);
  sp.min_keep         = (int32_t) integer(body, "min_keep", sp.min_keep);
  // common_sampler_init throws std::invalid_argument for these (common/sampling.cpp:190-200).
  if (sp.penalty_repeat <= 0.0f) fail(SE_ERR_INVALID_ARG, "repeat_penalty must be > 0");
  if (sp.top_p < 0.0f || sp.top_p > 1.0f || sp.min_p < 0.0f || sp.min_p > 1.0f) fail(SE_ERR_INVALID_ARG, "top_p/min_p must be in [0, 1]");
  if (sp.penalty_last_n < -1 || sp.dry_penalty_last_n < -1) fail(SE_ERR_INVALID_ARG, "penalty windows must be >= -1");
  if (const common_json * seed = opt(body, "seed")) {
    if (!seed->is_number()) fail(SE_ERR_INVALID_ARG, "'seed' must be an integer");
    sp.seed     = (uint32_t) seed->get<long long>();
    r.has_seed  = true;
  }

  r.max_tokens = (int32_t) integer(body, "max_tokens", integer(body, "max_completion_tokens", integer(body, "n_predict", -1)));
  if (r.max_tokens < -1) fail(SE_ERR_INVALID_ARG, "max_tokens must be >= -1");
  if (r.max_tokens == 0) fail(SE_ERR_INVALID_ARG, "max_tokens must be >= 1 (or -1 for no limit)");
  if (const common_json * st = opt(body, "stop")) {
    if (st->is_string()) {
      r.stop.push_back(st->get<std::string>());
    } else if (st->is_array()) {
      for (const auto & s : *st) r.stop.push_back(s.get<std::string>());
    } else {
      fail(SE_ERR_INVALID_ARG, "'stop' must be a string or an array of strings");
    }
  }
  r.stop.erase(std::remove(r.stop.begin(), r.stop.end(), std::string()), r.stop.end());
  r.cache_prompt = boolean(body, "cache_prompt", true);
  r.speculative  = boolean(body, "speculative", true);
  return r;
}

// =========================================================================================================
// Generation
// =========================================================================================================

namespace {

// Turns successive (partial) parses into typed events.
struct Emitter {
  SessionImpl &            S;
  uint32_t                 gen_id;
  common_chat_msg          prev;          // the state already turned into events
  std::vector<std::string> ids_cache;     // stable tool-call ids across partial parses
  struct ToolCall {
    bool        started = false;
    std::string id, name, pending;        // arguments seen before START was emitted
  };
  std::vector<ToolCall>    calls;

  void send(int32_t type, std::string text = {}, int32_t index = -1, std::string id = {}, std::string name = {}) {
    Event e;
    e.ev.type          = type;
    e.ev.index         = index;
    e.text             = std::move(text);
    e.id               = std::move(id);
    e.name             = std::move(name);
    S.emit(std::move(e));
  }

  void update(common_chat_msg msg, bool final) {
    msg.set_tool_call_ids(ids_cache, [this] { return "call_" + random_id(S.rng, 24); });
    std::vector<common_chat_msg_diff> diffs;
    try {
      diffs = common_chat_msg_diff::compute_diffs(prev, msg);
    } catch (const std::exception & e) {
      // compute_diffs throws when a later parse is not an extension of the earlier one (common/chat.cpp:
      // 57-70, 286-298). Keep the last emitted state and retry on the next token; FINISH carries the
      // authoritative final message either way.
      log(SE_LOG_DEBUG, "skipping non-monotonic partial parse: %s\n", e.what());
      if (!final) return;
    }
    for (auto & d : diffs) {
      if (!d.reasoning_content_delta.empty()) send(SE_EVENT_REASONING_DELTA, d.reasoning_content_delta);
      if (!d.content_delta.empty()) send(SE_EVENT_TEXT_DELTA, d.content_delta);
      if (d.tool_call_index == std::string::npos) continue;
      const size_t idx = d.tool_call_index;
      if (calls.size() <= idx) calls.resize(idx + 1);
      ToolCall & tc = calls[idx];
      if (!d.tool_call_delta.name.empty()) tc.name = d.tool_call_delta.name;
      if (!d.tool_call_delta.id.empty()) tc.id = d.tool_call_delta.id;
      if (tc.started) {
        if (!d.tool_call_delta.arguments.empty()) send(SE_EVENT_TOOL_CALL_ARGS_DELTA, d.tool_call_delta.arguments, (int32_t) idx, tc.id);
      } else {
        tc.pending += d.tool_call_delta.arguments;
      }
    }
    // Like the server, hold START until the arguments begin: before that the name may still be growing.
    for (size_t i = 0; i < calls.size(); ++i) {
      ToolCall & tc = calls[i];
      if (!tc.started && !tc.name.empty() && (!tc.pending.empty() || final)) {
        tc.started = true;
        send(SE_EVENT_TOOL_CALL_START, {}, (int32_t) i, tc.id, tc.name);
        if (!tc.pending.empty()) send(SE_EVENT_TOOL_CALL_ARGS_DELTA, std::move(tc.pending), (int32_t) i, tc.id);
        tc.pending.clear();
      }
    }
    prev = std::move(msg);
  }
};

size_t find_stop(const std::string & text, size_t from, const std::vector<std::string> & stops) {
  size_t best = std::string::npos;
  for (const auto & s : stops) {
    const size_t start = from > s.size() ? from - s.size() : 0;
    const size_t p     = text.find(s, start);
    if (p != std::string::npos && p < best) best = p;
  }
  return best;
}

}  // namespace

void SessionImpl::run_generation(uint32_t gen_id, ChatRequest & req) {
  const auto t0 = Clock::now();
  cur_gen = gen_id;
  Emitter    out{*this, gen_id, {}, {}, {}};
  se_status  err = SE_OK;
  std::string err_msg;
  int32_t    finish = SE_FINISH_STOP;
  int32_t    n_prompt = 0, n_cached = 0, n_gen = 0, n_prefilled = 0;
  int64_t    drafted = 0, accepted = 0;
  double     ttft_ms = 0, prefill_ms = 0, decode_ms = 0;
  Clock::time_point t_prefill0 = t0, t_first = t0;
  bool       have_first = false;
  std::string text;
  common_chat_parser_params pp;
  bool       parser_ready = false;
  llama_memory_t mem  = llama_get_memory(ctx);
  llama_memory_t dmem = ctx_dft ? llama_get_memory(ctx_dft) : nullptr;
  const llama_vocab * vocab = model->vocab;

  auto check_rc = [&](int32_t rc, const char * what) {
    // llama_decode return codes (include/llama.h:991-1005, R04 §8).
    if (rc == 0) return;
    if (rc == 2) fail(SE_ERR_CANCELLED, "cancelled");
    if (rc == 1) fail(SE_ERR_CONTEXT_FULL, std::string(what) + ": no KV slot (context full)");
    fail(rc == -2 ? SE_ERR_OOM : SE_ERR_DECODE, std::string(what) + ": llama_decode returned " + std::to_string(rc));
  };
  // After an aborted/failed decode, the KV may hold a prefix of the batch (finished ubatches stay, the
  // failing one is removed, llama-context.cpp:1885-1917). Re-derive the token history from pos_max.
  auto resync = [&](const std::vector<llama_token> * chunk_src, size_t chunk_begin) {
    const llama_pos pmax = llama_memory_seq_pos_max(mem, 0);
    const size_t n = pmax < 0 ? 0 : (size_t) pmax + 1;
    if (n < history.size()) {
      history.resize(n);
    } else if (n > history.size()) {
      const size_t extra = n - history.size();
      if (chunk_src && chunk_begin + extra <= chunk_src->size() && chunk_begin == history.size()) {
        history.insert(history.end(), chunk_src->begin() + chunk_begin, chunk_src->begin() + chunk_begin + extra);
      } else {
        llama_memory_seq_rm(mem, 0, (llama_pos) history.size(), -1);
      }
    }
    if (dmem) {
      llama_memory_seq_rm(dmem, 0, (llama_pos) std::min(n_dft_synced, history.size()), -1);
      n_dft_synced = std::min(n_dft_synced, history.size());
    }
  };

  try {
    // ---- 1. template -------------------------------------------------------------------------------
    const common_chat_params chat = apply_template(*model, req.inputs);

    // ---- 2. sampler: the server's mapping of chat params (server-schema.cpp:330-381) -----------------
    common_params_sampling sp = req.sampling;
    if (!req.has_seed) sp.seed = params.seed;
    if (!chat.grammar.empty()) {
      const common_grammar_type gt = req.grammar_type != COMMON_GRAMMAR_TYPE_NONE ? req.grammar_type
                                                                                  : COMMON_GRAMMAR_TYPE_TOOL_CALLS;
      sp.grammar = common_grammar(gt, chat.grammar);
    }
    sp.grammar_lazy      = chat.grammar_lazy;
    sp.generation_prompt = chat.generation_prompt;
    for (const auto & t : chat.preserved_tokens) {
      const auto ids = common_tokenize(vocab, t, false, true);
      if (ids.size() == 1) sp.preserved_tokens.insert(ids[0]);
    }
    for (const auto & t : chat.grammar_triggers) {
      if (t.type == COMMON_GRAMMAR_TRIGGER_TYPE_WORD) {
        // Single-token trigger words become TOKEN triggers (cheaper, and robust to tokenization of the
        // surrounding text); multi-token ones (Qwen3's "<tool_call>\n") stay regex-escaped WORDs.
        const auto ids = common_tokenize(vocab, t.value, false, true);
        if (ids.size() == 1 && sp.preserved_tokens.count(ids[0])) {
          common_grammar_trigger tt;
          tt.type  = COMMON_GRAMMAR_TRIGGER_TYPE_TOKEN;
          tt.value = t.value;
          tt.token = ids[0];
          sp.grammar_triggers.push_back(tt);
          continue;
        }
      }
      sp.grammar_triggers.push_back(t);
    }
    if (sp.grammar_lazy && sp.grammar_triggers.empty()) {
      // A lazy grammar without triggers would never engage (the server rejects it); generate unconstrained.
      log(SE_LOG_WARN, "lazy grammar without triggers; generating without grammar\n");
      sp.grammar      = common_grammar();
      sp.grammar_lazy = false;
    }
    // Thinking tags drive the reasoning-budget sampler, which also keeps a lazy tool grammar from
    // triggering inside <think>...</think> (common/sampling.cpp:310-317; server-common.cpp:1416-1426).
    if (!chat.thinking_end_tags.empty() && !chat.thinking_start_tag.empty()) {
      sp.reasoning_budget_tokens = req.reasoning_budget;
      sp.reasoning_budget_start  = common_tokenize(vocab, chat.thinking_start_tag, false, true);
      for (const auto & e : chat.thinking_end_tags) {
        if (!e.empty()) sp.reasoning_budget_end.push_back(common_tokenize(vocab, e, false, true));
      }
      if (!sp.reasoning_budget_end.empty()) sp.reasoning_budget_forced = sp.reasoning_budget_end.front();
    }
    std::vector<std::string> stops = req.stop;
    for (const auto & s : chat.additional_stops) if (!s.empty()) stops.push_back(s);

    common_sampler_ptr smpl;
    try {
      smpl.reset(common_sampler_init(model->model, sp));  // throws on grammar / penalty errors
    } catch (const std::exception & e) {
      fail(SE_ERR_GRAMMAR, std::string("sampler: ") + e.what());
    }
    if (!smpl) fail(SE_ERR_GRAMMAR, "sampler initialisation failed");

    pp = common_chat_parser_params(chat);
    pp.reasoning_format     = req.inputs.reasoning_format;
    pp.reasoning_in_content = false;
    pp.parse_tool_calls     = req.tools_active;
    pp.is_continuation      = req.inputs.continue_final_message != COMMON_CHAT_CONTINUATION_NONE;
    if (!chat.parser.empty()) pp.parser.load(chat.parser);  // as the server does (server-schema.cpp:321-325)
    parser_ready = true;

    // ---- 3. prompt -------------------------------------------------------------------------------
    const std::vector<llama_token> prompt = tokenize_prompt(vocab, chat.prompt, true);
    if (prompt.empty()) fail(SE_ERR_INVALID_ARG, "the rendered prompt is empty");
    n_prompt = (int32_t) prompt.size();
    if (prompt.size() + 1 > n_ctx_seq) {
      fail(SE_ERR_CONTEXT_FULL, "prompt has " + std::to_string(prompt.size()) + " tokens; the context holds " +
                                    std::to_string(n_ctx_seq));
    }
    // Penalty samplers look at the prompt too (server-context.cpp:378-384); grammar/budget do not.
    for (const llama_token t : prompt) common_sampler_accept(smpl.get(), t, false);

    // spec_on: draft this reply. feed_dft: keep a draft model / MTP context in lockstep with the target
    // (it has its own KV); it stays on after an auto-disable so the next reply can speculate again and
    // the draft context can still reuse the prompt cache.
    const bool use_draft_ctx = spec && ctx_dft && req.speculative;
    bool       spec_on       = spec != nullptr && req.speculative;
    bool       feed_dft      = use_draft_ctx;

    // ---- 4. prompt cache: reuse the longest common prefix of the KV cache --------------------------
    size_t keep = 0;
    if (req.cache_prompt) {
      while (keep < history.size() && keep < prompt.size() && history[keep] == prompt[keep]) ++keep;
    }
    // The last prompt token is always (re)decoded inside the loop so sampling sees fresh logits; state
    // files and old KV never provide logits (R04 §13).
    keep = std::min(keep, prompt.size() - 1);
    // A draft model keeps its own KV; it can only reuse what it has seen.
    if (use_draft_ctx) keep = std::min(keep, n_dft_synced);
    if (keep < history.size()) {
      if (!llama_memory_seq_rm(mem, 0, (llama_pos) keep, -1)) {
        // Recurrent / hybrid / non-full SWA memories cannot drop a suffix: start over.
        llama_memory_seq_rm(mem, 0, -1, -1);
        keep = 0;
      }
      history.resize(keep);
    }
    if (dmem) {
      const size_t dk = std::min(n_dft_synced, keep);
      if (!llama_memory_seq_rm(dmem, 0, (llama_pos) dk, -1)) {
        llama_memory_seq_rm(dmem, 0, -1, -1);
        n_dft_synced = 0;
      } else {
        n_dft_synced = dk;
      }
    }
    n_cached = (int32_t) keep;

    // ---- 5. chunked prefill of prompt[keep .. n-1), cancellable between chunks ----------------------
    t_prefill0 = Clock::now();
    common_batch batch(ctx);
    {
      const size_t end = prompt.size() - 1;
      Event pe;
      pe.ev.type           = SE_EVENT_PROMPT_PROGRESS;
      pe.ev.progress_done  = (int32_t) keep;
      pe.ev.progress_total = n_prompt;
      emit(std::move(pe));
      // Chunks of at most n_batch tokens: llama_decode GGML_ASSERTs n_tokens <= n_batch (llama-context.cpp:1785).
      for (size_t i = keep; i < end; i += n_batch) {
        if (cancel.load()) fail(SE_ERR_CANCELLED, "cancelled");
        const size_t e = std::min(end, i + n_batch);
        batch.clear();
        for (size_t k = i; k < e; ++k) batch.add(prompt[k], (llama_pos) k, 0, false);
        const int32_t rc = llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch.get());
        if (rc != 0) {
          resync(&prompt, i);
          check_rc(rc, "prefill");
        }
        history.insert(history.end(), prompt.begin() + i, prompt.begin() + e);
        n_prefilled += (int32_t) (e - i);
        if (feed_dft) {
          if (n_dft_synced == i && common_speculative_process(spec, batch)) {
            n_dft_synced = history.size();
          } else {
            feed_dft = spec_on = false;  // draft lost sync; finish this reply without it
          }
        }
        Event pr;
        pr.ev.type           = SE_EVENT_PROMPT_PROGRESS;
        pr.ev.progress_done  = (int32_t) e;
        pr.ev.progress_total = n_prompt;
        emit(std::move(pr));
      }
    }
    if (spec_on) common_speculative_begin(spec, 0, history);  // n-gram tables learn the prompt

    // ---- 6. decode loop ---------------------------------------------------------------------------
    llama_token  id_last = prompt.back();
    llama_tokens draft;
    size_t       parsed_len = 0, stop_scan = 0;
    int64_t      gen_drafted = 0, gen_accepted = 0;
    bool         done = false;
    while (!done) {
      if (cancel.load()) fail(SE_ERR_CANCELLED, "cancelled");
      if (req.max_tokens >= 0 && n_gen >= req.max_tokens) { finish = SE_FINISH_LENGTH; break; }
      const size_t n_past = history.size();
      if (n_past + 1 > n_ctx_seq) { finish = SE_FINISH_LENGTH; break; }  // context exhausted

      draft.clear();
      bool drafted_now = false;
      if (feed_dft && n_dft_synced != n_past) feed_dft = spec_on = false;
      if (spec_on) {
        int64_t room = (int64_t) n_ctx_seq - (int64_t) n_past - 1;
        room = std::min<int64_t>(room, (int64_t) n_outputs_max - 1);  // outputs/decode: GGML_ASSERT llama-context.cpp:2273
        room = std::min<int64_t>(room, (int64_t) n_batch - 1);        // tokens/decode: GGML_ASSERT llama-context.cpp:1785
        room = std::min<int64_t>(room, n_draft_max);
        if (req.max_tokens >= 0) room = std::min<int64_t>(room, (int64_t) req.max_tokens - n_gen - 1);
        if (room >= 1) {
          common_speculative_get_draft_params(spec, 0) = {true, (int32_t) room, (llama_pos) n_past, id_last, &history, &draft};
          common_speculative_draft(spec);
          drafted_now = true;
          if ((int64_t) draft.size() > room) draft.resize((size_t) room);
          // draft-simple/MTP leave their own lookahead in the draft KV; drop it before the verify batch
          // is mirrored into the draft context by common_speculative_process (speculative-simple.cpp).
          if (dmem) llama_memory_seq_rm(dmem, 0, (llama_pos) n_past, -1);
        }
      }

      batch.clear();
      batch.add(id_last, (llama_pos) n_past, 0, true);
      for (size_t i = 0; i < draft.size(); ++i) batch.add(draft[i], (llama_pos) (n_past + 1 + i), 0, true);
      const int32_t rc = llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch.get());
      if (rc != 0) {
        llama_memory_seq_rm(mem, 0, (llama_pos) n_past, -1);
        resync(nullptr, 0);
        if (rc == 1) { finish = SE_FINISH_LENGTH; break; }
        check_rc(rc, "decode");
      }
      if (feed_dft) {
        // Mirror the verify batch into the draft context (draft-simple decodes it; MTP reads the target's
        // NextN embeddings from this decode).
        if (!common_speculative_process(spec, batch)) feed_dft = spec_on = false;
      } else if (spec_on) {
        common_speculative_process(spec, batch);  // n-gram types: no-op today, kept for API parity
      }

      std::vector<llama_token> ids;
      if (draft.empty()) {
        const llama_token t = common_sampler_sample(smpl.get(), ctx, 0);
        common_sampler_accept(smpl.get(), t, true);
        ids.push_back(t);
      } else {
        ids = common_sampler_sample_and_accept_n(smpl.get(), ctx, draft);  // >= 1, accepts internally
      }
      if (drafted_now) common_speculative_accept(spec, 0, (uint16_t) (ids.size() - 1));
      if (!have_first) {
        have_first = true;
        t_first    = Clock::now();
        ttft_ms    = std::chrono::duration<double, std::milli>(t_first - t0).count();
        prefill_ms = std::chrono::duration<double, std::milli>(t_first - t_prefill0).count();
      }
      drafted      += (int64_t) draft.size();
      accepted     += (int64_t) ids.size() - 1;
      gen_drafted  += (int64_t) draft.size();
      gen_accepted += (int64_t) ids.size() - 1;

      // KV now holds id_last + the accepted drafts; ids.back() is new and not decoded yet.
      history.push_back(id_last);
      history.insert(history.end(), ids.begin(), ids.end() - 1);
      llama_memory_seq_rm(mem, 0, (llama_pos) history.size(), -1);
      if (dmem) {
        llama_memory_seq_rm(dmem, 0, (llama_pos) history.size(), -1);
        if (feed_dft) n_dft_synced = history.size();
      }
      id_last = ids.back();

      // Turn tokens into text; stop on EOG, stop strings or max_tokens.
      size_t consumed = 0;
      for (size_t i = 0; i < ids.size() && !done; ++i) {
        const llama_token t = ids[i];
        if (llama_vocab_is_eog(vocab, t)) { finish = SE_FINISH_STOP; done = true; break; }
        // Render control tokens only when the template asked to preserve them (<think>, <tool_call>, ...),
        // like the server's accept_special_token (server-context.cpp:3781-3784).
        text += common_token_to_piece(vocab, t, sp.preserved_tokens.count(t) != 0);
        ++n_gen;
        consumed = i + 1;
        if (!stops.empty()) {
          const size_t p = find_stop(text, stop_scan, stops);
          stop_scan = text.size();
          if (p != std::string::npos) { text.resize(p); finish = SE_FINISH_STOP; done = true; break; }
        }
        if (req.max_tokens >= 0 && n_gen >= req.max_tokens) { finish = SE_FINISH_LENGTH; done = true; break; }
      }
      if (done && consumed + 1 < ids.size()) {
        // Stopped inside an accepted draft: drop the KV of tokens that are not part of the reply.
        const size_t keep_len = n_past + 1 + std::min(consumed, ids.size() - 1);
        history.resize(keep_len);
        llama_memory_seq_rm(mem, 0, (llama_pos) keep_len, -1);
        if (dmem) {
          llama_memory_seq_rm(dmem, 0, (llama_pos) keep_len, -1);
          n_dft_synced = std::min(n_dft_synced, keep_len);
        }
      }

      if (!done) {
        // Stream only complete UTF-8 that cannot be the start of a stop string.
        size_t safe = utf8_complete_prefix(text);
        for (const auto & s : stops) {
          const size_t p = string_find_partial_stop(std::string_view(text).substr(0, safe), s);
          if (p != std::string::npos) safe = std::min(safe, p);
        }
        if (safe > parsed_len) {
          try {
            out.update(common_chat_parse(text.substr(0, safe), /*is_partial*/ true, pp), false);
          } catch (const std::exception & e) {
            log(SE_LOG_DEBUG, "partial parse failed: %s\n", e.what());
          }
          parsed_len = safe;
        }
      }

      // Speculation that keeps missing costs more than it saves: switch it off for this reply.
      if (spec_on && params.spec_min_accept > 0 && gen_drafted >= params.spec_min_drafted &&
          (double) gen_accepted < params.spec_min_accept * (double) gen_drafted) {
        spec_on = false;
        spec_stats.n_auto_disabled.fetch_add(1);
        log(SE_LOG_INFO, "speculative decoding disabled for this reply (accepted %lld/%lld)\n",
            (long long) gen_accepted, (long long) gen_drafted);
      }
    }
  } catch (const Error & e) {
    if (e.code == SE_ERR_CANCELLED) {
      finish = SE_FINISH_CANCELLED;
    } else {
      err = e.code;
      err_msg = e.msg;
      finish = SE_FINISH_ERROR;
    }
  } catch (const std::bad_alloc &) {
    err = SE_ERR_OOM;
    err_msg = "out of memory";
    finish = SE_FINISH_ERROR;
  } catch (const std::exception & e) {
    err = SE_ERR_INTERNAL;
    err_msg = e.what();
    finish = SE_FINISH_ERROR;
  }
  if (cancel.load() && finish != SE_FINISH_ERROR) finish = SE_FINISH_CANCELLED;

  // ---- 7. finish: final parse, tool calls, usage, perf, FINISH (never throws) ----------------------
  try {
    common_chat_msg final_msg;
    final_msg.role = "assistant";
    // A reply cut by max_tokens / cancel can end inside a multi-byte character; never emit half of it.
    text.resize(utf8_complete_prefix(text));
    if (parser_ready) {
      // A reply cut by max_tokens or cancellation may end inside a tool call: parse it as partial.
      const bool partial = finish != SE_FINISH_STOP;
      try {
        final_msg = common_chat_parse(text, partial, pp);
      } catch (const std::exception & e) {
        // "The model produced output that does not match the expected ... format" (chat.cpp:1494-1498).
        log(SE_LOG_WARN, "final parse failed (%s); falling back to a partial parse\n", e.what());
        try {
          final_msg = common_chat_parse(text, true, pp);
        } catch (...) {
          final_msg = out.prev;
          if (final_msg.empty()) final_msg.content = text;
        }
      }
      if (final_msg.role.empty()) final_msg.role = "assistant";
      out.update(final_msg, true);
      final_msg = out.prev;
    }
    // DONE promises a complete call. A reply cut by max_tokens / cancel / error may end inside the
    // arguments; those partial calls are only in FINISH's message JSON.
    if (finish == SE_FINISH_STOP) {
      for (size_t i = 0; i < final_msg.tool_calls.size(); ++i) {
        const auto & tc = final_msg.tool_calls[i];
        out.send(SE_EVENT_TOOL_CALL_DONE, tc.arguments, (int32_t) i, tc.id, tc.name);
      }
      if (!final_msg.tool_calls.empty()) finish = SE_FINISH_TOOL_CALLS;
    }
    if (err != SE_OK) {
      Event e;
      e.ev.type = SE_EVENT_ERROR;
      e.ev.code = err;
      e.text    = err_msg;
      emit(std::move(e));
    }
    if (have_first) decode_ms = ms_since(t_first);
    {
      Event u;
      u.ev.type              = SE_EVENT_USAGE;
      u.ev.prompt_tokens     = n_prompt;
      u.ev.cached_tokens     = n_cached;
      u.ev.completion_tokens = n_gen;
      emit(std::move(u));
    }
    {
      Event p;
      p.ev.type              = SE_EVENT_PERF;
      p.ev.ttft_ms           = ttft_ms;
      p.ev.prefill_ms        = prefill_ms;
      p.ev.decode_ms         = decode_ms;
      // The first sampled token comes out of the prefill pass, so decode t/s counts the tokens after it.
      p.ev.prefill_tps       = prefill_ms > 0 ? (n_prefilled + 1) * 1000.0 / prefill_ms : 0.0;
      p.ev.decode_tps        = (decode_ms > 0 && n_gen > 1) ? (n_gen - 1) * 1000.0 / decode_ms : 0.0;
      p.ev.n_drafted         = (int32_t) drafted;
      p.ev.n_accepted        = (int32_t) accepted;
      p.ev.draft_accept_rate = drafted > 0 ? (double) accepted / (double) drafted : 0.0;
      p.name                 = backend_label();
      emit(std::move(p));
    }
    spec_stats.n_drafted.fetch_add(drafted);
    spec_stats.n_accepted.fetch_add(accepted);
    {
      Event f;
      f.ev.type = SE_EVENT_FINISH;
      f.ev.code = finish;
      f.name    = finish == SE_FINISH_STOP ? "stop" : finish == SE_FINISH_LENGTH ? "length"
                : finish == SE_FINISH_TOOL_CALLS ? "tool_calls" : finish == SE_FINISH_CANCELLED ? "cancelled" : "error";
      f.text    = final_msg.to_json_oaicompat().dump_safe();  // model output may hold invalid UTF-8
      emit(std::move(f));
    }
  } catch (...) {
    // Last resort: still terminate the stream.
    Event f;
    f.ev.type = SE_EVENT_FINISH;
    f.ev.code = SE_FINISH_ERROR;
    f.name    = "error";
    f.text    = "{\"role\":\"assistant\",\"content\":\"\"}";
    try { emit(std::move(f)); } catch (...) {}
  }
}

}  // namespace se
