# native/ — Sherpa's on-device inference engine

`native/engine` is `sherpa_engine`, one C++17 shim over llama.cpp + `common/` behind a small, versioned
C ABI ([`include/sherpa_engine.h`](../engine/include/sherpa_engine.h), history in
[`CHANGELOG.md`](../engine/CHANGELOG.md)). `native/llama` pins llama.cpp and builds the mobile artifacts.
Background: [`docs/PLAN.md`](../../docs/PLAN.md) "Local inference engine",
[`docs/research/04-llamacpp-api.md`](../../docs/research/04-llamacpp-api.md) (API, R04) and
[`05-llamacpp-build.md`](../../docs/research/05-llamacpp-build.md) (build, R05).

```
native/llama/   llama.lock  fetch.sh  build_android.sh  build_ios.sh  out/ (gitignored)
native/engine/  CMakeLists.txt  include/sherpa_engine.h  src/*.cpp  tests/
```

## Pins and sources

[`llama.lock`](llama.lock) is shell-sourceable and also read by CMake: llama.cpp `0c1e57098` (2026-10-01),
a content hash of the build-relevant tree, the GitHub tarball URL, the PyPI sdist mirror
(`llama_cpp_python-0.3.36`, which vendors exactly this commit) with its sha256, KleidiAI v1.24.0 (sha256 +
tree hash), NDK `29.0.14206865`, CMake 3.31.6, Android platform 29, iOS 17.0, and the Android size budget.

`fetch.sh` prints `LLAMA_CPP_SRC=… KLEIDIAI_SRC=…` for `eval`. Order: `$LLAMA_CPP_SRC` /
`$KLEIDIAI_SRC` → `$SHERPA_NATIVE_CACHE` (default `~/.cache/sherpa-native`) → GitHub tarball → PyPI sdist
(llama.cpp) / gitlab.arm.com then GitHub (KleidiAI). Every tree is checked against the lock's content hash
(GitHub archive bytes are not guaranteed stable, and github.com was unreachable when pinning); downloads
retry and resume because large transfers through proxies get cut. Sources stay **outside the repo**: ggml
runs `git rev-parse` in its own directory and would otherwise embed Sherpa's commit; the build scripts also
set `GIT_CEILING_DIRECTORIES`. `SHERPA_OFFLINE=1` never downloads, `SHERPA_STRICT=1` turns mismatches into
errors. The root `.gitignore` ignores `*.lock`; `native/llama/.gitignore` re-includes `llama.lock`.

## Host build and tests (Linux/macOS)

```sh
eval "$(native/llama/fetch.sh --no-kleidiai)"
cmake -S native/engine -B /tmp/se-host -G Ninja -DLLAMA_CPP_SRC="$LLAMA_CPP_SRC" \
  -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_OPENMP=OFF \
  -DSHERPA_ENGINE_TESTS=ON -DSHERPA_TEST_MODEL=/opt/models/Qwen3-0.6B-Q4_K_M.gguf -DSHERPA_TEST_THREADS=4
cmake --build /tmp/se-host -j3
ctest --test-dir /tmp/se-host --output-on-failure        # c_abi, make_test_lora (needs numpy), engine
/tmp/se-host/sherpa_engine_tests --model <gguf> --threads 2 --filter prefix   # one test, verbose numbers
```

`GGML_NATIVE=ON` is faster but ties the binaries to the build machine's CPU (a container migration to a
CPU without AVX-512 VNNI/AMX turned it into SIGILL here). The tests talk to `libsherpa_engine.so` only
through the C ABI; `c_abi_test.c` compiles the header as C11. The engine test prints a benchmark table
(and `--bench-json`) for `tools/bench` baselines. On shared CI runners lower `SHERPA_TEST_THREADS`: ggml's
spinning barriers degrade badly when another process takes a core.

## Android (`build_android.sh`, runs on Linux or macOS)

```sh
native/llama/build_android.sh     # env: ANDROID_NDK_HOME/ANDROID_HOME, SHERPA_BUILD_DIR, JOBS=3, SHERPA_MTMD=1
```

Flags (R05 §7.3): arm64-v8a, `android-29`, `ANDROID_STL=c++_shared`, `BUILD_SHARED_LIBS=ON`,
`GGML_BACKEND_DL=ON`, `GGML_CPU_ALL_VARIANTS=ON` (7 variants, `android_armv8.0_1` … `android_armv9.2_2`),
`GGML_CPU_KLEIDIAI=ON` with `FETCHCONTENT_SOURCE_DIR_KLEIDIAI` (CMake never downloads),
`GGML_OPENMP=OFF`, `GGML_LLAMAFILE=OFF`, `GGML_LTO=ON`, `-ffile-prefix-map` for stable paths.
`llama-common` is compiled into `libsherpa_engine.so` as a static archive behind a version script, so the
engine exports exactly the 42 `se_*` functions of ABI 1.1 (39 in 1.0) and dead code (arg parser,
downloader, HTTP) is dropped. `libmtmd.so` (image input through a paired projector) is built by default;
`SHERPA_MTMD=0` leaves it out.

Output in `out/android/`: `jniLibs/arm64-v8a/*.so` (`--strip-debug`, symbol table kept for Play's
`SYMBOL_TABLE` level), `symbols-arm64-v8a.tar.gz` (unstripped + `build-ids.txt`), `variants.txt`,
`manifest.json` (pins, flags, per-file sizes/sha256/build-id, gate results). Gates: every `PT_LOAD`
aligned to `0x4000`; `NEEDED` ⊆ {libc, libm, libdl, liblog, libandroid, libc++_shared, own libs} (no
`libomp.so`, no hard `libOpenCL.so`); all 7 variants present and exporting
`ggml_backend_score`/`ggml_backend_init`; the engine exports only `se_*`; `--strip-unneeded` payload ≤
`ANDROID_SIZE_BUDGET_BYTES` (16 MiB). Measured with mtmd (ABI 1.1): 15.86 MB stripped of the
16.78 MB budget (engine 2.29 MB, llama 3.39 MB, mtmd 1.37 MB, each variant ~0.95 MB,
libc++_shared 1.37 MB); build 267 s at `-j3` with a warm build directory. Without mtmd
(ABI 1.0) it was 14.47 MB. The headroom is now small: a llama.cpp bump that grows the payload may need
`SHERPA_MTMD=0` or a budget review.

App integration: copy `jniLibs/` into the plugin, `ndk { abiFilters += "arm64-v8a" }`,
`packaging { jniLibs { pickFirsts += "**/libc++_shared.so" } }`. No `extractNativeLibs` /
`useLegacyPackaging`: the engine `dlopen`s each CPU variant by bare file name, best first, which bionic
resolves inside the APK (upstream's directory scan finds nothing in the default packaging, R05 §4.3; the
device behaviour of this loader is still to be confirmed on hardware). `se_system_info_json()` reports
which variant loaded and the CPU features read from `getauxval`.

## iOS (`build_ios.sh`, macOS + Xcode only)

```sh
native/llama/build_ios.sh          # -> out/ios/SherpaEngine.xcframework(.zip) + manifest.json
```

Builds `ios-arm64` and `ios-arm64-simulator` with Metal (embedded shader library), BLAS/Accelerate, no
OpenMP, iOS 17.0, as static archives; CMake writes the archive list (`sherpa-static-libs-Release.txt`),
which is merged with `libtool` and linked into one dynamic `SherpaEngine.framework` exporting only `_se_*`
(`sherpa_engine.exports`), then `vtool` (device), `dsymutil`, `strip`, and
`xcodebuild -create-xcframework` with dSYMs. Upstream's `build-xcframework.sh` cannot be used as is: it
leaves out `llama-common` and targets 16.4. The simulator forces `n_gpu_layers = 0` (as llama.swiftui
does). Consume with SwiftPM `.binaryTarget(path: "Frameworks/SherpaEngine.xcframework")` or a podspec
`vendored_frameworks`. **This script has not been run** (no macOS here); its CMake side
(`sherpa_engine_bundle`, archive list) was verified on Linux.

## Engine architecture (summary)

- **Handles**: `se_model` (weights, vocab, chat templates; immutable, shareable), `se_session`
  (llama_context, persistent ggml threadpools, optional draft/MTP context + `common_speculative`, token
  history, LoRA set, event ring, one worker thread), `se_lora`, `se_canceller`. Handles hold shared
  ownership, so free order does not matter (a session keeps its model alive; adapters keep the model alive).
- **Errors**: every entry point is wrapped (`se::guard`); exceptions become `se_status` + a thread-local
  message. Known abort paths are pre-validated: `n_outputs_max` vs `n_seq_max` and per-decode outputs
  (`llama-context.cpp:2120,2273`), tokens per decode ≤ `n_batch` (`:1785`), token ids for
  `token_to_piece` (`llama-vocab.cpp:3691`), dry run ⇒ `LOAD_MODE_NONE` (`llama-model.cpp:1855`),
  quantized V ⇒ flash attention and block-size checks (`llama-context.cpp:3840-3870`), per-layer queries on
  vocab-only models (`llama-hparams.cpp:50-56`, found by the tests), `common_memory` (aborts) is not used.
  `ggml_set_abort_callback` writes a crash breadcrumb for whatever remains.
- **Generation**: request JSON → `common_chat_msgs_parse_oaicompat` / `common_chat_tools_parse_oaicompat`
  → `common_chat_templates_apply` with `reasoning_format` set at apply time → sampler from the chat params
  (lazy grammar, single-token trigger words become token triggers, preserved tokens, thinking tags for the
  reasoning-budget sampler) → prompt tokens (BOS handled like the template expects) → longest common prefix
  with the session history, `llama_memory_seq_rm` beyond it → chunked prefill (cancel between chunks and
  inside `llama_decode` via the abort callback; a cancelled prefill keeps its finished chunks) → decode
  loop that always decodes the last prompt token itself (no stale logits after state loads) →
  `common_chat_parse(partial)` + `compute_diffs` → typed events. Speculation (`ngram-mod`, draft model,
  MTP) verifies drafts in one batch with `common_sampler_sample_and_accept_n`, keeps the draft context in
  lockstep, rolls KV back after partial acceptance and switches itself off when acceptance stays low.
- **Events**: bounded SPSC ring; the worker blocks when it is full (no event is ever dropped);
  `se_poll_events` hands out batches whose strings stay valid until the next poll; an optional synchronous
  callback (JNI/Swift; Dart should poll). Each generation ends with USAGE, PERF and exactly one FINISH.
- **State files**: `SHRPKV01` header (model id + fingerprint + shape, LoRA fingerprints and scales, KV
  types, resolved flash attention, llama.cpp commit) + token history + `llama_state_seq_get_data` bytes,
  written/read through `mmap` so hundreds of MB of KV need no heap copy; mismatches are refused before
  llama.cpp sees the bytes.
- **Memory estimate**: `no_alloc` dry run + context breakdown, corrected for llama.cpp's mmap layout (the
  mapped weight buffer spans the whole tensor-data section even when weights are also repacked into
  CPU_REPACK/KleidiAI/AMX buffers). On the host: estimate within 0.2% of the real allocation, 2% of RSS.

## Bumping llama.cpp

Change `LLAMA_COMMIT`, refresh `LLAMA_TREE_SHA256` with `fetch.sh --print-tree-hash <tree>`, update or
clear the PyPI mirror fields, re-read R04 §12 (chat parsers) and §15 (speculative API), rebuild, run the
host tests, then `build_android.sh` (its gates catch variant-list, alignment and NEEDED drift).
