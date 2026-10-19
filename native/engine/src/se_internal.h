// Internal declarations shared by the sherpa_engine translation units. Nothing here is part of the ABI.
#pragma once

#include "sherpa_engine.h"
#include "se_build_config.h"

#include "llama.h"
#include "common.h"
#include "chat.h"
#include "sampling.h"
#include "speculative.h"
#include "json.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#if SE_HAVE_MTMD
#include "mtmd.h"
#include "mtmd-helper.h"
#endif

namespace se {

// ---------------------------------------------------------------------------------------------------------
// Errors: internal code throws se::Error; every C entry point converts exceptions to an se_status + the
// thread-local message. Nothing may escape extern "C" functions (R04 §20, §22: llama_token_to_piece,
// grammar accept, llama_load_mode_from_str and common_* helpers throw C++ exceptions).
// ---------------------------------------------------------------------------------------------------------
struct Error : std::exception {
  se_status   code;
  std::string msg;
  Error(se_status c, std::string m) : code(c), msg(std::move(m)) {}
  const char * what() const noexcept override { return msg.c_str(); }
};

[[noreturn]] void fail(se_status code, const std::string & msg);
void set_last_error(se_status code, const std::string & msg);
void clear_last_error();

// Runs f() and converts any exception into a status. R is se_status/int32_t (negative = error).
template <class F>
int32_t guard(const char * fn, F && f) noexcept {
  try {
    clear_last_error();
    return f();
  } catch (const Error & e) {
    set_last_error(e.code, std::string(fn) + ": " + e.msg);
    return e.code;
  } catch (const std::bad_alloc &) {
    set_last_error(SE_ERR_OOM, std::string(fn) + ": out of memory");
    return SE_ERR_OOM;
  } catch (const std::exception & e) {
    set_last_error(SE_ERR_INTERNAL, std::string(fn) + ": " + e.what());
    return SE_ERR_INTERNAL;
  } catch (...) {
    set_last_error(SE_ERR_INTERNAL, std::string(fn) + ": unknown exception");
    return SE_ERR_INTERNAL;
  }
}

// struct_size-versioned params: start from the engine defaults, overlay the bytes the caller declared.
template <class T>
T read_params(const T * p, void (*init)(T *)) {
  T out;
  init(&out);
  if (p == nullptr) {
    return out;
  }
  const uint32_t declared = p->struct_size;
  if (declared < sizeof(uint32_t) || declared > (1u << 16)) {
    fail(SE_ERR_ABI, "struct_size " + std::to_string(declared) + " is invalid (expected " +
                         std::to_string(sizeof(T)) + ")");
  }
  std::memcpy(&out, p, std::min<size_t>(declared, sizeof(T)));
  out.struct_size = sizeof(T);
  return out;
}

template <class T>
void write_out(T * dst, const T & src) {
  if (dst == nullptr) {
    fail(SE_ERR_INVALID_ARG, "output struct is NULL");
  }
  const uint32_t declared = dst->struct_size;
  if (declared < sizeof(uint32_t) || declared > (1u << 16)) {
    fail(SE_ERR_ABI, "output struct_size " + std::to_string(declared) + " is invalid");
  }
  std::memcpy(dst, &src, std::min<size_t>(declared, sizeof(T)));
  dst->struct_size = declared;
}

// Copies `s` (+ NUL) into buf if it fits; returns the length (snprintf-like, but all-or-nothing).
int32_t copy_out(const std::string & s, char * buf, int32_t cap);

// ---------------------------------------------------------------------------------------------------------
// Backend / logging
// ---------------------------------------------------------------------------------------------------------
void ensure_backend();                       // se_backend_init with defaults if nobody did
void log(int32_t level, const char * fmt, ...) __attribute__((format(printf, 2, 3)));
std::string system_info_json();
std::string loaded_cpu_variant();            // Android DL: name of the variant that was loaded
std::string backend_label();                 // e.g. "CPU (android_armv8.2_2)" / "Metal"
int32_t     default_thread_count();          // performance-core estimate, capped at 8

// ---------------------------------------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------------------------------------
using Clock = std::chrono::steady_clock;
inline double ms_since(Clock::time_point t0) {
  return std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
}
size_t      utf8_complete_prefix(const std::string & s);   // length of the longest prefix w/o a cut code point
std::string quick_fingerprint(const std::string & path, uint64_t * size_out);
uint64_t    file_size_or_zero(const std::string & path);
std::string ggml_type_label(int32_t t);
bool        is_quantized_kv(int32_t t);
std::string random_id(uint64_t & rng_state, size_t n);    // [a-zA-Z0-9]{n}
std::vector<llama_token> tokenize_prompt(const llama_vocab * vocab, const std::string & text, bool add_bos);
std::string token_piece(const llama_vocab * vocab, llama_token tok, bool special);
common_json parse_json_object(const char * text, const char * what);

// ---------------------------------------------------------------------------------------------------------
// Models, adapters, cancellation
// ---------------------------------------------------------------------------------------------------------
struct ModelImpl {
  llama_model *             model = nullptr;
  const llama_vocab *       vocab = nullptr;
  common_chat_templates_ptr tmpls;               // null if the template failed to compile
  std::string               tmpl_error;
  // Jinja rendering is not documented as thread-safe; sessions on one model serialise template work.
  mutable std::mutex        tmpl_mu;
  std::string               path;
  std::string               model_id;            // caller-provided or the fingerprint
  std::string               fingerprint;
  uint64_t                  file_bytes = 0;
  bool                      vocab_only = false;
  bool                      mtp_loaded = false;
  llama_model *             draft = nullptr;     // optional draft model (SE_SPEC_DRAFT)
  std::string               draft_path;
  std::string               info_json;           // computed once at load
#if SE_HAVE_MTMD
  mtmd_context *            mtmd = nullptr;
  mutable std::mutex        mtmd_mu;             // mtmd_encode_chunk / its output buffer are not thread-safe
#endif
  // Marker the chat template renders for each image (random per load, so user text cannot fake one).
  std::string               media_marker;
  bool                      image_input = false; // a vision projector is loaded
  std::string               mmproj_fingerprint;  // quick fingerprint of the projector GGUF (state identity)
  ~ModelImpl();
};

struct LoraImpl {
  std::shared_ptr<ModelImpl> model;  // adapters are freed by llama_model_free; keep the model alive
  llama_adapter_lora *       adapter = nullptr;
  std::string                path;
  std::string                fingerprint;
  ~LoraImpl();
};

std::string build_model_info(ModelImpl & m);
// Renders a chat request through the template (holding tmpl_mu).
common_chat_params apply_template(const ModelImpl & m, const common_chat_templates_inputs & in);

// ---------------------------------------------------------------------------------------------------------
// Chat request (parsed synchronously in se_generate_start so malformed JSON fails fast)
// ---------------------------------------------------------------------------------------------------------
struct ChatRequest {
  common_chat_templates_inputs inputs;
  std::vector<std::string>     media;          // encoded images, in the order of their markers in the prompt
  common_params_sampling       sampling;
  common_grammar_type          grammar_type = COMMON_GRAMMAR_TYPE_NONE;
  bool                         tools_active = false;
  int32_t                      max_tokens = -1;
  std::vector<std::string>     stop;
  bool                         cache_prompt = true;
  bool                         speculative = true;
  int32_t                      reasoning_budget = -1;
  bool                         has_seed = false;
};
// External media of se_generate_start_ex ({type:"media",index:N} content parts).
struct MediaRef {
  const uint8_t * data = nullptr;
  size_t          size = 0;
  int32_t         type = 0;
};
ChatRequest parse_chat_request(const ModelImpl & m, const char * json, const std::vector<MediaRef> * ext = nullptr);
// Replaces image content parts of `messages` with media-marker parts; appends their bytes to `out`.
void extract_media(const ModelImpl & m, common_json & messages, const std::vector<MediaRef> * ext,
                   std::vector<std::string> & out);

// A tokenized prompt: one entry per position. Text positions hold token ids; the positions of an image chunk
// hold its pseudo token (< 0, from the image's SHA-256), so prefix matching treats equal images as equal.
struct PromptPlan {
  struct Span {
    size_t  begin = 0, end = 0;  // positions [begin, end)
    size_t  n_tokens = 0;        // KV cells (differs from end - begin for M-RoPE models)
    size_t  chunk = 0;           // index into chunks
  };
  std::vector<llama_token> tokens;
  std::vector<Span>        spans;  // image chunks, ascending
  size_t                   n_cells = 0;
#if SE_HAVE_MTMD
  mtmd::input_chunks_ptr   chunks;
  const mtmd_input_chunk * chunk(size_t i) const { return mtmd_input_chunks_get(chunks.get(), i); }
#endif
  bool has_media() const { return !spans.empty(); }
  // KV cells taken by positions [0, pos) (pos at a span boundary).
  size_t cells_before(size_t pos) const;
};
constexpr llama_token k_media_token_max = -2;  // pseudo tokens are <= this
inline bool is_media_token(llama_token t) { return t <= k_media_token_max; }
// The prompt for a rendered template: plain tokenization, or mtmd chunks when the request has media.
PromptPlan build_prompt(const ModelImpl & m, const std::string & prompt, const std::vector<std::string> & media);

// ---------------------------------------------------------------------------------------------------------
// Event ring: bounded single-producer / single-consumer queue. The worker (producer) blocks when it is
// full (backpressure, no event is ever dropped); the host (consumer) drains batches with se_poll_events.
// Slot strings stay put until the consumer's *next* poll, which is what lets se_poll_events hand out
// pointers without copying the payloads.
// ---------------------------------------------------------------------------------------------------------
struct Event {
  Event() { ev.index = -1; }
  se_event    ev{};
  std::string text, id, name;
  void bind();  // points ev.text/id/name at the owned strings
};

class EventRing {
 public:
  explicit EventRing(uint32_t capacity);
  // Producer. Returns false only when the ring is shut down (session being freed).
  bool push(Event && e);
  // Consumer.
  int32_t poll(int32_t timeout_ms, int32_t max_events, const se_event ** out);
  void    shutdown();
  size_t  pending() const;

 private:
  std::vector<Event>      slots_;
  const uint64_t          cap_;
  std::atomic<uint64_t>   head_{0};      // next slot the producer writes
  std::atomic<uint64_t>   tail_{0};      // next slot the consumer hands out
  std::atomic<uint64_t>   released_{0};  // slots below this may be overwritten
  std::atomic<bool>       shutdown_{false};
  std::vector<se_event>   batch_;        // consumer-owned array returned by poll
  mutable std::mutex      mu_;           // only for sleeping/waking, indices are atomics
  std::condition_variable cv_space_, cv_data_;
};

// ---------------------------------------------------------------------------------------------------------
// Persistent ggml threadpools: without them ggml-cpu creates and joins a disposable pool on every graph
// compute, i.e. once per generated token. Mirrors common_threadpools::init (common/common.cpp:1697-1739)
// but can be rebuilt for se_session_set_threads. Free the contexts using them first.
// ---------------------------------------------------------------------------------------------------------
struct ThreadPools {
  ggml_threadpool * tp = nullptr;
  ggml_threadpool * tp_batch = nullptr;
  void (*free_fn)(ggml_threadpool *) = nullptr;
  bool reset(int32_t n_threads, int32_t n_threads_batch);  // false: ggml creates pools per graph instead
  void attach(llama_context * ctx) const;
  void release();
  ~ThreadPools() { release(); }
};

// ---------------------------------------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------------------------------------
struct SpecStats {  // written by the worker, read by se_session_info_json at any time
  std::atomic<int64_t> n_drafted{0};
  std::atomic<int64_t> n_accepted{0};
  std::atomic<int64_t> n_auto_disabled{0};
};

struct SessionImpl {
  std::shared_ptr<ModelImpl> model;
  se_session_params          params{};          // resolved values
  llama_context *            ctx = nullptr;
  uint32_t                   n_ctx = 0, n_ctx_seq = 0, n_batch = 0, n_ubatch = 0, n_outputs_max = 1;
  int32_t                    n_threads = 0, n_threads_batch = 0;
  int32_t                    flash_attn_resolved = 0;
  bool                       can_partial_rm = true;  // false for recurrent/hybrid (seq_rm may fail)

  ThreadPools                pools;

  // Speculative decoding
  int32_t                    spec_type = SE_SPEC_NONE;
  int32_t                    n_draft_max = 0;
  llama_context *            ctx_dft = nullptr;      // draft model or MTP context
  common_speculative *       spec = nullptr;
  size_t                     n_dft_synced = 0;       // prefix of `history` present in ctx_dft
  SpecStats                  spec_stats;

  // Token history: exactly the tokens whose KV is in ctx (seq 0), in order. The prompt cache is the
  // longest common prefix between this and the next request's prompt.
  std::vector<llama_token>   history;

  // LoRA set (part of the prompt-cache identity)
  std::vector<std::shared_ptr<LoraImpl>> loras;
  std::vector<float>         lora_scales;

  // Generation worker
  std::thread                worker;
  std::mutex                 mu;
  std::condition_variable    cv;
  bool                       has_job = false;
  bool                       stopping = false;
  std::atomic<bool>          busy{false};
  std::atomic<bool>          cancel{false};
  ChatRequest                job;
  uint32_t                   job_id = 0;
  uint32_t                   next_gen_id = 1;
  uint32_t                   cur_gen = 0;           // worker-owned: id stamped on emitted events

  EventRing                  ring;
  se_event_cb                cb = nullptr;
  void *                     cb_user = nullptr;
  bool                       cb_queue_too = false;
  uint64_t                   rng = 0x9E3779B97F4A7C15ull;

  explicit SessionImpl(uint32_t event_capacity) : ring(event_capacity) {}
  ~SessionImpl();

  void worker_main();
  void run_generation(uint32_t gen_id, ChatRequest & req);
  void emit(Event && e);
  void clear_kv();
  void setup_threadpools();
  std::string info_json(bool idle);
  se_memory_estimate memory();
};

// Marks a session busy for maintenance calls (reset, state, LoRA, threads, info) so they never run
// concurrently with the generation worker or with each other. Throws SE_ERR_BUSY.
struct BusyScope {
  SessionImpl & s;
  explicit BusyScope(SessionImpl & s_);
  ~BusyScope();
  BusyScope(const BusyScope &) = delete;
  BusyScope & operator=(const BusyScope &) = delete;
};

// Session construction helpers shared with the estimator / bench.
struct ResolvedSessionParams {
  se_session_params    p{};
  llama_context_params cp{};
  int32_t              n_draft_max = 0;
  int32_t              spec_type = SE_SPEC_NONE;
};
ResolvedSessionParams resolve_session_params(const llama_model * model, bool mtp_loaded, bool has_draft,
                                             const se_session_params & in);
// mmap_expected: the real load will mmap the weights (dry runs use LOAD_MODE_NONE, so their "CPU" weight
// buffer is what becomes "CPU_Mapped" later).
// cpu_model_bytes (optional out): weight bytes in plain host buffers ("CPU" / "CPU_Mapped").
se_memory_estimate    breakdown_to_estimate(llama_context * ctx, const llama_model * model, uint32_t n_outputs_max,
                                            bool mmap_expected, uint64_t * cpu_model_bytes = nullptr);
// Bytes from the GGUF tensor-data offset to the end of the file (what an mmap'd weight buffer spans).
uint64_t gguf_tensor_data_span(const std::string & path);
// Captures llama/ggml log lines emitted on the calling thread while alive (used to learn how llama.cpp
// resolved flash_attn = auto, which no API exposes).
struct LogTap {
  explicit LogTap(std::string * sink);
  ~LogTap();
  std::string * prev;
};
int32_t resolved_flash_attn(int32_t requested, const std::string & log_text);

}  // namespace se

// Opaque ABI handles wrap shared ownership so freeing order never matters.
struct se_model   { std::shared_ptr<se::ModelImpl> impl; };
struct se_lora    { std::shared_ptr<se::LoraImpl> impl; };
struct se_session { std::unique_ptr<se::SessionImpl> impl; };
struct se_canceller { std::atomic<bool> flag{false}; };
