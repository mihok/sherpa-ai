# 04 — llama.cpp C/C++ API for Sherpa's embedded engine

Status: research digest, 2026-10-18. Scope: the C API (`include/llama.h`), the C++ helpers in `common/` (chat templates,
tool-call parsing, sampling, speculative decoding, state checkpoints), `tools/mtmd`, and the usage patterns in `tools/server`,
`examples/speculative*` and `examples/llama.android`, as they matter for a mobile engine behind Dart FFI / JNI.
Building, packaging and backend selection are covered in `05-llamacpp-build.md`; this doc does not repeat them.

Conventions
- `llama.cpp/<path>:<line>` = the pinned tree at `/opt/vendor-src/llama-py/llama_cpp_python-0.3.36/vendor/llama.cpp`
  (ggml-org/llama.cpp commit `0c1e57098bba43ac29e6e3b677cdceebdd22334f`, 2026-10-01; `LLAMA_VERSION "0.5.0-dev"`,
  `GGML_VERSION "0.25.3"` per the host build's `src/llama-version.h` / `ggml/src/ggml-version.h`).
- **PROBE-n** = a C++ program I compiled against the host static build (`/opt/vendor-src/llama-host-build`, x86-64, CPU only,
  AVX-512/AMX, OpenMP) and ran on `/opt/models/Qwen3-0.6B-Q4_K_M.gguf`. Sources: `/tmp/claude-0/llamacpp-api-probes/p*.cpp`.
- **UNVERIFIED** = not confirmed by source reading or a probe in this session.
- The host had other heavy jobs running (Gradle/Kotlin daemons, load avg about 5 on 4 cores). Throughput numbers are noisy.
  Use them for ratios only, never as mobile expectations.

---

## 0. TL;DR

1. **This tree is much newer than most llama.cpp knowledge.** `use_mmap`/`use_mlock` are gone (now `enum llama_load_mode`).
   The `flash_attn` bool is gone (now `enum llama_flash_attn_type`, default AUTO). LoRA is applied only with
   `llama_set_adapters_lora` (the plural form). There is a new `llama_batch_ext` / `llama_process()` API, and a
   `LLAMA_CONTEXT_TYPE_MTP` context type. Chat formats collapsed to `CONTENT_ONLY`, `PEG_SIMPLE`, `PEG_NATIVE`, `PEG_GEMMA4` and
   `PEG_MINIMAX_M3`. All tool-call parsing now goes through a PEG parser, generated either by about 17 specialized handlers or by
   a "differential autoparser" that reads the Jinja template (`common/chat.h:228-238`, `common/chat.cpp:1090-1366`).
2. **The chat pipeline works for Qwen3 out of the box** (PROBE-2/3). `common_chat_templates_apply` with tools returns a lazy
   GBNF grammar (trigger word `"<tool_call>\n"`), 4 preserved tokens, a serialized PEG parser string, and a `generation_prompt`.
   Greedy generation with `common_sampler` produced `<tool_call>{"name":"get_weather","arguments":{"city":"Paris"}}</tool_call>`,
   and `common_chat_parse` turned it into a structured tool call. Streaming partial parse plus
   `common_chat_msg_diff::compute_diffs` yields clean reasoning, content and tool-argument deltas.
3. **All 70 bundled templates apply without error with tools** (PROBE-6). However, **Llama 3.1/3.2/3.3, Phi-3.5, Gemma 2,
   SmolLM3 and Granite 3.3 get no grammar and no trigger** in `tool_choice=auto`. For Llama 3.2 the parser still extracts a bare
   JSON call (PROBE-6b), but generation is unconstrained. `docs/function-calling.md` is stale: it still lists "Generic" and
   named formats that no longer exist in code.
4. **Reasoning extraction is baked into the parser at apply time.** Set `common_chat_templates_inputs.reasoning_format`, for
   example `DEEPSEEK`. Setting it only on `common_chat_parser_params` has no effect (PROBE-2).
5. **KV cache bytes per token = Σ_layers [row_size(type_k, n_head_kv·head_dim_k) + row_size(type_v, n_head_kv·head_dim_v)].**
   Qwen3-0.6B (28 layers, 8 KV heads, head_dim 128) costs 112 KiB/token in f16 and 59.5 KiB/token in q8_0. At n_ctx 4096 that is
   **448 MiB vs 238 MiB** (q4_0: 126 MiB), exactly as measured (PROBE-1).
   `n_embd/n_head` gives the wrong head_dim for Qwen3 (64 instead of 128). Read `<arch>.attention.key_length` instead, or better,
   use the `no_alloc` dry run.
6. **Quantized V cache requires flash attention.** With `flash_attn_type=AUTO` it is force-enabled. With `DISABLED`, context
   creation returns NULL (`src/llama-context.cpp:3838-3848`; PROBE-1). A quantized K cache alone works without FA.
7. **The compute buffer is the hidden memory hog.** With default `n_outputs_max=0` (meaning `n_batch` outputs), Qwen3's
   152k-vocab logits buffer reserves **302.8 MiB**. With `n_outputs_max=1` it drops to **30.1 MiB**
   (`n_ubatch` 256 gives 15.1 MiB; 128 gives 7.6 MiB) (PROBE-1b). Caveat: `n_outputs_max < n_seq_max` hits a
   **GGML_ASSERT and kills the process** (`src/llama-context.cpp:2273`, via `:377`; PROBE-4).
8. **`n_ctx` is padded up to a multiple of 256** (1000 becomes 1024). With `n_seq_max>1` and `kv_unified=false` it is split per
   sequence and padded again: 4096 with 3 sequences becomes **4608** total, 1536 per sequence
   (`src/llama-context.cpp:290-305`; PROBE-1). Always read back `llama_n_ctx`/`llama_n_ctx_seq`.
9. **`llama_decode` return codes, verified:** `0` ok; `1` no KV slot (context full); `2` aborted by `abort_callback` (the
   aborted ubatch's positions are removed); `-1` invalid batch; `-2`/`-3` allocation/compute failure
   (`include/llama.h:991-1005`, `src/llama-context.cpp:1812-1919`; PROBE-3).
10. **Whole-context state (`llama_state_*`) no longer contains logits.** Only the arch string and memory are saved
    (`src/llama-context.cpp:3397-3440`). The header comment at `include/llama.h:824` is stale. After any state load, re-decode
    the last token (or call `common_replay_last_token`) before sampling. PROBE-3 shows that skipping the replay gives wrong
    continuations, while seq-state restore plus replay matches bit-for-bit.
11. **Sequence state works for prefix caching.** `llama_state_seq_get/set_data[_ext]` and `llama_state_seq_save/load_file`
    round-tripped exactly, into the same or a different seq_id (PROBE-3). The format is versioned
    (`LLAMA_STATE_SEQ_VERSION 3`). It is validated against layer count, K/V type and V-transposition (which depends on FA), so
    the cache key must include those.
12. **Several C entry points throw C++ exceptions or abort.** `llama_token_to_piece` with an out-of-range id throws
    `std::out_of_range` (PROBE-3). Grammar `accept` throws on a non-matching token. `no_alloc` with `load_mode` other than NONE
    hits `GGML_ASSERT` (`src/llama-model.cpp:1855`). The FFI shim **must** pre-validate and wrap everything in `try/catch`.
13. **Speculative decoding API was redesigned** (`common/speculative.h`): `common_speculative_init(params, n_seq)`, then per-seq
    `get_draft_params()`, `draft()`, `process(batch)` and `accept(seq, n)`. There are 10 types, including n-gram self-speculation
    with no draft model, `draft-simple`, `draft-eagle3`, `draft-mtp` (NextN heads in the target GGUF), and dflash/dspark.
    PROBE-5: `ngram-mod` reached 84% acceptance and 4.0 tokens/iteration on a repetitive JSON task, 93.6 t/s against about
    35-40 t/s baseline. A same-model draft reached 100% and 9 tokens/iteration.
14. **Perf counters are off by default.** `llama_context_default_params().no_perf = true`, so timings stay 0 while counts still
    accumulate. Stats are folded in only at `llama_synchronize()`, which reading logits triggers (PROBE-7).
15. **`ggml_cpu_has_dotprod/matmul_int8/sve/sme` report compile-time flags of the loaded CPU backend**, not the device
    (`ggml/src/ggml-cpu/ggml-cpu.c:3811-3849`). Runtime ARM features drive only the variant scoring in `GGML_BACKEND_DL` builds
    (`ggml/src/ggml-cpu/arch/arm/cpu-feats.cpp`). There is no `ggml_cpu_has_i8mm`; the function is `ggml_cpu_has_matmul_int8`.
16. **Proposed Sherpa ABI (§20):** one C++ shim, `libsherpa_engine`, with a stable, versioned C ABI of about 30 functions. It owns
    llama + common (chat/tool parse, sampling, speculative, prefix cache, mtmd), exposes pull-based events (a ring buffer) plus
    an optional callback, an atomic cancel flag that also drives `abort_callback`, `struct_size`-prefixed params, and integer
    error codes with a thread-local message.

---

## 1. API surface and stability tiers

| Layer | Header | Language | Stability at this commit | Sherpa usage |
|---|---|---|---|---|
| Core | `include/llama.h` (1739 lines) | C | Mostly stable, with explicit `DEPRECATED()` shims. Struct layouts change between versions (fields were added mid-struct, e.g. `load_mode`/`lazy_mode` in `llama_model_params`) | Call **only from the C++ shim**, never directly from Dart |
| C++ RAII | `include/llama-cpp.h` | C++ | Stable | Shim internals |
| Staging | `src/llama-ext.h` (not installed) | C++ | "breaking changes allowed, WIP" (`src/llama-ext.h:3-5`) | `llama_get_memory_breakdown` for memory telemetry (vendor the header) |
| ggml | `ggml/include/ggml.h`, `ggml-backend.h`, `ggml-cpu.h` | C | Stable-ish | Backend loading, device enumeration, abort hook |
| common | `common/*.h` (`libllama-common.a`) | C++17, uses a `common_json` wrapper (nlohmann pimpl) | **Unstable, no ABI promise.** Big refactors between releases (chat formats, speculative API) | Chat templates, tool parsing, sampler, speculative, checkpoints |
| mtmd | `tools/mtmd/mtmd.h`, `mtmd-helper.h` | C with C++ wrappers | "experimental and subject to many BREAKING CHANGES" (`tools/mtmd/mtmd.h:22-23`) | Vision/audio |

Consequence: pin the exact commit. Compile `libllama` + `libggml*` + `libllama-common` + `libmtmd` + Sherpa's shim into one
artifact per platform. Expose only the shim's C ABI to Dart and Kotlin/Swift.

---

## 2. Backend initialisation and devices

- `void llama_backend_init(void)` (`include/llama.h:486`; impl `src/llama.cpp:122-134`) runs `ggml_time_init()`,
  initialises the f16 tables, and **calls `ggml_backend_load_all()` only if `ggml_backend_reg_count()==0`**.
- Static builds (iOS xcframework, the host build) register compiled-in backends in the registry constructor
  (`ggml/src/ggml-backend-reg.cpp:~115-173`: CUDA, Metal, Vulkan, OpenCL, Hexagon, BLAS, …, CPU last), so `load_all` is a no-op.
- `GGML_BACKEND_DL` builds (Android) must call `ggml_backend_load_all_from_path(dir)` **before** `llama_backend_init()`
  (`examples/llama.android/lib/src/main/cpp/ai_chat.cpp:44-56`). `ggml_backend_load_best()` *enumerates the directory*
  (`ggml-backend-reg.cpp:480-530`), so the example needs `android:extractNativeLibs="true"`
  (`examples/llama.android/app/src/main/AndroidManifest.xml:7`). See 05 §4.3 for the workaround with no file listing.
  `GGML_BACKEND_PATH` env adds an out-of-tree backend (`:600-604`).
- `void llama_backend_free(void)` (`:489`), `llama_numa_init` (not relevant on mobile).
- Devices: `ggml_backend_dev_count/get/by_type`, `ggml_backend_dev_memory(dev,&free,&total)`, and
  `enum ggml_backend_dev_type {CPU, GPU, IGPU, ACCEL, META}` (`ggml/include/ggml-backend.h:134-144,183,241-260`).
  On the host, the CPU device reports free == total == physical RAM (PROBE-1). That is useless as a jetsam/LMK budget.
- Capability queries: `llama_supports_mmap/mlock/gpu_offload/rpc()`, `llama_max_devices()` (16), and
  `llama_max_parallel_sequences()` (256 = `LLAMA_MAX_SEQ`, `src/llama-cparams.h:8`) (`include/llama.h:563-570`).
- Logging: `llama_log_set(ggml_log_callback, void*)` is **global and not thread-safe** (`include/llama.h:1663-1667`).
  `mtmd_helper_log_set` also calls `mtmd_log_set`.
- Fatal-error hook: `ggml_set_abort_callback(void (*)(const char*))` (`ggml/include/ggml.h:349-353`). It is called with the
  message *before* `abort()` (`ggml/src/ggml.c:253-273`). Use it to write a crash breadcrumb. It cannot prevent the abort.

---

## 3. Model loading — `struct llama_model_params` (`include/llama.h:319-356`; defaults `src/llama-model.cpp:2909-2930`)

| Field | Type | Default | Notes |
|---|---|---|---|
| `devices` | `ggml_backend_dev_t*` (NULL-terminated) | NULL = all | Restrict to CPU-only, Metal, etc. |
| `tensor_buft_overrides` | `{pattern, buft}*` (NULL-terminated) | NULL | e.g. keep MoE experts on CPU (`common/common.h:1206` `llm_ffn_exps_cpu_override`) |
| `n_gpu_layers` | int32 | **-1 = all** | In the llama.h comment, negative means all. `common_params.n_gpu_layers` -1 means "auto (fit)" and ≤-2 means all (`common/common.h:475`) |
| `split_mode` | enum | `LAYER` | NONE/LAYER/ROW/TENSOR (TENSOR forces FA) |
| `load_mode` | `enum llama_load_mode` | **AUTO (-1)** | AUTO/NONE(0)/MMAP(1)/MLOCK(2)/MMAP_MLOCK(3)/DIRECT_IO(4) (`include/llama.h:206-213`). AUTO behaves as mmap unless a selected device lacks `caps.mmap_support` (`src/llama-model.cpp:1512-1521`; `src/llama-model-loader.cpp:559-560`). PROBE-1 log: `load_mode = mmap`. MLOCK alone means read into buffers, then mlock. Helpers `llama_load_mode_name/_from_str` (`_from_str` **throws** on unknown strings, `src/llama.cpp:68-76`) |
| `lazy_mode` | `enum llama_lazy_mode` | AUTO | OFF/AUTO(lazy only for arch-marked tensors >4 GiB, needs mmap)/ON (`include/llama.h:218-222`) |
| `main_gpu`, `tensor_split` | | 0, NULL | multi-GPU only |
| `progress_callback` + `_user_data` | `bool(*)(float,void*)` | NULL | Return false to **abort loading** (it then returns NULL). PROBE-1: 312 calls for a 0.6B model. This is Sherpa's model-load cancel |
| `kv_overrides` | `llama_model_kv_override*` (terminated by `key[0]==0`) | NULL | e.g. override `tokenizer.chat_template`? Prefer the template override in common |
| `vocab_only` | bool | false | Tokenizer + metadata + chat template, no weights. Used in PROBE-2 for fast template work |
| `check_tensors` | bool | false | Validates tensor data (slow; useful after download) |
| `use_extra_bufts` | bool | **true** | Weight repacking buffers (CPU_REPACK / AMX / KleidiAI). On the host it **duplicated** the matmul weights (AMX 378 MiB + CPU_Mapped 371 MiB; with `false`, 372.7 MiB) (PROBE-1/1b). On-device RSS effect is UNVERIFIED (§22) |
| `no_host` | bool | false | Skip host buffer |
| `no_alloc` | bool | false | **Dry run**: metadata plus simulated allocations. **Requires `load_mode = LLAMA_LOAD_MODE_NONE`**, otherwise `GGML_ASSERT(!ml.no_alloc)` aborts (`src/llama-model.cpp:1855`; PROBE-1b; `common/fit.cpp:56-58` does exactly this). With a dry-run model, `llama_init_from_model` + `llama_get_memory_breakdown` give exact model/KV/compute bytes |
| `load_mtp` | bool | false | Load NextN/MTP layers (for `draft-mtp`) |
| — | — | — | `use_direct_io` does not exist as a bool. It is `load_mode = LLAMA_LOAD_MODE_DIRECT_IO` |

Loaders (`include/llama.h:508-547`):
- `llama_model_load_from_file(path, params)` (split files auto-detected by the `-%05d-of-%05d.gguf` name).
- `llama_model_load_from_file_ptr(FILE*, params)`: reads from the current offset. mmap needs the data section 32-byte aligned
  (`:526-531`). This is useful for Android `AssetFileDescriptor`/SAF fds via `fdopen` (UNVERIFIED on device).
- `llama_model_load_from_splits(paths, n, params)`.
- `llama_model_init_from_user(gguf_ctx, set_tensor_data_cb, ud, params)`.
- `llama_model_free(model)`.
- Deprecated: `llama_load_model_from_file`, `llama_free_model`.

---

## 4. Model metadata and introspection

Functions (`include/llama.h:593-680`):
- `llama_model_get_vocab`, `llama_model_rope_type`, `llama_model_n_ctx_train`, `llama_model_n_embd`, `_n_embd_inp`,
  `_n_embd_out`, `_n_layer`, `_n_layer_nextn` (MTP heads), `_n_head`, `_n_head_kv`, `_n_swa`,
  `llama_model_rope_freq_scale_train`, `llama_model_desc(buf)`, `llama_model_ftype` + `llama_ftype_name`,
  `llama_model_size` (tensor bytes), `llama_model_n_params`, `llama_model_has_encoder/has_decoder/is_recurrent/is_hybrid/is_diffusion`,
  `llama_model_chat_template(model, name)` (NULL name = default; `"tool_use"` = the `tokenizer.chat_template.tool_use` variant).
- `int32_t llama_model_meta_val_str(model, key, buf, size)` returns **the full value length with snprintf semantics**, even when
  truncated (PROBE-1: a 16-byte buffer returned 4905 for the Qwen3 template). It returns -1 if missing (buffer cleared).
  **Array-valued keys (e.g. `tokenizer.ggml.tokens`) return -1** (PROBE-1). Also `llama_model_meta_count`,
  `_meta_key_by_index`, `_meta_val_str_by_index`, and `llama_model_meta_key_str(enum llama_model_meta_key)` for the
  `general.sampling.*` recommended-sampling keys (`include/llama.h:281-294`). Sherpa can read the model author's recommended
  temp/top_k/top_p from these.
- Useful keys (`src/llama-arch.cpp:167-411`): `general.architecture`, `general.name`, `general.basename`, `general.size_label`,
  `general.file_type`, `general.license`, `general.quantization_version`, `<arch>.context_length`, `<arch>.block_count`,
  `<arch>.embedding_length`, `<arch>.attention.head_count_kv`, `<arch>.attention.key_length`,
  `<arch>.attention.value_length`, `<arch>.attention.sliding_window`, `tokenizer.ggml.model`, `tokenizer.ggml.pre`,
  `tokenizer.ggml.eos_token_id`, `tokenizer.chat_template`.
- PROBE-1 Qwen3-0.6B-Q4_K_M: `size=390,753,280`, `n_params=596,049,920`, `n_ctx_train=40960`, `n_embd=1024`, `n_layer=28`,
  `n_head=16`, `n_head_kv=8`, `key_length=value_length=128`, `n_swa=0`, `rope_type=2` (NEOX), vocab BPE `n_tokens=151936`,
  `eos=eot=151645`, `add_bos=0`. Six EOG ids: `</s>` 128247, `<|endoftext|>` 151643, `<|im_end|>` 151645, `<|fim_pad|>`,
  `<|repo_name|>`, `<|file_sep|>`.
- Staging (`src/llama-ext.h:84-91`): `llama_model_n_expert`, `llama_model_n_devices`, `llama_model_get_device`, and
  `llama_get_memory_breakdown(ctx)`, which returns a `std::map<buft, {model, context, compute}>`.

---

## 5. Context — `struct llama_context_params` (`include/llama.h:365-425`; defaults `src/llama-context.cpp:3754-3797`)

| Field | Default | Semantics and constraints (source) |
|---|---|---|
| `n_ctx` | 512 | 0 = `n_ctx_train`. **Padded up to a multiple of 256** (`llama-context.cpp:290`) |
| `n_batch` | 2048 | Logical max per `llama_decode`. Clamped to `n_ctx` for causal models (`:246`) |
| `n_ubatch` | 512 | Physical micro-batch, `min(n_batch, n_ubatch)` (`:248`). Scales the compute buffer roughly linearly |
| `n_seq_max` | 1 | ≤ 256. If `!kv_unified`: `n_ctx_seq = pad256(n_ctx/n_seq_max)` and `n_ctx = n_ctx_seq·n_seq_max` (`:292-305`) |
| `n_rs_seq` | 0 | [EXPERIMENTAL] recurrent-state snapshots per seq for rollback. Clamped to 0 if the arch can't do it (`:103-108`). Speculative MTP/EAGLE3/DFlash ask for `draft.n_max` (`common/common.h` `need_n_rs_seq`) |
| `n_outputs_max` | 0 (= n_batch) | Max outputs per ubatch. **Dominates the compute buffer for large vocabularies** (PROBE-1b). **Must be ≥ n_seq_max** or the process aborts (`:377` then `:2273`) |
| `n_outputs_max_per_seq` | **1** | Raise to `n_draft+1` for speculative verification (`common_speculative_get_output_limits`, `common/speculative.cpp:2586-2597`) |
| `n_threads` / `n_threads_batch` | `GGML_DEFAULT_N_THREADS`=4 (`ggml/include/ggml.h:232`) | Change later with `llama_set_n_threads(ctx, gen, batch)` (`include/llama.h:1095`) |
| `ctx_type` | DEFAULT | `LLAMA_CONTEXT_TYPE_MTP` creates an MTP draft context. Returns NULL if the model has no NextN layers (`:3881-3885`) |
| `rope_scaling_type`, `rope_freq_base/scale`, `yarn_*` | from model | |
| `pooling_type`, `attention_type`, `embeddings` | unspecified/false | For embedding models |
| `flash_attn_type` | **AUTO (-1)** | `LLAMA_FLASH_ATTN_TYPE_{AUTO=-1, DISABLED=0, ENABLED=1}` (`include/llama.h:191-195`). AUTO is resolved after a graph-reserve probe: FA is kept only if every layer's FA op lands on that layer's device (`llama-context.cpp:510-560`) |
| `type_k` / `type_v` | F16 / F16 | [EXPERIMENTAL]. **Quantized V needs FA**: AUTO is forced to ENABLED, DISABLED gives NULL (`:3838-3848`, re-checked `:465-468`). With FA, the quant block size must divide head_dim (`:3850-3870`). MLA/DeepSeek4 require `type_k == type_v` (`:3834-3837`) |
| `defrag_thold` | -1 | **[DEPRECATED]** |
| `cb_eval` / `_user_data` | NULL | Per-tensor eval callback (debug) |
| `abort_callback` / `_data` | NULL | `bool(*)(void*)`. Returning true aborts `llama_decode` with code 2. The header says CPU only (`include/llama.h:398-402`), but the Metal backend also polls it between command buffers (`ggml/src/ggml-metal/ggml-metal-context.m:586-644,774`). Vulkan/OpenCL: UNVERIFIED. Also settable with `llama_set_abort_callback` (`:1123`) |
| `offload_kqv` | true | KV + KQV on GPU |
| `no_perf` | **true** | **Timings are not measured by default** (§16) |
| `op_offload` | true | Offload host-tensor ops to the device |
| `swa_full` | **true** | Full-size SWA cache (more memory, but prompt-cache friendly). `common_params.swa_full` defaults to **false** (`common/common.h:574`). SWA cache size when false: `pad256(min(n_ctx, n_swa·(unified?n_seq:1)+n_ubatch))` (`src/llama-kv-cache-iswa.cpp:73-80`) |
| `kv_unified` | false | One KV buffer shared by all sequences (lets `n_ctx_seq = n_ctx`; required for cheap `seq_cp` prefix sharing) |
| `samplers` / `n_samplers` | NULL/0 | [EXPERIMENTAL] backend (on-GPU) sampler chains per seq |
| `ctx_other` | NULL | Parent/target context (draft models share memory; Gemma4Assistant/EAGLE3/DFlash require it, `:150-170`) |

Create with `llama_init_from_model(model, params)` (`include/llama.h:549`), which returns NULL on failure (exceptions are caught,
`src/llama-context.cpp:3887-3900`). Free with `llama_free(ctx)`. Deprecated: `llama_new_context_with_model`.
After creation, **query actual values** (`include/llama.h:572-580`): `llama_n_ctx`, `llama_n_ctx_seq`, `llama_n_batch`,
`llama_n_ubatch`, `llama_n_seq_max`, `llama_n_rs_seq`, `llama_n_threads[_batch]`, and `llama_get_memory(ctx)`.

PROBE-1 actual values: `n_ctx=1000` gives `1024`. `n_ctx=4096, n_seq_max=3, unified=0` gives `n_ctx=4608, n_ctx_seq=1536`
and **504 MiB** KV. With `unified=1` it gives `n_ctx=n_ctx_seq=4096` and 448 MiB.

---

## 6. Memory sizing (KV, compute, model) and the dry-run estimator

**KV formula** (from `src/llama-kv-cache.cpp:209-234`: one `[n_embd_k_gqa(il), kv_size, n_stream]` K tensor and one V tensor
per attention layer):

```
bytes_per_cell = Σ_{attention layers il} ( row_size(type_k, n_head_kv(il)·head_dim_k(il))
                                          + row_size(type_v, n_head_kv(il)·head_dim_v(il)) )
KV_bytes       = bytes_per_cell · kv_size · n_stream        (kv_size = n_ctx_seq, n_stream = kv_unified ? 1 : n_seq_max)
row_size(f16|bf16, n) = 2n ; q8_0 = 34·n/32 ; q4_0 = iq4_nl = 18·n/32 ; q4_1 = 20·n/32 ; q5_0 = 22·n/32 ; q5_1 = 24·n/32
```

Qwen3-0.6B (28 layers × 8 KV heads × 128): f16 = 114,688 B/token; q8_0 = 60,928 B/token; q4_0 = 32,256 B/token.

| n_ctx 4096, n_seq 1 (PROBE-1 log `llama_kv_cache: size = …`) | K | V | total |
|---|---|---|---|
| f16 / f16, FA auto | 224 MiB | 224 MiB | **448.00 MiB** |
| q8_0 / q8_0 (FA forced on) | 119 MiB | 119 MiB | **238.00 MiB** |
| q8_0 / f16, FA off | 119 MiB | 224 MiB | 343.00 MiB |
| q4_0 / q4_0, FA on | 63 MiB | 63 MiB | 126.00 MiB |

Seq-state size check: 5 tokens in q8_0 gave `llama_state_seq_get_size = 305,396 B`, about 59.6 KiB/token (PROBE-3).

Exceptions to the simple formula: SWA layers (separate smaller cache unless `swa_full`), MLA (DeepSeek), recurrent/hybrid
(fixed-size state per seq, independent of n_ctx), and per-layer head counts (Gemma 3/4, OpenELM). **Sherpa should use the dry
run instead of the formula**, and use the formula only for UI hints.

**Compute buffer** (PROBE-1b, q8_0 KV, n_ctx 4096):

| n_ubatch | n_outputs_max | compute buffer |
|---|---|---|
| 512 | 0 (= n_batch 512) | 302.8 MiB |
| 512 | 1 | 30.1 MiB |
| 512 | 8 | 30.1 MiB (reserve rounds) |
| 256 | 1 | 15.1 MiB |
| 128 | 1 | 7.6 MiB |

**Model memory:** mmap'd file (`CPU_Mapped`) plus any repack/extra buffer copies (`AMX`/`CPU_REPACK`/KleidiAI). The dry run
(`no_alloc`, `load_mode NONE`) reported 500.1 MiB model (378 AMX + 122 CPU) + 238 KV + 30.1 compute = **768 MiB** for the
`omax=1` configuration (PROBE-1b).

Dry-run recipe (exactly what `common_get_device_memory_data`, `common/fit.h:56-66`, does):
`mp.no_alloc=true; mp.load_mode=LLAMA_LOAD_MODE_NONE; m=llama_model_load_from_file(); c=llama_init_from_model(m,cp);
llama_get_memory_breakdown(c)`. On the host it takes well under a second for 0.6B (metadata only). `common_fit_params()`
(`common/fit.h:28-37`) shrinks `n_gpu_layers`/`n_ctx` to fit *device* memory, but "assumes system memory is unlimited". That
is wrong for a CPU-only phone, so Sherpa needs its own RAM budget policy.

---

## 7. Tokenization and vocab (`include/llama.h:1195-1308`; "The API is thread-safe", `:1262`)

- `int32_t llama_tokenize(vocab, text, text_len, tokens, n_tokens_max, add_special, parse_special)` returns the count, or
  **−(required count)** if `n_tokens_max` is too small, or `INT32_MIN` on overflow (`src/llama-vocab.cpp:4212-4235`).
  PROBE-3: `"<|im_start|>user\nhi<|im_end|>"` gives 5 tokens with `parse_special=1` and 15 with `0`. With a cap of 2 it gives -5.
  **Chat prompts rendered by templates must be tokenized with `add_special=false, parse_special=true`.**
  The template already contains BOS if needed; `common_chat_templates_inputs.add_bos/add_eos` exist.
- `int32_t llama_token_to_piece(vocab, token, buf, length, lstrip, special)` writes no NUL. It returns the byte count, or
  **−(required)**. Control/unknown tokens return **0** if `special=false` (`src/llama-vocab.cpp:3660-3684`). PROBE-3:
  `<|im_start|>` gives 0 with special=0 and -12 with an 8-byte buffer and special=1.
  **An out-of-range token id throws `std::out_of_range` through the C function** (`cache.at(token)`, `:3688-3692`; PROBE-3).
- Pieces can be partial UTF-8. A 7-byte emoji sequence came back as 4- and 3-byte pieces (PROBE-3). The Android example buffers
  until `is_valid_utf8` (`ai_chat.cpp:527-544`), and the server tracks `n_sent_text` for the same reason. **The shim must emit
  only complete UTF-8.**
- `llama_detokenize(vocab, tokens, n, text, max, remove_special, unparse_special)` uses the same sign convention.
- Vocab: `llama_vocab_n_tokens`, `_type`, `_get_text`, `_get_score`, `_get_attr`, **`llama_vocab_is_eog`** (the stop
  check; covers EOS/EOT/etc.), `_is_control`, `_bos/_eos/_eot/_sep/_nl/_pad/_mask`, `_get_add_bos/_add_eos/_add_sep`,
  `_get_suppress_tokens`, `_fim_*`. Deprecated: all `llama_token_*` vocab getters and `llama_vocab_cls` (`:1234-1257`).
- C++ helpers: `common_tokenize(vocab|ctx, text, add_special, parse_special=false)`, `common_token_to_piece(…, special=true)`
  (handles resize), `common_detokenize` (`common/common.h:1115-1150`).
- Legacy template: `llama_chat_apply_template(tmpl, msgs, n, add_ass, buf, len)` (no Jinja, built-in list only;
  `include/llama.h:1324-1333`). The Android example still uses this path (`use_jinja=false`, `ai_chat.cpp:293`), which is
  why it cannot do tools.

---

## 8. Batches, decode, logits

- `struct llama_batch {n_tokens, token*, embd*, pos*, n_seq_id*, seq_id**, logits*}` (`include/llama.h:263-272`).
  `llama_batch_init(n_tokens, embd, n_seq_max)` / `llama_batch_free`. `llama_batch_get_one(tokens,n)` is "avoid using it"
  (`:956-964`) but convenient (positions are auto-tracked, seq 0).
- **New extended batch API** (`:1007-1090`): `llama_batch_ext_init(ctx)`, `_free`, `_clear`, `_add(seq)`,
  `_add_token(seq,id)` (returns idx, or -1 full / -2 invalid / -3 bad seq), `_add_embd(seq, llama_embd{data,n_rows,n_embd})`,
  `_add_seq(idx, seq)`, `_set_embd_token`, `_set_embd_state` (MTP / Qwen3-VL deepstack), `_set_output_logits/_embd`,
  `_set_pos(idx, const llama_pos*)` (multiple positions for M-RoPE), and
  `int32_t llama_process(ctx, LLAMA_PROCESS_TYPE_{ENCODE,DECODE}, batch_ext)` (same return codes as `llama_decode`).
  `llama_decode(llama_batch)` is now a compat shim that converts to `llama_batch_ext` (`src/llama-context.cpp:4373-4386`).
  The C++ wrapper `common_batch` (`common/common.h:1036-1085`) is what examples and the server use:
  `add(id,pos,seq,output)`, `get()`, `get_sub_batch(off,n)`, and `common_batch_get_one(ctx,tokens)`.
- **`llama_decode` return codes** (`include/llama.h:991-1005`):

| rc | meaning | memory after | source / probe |
|---|---|---|---|
| 0 | success | — | |
| 1 | no KV slot (context full) | restored | `src/llama-context.cpp:1843`. PROBE-3: n_ctx 256 filled, one more token gave 1 |
| 2 | aborted via `abort_callback` | processed ubatches stay; **the failed ubatch's positions are removed** | `:1885-1917`. PROBE-3: rc 2, `pos_max=-1` after aborting the first ubatch |
| -1 | invalid batch (e.g. seq_id ≥ n_seq_max, empty batch, embd width mismatch) | unchanged | PROBE-3: seq_id 5 with n_seq_max 1 gave -1 |
| -2 | memory/alloc failure (incl. output buffer) | partial | `:1814-1859,1918` |
| -3 | compute failed | partial | `:1919` |

  Recovery after `<0` or `2`: query `llama_memory_seq_pos_min/max` and truncate the app's token mirror to match.
- Logits: `llama_get_logits_ith(ctx, i)` (negative i counts from the end; NULL on invalid) is preferred over
  `llama_get_logits`. Embeddings: `llama_get_embeddings_ith/_seq`. `llama_synchronize(ctx)` waits for async compute (implicit
  in getters). `llama_set_embeddings`, `llama_set_causal_attn`. **`llama_set_warmup` is DEPRECATED** (`:1119`): do warmup
  manually.
- Backend (on-device) sampling [EXPERIMENTAL]: `llama_set_sampler(ctx, seq, chain)`, `llama_get_sampled_token_ith`,
  `_probs_ith`, `_logits_ith`, `_candidates_ith` (`:1166-1193`). `common_sampler` disables it when a grammar or reasoning
  budget is active (`common/sampling.cpp:415-424`), so it is irrelevant for tool calling.

---

## 9. Memory API (`include/llama.h:746-818`) and context shifting

`llama_memory_t mem = llama_get_memory(ctx);` Positions are half-open `[p0, p1)`; a negative p0/p1 means unbounded.

| Function | Semantics |
|---|---|
| `void llama_memory_clear(mem, bool data)` | `data=true` also zeroes the buffers |
| `bool llama_memory_seq_rm(mem, seq, p0, p1)` | `seq<0` = any. **Returns false if a partial removal is impossible** (recurrent/hybrid). A whole-sequence removal never fails. PROBE-3: partial rm on a KV model returned true |
| `void llama_memory_seq_cp(mem, src, dst, p0, p1)` | Fork/prefix share. PROBE-3: fork then continue on seq 1 matched the reference exactly (`kv_unified=true`) |
| `void llama_memory_seq_keep(mem, seq)` | Drop all other sequences |
| `void llama_memory_seq_add(mem, seq, p0, p1, delta)` | Shift positions (RoPE K-shift is applied lazily at the next decode) |
| `void llama_memory_seq_div(mem, seq, p0, p1, d)` | Integer-divide positions (self-extend / group attention) |
| `llama_pos llama_memory_seq_pos_min/max(mem, seq)` | -1 if empty. pos_min > 0 is typical for SWA |
| `bool llama_memory_can_shift(mem)` | false for M-RoPE (`n_pos_per_embd>1`), Step35, DSV4. For iSWA it requires equal base and SWA sizes, i.e. effectively `swa_full` (`src/llama-kv-cache.cpp:1188-1197`, `src/llama-kv-cache-iswa.cpp:253-257`). PROBE-1: Qwen3 = 1 |

- `common_context_can_seq_rm(ctx)` probes by decoding 2 tokens and trying a partial rm, **and clears memory**. It returns
  `NO / PART / FULL (only whole-seq rm, i.e. recurrent) / RS (bounded by n_rs_seq)` (`common/common.h:1007-1016`,
  `common/common.cpp:1491-1534`). Call it once right after context creation.
- **Context shift (server)** (`tools/server/server-context.cpp:2888-2950`): when `n_tokens+1 ≥ n_ctx`, it keeps `n_keep`
  (task param; `-1` = whole prompt; +1 for BOS), sets `n_discard = n_discard_param ? : n_left/2` (clamped to
  `[0, n_left-1]`), then `seq_rm(n_keep, n_keep+n_discard)` and `seq_add(n_keep+n_discard, end, -n_discard)`, and compacts the
  token mirror. It is **off by default** (`common_params.ctx_shift=false`, `common/common.h:573`), and is auto-disabled with
  mmproj or `!can_shift` (`server-context.cpp:1155-1176`). Without shift, generation stops at the context limit (`:1867`).
  The Android example does the same "discard half after the system prompt" (`ai_chat.cpp:278-287`).
- **Recommendation for an agent harness:** don't shift mid-generation, because a shift silently breaks tool-call JSON. Let
  the Dart context manager summarise or trim at turn boundaries, then rely on prefix reuse (§17) to re-prefill cheaply.

---

## 10. Sampling (`include/llama.h:1335-1641`) and `common_sampler` (`common/sampling.h`)

Chain API: `llama_sampler_chain_init({no_perf})` (default `no_perf=true`, `src/llama.cpp:78-84`),
`llama_sampler_chain_add(chain, s)` (**takes ownership**), `_chain_get(i)` (`i=-1` returns the chain itself, useful to test
"is chain"), `_chain_n`, `_chain_remove(i)` (gives ownership back), `llama_sampler_sample(s, ctx, idx)` (apply + accept;
call in output order with no gaps), `llama_sampler_accept/apply/reset/clone/copy/free`, `llama_sampler_get_seed`. Custom
samplers implement `struct llama_sampler_i` (`:1380-1421`).

Samplers and their exact signatures:
`init_greedy()`, `init_dist(uint32 seed)` (`LLAMA_DEFAULT_SEED`=0xFFFFFFFF = random), `init_top_k(int32 k)` (k≤0 = noop),
`init_top_p(float p, size_t min_keep)`, `init_min_p(float p, size_t min_keep)`, `init_typical(p, min_keep)`, `init_temp(t)`
(t≤0 = keep only the max logit), `init_temp_ext(t, delta, exponent)`, `init_xtc(p, t, min_keep, seed)`,
`init_top_n_sigma(n)`, `init_mirostat(n_vocab, seed, tau, eta, m)`, `init_mirostat_v2(seed, tau, eta)`,
`init_penalties(n_vocab, last_n, repeat, freq, present)` (apply after top-k for speed), `init_dry(vocab, mult, base,
allowed_len, last_n, breakers, n)`, `init_adaptive_p(target, decay, seed)` (must be last), `init_logit_bias(n_vocab, n, biases)`,
`init_infill(vocab)`, `init_grammar(vocab, gbnf, root)` (returns **NULL on a parse error**; an empty string is a no-op grammar,
`src/llama-sampler.cpp:2766-2820`),
`init_grammar_lazy_patterns(vocab, gbnf, root, const char** trigger_patterns, n, const llama_token* trigger_tokens, n)`. Patterns
are matched from the start of the output and the grammar is fed from the first match group. Token triggers feed from the
trigger token itself (`:1541-1551`). `init_grammar_lazy(…trigger_words…)` is **DEPRECATED** (`:1530-1538`).
**`llama_sampler_accept` on a grammar sampler throws `std::runtime_error`** if the token doesn't fit
(`src/llama-grammar.cpp:1472,1527`).

`common_sampler` (what the server and examples use; `common/sampling.h:40-125`, `common/sampling.cpp:187-420`):
- `common_sampler_init(model, common_params_sampling&)` (may mutate params; **throws** on invalid penalties or a grammar parse
  failure), `common_sampler_sample(gs, ctx, idx, grammar_first=false)`, `common_sampler_accept(gs, tok, is_generated)`,
  `common_sampler_sample_and_accept_n(gs, ctx, draft)` (speculative verification), `_clone`, `_reset`, `_free`,
  `common_sampler_reasoning_budget_force`, `common_sampler_get_candidates`, `common_perf_print`.
- Fast path: sample with the chain, check the token against the grammar, and only on rejection apply the grammar to the full
  vocab and resample.
- Default chain (PROBE-3 print): `logits -> ?penalties -> ?dry -> ?top-n-sigma -> top-k -> ?typical -> top-p -> min-p -> ?xtc
  -> temp-ext -> dist`. A logit-bias sampler (user bias plus the model's suppress tokens as -inf) is prepended.
- `common_params_sampling` defaults (`common/common.h:226-292`): seed random, top_k 40, top_p 0.95, min_p 0.05, temp 0.80,
  penalty_last_n 64, repeat 1.0, freq/present 0, DRY off (mult 0), XTC off, mirostat 0, top_n_sigma -1, adaptive_target -1.
  Grammar fields: `common_grammar grammar{type, text}` with
  `type ∈ {NONE, USER, OUTPUT_FORMAT, TOOL_CALLS}` (`:189-222`), `grammar_lazy`, `grammar_triggers`, `preserved_tokens`
  (a `std::set<llama_token>`), and `generation_prompt`. The generation prompt is fed to the grammar ("prefill") only for
  OUTPUT_FORMAT/TOOL_CALLS grammars that are not lazy (`common/sampling.cpp:294-308`).
  Reasoning budget: `reasoning_budget_tokens` (-1 off), `_start`, `_end`, `_forced`, `_message`, `reasoning_control`
  (state machine in `common/reasoning-budget.h`: IDLE → COUNTING → WAITING_UTF8 → FORCING → DONE).
- Trigger conversion done by the server (and needed in the shim): `common_chat_params.grammar_triggers` of type WORD that
  tokenize to **one token** become TOKEN triggers, and the word must be in `preserved_tokens`. Multi-token words stay WORD
  (regex-escaped into a pattern). `PATTERN_FULL` gets anchored with `^…$` (`tools/server/server-schema.cpp:353-381`,
  `common/sampling.cpp:220-262`). Qwen3's trigger `"<tool_call>\n"` is two tokens, so it stays WORD.
- Optional llguidance: a grammar string starting with `%llguidance` uses `llama_sampler_init_llg` (Lark), only with
  `LLAMA_USE_LLGUIDANCE`.

---

## 11. JSON Schema → GBNF (`common/json-schema-to-grammar.h:9-23`)

- `std::string json_schema_to_grammar(const common_json & schema, bool force_gbnf=false)`, plus an overload for
  `common_chat_schema_document`, `build_grammar(cb, options)` and `gbnf_format_literal`. It throws on unsupported schemas.
- The usual path is `common_chat_templates_inputs.json_schema = "<json text>"`. The template pipeline then returns
  `grammar` (non-lazy) and a parser that strips the generation prompt (PROBE-2: 992-byte grammar for a one-field object).
  Tools and a custom `grammar` are mutually exclusive (throws "Cannot specify grammar with tools", `common/chat.cpp:1305-1309`).
- The server maps `response_format: {type: json_object|json_schema}` to `json_schema`. An empty schema becomes
  `{"type":"object"}` (`tools/server/server-common.cpp:1258-1277`).

---

## 12. Chat templates, tool calls, reasoning (`common/chat.h`, `common/chat.cpp`)

### 12.1 API

```cpp
common_chat_templates_ptr common_chat_templates_init(const llama_model*, const std::string& tmpl_override,
                                                     const std::string& bos_override = "", const std::string& eos_override = "");
// chat.h:316. Empty override: uses llama_model_chat_template(model,NULL) and the "tool_use" variant. An empty or "chatml"
// template falls back to the built-in ChatML. Jinja compile errors THROW (chat.cpp:839-846). model may be NULL if an override is given.
common_chat_params common_chat_templates_apply(const common_chat_templates*, const common_chat_templates_inputs&); // chat.h:324
common_chat_msg    common_chat_parse(const std::string& input, bool is_partial, const common_chat_parser_params&); // chat.h:340
std::vector<common_chat_msg_diff> common_chat_msg_diff::compute_diffs(const common_chat_msg& prev, const common_chat_msg& next); // chat.h:136
// helpers: common_chat_templates_was_explicit, _source, _get_caps (map), _support_enable_thinking, common_chat_format_single,
// common_chat_msgs_parse_oaicompat(json), common_chat_tools_parse_oaicompat(json), common_chat_tool_choice_parse_oaicompat,
// common_chat_verify_template, common_reasoning_format_from_name
```

`common_chat_templates_inputs` (`chat.h:249-267`):

| field | default | notes |
|---|---|---|
| `messages` | — | `common_chat_msg{role, content, content_parts[{type,text}], tool_calls[{name, arguments(json string), id}], reasoning_content, tool_name, tool_call_id}` (`:80-128`) |
| `grammar`, `json_schema` | "" | mutually exclusive with tools |
| `add_generation_prompt` | true | |
| `continue_final_message` | NONE | NONE/AUTO/REASONING/CONTENT (assistant prefill continuation, `:242-247`) |
| `use_jinja` | true | false = legacy `llama_chat_apply_template` path: **no tools, no parser, format CONTENT_ONLY** (PROBE-2) |
| `tools` | [] | `common_chat_tool{name, description, parameters(JSON-schema string)}` (`:216-220`) |
| `tool_choice` | AUTO | AUTO / REQUIRED / NONE (`:222-226`). REQUIRED gives a non-lazy grammar (PROBE-2) |
| `parallel_tool_calls` | false | The server defaults it to the template cap `supports_parallel_tool_calls` |
| `reasoning_format` | **NONE** | **Controls whether the generated parser splits `<think>` into `reasoning_content`**. Use DEEPSEEK or AUTO. `DEEPSEEK_LEGACY` keeps thinking inline when streaming (`common/common.h:421-430`) |
| `enable_thinking` | true | false makes Qwen3's generation prompt `"<|im_start|>assistant\n<think>\n\n</think>\n\n"` (PROBE-2) |
| `now` | now() | Used by templates that render dates |
| `chat_template_kwargs` | {} | Map of JSON-encoded values (e.g. `reasoning_effort`) |
| `add_bos`, `add_eos` | false | Overwritten from vocab |
| `force_pure_content` | false | Skips tool and reasoning parsing |

`common_chat_params` output (`chat.h:269-283`):
`format`; `prompt` (render, then tokenize with `parse_special=true`); `grammar` (GBNF, may be empty); `grammar_lazy`;
`generation_prompt` (the assistant header the template appended; fed to the grammar and prepended before parsing);
`supports_thinking`, `thinking_start_tag`, `thinking_end_tags` (for the reasoning-budget sampler);
`grammar_triggers` (`{type: TOKEN|WORD|PATTERN|PATTERN_FULL, value, token}`); `preserved_tokens` (strings);
`additional_stops` (strings to add to stop sequences); `parser` (**serialized PEG arena string**;
load it with `common_chat_parser_params.parser.load(str)`); `message_delimiters` (role-start markers, used for checkpointing at
user-message boundaries).

`common_chat_parser_params` (`chat.h:287-303`): `format`, `reasoning_format`, `reasoning_in_content`, `generation_prompt`,
`parse_tool_calls`, `is_continuation`, `echo`, `debug`, `parser`. Construct it from `common_chat_params` and then **call
`parser.load(params.parser)`**, as the server does (`server-schema.cpp:321-325`). With an empty parser it falls back to
"everything is content".

### 12.2 Format dispatch at this commit (`common/chat.cpp:1225-1366`)

1. `use_jinja=false`: legacy C++ templates, `CONTENT_ONLY`.
2. `force_pure_content`: content-only PEG parser.
3. **Specialized handlers**, detected by substrings in the template source (`chat.cpp:1090-1222`), in this order:
   Ministral/Magistral 3, GPT-OSS (harmony `<|channel|>`), Muse Glimmer, Functionary v3.2, Kimi K2 (Thinking),
   Kimi K3, Ling 3.0, Cohere2 MoE, LFM2, LFM2.5, GigaChatV3, MiniMax-M3, DeepSeek V3.2/V4 (DSML), Gemma4
   (`PEG_GEMMA4`; old templates get a workaround), MiniCPM5, and Qwen3-Coder XML (also Nemotron Nano 3, Qwen3.5,
   StepFun-3.5).
4. Otherwise, the **differential autoparser** (`common/chat-auto-parser*.cpp`, `chat-diff-analyzer.cpp`, `docs/autoparser.md`).
   It renders the template with message variants, diffs the outputs to find reasoning markers, content markers and the tool
   format (`JSON_NATIVE`, `TAG_WITH_JSON`, `TAG_WITH_TAGGED`), section/call/arg markers and call-id position, then builds a PEG
   parser and a GBNF grammar. It throws `invalid_argument("Unable to generate parser…")` on failure.

The old named formats (`COMMON_CHAT_FORMAT_HERMES_2_PRO`, `LLAMA_3_X`, `GENERIC`, `FIREFUNCTION`, …) and
`common_chat_msg_parser` **no longer exist** (verified with grep). Hermes/Qwen 2.5/3, Mistral Nemo, Command R, Granite 4,
DeepSeek R1 and Functionary v3.1 are now handled by the autoparser (PROBE-6).

### 12.3 Template coverage (PROBE-6: all 70 `models/templates/*.jinja`, one tool, `tool_choice=auto`; 70/70 applied)

| Outcome | Templates (mobile-relevant first) |
|---|---|
| Lazy grammar + trigger `<tool_call>` (Hermes-style JSON) | Qwen3-0.6B, Qwen3.5-4B, Qwen2.5-7B, QwQ, Hermes-2-Pro/3, Granite 4.0/4.1, MiMo-VL, Bielik, Reka-Edge, GLM-4.6/4.7, Nemotron-3-Nano, StepFun |
| Lazy, model-specific trigger | LFM2/LFM2.5 `<|tool_call_start|>`; Gemma 4 `<|tool_call>` (fmt `peg-gemma4`); Mistral Nemo / Small 3.2 / Ministral 3 / Devstral `[TOOL_CALLS]`; DeepSeek R1-distill-Qwen / V3.1 `<｜tool▁calls▁begin｜>`; V3.2/V4 DSML; Command-R7B / Cohere2MoE `<|START_ACTION|>`; Command-R+ ``Action: ```json``; Functionary v3.1 `<function=`, v3.2 pattern `>>>(?!all)`; GPT-OSS 4 patterns; Kimi K2/K3; MiniCPM5 `<function`; Firefunction `functools`; MiniMax M1/M2/M3 (`peg-minimax-m3`) |
| **No grammar, no trigger** (tools rendered, output not constrained) | **Llama 3.1 / 3.2 / 3.3**, **Phi-3.5-mini**, **Gemma 2**, **SmolLM3-3B**, **Granite 3.3**, DeepSeek-R1-Distill-Llama-8B, RWKV-world |

Llama 3.2 detail (PROBE-6b): the parser still converts `{"name":…,"parameters":{…}}` into a tool call (and `<|python_tag|>`
leaks into content). `tool_choice=required` gives a 1221-byte non-lazy grammar. So for Llama 3.x Sherpa must either force
`required` when a tool is expected, or run its own "JSON envelope" mode: a `json_schema` with `oneOf[{tool_call}, {response}]`
plus its own parse. This replaces the removed upstream "Generic" handler.

### 12.4 Streaming parse

The server pattern (`tools/server/server-task.cpp:151-235`): accumulate `generated_text`; on each new piece call
`common_chat_parse(generated_text, /*is_partial*/true, pp)`; then `compute_diffs(prev, new)`; and assign stable tool-call ids
with `msg.set_tool_call_ids(ids_cache, gen_id)`. The server buffers a tool call's name until its first argument delta.
PROBE-2 (Qwen3, 8-char chunks): 10 diffs = 3 reasoning deltas, 3 content deltas, then `tc_idx=0 name=get_weather args+='{'`
and 3 argument deltas. The final `is_partial=false` parse gave `reasoning='User wants weather.\n'`, `content='Let me check.\n'`,
and one tool call. A partial-parse failure returns what was captured. A final-parse mismatch **throws** "The model produced
output that does not match the expected … format" (`chat.cpp:1494-1498`). Cost: a full re-parse per token (O(n²) over a
reply), which is fine for replies of a few KB.

---

## 13. State save/load and prefix caching (`include/llama.h:820-950`)

| API | Scope | Contains | Notes |
|---|---|---|---|
| `llama_state_get_size / get_data / set_data` | whole context | arch string + memory (**no logits/embeddings**; `src/llama-context.cpp:3397-3440`) | `get_size` is the "actual" size, valid for saving only |
| `llama_state_save_file(ctx, path, tokens, n)` / `load_file(ctx, path, out, cap, &n)` | whole context, file | magic `ggsn`, `LLAMA_SESSION_VERSION 10` (`include/llama.h:45-46`; checked `src/llama-context.cpp:3271`) + tokens + state | PROBE-3: load OK but the continuation **mismatched** without a replay (stale logits) |
| `llama_state_seq_get_size / get_data / set_data(ctx, …, seq_id)` | one sequence | that seq's KV cells | `set_data` returns 0 on failure. PROBE-3: restore into seq 1, rm the last pos, re-decode the last token: **exact match** |
| `llama_state_seq_save_file(ctx, path, seq, tokens, n)` / `seq_load_file(ctx, path, dest_seq, out, cap, &n)` | one seq, file | magic `ggsq`, `LLAMA_STATE_SEQ_VERSION 3` | `tokens_out=NULL` reads only the count (`:910`). PROBE-3: 305,420-byte file for 5 tokens, exact match after replay |
| `…_ext(…, llama_state_seq_flags)` | one seq | flags: `LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY=1` (formerly `SWA_ONLY`) = only the non-rollbackable parts (SWA KV, recurrent state); `LLAMA_STATE_SEQ_FLAGS_ON_DEVICE=2` = keep on device buffers (fast; a new get invalidates earlier ones) (`:919-950`) | Server checkpoints use PARTIAL_ONLY. The server prompt cache uses NONE |

- Validation on load (`src/llama-kv-cache.cpp:2549-2577`): layer count, enough cells, **V transposition (FA on vs off)**, K/V
  type per layer. Whole-context load checks the arch name only. **Nothing checks the model file identity, the LoRA set or
  the rope params.** Sherpa's cache key therefore needs at least: model sha256, `type_k/type_v`, resolved FA, n_ctx_seq ≥ needed,
  active LoRA ids+scales, a llama.cpp commit hash, and the template/system-prompt hash.
- Replay helpers: `common_replay_last_token(ctx, last, pos)` and `common_prompt_batch_decode(…, state_path, save_state)`
  (saves state *before* the last token so it can be replayed; works for recurrent models too) (`common/common.h:1090-1107`).
- `common_prompt_checkpoint {n_tokens, pos_min, pos_max, data_tgt, data_dft, data_spec}` with
  `update_tgt/dft(ctx, seq, flags)` and `load_tgt/dft` (`common/common.h:1232-1280`). This is the unit both the speculative
  example and the server use.
- **Prefix-cache design for Sherpa:**
  1. Keep a token mirror per seq.
  2. On a new request, compute the LCP with the mirror, `seq_rm(seq, lcp, -1)`, and decode only the suffix.
  3. For "system prompt + tool schemas" (stable across sessions), snapshot with `llama_state_seq_get_data` right after
     prefill and persist it with `seq_save_file` keyed as above.
  4. For recurrent/hybrid/SWA models (`can_seq_rm != PART`), use PARTIAL_ONLY checkpoints at user-message boundaries,
     as the server does (§17).

---

## 14. LoRA and control vectors (`include/llama.h:682-744`)

- `llama_adapter_lora * llama_adapter_lora_init(model, path)` and `…_init_from_file_ptr(model, FILE*)`. Adapters live until
  `llama_adapter_lora_free` or model free. Metadata via `llama_adapter_meta_*`. aLoRA (activated LoRA): use
  `llama_adapter_get_alora_n_invocation_tokens` and `…_invocation_tokens`.
- **Apply:** `int32_t llama_set_adapters_lora(ctx, llama_adapter_lora** adapters, size_t n, float* scales)` replaces the whole
  set. It is a no-op if the set and scales are unchanged. Adapters with scale 0 are dropped. It sets `sched_need_reserve`
  (graph re-reserve on the next decode, **no model reload**) (`src/llama-context.cpp:1339-1381, 4132-4144`). Hot-swap is
  therefore cheap; source-verified, no adapter was available to probe (UNVERIFIED performance).
  The old `llama_set_adapter_lora`, `llama_rm_adapter_lora` and `llama_clear_adapter_lora` **do not exist** (grep). The stale
  comment at `common/common.h:531` still mentions `llama_adapter_lora_apply`.
  Helper: `common_set_adapter_lora(ctx, std::vector<common_adapter_lora_info>&)` (`:973`).
- **Cache invalidation:** KV computed under adapter set A is wrong under set B. The server clears the slot cache on any LoRA
  change unless all adapters are aLoRA (`tools/server/server-common.cpp:163-175`, `server-context.cpp:1689-1703`). It also
  refuses to batch slots with different LoRA sets (`:424`). Sherpa must include the LoRA set in the prefix-cache key.
- Control vectors: `llama_set_adapter_cvec(ctx, data, len, n_embd, il_start, il_end)` (`data=NULL` clears) and
  `common_control_vector_load({strength, fname}…)`.

---

## 15. Speculative decoding (`common/speculative.h`, `common/speculative.cpp`, `examples/speculative-simple`)

Types (`common/common.h:173-185`; names from `common_speculative_type_to_str`, `speculative.cpp:2226-2241`): `none`,
`draft-simple` (separate small model), `draft-eagle3`, `draft-mtp` (NextN heads inside the target GGUF; needs
`load_mtp=true` and `LLAMA_CONTEXT_TYPE_MTP`), `draft-dflash`, `draft-dspark`, `ngram-simple`, `ngram-map-k`,
`ngram-map-k4v`, `ngram-mod`, `ngram-cache` (static/dynamic cache files). Several types can be enabled at once. Priority:
n-gram types first, then draft types (`speculative.cpp:2604-2628`). `common_speculative_types_from_gguf(path)` auto-detects
MTP or dflash/dspark from the draft file.

Params (`common/common.h:327-401`): `draft.{n_max=3, n_min=0, p_split=0.1, p_min=0.0, backend_sampling=true, mparams.path,
n_gpu_layers=-1, cache_type_k/v=F16, devices, cpuparams}`, `ngram_mod{n_match=24, n_max=64, n_min=48}`,
`ngram_simple/map_k/map_k4v{size_n=12, size_m=48, min_hits=1}`, `ngram_cache{lookup_cache_static, _dynamic}`, and
`synth_len/synth_rates` (benchmark-only synthetic acceptance). CLI: `--spec-type`, `--spec-draft-model/-md`,
`--spec-draft-n-max`, `--spec-ngram-mod-*`. **`--draft-max`/`--draft-min` are removed** (`common/arg.cpp:4387-4398`).

Call sequence (from `examples/speculative-simple/speculative-simple.cpp:33-341`; reproduced in PROBE-5):

```cpp
auto lim = common_speculative_get_output_limits(n_batch, n_parallel, common_speculative_n_max(&params.speculative));
params.n_outputs_max = lim.total; params.n_outputs_max_per_seq = lim.per_seq;          // must be set before ctx creation
auto tgt = common_init_from_params(params);                                            // target model+ctx
auto pd  = common_base_params_to_speculative(params);                                  // swaps model -> draft, KV types, outputs
auto spi = common_speculative_init_from_params(pd, model_tgt, ctx_tgt);                // loads draft model / creates MTP ctx (ctx_other = ctx_tgt)
params.speculative.draft.ctx_tgt = ctx_tgt; params.speculative.draft.ctx_dft = spi->context();
common_speculative * spec = common_speculative_init(params.speculative, /*n_seq*/1);   // NULL if no impl is usable
// prompt: decode inp[0..n-2], common_speculative_process(spec, batch), common_speculative_begin(spec, seq, prompt_tgt)
loop {
  common_speculative_get_draft_params(spec, seq) = { /*drafting*/true, /*n_max*/ctx_left, /*pos0*/n_past, id_last, &prompt_tgt, &draft };
  common_speculative_draft(spec);                       // fills `draft` (possibly empty)
  batch = [id_last, draft...] (all outputs) ; llama_process(ctx_tgt, DECODE, batch); common_speculative_process(spec, batch);
  ids = common_sampler_sample_and_accept_n(smpl, ctx_tgt, draft);   // >= 1 token
  common_speculative_accept(spec, seq, ids.size()-1);
  llama_memory_seq_rm(tgt_mem, seq, n_past, -1); (and the draft ctx's)
}
```

- Vocab compatibility (internal `common_speculative_are_compatible`, `speculative.cpp:67-128`; no longer public): same vocab
  type, same add_bos/add_eos and ids, `|n_vocab_tgt − n_vocab_dft| ≤ SPEC_VOCAB_MAX_SIZE_DIFFERENCE`, and identical token text
  from `SPEC_VOCAB_CHECK_START_TOKEN_ID`. On failure `draft-simple` throws during init.
- Recurrent/hybrid targets (`can_seq_rm == FULL`): the example snapshots `common_prompt_checkpoint` PARTIAL_ONLY state before
  verification and restores it on partial acceptance (`speculative-simple.cpp:69-289`).
- Server wiring: one `common_speculative` for all slots (`n_seq = n_parallel`, seq_id = slot id;
  `server-context.cpp:1224-1240`). It is skipped if `can_seq_rm == NO`. Checkpoints stash `common_speculative_get_state`.
  Output limits come from `server_output_limits` (`:995-997`).
- **PROBE-5** (Qwen3-0.6B target, "copy this JSON 3×", greedy, 96 tokens; host contended):

| type | accepted / drafted | tokens per target pass | wall |
|---|---|---|---|
| `ngram-mod` (n_match 8, n_min 4, n_max 16) | 81/96 = **84.4 %** | 4.00 | **93.6 t/s** (baseline ≈ 35-40 t/s) |
| `ngram-simple` | 76/112 = 67.9 % | 3.38 | contended run, wall not meaningful |
| `draft-simple` (same 0.6B as draft, n_max 8) | 88/88 = 100 % | 9.00 | contended run |

  For an agent harness, `ngram-mod`/`ngram-map-k` are free wins on tool-call JSON, code edits and quoting tool results. They
  need no second model. A draft model doubles RAM on a phone, so leave it optional.

---

## 16. Multimodal — `tools/mtmd` (source-verified only; no mmproj model and `LLAMA_BUILD_MTMD=OFF` in the host build: **UNVERIFIED by probe**)

- `mtmd_context_params mtmd_context_params_default()` (`tools/mtmd/mtmd.cpp:458-477`): `use_gpu=true, device=NULL,
  print_timings=true, n_threads=4, media_marker=mtmd_default_marker() ("<__media__>"), flash_attn_type=AUTO, warmup=true,
  image_min/max_tokens=-1, batch_max_tokens=1024, progress_callback`.
- `mtmd_context * mtmd_init_from_file(mmproj_path, text_model, params)` (NULL on failure) and `mtmd_free`. Capability checks:
  `mtmd_support_vision`, `_audio`, `mtmd_get_audio_sample_rate` (-1 if none), `mtmd_decode_use_mrope`,
  `mtmd_decode_use_non_causal`. `mtmd_get_cap_from_file(path)` is [EXPERIMENTAL] and avoids a full init.
  `mtmd_get_memory_usage(path, params)` is C++, unstable, and used by fit.
- Bitmaps: `mtmd_bitmap_init(nx, ny, rgb_bytes)` (RGBRGB…, len nx·ny·3), `mtmd_bitmap_init_from_audio(n_samples, float pcm)`,
  `_set_id` (use a content hash for KV cache tracking), `_set_mergeable` (video frames), `mtmd_bitmap_init_lazy(…cb…)` (stream
  video frames), and `data=NULL` for a placeholder (token counting only).
  `mtmd_helper_bitmap_init_from_buf(ctx, buf, len, placeholder, opt)` decodes jpg/png/bmp/gif (stb) and wav/mp3/flac
  (miniaudio). WebP needs ffmpeg (the `MTMD_VIDEO` build). The ID is the SHA-256 (`mtmd-helper.h:66-81`).
- `int32_t mtmd_tokenize(ctx, chunks_out, const mtmd_input_text{text,len,add_special,parse_special}*, bitmaps, n)`
  returns 0 ok, 1 marker/bitmap count mismatch, 2 preprocessing error. It is thread-safe. `mtmd_tokenize_from_parts` takes
  text/bitmap parts without markers. Chunks: `mtmd_input_chunks_size/get`, `mtmd_input_chunk_get_type
  {TEXT,IMAGE,AUDIO}`, `_get_tokens_text`, `_get_n_tokens`, `_get_n_pos` (≠ n_tokens for M-RoPE), `_get_id`, `_copy/_free`,
  and `mtmd_input_chunk_save/load` (metadata only; the loaded chunk is a placeholder).
- Eval: `mtmd_helper_eval_chunks(ctx, lctx, chunks, n_past, seq, n_batch, logits_last, &new_n_past)` (NOT thread-safe),
  `mtmd_helper_eval_chunk_single`, or manual `mtmd_encode_chunk` + `mtmd_get_output_embd` + `mtmd_helper_decode_image_chunk`.
  Batch encoding: `mtmd_batch_init/add_chunk/encode/get_output_embd`. `mtmd_encode` is DEPRECATED.
  `mtmd_image_tokens_get_nx/ny` are DEPRECATED in favour of `_get_decoder_pos` (`mtmd.h:264-284`).
- Canonical flow (`tools/mtmd/mtmd-cli.cpp:268-345`): render the chat with media markers, tokenize, then for each chunk eval
  text with `eval_chunk_single`, or encode and decode media.
- Server constraints: with mmproj, **ctx_shift and cache_reuse are disabled** (`server-context.cpp:1155-1163`). M-RoPE models
  also report `can_shift=false`. Prefix caching works by token mirror + LCP, with media chunks represented as
  `LLAMA_TOKEN_NULL` runs keyed by bitmap id (server `server_tokens`).

---

## 17. tools/server usage patterns worth copying

- **Slots** (`server-context.cpp:198-300`): per slot `ctx_tgt/ctx_dft` (shared contexts; slot id = seq_id), `common_memory mem`
  (seq ops applied to target and draft together), `mtmd_context*`, `common_speculative* spec` (shared), `spec_draft`,
  `spec_ckpt`, `n_ctx` per slot (= `llama_n_ctx_seq`, optionally capped by `--kv-unified-per-slot`), `n_keep`,
  `server_prompt prompt{tokens, checkpoints}`, `lora`, `generated_text`, `n_sent_text` (UTF-8-safe streaming), and
  `t_last_used`. Slot selection uses prompt similarity ≥ `slot_prompt_similarity` (0.1), otherwise LRU.
- **Prompt reuse, three tiers:**
  1. `cache_prompt` (default true): LCP between the slot's tokens and the new prompt, then `n_past = lcp`
     (`:3203-3207`).
  2. `n_cache_reuse` (`--cache-reuse N`, default 0, `common/common.h:628`): after the LCP, walk both sequences and **re-use
     matching chunks of ≥ N tokens by KV shifting** (`seq_rm(head_p, head_c)` + `seq_add(head_c, head_c+n, head_p-head_c)`).
     Requires `can_shift && !mtmd` (`:3208-3266`).
  3. `--cache-ram` / `cache_ram_mib` (default **8192 MiB**, -1 unlimited, 0 off; `common/common.h:634`): a host-RAM LRU of
     whole-seq states (`llama_state_seq_get_data_ext(…, NONE)` for target and draft) plus their checkpoints
     (`server-task.h:566-640`, `server-task.cpp:1691-1900`). On a new task it picks the cached prompt that maximises both
     `f_keep = lcp/cached_len` (must be ≥ 0.25) and `f_sim = lcp/new_len`, restores it into the slot, and evicts entries
     contained in the new prompt. On `bad_alloc` it shrinks the limit to 40%. `cache_idle_slots` (default true) saves and
     clears idle slots when a new task starts.
- **Context checkpoints** (`--ctx-checkpoints` = `n_ctx_checkpoints` 32, `checkpoint_min_step` 8192): PARTIAL_ONLY snapshots
  taken only when the model can't roll back (`can_seq_rm` FULL or RS) or uses SWA without `swa_full` (`:3441-3455`).
  They are created a few tokens before the end of the prompt (offsets `4+n_ubatch` and `4`) and at user-message starts
  found with `message_delimiters` (`:3530-3550`). Restore takes the newest checkpoint with
  `pos_min < pos_min_thold` (`:3331-3360`). This is how SWA (Gemma 3/4) and hybrid (Granite 4, LFM2, Qwen3.5 hybrid) models
  still get prompt caching.
- **Chat request flow** (`server-common.cpp:1230-1450`): OAI JSON, then `common_chat_templates_inputs`. Trailing assistant
  messages become `continue_final_message=AUTO`. `reasoning_effort:"none"` sets `enable_thinking=false`. Then
  `common_chat_templates_apply`, then task params: `prompt`, `grammar`+`grammar_type=tool_calls`, `grammar_lazy`,
  `grammar_triggers`, `preserved_tokens`, `generation_prompt`, `stop += additional_stops`, `chat_parser`, and reasoning-budget
  tags. Sherpa's shim should reproduce exactly this mapping in C++.

---

## 18. Perf counters and system info

- `struct llama_perf_context_data {double t_start_ms, t_load_ms, t_p_eval_ms, t_eval_ms; int32_t n_p_eval, n_eval, n_reused;}`
  (`include/llama.h:1675-1685`). Functions: `llama_perf_context(ctx)`, `_print`, `_reset`; for chains,
  `llama_perf_sampler(chain)` → `{t_sample_ms, n_sample}`. Header note: "avoid using in third-party apps" (`:1672`).
- Semantics (`src/llama-context.cpp:770-800, 3463-3482`):
  - Timings are added **only if `no_perf=false`**, and the default is true. With the default, PROBE-7 gave
    `t_p_eval=0, t_eval=0` while `n_p_eval=8, n_eval=4` still counted.
  - Accounting happens at `llama_synchronize()`. Several decodes without a sync are merged into one bucket, and a multi-token
    decode (including speculative verification) counts as "prompt eval".
  - `n_p_eval`/`n_eval` are reported as `max(1, x)`, so 0 reads as 1.
  - `t_load_ms` runs from model-load start to the first eval.
  - Sherpa should measure TTFT and decode t/s itself in the shim (monotonic clock around decode plus sampling), and use the
    perf struct only for diagnostics.
- `llama_print_system_info()` (`src/llama.cpp:599-620`) concatenates each backend's `ggml_backend_get_features` (host:
  `CPU : SSE3 = 1 | … | AVX512 = 1 | AMX_INT8 = 1 | LLAMAFILE = 1 | OPENMP = 1 | REPACK = 1`). It returns a static buffer and
  is not thread-safe.
- `ggml_cpu_has_neon/arm_fma/fp16_va/dotprod/matmul_int8/sve/sme/sme2` and `ggml_cpu_get_sve_cnt`
  (`ggml/include/ggml-cpu.h:95-103`) are **compile-time `#if __ARM_FEATURE_*` checks of the CPU backend that is linked or
  loaded** (`ggml-cpu.c:3811-3849`). With `GGML_CPU_ALL_VARIANTS`, the loaded variant was chosen by runtime HWCAP scoring
  (`arch/arm/cpu-feats.cpp`: dotprod, fp16, sve, i8mm, sve2, sme). So these reflect the chosen variant, which is good enough
  for telemetry, but they are not a device query.

---

## 19. Deprecated and removed APIs (relative to the API most docs and LLMs know)

| Old | Now | Ref |
|---|---|---|
| `llama_load_model_from_file`, `llama_free_model`, `llama_new_context_with_model` | `llama_model_load_from_file`, `llama_model_free`, `llama_init_from_model` | `include/llama.h:514-556` (DEPRECATED) |
| `llama_n_ctx_train/n_embd/n_layer/n_head(model)`, `llama_n_vocab` | `llama_model_n_*`, `llama_vocab_n_tokens` | `:582-587` |
| `llama_get_state_size`, `llama_copy_state_data`, `llama_set_state_data`, `llama_load/save_session_file` | `llama_state_*` | `:828-879` |
| `llama_token_get_text/score/attr`, `llama_token_is_eog/is_control`, `llama_token_bos/eos/eot/…`, `llama_add_bos_token`, `llama_vocab_cls` | `llama_vocab_*` | `:1234-1257` |
| `llama_sampler_init_grammar_lazy(trigger_words…)` | `llama_sampler_init_grammar_lazy_patterns` | `:1530-1551` |
| `llama_set_warmup` | manual warmup | `:1119` |
| `defrag_thold` | — (deprecated field) | `:390` |
| `LLAMA_STATE_SEQ_FLAGS_SWA_ONLY` | `LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY` (same value 1) | `:921-925` |
| **removed:** `use_mmap`, `use_mlock`, `use_direct_io` bools | `load_mode` enum | `:206-213, 328` |
| **removed:** `bool flash_attn` | `flash_attn_type` enum | `:191-195, 380` |
| **removed:** `llama_set_adapter_lora`, `llama_rm_adapter_lora`, `llama_clear_adapter_lora` | `llama_set_adapters_lora` (set-replace) | `:726-730` |
| **removed:** `llama_kv_self_*` / `llama_kv_cache_*` | `llama_memory_*` | `:746-818` |
| **removed:** named `COMMON_CHAT_FORMAT_*` (Hermes, Llama3.x, Generic, …), `common_chat_msg_parser` | PEG formats + `parser` string | `common/chat.h:228-238` |
| **removed:** `common_speculative_gen_draft`, public `common_speculative_are_compatible`, `--draft-max/--draft-min` | new speculative API | `common/speculative.h`, `common/arg.cpp:4387-4398` |
| `mtmd_encode`, `mtmd_image_tokens_get_nx/ny`, `image_marker` | `mtmd_encode_chunk`, `_get_decoder_pos`, `media_marker` | `tools/mtmd/mtmd.h:102,269-272,320` |

---

## 20. Proposed thin engine C ABI for Sherpa (`sherpa_engine.h`, ABI v1)

Design rules:
- **One C++ shim owns llama + common + mtmd.** Dart (FFI) and Kotlin/Swift (JNI/C) see only this header.
- **Versioning:** `se_abi_version()` returns `SE_ABI_VERSION`. Every params/out struct starts with
  `uint32_t struct_size`. The shim reads only fields within `struct_size` and zero-fills newer ones, so new fields go at the
  end and old callers keep working. JSON is used for rich, evolving payloads (chat requests, model info, tool calls), so the
  C struct surface stays tiny and stable.
- **No exceptions or aborts cross the boundary.** Every entry point is wrapped in `try { … } catch (...)` and returns
  `se_status`. The details go to `se_last_error()` (thread-local). Inputs that would hit a `GGML_ASSERT` are validated first:
  `n_outputs_max ≥ n_seq_max`, `no_alloc ⇒ load_mode NONE`, token ids in range, quantized V ⇒ FA not DISABLED, KV block size
  divides head_dim. `ggml_set_abort_callback` writes a crash breadcrumb.
- **Threading:** a session is single-threaded. All decode work runs on a shim-owned worker thread per session, and FFI calls
  never block the Dart UI isolate. Read-only model queries are thread-safe. `se_session_cancel` is callable from any thread.
- **Streaming:** primary mode is pull. `se_session_next_event(timeout)` drains an SPSC ring buffer, so Dart and Kotlin poll
  from a background isolate or coroutine without cross-thread callbacks. Optional push mode: an `se_event_cb` invoked on the
  worker thread (JNI attaches the thread; Dart would need a `NativeCallable.listener` and must copy payloads — UNVERIFIED here,
  see 09). Event strings are owned by the session and valid until the next `next_event` call.
- **Cancellation:** a `std::atomic<bool>` checked (a) between tokens, (b) inside `abort_callback` during decode (CPU and Metal)
  so a long prefill stops mid-batch (rc 2, which then truncates the mirror to `pos_max`), and (c) in the model-load
  `progress_callback`.

```c
/* sherpa_engine.h — ABI v1 (sketch) */
#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
#define SE_ABI_VERSION 1u
#if defined(_WIN32)
#  define SE_API __declspec(dllexport)
#else
#  define SE_API __attribute__((visibility("default")))
#endif

typedef struct se_engine  se_engine;   /* process-wide: backends, logging, abort hook   */
typedef struct se_model   se_model;    /* weights + vocab + chat templates (shareable)  */
typedef struct se_session se_session;  /* llama_context + sampler + chat/parse state    */
typedef struct se_lora    se_lora;
typedef struct se_mmproj  se_mmproj;   /* mtmd_context                                  */

typedef enum se_status {
  SE_OK = 0,
  SE_ERR_INVALID_ARG = -1,   SE_ERR_OOM = -2,            SE_ERR_IO = -3,
  SE_ERR_MODEL_LOAD = -4,    SE_ERR_CONTEXT_CREATE = -5, SE_ERR_CONTEXT_FULL = -6,   /* llama_decode == 1        */
  SE_ERR_CANCELLED = -7,     /* abort cb / progress cb    */
  SE_ERR_DECODE = -8,        /* llama_decode < 0           */
  SE_ERR_TEMPLATE = -9,      SE_ERR_GRAMMAR = -10,       SE_ERR_PARSE = -11,
  SE_ERR_STATE_MISMATCH = -12, SE_ERR_BUSY = -13,        SE_ERR_UNSUPPORTED = -14,
  SE_ERR_BUFFER_TOO_SMALL = -15, SE_ERR_TIMEOUT = -16,   SE_ERR_INTERNAL = -99
} se_status;

typedef void (*se_log_cb)(int32_t level, const char * msg, void * user);
typedef bool (*se_progress_cb)(float progress, void * user);          /* return false = cancel */

typedef struct se_engine_params {
  uint32_t struct_size;
  const char * backend_dir;       /* Android GGML_BACKEND_DL dir or NULL (static)          */
  se_log_cb log_cb; void * log_user; int32_t log_level;
  const char * crash_breadcrumb_path;   /* written from ggml_set_abort_callback               */
} se_engine_params;

typedef struct se_model_params {
  uint32_t struct_size;
  int32_t  n_gpu_layers;          /* -1 all, 0 CPU only                                     */
  int32_t  load_mode;             /* llama_load_mode values                                 */
  bool     use_extra_bufts;       /* weight repack                                         */
  bool     vocab_only;
  bool     check_tensors;
  bool     load_mtp;
  const char * chat_template_override;  /* NULL = from GGUF                                */
} se_model_params;

typedef struct se_session_params {
  uint32_t struct_size;
  uint32_t n_ctx, n_batch, n_ubatch, n_seq_max;
  int32_t  n_threads, n_threads_batch;
  int32_t  flash_attn;            /* -1 auto, 0 off, 1 on                                  */
  int32_t  type_k, type_v;        /* ggml_type ids (validated)                             */
  bool     kv_unified, swa_full;
  uint32_t n_outputs_max;         /* shim forces >= n_seq_max and >= n_draft+1             */
  const char * speculative_json;  /* {"types":["ngram-mod"],"draft_model":null,"n_max":16}  */
} se_session_params;

typedef struct se_memory_estimate {
  uint32_t struct_size;
  uint64_t model_bytes, kv_bytes, compute_bytes, mmproj_bytes;
  uint32_t n_ctx_actual, n_ctx_seq_actual;
  uint64_t kv_bytes_per_token;
  int32_t  flash_attn_resolved;
} se_memory_estimate;

typedef enum se_event_type {
  SE_EV_PROMPT_PROGRESS = 1,  /* n_done / n_total prefill                     */
  SE_EV_REASONING_DELTA = 2,
  SE_EV_CONTENT_DELTA   = 3,
  SE_EV_TOOL_CALL_DELTA = 4,  /* index, id, name (first), args delta          */
  SE_EV_DONE            = 5,  /* stop_reason + stats + final message JSON     */
  SE_EV_ERROR           = 6
} se_event_type;

typedef enum se_stop_reason { SE_STOP_EOG = 1, SE_STOP_LENGTH = 2, SE_STOP_STOPSTR = 3,
                              SE_STOP_CANCELLED = 4, SE_STOP_CONTEXT_FULL = 5, SE_STOP_TOOL_CALL = 6 } se_stop_reason;

typedef struct se_event {
  uint32_t struct_size;
  int32_t  type;               /* se_event_type                                           */
  int32_t  status;             /* se_status for ERROR                                     */
  int32_t  tool_index;         /* -1 if n/a                                               */
  const char * text;  uint32_t text_len;     /* UTF-8 complete code points only          */
  const char * tool_id;   const char * tool_name;
  uint32_t n_prompt, n_cached, n_generated, n_drafted, n_accepted;
  double   t_prefill_ms, t_decode_ms;
  int32_t  stop_reason;
  const char * final_json;     /* DONE: {"role":"assistant","content":…,"reasoning_content":…,"tool_calls":[…]} */
} se_event;

typedef void (*se_event_cb)(const se_event * ev, void * user);

/* --- engine (1-6) --- */
SE_API uint32_t  se_abi_version(void);
SE_API se_status se_engine_init(const se_engine_params * p, se_engine ** out);
SE_API void      se_engine_free(se_engine * e);
SE_API int32_t   se_engine_info_json(se_engine * e, char * buf, size_t len);   /* devices, cpu feats, build; returns needed len */
SE_API int32_t   se_last_error(char * buf, size_t len);                          /* thread-local                                */
SE_API void      se_string_free(char * s);                                       /* for APIs that allocate                       */

/* --- model (7-12) --- */
SE_API se_status se_model_estimate(se_engine * e, const char * path, const se_model_params * mp,
                                   const se_session_params * sp, se_memory_estimate * out);   /* no_alloc + LOAD_MODE_NONE dry run */
SE_API se_status se_model_load(se_engine * e, const char * path, const se_model_params * p,
                               se_progress_cb cb, void * user, se_model ** out);
SE_API void      se_model_free(se_model * m);
SE_API int32_t   se_model_info_json(se_model * m, char * buf, size_t len);   /* desc, n_params, size, n_ctx_train, layers, kv/token,
                                                                                 template caps, tool support (lazy/required/none),
                                                                                 recommended sampling (general.sampling.*), mtp heads */
SE_API int32_t   se_model_tokenize(se_model * m, const char * text, int32_t len, bool add_special, bool parse_special,
                                   int32_t * out, int32_t cap);              /* <0 = -needed */
SE_API int32_t   se_model_count_chat_tokens(se_model * m, const char * request_json);   /* render + tokenize, no decode */

/* --- session (13-22) --- */
SE_API se_status se_session_create(se_model * m, const se_session_params * p, se_session ** out);
SE_API void      se_session_free(se_session * s);
SE_API se_status se_session_reset(se_session * s, int32_t seq_id);           /* -1 = all */
SE_API se_status se_session_start(se_session * s, const char * request_json);
          /* OAI-like: messages, tools, tool_choice, parallel_tool_calls, enable_thinking, reasoning_format,
             json_schema, sampling{temp,top_k,top_p,min_p,repeat_penalty,seed,...}, max_tokens, stop[],
             seq_id, lora[{id,scale}], media[{id}]. Does: template apply -> tokenize -> LCP reuse -> prefill
             on worker thread -> generation; non-blocking.                                        */
SE_API se_status se_session_next_event(se_session * s, int32_t timeout_ms, se_event * out);   /* pull mode */
SE_API se_status se_session_set_event_cb(se_session * s, se_event_cb cb, void * user);        /* push mode (optional) */
SE_API void      se_session_cancel(se_session * s);                          /* any thread; atomic + abort_callback */
SE_API se_status se_session_wait(se_session * s, int32_t timeout_ms);
SE_API se_status se_session_stats_json(se_session * s, char * buf, size_t len); /* n_ctx used, cache hits, t/s, spec accept */
SE_API se_status se_session_set_threads(se_session * s, int32_t n_threads, int32_t n_threads_batch);

/* --- prefix cache / state (23-26) --- */
SE_API se_status se_session_snapshot_save(se_session * s, int32_t seq_id, const char * path, const char * cache_key_json);
SE_API se_status se_session_snapshot_load(se_session * s, int32_t seq_id, const char * path, const char * cache_key_json,
                                          uint32_t * n_tokens_out);  /* validates key; replays last token */
SE_API int64_t   se_session_snapshot_size(se_session * s, int32_t seq_id);
SE_API se_status se_session_fork(se_session * s, int32_t src_seq, int32_t dst_seq);   /* llama_memory_seq_cp (kv_unified) */

/* --- adapters (27-29) --- */
SE_API se_status se_lora_load(se_model * m, const char * path, se_lora ** out);
SE_API void      se_lora_free(se_lora * l);
SE_API se_status se_session_set_loras(se_session * s, se_lora * const * loras, const float * scales, size_t n); /* invalidates cache if changed */

/* --- multimodal (30-32) --- */
SE_API se_status se_mmproj_load(se_model * m, const char * path, bool use_gpu, se_mmproj ** out);
SE_API void      se_mmproj_free(se_mmproj * mm);
SE_API se_status se_session_add_media(se_session * s, se_mmproj * mm, const uint8_t * bytes, size_t len,
                                      char * media_id_out, size_t id_len);   /* sha256 id; referenced from request_json */
#ifdef __cplusplus
}
#endif
```

Implementation notes for the shim, mapping each function to llama.cpp:
- `se_model_load`: `llama_model_load_from_file` + `common_chat_templates_init` (catch Jinja errors → `SE_ERR_TEMPLATE`, keep
  the model). Cache `llama_model_chat_template`, the caps map and the EOG set.
- `se_session_create`: compute effective params (validate, then `llama_init_from_model`), read back `llama_n_ctx[_seq]`, call
  `common_context_can_seq_rm` once, and initialise speculative from `speculative_json`. It also creates a
  `common_batch(ctx)`, a token mirror per seq, and the ring buffer.
- `se_session_start`: the §17 chat-request flow; the sampler from §10 (trigger conversion); `common_sampler_init` (catch);
  LCP + `llama_memory_seq_rm`; prefill in `n_batch` chunks emitting PROMPT_PROGRESS; decode loop with
  `common_sampler_sample/accept`. Per token: UTF-8 assembly, stop strings (`string_find_partial_stop`, `common/common.h:862`), and
  `common_chat_parse(partial)` + `compute_diffs` turned into events. At EOG/stop/length: final parse into DONE.final_json.
  Every `llama_decode` rc is mapped (1 → CONTEXT_FULL, 2 → CANCELLED, <0 → DECODE with a mirror resync from `pos_max`).
- `se_session_snapshot_*`: `llama_state_seq_save_file/load_file` plus a sidecar JSON cache key (§13). On a key mismatch, return
  `SE_ERR_STATE_MISMATCH` without loading.
- Dart side: `package:ffi` + `ffigen` from this header; JSON via `dart:convert`. Kotlin: a thin JNI (or a JNA-free
  `external fun`) layer mirroring the same 32 calls.

---

## 21. Recommendations for Sherpa

1. **Pin `0c1e57098` and treat `common/` as vendored source**, compiled into the shim, not as a dependency with an API
   contract. Re-verify §12 and §15 on every bump: those areas changed completely in the months before this commit.
2. **Use the template pipeline, not hand-rolled prompts.** `use_jinja=true`, `reasoning_format=DEEPSEEK` at apply time,
   `enable_thinking` per request, and the server's trigger and preserved-token conversion. Tokenize the rendered prompt with
   `add_special=false, parse_special=true`.
3. **Ship a tool-support matrix.** Classify each installed model at load time by calling `common_chat_templates_apply` with a
   dummy tool, recording `grammar.empty()` and `grammar_lazy`. Classes: *native lazy* (Qwen3/3.5, Hermes, Granite 4, LFM2.5,
   Gemma 4, Mistral), *required-only* (Llama 3.x), and *none* (Phi-3.5, Gemma 2). For the last two, offer a Sherpa
   "JSON envelope" mode (json_schema grammar plus its own parse) and surface it in the UI.
4. **Memory policy:** before loading, run `se_model_estimate` (`no_alloc`) and compare it with an OS-specific budget
   (Android `ActivityManager.getMemoryInfo`/`availMem`; iOS `os_proc_available_memory()`; UNVERIFIED APIs, see 06/07).
   Defaults for phones: `type_k=type_v=q8_0` (FA forced on), `n_ctx` 4096-8192, `n_ubatch` 256, `n_batch` 512,
   **`n_outputs_max = max(n_seq_max, n_draft+1)`**, `kv_unified=true`, `swa_full=false` + checkpoints for SWA models.
   Benchmark `use_extra_bufts` on and off on devices before choosing.
5. **Threads:** set `n_threads` to the performance-core count (not all cores). Prefer a non-OpenMP build so threads don't
   spin-wait under contention. PROBE-4 showed 50-100× stalls on an oversubscribed host with OpenMP; doc 05 already
   recommends `GGML_OPENMP=OFF` for Android. Expose `se_session_set_threads` so thermal throttling can lower it.
6. **Prefix caching is the biggest latency lever for an agent loop.** Keep a per-session token mirror and LCP reuse on every
   turn. Persist a snapshot of "system + tool schemas" per (model, toolset) with a strict cache key. For SWA/hybrid models use
   PARTIAL_ONLY checkpoints at user boundaries (copy the server's logic). Disable `ctx_shift`; do context management in Dart.
7. **Enable `ngram-mod` self-speculation by default for tool-heavy turns** (no extra RAM). Make `draft-mtp` automatic when
   `llama_model_n_layer_nextn(model) > 0`. Make a draft model opt-in only.
8. **Cancellation everywhere:** progress_callback for load, abort_callback for prefill and decode, a token-boundary flag for
   sampling. Always resync the token mirror from `llama_memory_seq_pos_max` after rc 2 or rc < 0.
9. **Measure performance yourself** (TTFT, prefill t/s, decode t/s, spec acceptance). Don't rely on `llama_perf_context` (its
   timings default to off and its buckets are merged).
10. **Harden the boundary:** validate token ids, catch everything, register `ggml_set_abort_callback` for crash breadcrumbs,
    and run one fuzz/CI job that feeds random requests through `se_session_start` on a tiny model (host build, as in these
    probes).

## 22. Risks

- **API churn in `common/`.** Chat formats, the speculative API, the `common_batch` and `llama_batch_ext` migration, and
  `load_mode` all changed recently. Upgrading llama.cpp means re-porting the shim. Mitigation: pin the commit; the probes in
  `/tmp/claude-0/llamacpp-api-probes/` are a ready-made regression suite.
- **Process-killing aborts** from `GGML_ASSERT` (`n_outputs_max<n_seq_max`, `no_alloc` + mmap, other asserts deep in ggml), and
  C++ exceptions crossing C functions (`llama_token_to_piece`, grammar accept, `llama_load_mode_from_str`). Mitigation:
  validation and try/catch in the shim. Residual risk from untested asserts remains: a crash takes down the Flutter app,
  because the engine is in-process.
- **Tool calling gaps for popular small models.** No lazy grammar for Llama 3.x, Phi-3.5, Gemma 2 or SmolLM3. The autoparser is
  heuristic, so a quirky community template can fail with "Unable to generate parser" or mis-parse.
- **Memory surprises on device:** the compute buffer (vocab × outputs), repack duplication (`use_extra_bufts`), n_ctx padding
  growth with `n_seq_max`, and SWA full-size caches (`swa_full` defaults to true in llama.h). Jetsam/LMK kills come without a
  catchable error.
- **Quantized KV performance on ARM is unmeasured.** q8_0 KV forces FA, and FA's CPU path speed on mobile cores is
  UNVERIFIED (host results were dominated by contention noise).
- **State-file compatibility is weakly validated** (no model hash, no LoRA check). A stale snapshot loaded into a different
  fine-tune of the same arch and shape would "work" and produce wrong output. A strict cache key is mandatory.
- **mtmd is experimental and untested here**, and it disables ctx_shift and cache_reuse. M-RoPE models can't shift.
- **Full re-parse per token** in `common_chat_parse` is O(n²). It is fine for normal replies, but it could become measurable
  for multi-thousand-token tool arguments (e.g. file writes) on slow cores (UNVERIFIED magnitude).

## 23. Open questions for the product owner

1. Which model families are first-class at launch? This decides whether the "JSON envelope" fallback (Llama 3.x, Phi, Gemma 2)
   is needed for v1, or whether we restrict to natively-supported templates (Qwen3/3.5, Granite 4, LFM2.5, Gemma 4, Mistral).
2. Is parallel decoding of several agent sessions in one context (`n_seq_max>1`, `kv_unified`) required? Sub-agents sharing a
   system-prompt prefix via `seq_cp` is attractive but costs KV memory per sequence.
3. Should thinking ("reasoning") be on by default on phones, given the token cost? Should a reasoning-budget cap be exposed
   (`reasoning_budget_tokens`)?
4. Is it acceptable to keep the persisted prompt-cache snapshots (tens to hundreds of MB per model and toolset) on disk?
   What should the eviction budget be?
5. Is a second (draft) model ever acceptable on device, or is speculative limited to n-gram and MTP?
6. Is multimodal (images/audio via mmproj) in scope for v1? It disables context shift and chunk reuse, and adds a few hundred
   MB.
7. Is LoRA hot-swap (per-agent or per-skill adapters) a product feature? If yes, the prefix cache must be partitioned by
   adapter set.
8. For crash safety, would we accept running the engine in a separate Android process (bound service) at the cost of IPC
   streaming? On iOS this isn't available.

## 24. Verification log (10 most load-bearing claims)

| # | Claim | Confirmed by | Reference |
|---|---|---|---|
| 1 | `common_chat_templates_apply` with tools on Qwen3 yields `format=peg-native`, a lazy grammar (1132 B), trigger WORD `"<tool_call>\n"`, 4 preserved tokens and a serialized parser. Greedy generation + `common_sampler` produced a tool call that `common_chat_parse` structured | PROBE-2, PROBE-3 | `common/chat.cpp:1225-1366`, `common/sampling.cpp:187-310` |
| 2 | Reasoning splitting depends on `inputs.reasoning_format` at apply time, not on the parser params | PROBE-2 (NONE at apply → `<think>` left in content; DEEPSEEK → `reasoning='hmm'`) | `common/chat.h:260,289` |
| 3 | Llama 3.1/3.2/3.3, Phi-3.5, Gemma 2, SmolLM3 and Granite 3.3 get no grammar with tools in auto mode. Llama 3.2 JSON calls are still parsed; `required` yields a grammar | PROBE-6 (70/70 templates), PROBE-6b, `tests/test-chat.cpp:6297-6350` | `common/chat.cpp:1090-1222` |
| 4 | KV bytes: Qwen3-0.6B @4096: f16 448 MiB, q8_0 238 MiB, q4_0 126 MiB; per-token 114,688 / 60,928 / 32,256 B | PROBE-1 (llama_kv_cache log + memory breakdown), PROBE-3 (seq state 305,396 B / 5 tok) | `src/llama-kv-cache.cpp:209-234` |
| 5 | Quantized V requires FA (AUTO is forced on, DISABLED gives NULL); quantized K alone works without FA | PROBE-1 | `src/llama-context.cpp:3838-3848` |
| 6 | `n_outputs_max` controls the compute buffer (302.8 → 30.1 MiB). `n_outputs_max < n_seq_max` aborts the process | PROBE-1b, PROBE-4 (`GGML_ASSERT(n_outputs_max <= cparams.n_outputs_max)`) | `src/llama-context.cpp:250,377,2273` |
| 7 | n_ctx padded to 256; `n_seq_max=3` non-unified turns 4096 into 4608 / 1536 per seq | PROBE-1 | `src/llama-context.cpp:290-305` |
| 8 | `llama_decode` returns 1 when full, 2 on abort (aborted ubatch removed), -1 on bad seq_id | PROBE-3 | `include/llama.h:991-1005`, `src/llama-context.cpp:1843,1885-1919` |
| 9 | Seq state save/load (memory and file, cross-seq) round-trips exactly with a last-token replay. Whole-context state has no logits | PROBE-3 (match=1 / match=0 without replay) | `src/llama-context.cpp:3397-3440` |
| 10 | The new speculative API works. ngram-mod self-spec: 84.4% acceptance, 4 tokens/pass. Same-model draft-simple: 100%, 9 tokens/pass | PROBE-5 | `common/speculative.h:49-115`, `examples/speculative-simple/speculative-simple.cpp` |

Additional probe-confirmed facts: `no_alloc` needs `load_mode NONE` (PROBE-1b assert at `src/llama-model.cpp:1855`);
`llama_token_to_piece` throws on an invalid id (PROBE-3); `meta_val_str` returns the full length on truncation and -1 for arrays
(PROBE-1); `no_perf=true` (default) zeroes timings and stats accrue only at synchronize (PROBE-7); `progress_callback` fires
312× for the 0.6B load (PROBE-1).

Probe sources (compile with `/tmp/claude-0/llamacpp-api-probes/build.sh <name>`): `p1_meta_kv.cpp`, `p1b_compute.cpp`,
`p2_chat.cpp`, `p3_gen_state.cpp`, `p4_speed.cpp`, `p5_spec.cpp`, `p6_templates.cpp`, `p6b_llama32.cpp`, `p7_noperf.cpp`.
