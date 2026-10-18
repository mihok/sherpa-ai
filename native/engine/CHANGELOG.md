# sherpa_engine C ABI changelog

The ABI is versioned by `SE_ABI_VERSION` (`se_abi_version()`). Rules: params/out structs only grow at the
end (callers declare `struct_size`; fields beyond it keep engine defaults); enum values and event field
meanings never change; a removal or semantic change bumps the major ABI version. JSON payloads may gain
keys at any time, so consumers must ignore unknown keys.

## ABI 1 — 2026-10-18 (engine 1.0.0, llama.cpp `0c1e57098`)

First version, built on llama.cpp `0c1e57098bba43ac29e6e3b677cdceebdd22334f` + `common/`.

- **Errors**: integer `se_status` codes, thread-local `se_last_error()` / `se_last_error_code()`,
  `se_status_name()`. No C++ exception or known `GGML_ASSERT` crosses the boundary.
- **Backend**: `se_backend_init()` (optional, once per process; Android loads the best
  `libggml-cpu-android_*` variant by bare file name), `se_system_info_json()` (runtime CPU features,
  devices, loaded variant), `se_version_string()`.
- **Cancellation tokens**: `se_canceller_*` for the blocking calls (model load, bench).
- **Models**: `se_model_load()` (progress callback, cancel, `load_mode`, `n_gpu_layers`, weight repack,
  optional draft model, MTP heads, mmproj when built with mtmd), `se_model_free()`,
  `se_model_info_json()` (shape, KV bytes/token, chat-template caps, tool-call classification
  `native_grammar | parsed_without_grammar | none`, thinking support, recommended sampling),
  `se_tokenize()`, `se_detokenize()`, `se_count_chat_tokens()`.
- **Memory planning**: `se_estimate_memory()` (no-alloc dry run, mmap-aware) and `se_session_memory()`.
- **Sessions**: `se_session_create()` (n_ctx/batch/ubatch, threads, K/V types with the
  quantized-V-needs-flash-attention rule, flash attention, safe `n_outputs_max`, SWA cache, seed,
  speculative decoding: n-gram self-speculation, draft model, MTP), `se_session_free()`,
  `se_session_reset()`, `se_session_set_threads()`, `se_session_info_json()`.
- **Generation**: `se_generate_start()` (OpenAI-style chat JSON: messages incl. tool calls/results and
  reasoning, tools, tool_choice, parallel_tool_calls, thinking, JSON schema / GBNF, sampling, max_tokens,
  stop, cache_prompt, speculative), `se_poll_events()` (pull, zero-copy batches), `se_set_event_callback()`
  (push), `se_cancel()`, `se_wait()`. Events: TEXT_DELTA, REASONING_DELTA, TOOL_CALL_START,
  TOOL_CALL_ARGS_DELTA, TOOL_CALL_DONE, USAGE, PERF, FINISH, ERROR, PROMPT_PROGRESS.
- **Prompt cache**: automatic longest-common-prefix reuse per session; `se_state_save()` /
  `se_state_load()` with a Sherpa identity header (model id + fingerprint, LoRA set, KV types,
  flash-attention layout, llama.cpp commit).
- **LoRA**: `se_lora_load()`, `se_lora_free()`, `se_session_set_loras()` (replace-only set, no reload,
  invalidates the prompt cache when the set changes).
- **Bench**: `se_bench()` (prompt-processing and generation tokens/s for a given shape).
