# sherpa_engine C ABI changelog

The ABI is versioned by `SE_ABI_VERSION` (`se_abi_version()`). Rules: params/out structs only grow at the
end (callers declare `struct_size`; fields beyond it keep engine defaults); enum values and event field
meanings never change; a removal or semantic change bumps the major ABI version. JSON payloads may gain
keys at any time, so consumers must ignore unknown keys.

`SE_ABI_VERSION` is the major version. Additions raise `SE_ABI_MINOR` (`se_abi_minor()`, added in 1.1;
an engine without the symbol is 1.0): a caller written for 1.0 keeps working against a 1.1 engine, and a
caller that wants an addition checks the minor version (or the symbol) first.

## ABI 1.1 — 2026-10-19 (engine 1.1.0, llama.cpp `0c1e57098`)

Image input through the vision projector (`se_model_params.mmproj_path`, `SHERPA_ENGINE_MTMD` builds).

- **`se_abi_minor()`** and `SE_ABI_MINOR` (1).
- **Image content parts** in `se_generate_start` / `se_count_chat_tokens` requests:
  `{type:"image_url", image_url:{url:"data:image/<type>;base64,…"}}` (no remote URLs). Rendered as a per-load
  random media marker, tokenized by mtmd, encoded and decoded into the KV in prompt order. Refused with
  `SE_ERR_UNSUPPORTED` without a vision projector (or without mtmd); undecodable bytes are
  `SE_ERR_INVALID_ARG`.
- **`se_generate_start_ex(session, se_generate_params*, id*)`** with `se_generate_params`
  (`struct_size`, `request_json`, `media`, `n_media`, `se_generate_params_init()`) and `se_media`
  (`struct_size`, `type` = `SE_MEDIA_IMAGE`, `data`, `size`; array stride = `media[0].struct_size`):
  raw image buffers referenced from the request as `{type:"media", index:N}`, copied before the call
  returns.
- **Prompt cache with images**: an image's positions hold a pseudo token (≤ -2) derived from the SHA-256
  of its bytes, so an unchanged image is reused from the KV (and from state files, whose token check
  accepts pseudo tokens) and a changed one re-decodes from there; the cache never resumes inside an image.
  With a projector loaded, the state identity header also carries its fingerprint (`mmproj`), so a
  state file is not restored through another projector.
  Speculative decoding is skipped when the prompt holds images. `USAGE.prompt_tokens` /
  `cached_tokens` and `PROMPT_PROGRESS` count KV cells (an M-RoPE image takes more cells than positions).
- Images whose chunk needs non-causal attention (Gemma 3) and exceeds `n_batch`/`n_ubatch` are refused
  (`SE_ERR_INVALID_ARG`) instead of hitting llama.cpp's `n_ubatch >= n_tokens` assertion.
- JSON: `se_model_info_json` `mmproj.image_input` (true only with a loaded vision projector) and
  `mmproj.mrope`; `se_system_info_json` `abi_minor` and `image_input` (an mtmd build). mtmd/clip logs go
  through the engine's log callback. The version string reads `abi 1.1`.

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
