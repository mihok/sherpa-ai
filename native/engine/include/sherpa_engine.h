/*
 * sherpa_engine.h - Sherpa on-device inference engine, C ABI version 1.
 *
 * One C++17 shim over llama.cpp + common (pinned in native/llama/llama.lock). Dart (FFI), Kotlin (JNI) and
 * Swift see only this header. Design rules (docs/research/04-llamacpp-api.md §20):
 *
 *  - Versioned: se_abi_version() == SE_ABI_VERSION. Every params/out struct starts with `struct_size`
 *    (set it to sizeof(the struct you compiled against), or use the *_init() helpers). The engine reads only
 *    the bytes the caller declared and keeps its defaults for fields added later, so new fields are only ever
 *    appended. Rich, evolving payloads (chat requests, model/system info) are JSON (UTF-8).
 *  - Nothing throws or aborts across the boundary. Every entry point catches all C++ exceptions and returns
 *    an se_status (< 0 = error); the message is in se_last_error() (thread-local). Inputs that would hit a
 *    known GGML_ASSERT/abort inside llama.cpp are validated first (token ids, batch sizes, n_outputs_max,
 *    dry-run load mode, quantized-V-needs-flash-attention, ...). A crash inside ggml itself is still
 *    possible; see se_init_params.crash_breadcrumb_path.
 *  - Threading: model handles are immutable after load and safe to share between threads and sessions.
 *    A session runs at most one generation at a time on its own worker thread; other session calls made
 *    while it is generating return SE_ERR_BUSY (except se_cancel / se_poll_events / se_wait / info). Events
 *    are pulled with se_poll_events (single consumer) and/or pushed to an optional callback.
 *  - Handles are reference counted internally: freeing a model while sessions or LoRA adapters still use it
 *    is safe (the weights are released when the last user goes). Freeing a session cancels and joins its
 *    worker. Never call an API on a handle after freeing it, or free a handle another thread is using.
 *  - Strings returned through se_event and *_json buffers are UTF-8 and contain only complete code points.
 *
 * Return conventions:
 *  - se_status functions: SE_OK (0) or a negative SE_ERR_*.
 *  - "*_json(…, char *buf, int32_t cap)": returns the JSON length in bytes excluding the NUL (>= 0). If
 *    cap > length the JSON and a NUL are written; otherwise nothing is written (call again with a larger
 *    buffer). Returns a negative se_status on error.
 *  - Counting functions (se_tokenize, se_detokenize): return the full count; output is written only if it
 *    fits in `cap`. Negative = se_status.
 *
 * See native/engine/CHANGELOG.md for the ABI history.
 */
#ifndef SHERPA_ENGINE_H
#define SHERPA_ENGINE_H

#include <stddef.h>
#include <stdint.h>

#define SE_ABI_VERSION 1u

#if defined(_WIN32)
#  if defined(SE_BUILDING_LIBRARY)
#    define SE_API __declspec(dllexport)
#  else
#    define SE_API __declspec(dllimport)
#  endif
#else
#  define SE_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ===================================================================================================== */
/* Status codes                                                                                           */
/* ===================================================================================================== */

typedef int32_t se_status;

enum {
  SE_OK                   = 0,
  SE_ERR_INVALID_ARG      = -1,  /* bad pointer, out-of-range value, malformed JSON, invalid token id      */
  SE_ERR_OOM              = -2,  /* allocation failed (std::bad_alloc, ggml buffer allocation)            */
  SE_ERR_IO               = -3,  /* file missing / unreadable / unwritable                                */
  SE_ERR_MODEL_LOAD       = -4,  /* llama.cpp could not load the GGUF                                     */
  SE_ERR_CONTEXT_CREATE   = -5,  /* llama_init_from_model failed (memory, unsupported KV type combination) */
  SE_ERR_CONTEXT_FULL     = -6,  /* prompt does not fit into n_ctx                                         */
  SE_ERR_CANCELLED        = -7,  /* cancelled via se_cancel / se_canceller / progress callback            */
  SE_ERR_DECODE           = -8,  /* llama_decode returned < 0 (invalid batch, allocation/compute failure)  */
  SE_ERR_TEMPLATE         = -9,  /* chat template missing, failed to compile or to render                 */
  SE_ERR_GRAMMAR          = -10, /* grammar / JSON schema could not be compiled                            */
  SE_ERR_PARSE            = -11, /* model output could not be parsed in the template's format             */
  SE_ERR_STATE_MISMATCH   = -12, /* state file belongs to another model / LoRA set / KV layout           */
  SE_ERR_BUSY             = -13, /* a generation is running on this session                               */
  SE_ERR_UNSUPPORTED      = -14, /* feature not compiled in or not supported by this model                */
  SE_ERR_BUFFER_TOO_SMALL = -15,
  SE_ERR_TIMEOUT          = -16,
  SE_ERR_ABI              = -17, /* struct_size smaller than the minimum this ABI understands            */
  SE_ERR_INTERNAL         = -99  /* unexpected C++ exception; see se_last_error()                         */
};

/* Message of the last failed call on the calling thread ("" if none). Valid until the next se_* call on
 * the same thread. Call it right after the failing call, from the same thread. */
SE_API const char * se_last_error(void);
SE_API se_status    se_last_error_code(void);
/* Stable name of a status code, e.g. "SE_ERR_BUSY". */
SE_API const char * se_status_name(se_status status);

/* ===================================================================================================== */
/* Versioning, backend initialisation, system info                                                        */
/* ===================================================================================================== */

SE_API uint32_t     se_abi_version(void);
/* "sherpa_engine <semver> (abi <n>, llama.cpp <commit7>, ggml <version>)" - static storage. */
SE_API const char * se_version_string(void);

typedef enum se_log_level {
  SE_LOG_DEBUG = 1,
  SE_LOG_INFO  = 2,
  SE_LOG_WARN  = 3,
  SE_LOG_ERROR = 4,
  SE_LOG_NONE  = 5
} se_log_level;

/* Log sink. Called from any engine thread (loader, worker); `msg` is valid only during the call. */
typedef void (*se_log_cb)(int32_t level, const char * msg, void * user);

typedef struct se_init_params {
  uint32_t     struct_size;
  int32_t      log_level;             /* minimum se_log_level forwarded to log_cb; default SE_LOG_WARN       */
  se_log_cb    log_cb;                /* NULL = errors to stderr (Android: logcat tag "sherpa_engine")       */
  void *       log_user;
  /* Directory holding dynamically loadable ggml backends. NULL (default) = Android: dlopen each CPU variant
   * by bare file name, best first (works with AGP's default non-extracted libs, where nativeLibraryDir is
   * empty); elsewhere: ggml_backend_load_all() (a no-op for static builds such as iOS and the host tests). */
  const char * backend_dir;
  /* If set, a fatal ggml error (GGML_ASSERT/GGML_ABORT) appends its message to this file before the process
   * aborts, so the app can report it on the next start. It cannot prevent the abort. */
  const char * crash_breadcrumb_path;
} se_init_params;

SE_API void se_init_params_init(se_init_params * p);

/* Initialise backends once per process (later calls return SE_OK and change nothing). Optional: model
 * loading and the estimators initialise with defaults on first use. Thread-safe. */
SE_API se_status se_backend_init(const se_init_params * p);

/* JSON: engine/llama/ggml versions; registered backends and devices (name, type, memory); the CPU variant
 * that was loaded (Android); CPU features detected at runtime (getauxval HWCAP/HWCAP2 on Linux/Android,
 * sysctl hw.optional.* on Apple, cpuid on x86) - NOT ggml_cpu_has_*, which report compile-time flags of the
 * loaded backend (R04 §18; reported separately as "cpu_backend_features"); core counts incl. a
 * performance-core estimate from cpufreq; llama_supports_mmap/mlock/gpu_offload. */
SE_API int32_t se_system_info_json(char * buf, int32_t cap);

/* ===================================================================================================== */
/* Cancellation tokens (for synchronous calls: model load, memory estimate, bench)                        */
/* ===================================================================================================== */

typedef struct se_canceller se_canceller;
SE_API se_canceller * se_canceller_create(void);
SE_API void           se_canceller_cancel(se_canceller * c);   /* thread-safe, idempotent               */
SE_API void           se_canceller_reset(se_canceller * c);
SE_API void           se_canceller_free(se_canceller * c);     /* only after the call using it returned */

/* ===================================================================================================== */
/* Models                                                                                                  */
/* ===================================================================================================== */

typedef struct se_model se_model;

/* Called on the loading thread with progress in [0,1]. Return 0 to cancel the load. */
typedef int32_t (*se_progress_cb)(float progress, void * user);

typedef enum se_load_mode {     /* mirrors llama_load_mode (llama.h) */
  SE_LOAD_MODE_AUTO       = -1, /* mmap unless a selected device cannot map (default)                         */
  SE_LOAD_MODE_NONE       = 0,  /* read weights into anonymous memory                                         */
  SE_LOAD_MODE_MMAP       = 1,
  SE_LOAD_MODE_MLOCK      = 2,
  SE_LOAD_MODE_MMAP_MLOCK = 3,
  SE_LOAD_MODE_DIRECT_IO  = 4
} se_load_mode;

typedef struct se_model_params {
  uint32_t       struct_size;
  int32_t        n_gpu_layers;          /* -1 = all (default), 0 = CPU only. Ignored without a GPU backend.  */
  int32_t        load_mode;             /* se_load_mode, default SE_LOAD_MODE_AUTO                           */
  int32_t        use_extra_bufts;       /* 1 (default) = weight repack buffers (KleidiAI / CPU_REPACK / AMX)  */
  int32_t        check_tensors;         /* 1 = validate tensor data while loading (slow); default 0          */
  int32_t        load_mtp;              /* 1 = also load NextN/MTP heads (for SE_SPEC_MTP); default 0        */
  int32_t        vocab_only;            /* 1 = tokenizer + chat template only (token counting); default 0    */
  int32_t        mmproj_use_gpu;        /* default 1                                                         */
  int32_t        draft_n_gpu_layers;    /* default -1                                                        */
  const char *   chat_template_override;/* Jinja source; NULL = template embedded in the GGUF                */
  /* Identity recorded in state files and checked on load, e.g. "sha256:<hex of the GGUF>". NULL = a quick
   * fingerprint (sha256 over size + first/last MiB), which detects other files but not every edit. */
  const char *   model_id;
  const char *   mmproj_path;           /* optional multimodal projector (needs se_feature "mtmd")           */
  const char *   draft_model_path;      /* optional draft model for SE_SPEC_DRAFT                            */
  se_progress_cb progress_cb;           /* optional                                                          */
  void *         progress_user;
  se_canceller * cancel;                /* optional: cancelling aborts the load with SE_ERR_CANCELLED        */
} se_model_params;

SE_API void      se_model_params_init(se_model_params * p);
/* Blocking; call from a background thread. */
SE_API se_status se_model_load(const char * path, const se_model_params * p, se_model ** out);
SE_API void      se_model_free(se_model * m);

/* JSON: arch, name, description, ftype, n_params, size_bytes, file_bytes, n_ctx_train, n_layer, n_embd,
 * n_head, n_head_kv, key_length, value_length, sliding_window (n_swa), n_layer_nextn, n_vocab, eog tokens,
 * kv_bytes_per_token {f16,q8_0,q4_0}, recurrent/hybrid flags, chat_template {present, source, caps},
 * tool_calls {"native_grammar" | "parsed_without_grammar" | "none", grammar_lazy, required_grammar,
 * triggers, format}, thinking {supported, start_tag, end_tags}, recommended_sampling (general.sampling.*),
 * mmproj {vision, audio}, draft model, model_id, fingerprint. The tool classification comes from applying
 * the chat template with a dummy tool (tool_choice auto, then required), R04 §21.3. */
SE_API int32_t se_model_info_json(const se_model * m, char * buf, int32_t cap);

/* Tokenize UTF-8 text. add_special: prepend BOS if the vocab wants it. parse_special: map special-token
 * text (e.g. "<|im_start|>") to its id. Returns the token count; tokens are written only if count <= cap. */
SE_API int32_t se_tokenize(const se_model * m, const char * text, int32_t text_len, int32_t add_special,
                           int32_t parse_special, int32_t * tokens, int32_t cap);
/* Token ids are validated (an out-of-range id is SE_ERR_INVALID_ARG; llama_token_to_piece would throw).
 * Returns the byte count (excluding NUL); written with a NUL if it fits. */
SE_API int32_t se_detokenize(const se_model * m, const int32_t * tokens, int32_t n_tokens, int32_t render_special,
                             char * buf, int32_t cap);
/* Render a chat request (same JSON as se_generate_start) through the template and count prompt tokens. */
SE_API int32_t se_count_chat_tokens(const se_model * m, const char * request_json);

/* ===================================================================================================== */
/* Sessions                                                                                                */
/* ===================================================================================================== */

typedef struct se_session se_session;

/* KV cache element types: ggml_type ids (stable, they are part of the GGUF format). */
typedef enum se_kv_type {
  SE_KV_DEFAULT = -1, /* f16 */
  SE_KV_F32     = 0,
  SE_KV_F16     = 1,
  SE_KV_Q4_0    = 2,
  SE_KV_Q4_1    = 3,
  SE_KV_Q5_0    = 6,
  SE_KV_Q5_1    = 7,
  SE_KV_Q8_0    = 8,
  SE_KV_IQ4_NL  = 20,
  SE_KV_BF16    = 30
} se_kv_type;

typedef enum se_spec_type {
  SE_SPEC_AUTO      = -1, /* MTP if the model has (loaded) NextN heads, else the draft model if given, else none */
  SE_SPEC_NONE      = 0,
  SE_SPEC_NGRAM_MOD = 1,  /* self-speculation from n-grams of the context; no extra model, ~16 MB table       */
  SE_SPEC_DRAFT     = 2,  /* separate draft model (se_model_params.draft_model_path)                          */
  SE_SPEC_MTP       = 3   /* NextN heads inside the target GGUF (se_model_params.load_mtp = 1)                */
} se_spec_type;

#define SE_SEED_RANDOM 0xFFFFFFFFu

typedef struct se_session_params {
  uint32_t struct_size;
  uint32_t n_ctx;              /* 0 = 4096 capped at n_ctx_train. llama.cpp pads to a multiple of 256;
                                  read the actual value from se_session_info_json                          */
  uint32_t n_batch;            /* logical batch = prefill chunk (cancel is checked between chunks); 0 = 512   */
  uint32_t n_ubatch;           /* physical micro-batch (compute buffer scales with it); 0 = 512               */
  int32_t  n_threads;          /* <= 0: performance-core estimate (max 8)                                   */
  int32_t  n_threads_batch;    /* <= 0: same as n_threads                                                   */
  int32_t  type_k;             /* se_kv_type, default f16                                                   */
  int32_t  type_v;             /* se_kv_type. A quantized V cache requires flash attention (llama-context.cpp
                                  :3838-3848): with flash_attn = 0 session creation fails with
                                  SE_ERR_INVALID_ARG; with -1 (auto) flash attention is forced on            */
  int32_t  flash_attn;         /* -1 auto (default), 0 off, 1 on                                            */
  /* Max logits rows per decode. 0 = auto = max(1, n_draft + 1). It sizes the output/compute buffers
   * (152k-vocab models: 0.6 MB per row; the upstream default n_batch costs ~300 MB, R04 §6). Values below
   * what this session needs (n_seq_max = 1, n_draft + 1) are rejected instead of hitting GGML_ASSERT. */
  uint32_t n_outputs_max;
  int32_t  swa_full;           /* -1 default (on: full-size SWA cache keeps prefix caching exact), 0, 1      */
  uint32_t seed;               /* default sampling seed when a request has none; SE_SEED_RANDOM            */
  int32_t  spec_type;          /* se_spec_type, default SE_SPEC_NONE                                        */
  int32_t  spec_n_max;         /* max drafted tokens per step; 0 = 16                                       */
  int32_t  spec_n_min;         /* min draft length (n-gram); 0 = 4                                          */
  int32_t  spec_ngram_n_match; /* n-gram key length; 0 = 12                                                 */
  float    spec_min_accept;    /* speculation switches itself off for the rest of a generation when the
                                  acceptance rate stays below this after spec_min_drafted tokens; 0 = 0.30,
                                  < 0 = never                                                               */
  int32_t  spec_min_drafted;   /* 0 = 48                                                                    */
  uint32_t event_capacity;     /* ring buffer slots; 0 = 256. A full ring blocks the worker (backpressure)  */
} se_session_params;

SE_API void      se_session_params_init(se_session_params * p);
SE_API se_status se_session_create(se_model * m, const se_session_params * p, se_session ** out);
/* Cancels a running generation, joins the worker, frees KV and buffers. */
SE_API void      se_session_free(se_session * s);
/* Drop the token history and clear the KV cache (the next request prefills from scratch). */
SE_API se_status se_session_reset(se_session * s);
SE_API se_status se_session_set_threads(se_session * s, int32_t n_threads, int32_t n_threads_batch);
/* JSON: resolved n_ctx / n_ctx_seq / n_batch / n_ubatch / threads / KV types / flash attention / outputs,
 * history length, speculative config and lifetime stats, active LoRA set, memory breakdown, busy flag. */
SE_API int32_t   se_session_info_json(se_session * s, char * buf, int32_t cap);

/* ===================================================================================================== */
/* Generation                                                                                              */
/* ===================================================================================================== */

typedef enum se_event_type {
  SE_EVENT_TEXT_DELTA           = 1,  /* text                                                                 */
  SE_EVENT_REASONING_DELTA      = 2,  /* text                                                                 */
  SE_EVENT_TOOL_CALL_START      = 3,  /* index, id, name                                                      */
  SE_EVENT_TOOL_CALL_ARGS_DELTA = 4,  /* index, id, text = arguments fragment                                 */
  SE_EVENT_TOOL_CALL_DONE       = 5,  /* index, id, name, text = complete arguments JSON                      */
  SE_EVENT_USAGE                = 6,  /* prompt_tokens, cached_tokens, completion_tokens                      */
  SE_EVENT_PERF                 = 7,  /* ttft_ms, prefill_tps, decode_tps, draft_accept_rate, name = backend  */
  SE_EVENT_FINISH               = 8,  /* code = se_finish_reason, name = reason string,
                                         text = final assistant message JSON (OpenAI shape: role, content,
                                         reasoning_content, tool_calls[])                                    */
  SE_EVENT_ERROR                = 9,  /* code = se_status, text = message. Always followed by FINISH(error)   */
  SE_EVENT_PROMPT_PROGRESS      = 10  /* progress_done / progress_total prompt tokens decoded                */
} se_event_type;

typedef enum se_finish_reason {
  SE_FINISH_STOP       = 1, /* end-of-generation token or a stop string                    */
  SE_FINISH_LENGTH     = 2, /* max_tokens reached or the context is full                   */
  SE_FINISH_TOOL_CALLS = 3, /* stopped normally and the reply contains tool calls          */
  SE_FINISH_CANCELLED  = 4,
  SE_FINISH_ERROR      = 5
} se_finish_reason;

/* One event. Pointers are never NULL ("" when unused) and stay valid until the next se_poll_events call on
 * the same session (poll mode) or until the callback returns (callback mode). Every generation ends with
 * exactly one FINISH, preceded by USAGE and PERF (and by ERROR when code is SE_FINISH_ERROR). */
typedef struct se_event {
  uint32_t     struct_size;
  int32_t      type;              /* se_event_type                                              */
  uint32_t     generation_id;     /* from se_generate_start                                     */
  int32_t      index;             /* tool call index, -1 otherwise                              */
  int32_t      code;              /* FINISH: se_finish_reason; ERROR: se_status                 */
  uint32_t     text_len;          /* bytes in text (excluding NUL)                              */
  const char * text;
  const char * id;                /* tool call id                                               */
  const char * name;              /* tool name; PERF: backend; FINISH: "stop" | "length" | ...  */
  int32_t      prompt_tokens;     /* USAGE                                                      */
  int32_t      cached_tokens;     /* USAGE: prompt tokens reused from the KV cache              */
  int32_t      completion_tokens; /* USAGE                                                      */
  int32_t      n_drafted;         /* PERF: speculative tokens proposed / accepted               */
  int32_t      n_accepted;
  int32_t      progress_done;     /* PROMPT_PROGRESS                                            */
  int32_t      progress_total;
  int32_t      reserved0;
  double       ttft_ms;           /* PERF: request accepted -> first token sampled              */
  double       prefill_tps;       /* PERF: uncached prompt tokens / prefill time                */
  double       decode_tps;        /* PERF: generated tokens / decode time                       */
  double       draft_accept_rate; /* PERF: n_accepted / n_drafted (0 if nothing was drafted)    */
  double       prefill_ms;
  double       decode_ms;
} se_event;

/* Start a generation from an OpenAI-style chat request and return immediately; the work runs on the
 * session's worker thread. Request JSON (unknown keys are ignored):
 *   messages[]            role system|user|assistant|tool; content (string or [{type:"text",text}]);
 *                         assistant tool_calls[{id,type:"function",function:{name,arguments}}] and
 *                         reasoning_content; tool messages tool_call_id (+ name)
 *   tools[]               [{type:"function", function:{name, description, parameters}}]
 *   tool_choice           "auto" (default) | "none" | "required" | {type:"function",function:{name}}
 *   parallel_tool_calls   bool (default: what the template supports)
 *   enable_thinking       bool (default true when the template supports it); also reasoning_effort:"none",
 *                         chat_template_kwargs.enable_thinking
 *   reasoning_format      "deepseek" (default: reasoning goes to REASONING_DELTA) | "none" | "auto"
 *   reasoning_budget_tokens  int, -1 = unlimited
 *   response_format       {type:"json_object"} | {type:"json_schema", json_schema:{schema}}; or json_schema
 *   grammar               GBNF string (not together with tools)
 *   temperature top_k top_p min_p typical_p repeat_penalty presence_penalty frequency_penalty
 *   penalty_last_n seed dry_multiplier dry_base dry_allowed_length xtc_probability xtc_threshold
 *   max_tokens            (or max_completion_tokens / n_predict); default: until EOG or context full
 *   stop                  string | [string]
 *   cache_prompt          bool, default true (reuse the longest common prefix of the KV cache)
 *   speculative           bool, default true when the session has speculation configured
 *   add_generation_prompt bool (default true); continue_final_message
 * Returns SE_ERR_BUSY if a generation is running and SE_ERR_INVALID_ARG for malformed JSON. Template,
 * grammar, context and decode errors are reported as ERROR + FINISH(error) events. */
SE_API se_status se_generate_start(se_session * s, const char * request_json, uint32_t * generation_id_out);

/* Drain up to max_events (<= 0: all available) events. Blocks up to timeout_ms (0: don't block, < 0: wait
 * forever) when none are queued. On return *events points to an engine-owned array of *n_events events,
 * valid until the next se_poll_events call on this session; the previous batch is released by this call.
 * Single consumer: call from one thread at a time. Returns SE_OK (possibly with *n_events == 0). */
SE_API se_status se_poll_events(se_session * s, int32_t timeout_ms, int32_t max_events,
                                const se_event ** events, int32_t * n_events);

/* Optional push delivery, invoked synchronously on the worker thread for every event (slow callbacks
 * apply backpressure). The event is valid only during the call, so an asynchronous Dart
 * NativeCallable.listener must not be used with it; Dart should poll. queue_too = 1 also queues events
 * for se_poll_events. Only while idle (SE_ERR_BUSY otherwise). cb = NULL restores poll-only delivery. */
typedef void (*se_event_cb)(const se_event * ev, void * user);
SE_API se_status se_set_event_callback(se_session * s, se_event_cb cb, void * user, int32_t queue_too);

/* Request cancellation of the running generation. Thread-safe, idempotent, returns immediately. It is
 * observed between tokens, between prefill chunks, while blocked on a full event ring, and inside
 * llama_decode through ggml's abort callback (a long prefill chunk stops mid-way). FINISH(cancelled)
 * follows. SE_OK also when nothing is running. */
SE_API se_status se_cancel(se_session * s);

/* Wait until the session is idle: SE_OK, or SE_ERR_TIMEOUT. timeout_ms 0 = poll the busy state, < 0 =
 * forever. Undelivered events stay queued. */
SE_API se_status se_wait(se_session * s, int32_t timeout_ms);

/* ===================================================================================================== */
/* Prompt cache persistence (sequence state files)                                                         */
/* ===================================================================================================== */

/* Save the session's KV cache + token history to `path` (written atomically via a temp file). The file
 * has a Sherpa header (model id + fingerprint + shape, LoRA set, n_ctx, KV types, flash attention, engine
 * and llama.cpp versions) because llama.cpp's own state validation checks only the layer count, cell count,
 * K/V types and V layout (llama-kv-cache.cpp:2549-2577), not the weights or adapters. */
SE_API se_status se_state_save(se_session * s, const char * path);
/* Restore a file written by se_state_save. Refuses (SE_ERR_STATE_MISMATCH) files from another model, LoRA
 * set, KV type or flash-attention layout, or larger than this session's n_ctx; the session is unchanged
 * then. State files carry no logits (llama-context.cpp:3397-3440), so the engine never samples from
 * restored logits: the next generation re-decodes at least the last prompt token. */
SE_API se_status se_state_load(se_session * s, const char * path, int32_t * n_tokens_out);

/* ===================================================================================================== */
/* LoRA adapters                                                                                           */
/* ===================================================================================================== */

typedef struct se_lora se_lora;
SE_API se_status se_lora_load(se_model * m, const char * path, se_lora ** out);
SE_API void      se_lora_free(se_lora * l);   /* deferred while a session still uses the adapter */
/* Replace the session's whole adapter set (llama_set_adapters_lora is replace-only; scale 0 drops one).
 * No model reload; the next decode re-reserves the graph. Changing the set invalidates the prompt cache.
 * n = 0 removes all adapters. */
SE_API se_status se_session_set_loras(se_session * s, se_lora * const * loras, const float * scales, int32_t n);

/* ===================================================================================================== */
/* Memory planning                                                                                         */
/* ===================================================================================================== */

typedef struct se_memory_estimate {
  uint32_t struct_size;
  uint32_t n_ctx;              /* resolved (padded) context                                         */
  uint32_t n_ctx_seq;
  int32_t  flash_attn;         /* resolved: 1 on, 0 off                                              */
  uint64_t model_bytes;        /* weight buffers incl. repack copies (mmap'd file pages included)    */
  uint64_t model_mapped_bytes; /* part of model_bytes that is file-backed (mmap): reclaimable by the OS */
  uint64_t kv_bytes;           /* KV cache / recurrent state                                         */
  uint64_t compute_bytes;      /* scheduler compute buffers                                          */
  uint64_t output_bytes;       /* logits buffer: n_vocab * n_outputs_max * 4                         */
  uint64_t total_bytes;        /* model + kv + compute + output                                      */
  uint64_t kv_bytes_per_token; /* kv_bytes / n_ctx                                                    */
  uint64_t file_bytes;         /* GGUF file size                                                     */
} se_memory_estimate;

/* Dry run without reading weights: loads metadata with no_alloc (which requires LOAD_MODE_NONE, forced
 * here because otherwise GGML_ASSERT(!ml.no_alloc) aborts, llama-model.cpp:1855), creates a context with
 * the session params and sums llama_get_memory_breakdown (model + KV + compute), plus the logits buffer.
 * Session params are validated exactly like se_session_create. `mp` may be NULL. */
SE_API se_status se_estimate_memory(const char * path, const se_model_params * mp, const se_session_params * sp,
                                    se_memory_estimate * out);
/* The same breakdown for a live session (real allocations). */
SE_API se_status se_session_memory(se_session * s, se_memory_estimate * out);

/* ===================================================================================================== */
/* Quick benchmark (first-run autotune)                                                                    */
/* ===================================================================================================== */

typedef struct se_bench_params {
  uint32_t       struct_size;
  int32_t        n_threads;       /* <= 0 auto                       */
  int32_t        n_threads_batch; /* <= 0 = n_threads               */
  uint32_t       n_batch;         /* 0 = 512                         */
  uint32_t       n_ubatch;        /* 0 = 512                         */
  uint32_t       n_ctx;           /* 0 = n_prompt + n_gen rounded up */
  int32_t        n_prompt;        /* prompt-processing tokens, 0 = 128 */
  int32_t        n_gen;           /* generated tokens, 0 = 32       */
  int32_t        n_reps;          /* 0 = 2 (the first is warm-up when > 1) */
  int32_t        type_k;
  int32_t        type_v;
  int32_t        flash_attn;
  se_canceller * cancel;          /* optional */
} se_bench_params;

typedef struct se_bench_result {
  uint32_t struct_size;
  int32_t  n_prompt;
  int32_t  n_gen;
  int32_t  n_threads;
  double   pp_tps;     /* prompt processing tokens/s (mean of measured reps) */
  double   tg_tps;     /* generation tokens/s                                 */
  double   pp_ms;
  double   tg_ms;
} se_bench_result;

SE_API void      se_bench_params_init(se_bench_params * p);
/* Blocking. Creates a temporary context on `m` (synthetic tokens, greedy, no sampling cost). */
SE_API se_status se_bench(se_model * m, const se_bench_params * p, se_bench_result * out);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* SHERPA_ENGINE_H */
