# 05 — Building llama.cpp for mobile (Android + iOS) for Sherpa

Status: research digest, 2026-10-18. Scope: how to compile, package and load llama.cpp in a Flutter app with
Kotlin/Swift plugins. Covers CMake options, Android NDK, runtime CPU dispatch, GPU/NPU backends, 16 KB pages,
the xcframework, Flutter 3.47.7 toolchain defaults and native assets, and a pinned, reproducible layout for Sherpa.

Conventions
- `llama.cpp/<path>:<line>` = the pinned tree at `/opt/vendor-src/llama-py/llama_cpp_python-0.3.36/vendor/llama.cpp`
  (ggml-org/llama.cpp commit `0c1e57098bba43ac29e6e3b677cdceebdd22334f`, 2026-10-01, "webgpu: fix SSM_SCAN binding aliasing (#29750)").
- `flutter/<path>:<line>` = `/opt/flutter-sdk/flutter` (Flutter 3.47.7 stable, framework `abaf9c5237`, engine `deb287481e`, Dart 3.13.5;
  from `bin/cache/flutter.version.json`).
- **EXP-A/B/C/D** = cross-compile experiments I ran with NDK r29 (results in §4.10). Build dirs are under `/opt/vendor-src/llama-android-build/`.
- **UNVERIFIED** = not checked against source or official docs in this session.

---

## 0. TL;DR

1. **Android build (recommended):** NDK r29 `29.0.14206865`, `ANDROID_ABI=arm64-v8a`, `ANDROID_STL=c++_shared`, `BUILD_SHARED_LIBS=ON`,
   `GGML_BACKEND_DL=ON`, `GGML_CPU_ALL_VARIANTS=ON`, `GGML_CPU_KLEIDIAI=ON`, `GGML_NATIVE=OFF`, `GGML_OPENMP=OFF`, `GGML_LLAMAFILE=OFF`,
   `LLAMA_OPENSSL=OFF`, everything in `LLAMA_BUILD_*` set to OFF. It builds in **185 s at -j3** on a 4-core host, produces 7 Android
   CPU variants (`android_armv8.0_1` … `android_armv9.2_2`), and every LOAD segment is **aligned to 0x4000 (16 KB) by default**.
   The stripped output is **11.5 MB** (10.8 MB with `GGML_LTO=ON`), plus `libc++_shared.so` at 1.37 MB.
2. **The upstream backend loader does not fit Android's default packaging.** `ggml_backend_load_all_from_path()` lists the files in a
   directory. With AGP's default uncompressed JNI libs (minSdk ≥ 23), `nativeLibraryDir` contains nothing. The upstream example works
   around this with `android:extractNativeLibs="true"`. Sherpa should instead `ggml_backend_load("libggml-cpu-android_<v>.so")` each
   variant by bare file name, best first (§4.3).
3. **iOS:** use the upstream `build-xcframework.sh`. It builds static libs and merges 8 of them into a *dynamic* `llama.framework`,
   with Metal and an embedded Metal source library. Minimum iOS is **16.4**. **The upstream release xcframework has no simulator slice**
   (release.yml builds only `macos ios-device`), so Sherpa has to build its own.
4. **Flutter 3.47.7 defaults:** compileSdk 36, minSdk 24, targetSdk 36, NDK `28.2.13676358`, AGP 9.1.0, Gradle 9.3.1, KGP 2.4.0.
   AGP 9's built-in Kotlin is **opted out** (`android.builtInKotlin=false`, `android.newDsl=false`); the Flutter Gradle plugin
   applies `kotlin-android` itself. SwiftPM is **on by default**. `plugin_ffi` is **deprecated** in favour of `package_ffi`, which uses
   build hooks. Native assets are on by default.
5. **Native assets could build llama.cpp**, but it doesn't fit Sherpa's Kotlin/Swift-plugin design (§5.5). Ship **prebuilt artifacts**
   instead: `jniLibs` on Android and a vendored xcframework on iOS. Both are produced by `native/llama/build_{android,ios}.sh` from a
   pinned commit. A `LLAMA_CPP_SRC` override and a **PyPI sdist mirror** make offline or GitHub-less builds work (§6).
6. **No QNN / NNAPI / CoreML / ANE backend exists at this commit.** The NPU path is `ggml-hexagon`, which is experimental, needs the
   Snapdragon Docker toolchain and Hexagon SDK 6.6, and builds v73–v81 skels. The GPU paths are OpenCL (Adreno) and Vulkan
   (Vulkan ≥ 1.2). Both need extra SDK pieces that are not in the NDK.

---

## 1. Pinned upstream facts

| Item | Value | Ref |
|---|---|---|
| llama.cpp version string | `0.5.0-dev` (`LLAMA_BUILD_IS_DEV` ON) | `llama.cpp/CMakeLists.txt:6-21` |
| ggml version | `0.25.3` | `llama.cpp/ggml/CMakeLists.txt:6-8` |
| CMake minimum | `3.14...3.28`; KleidiAI needs ≥ 3.16; Vulkan needs ≥ 3.19 | `CMakeLists.txt:1`, `ggml/src/ggml-cpu/CMakeLists.txt:627`, `ggml/src/ggml-vulkan/CMakeLists.txt:1` |
| C/C++ standard | C11 / C++17 | `ggml/CMakeLists.txt:288-292` |
| KleidiAI pin | `v1.24.0`, MD5 `2f02ebe29573d45813e671eb304f2a00`, fetched at **configure time** from github.com releases | `ggml/src/ggml-cpu/CMakeLists.txt:648-650` |
| KleidiAI mirror | `https://gitlab.arm.com/kleidi/kleidiai/-/archive/v1.24.0/kleidiai-v1.24.0.tar.gz` is **byte-identical** (same MD5; sha256 `9348b969e042d8890a54b01a463dbe71f5a4c074b5329e9c26a85ef3b68aa19b`) | verified with `md5sum` in this session |
| Source mirror | PyPI `llama_cpp_python-0.3.36.tar.gz` (76,589,250 B, sha256 `832db0699007f1be95a7e41ef12e88926b02ba836461e36a36372db2760c1a2e`) contains `vendor/llama.cpp` at exactly this commit | PyPI JSON API plus local `sha256sum` |
| Release tag (`bNNNN`) for this commit | **UNVERIFIED.** The local checkout is shallow (`rev-list --count` = 1) and the GitHub API is not reachable from this session | — |
| Upstream Android CI NDK | `29.0.14206865` (r29), `ANDROID_PLATFORM=android-28` | `.github/workflows/build-android.yml:99,141`, `release.yml:465,514` |

## 2. CMake option reference (mobile-relevant)

| Option | Default | Sherpa Android | Sherpa iOS | Notes / ref |
|---|---|---|---|---|
| `BUILD_SHARED_LIBS` | ON (OFF on MinGW/Emscripten) | **ON** (DL requires it) | **OFF** (xcframework script) | `CMakeLists.txt:79`, `ggml/CMakeLists.txt:85` |
| `GGML_BACKEND_DL` | OFF | **ON** | OFF | Fatal error if `BUILD_SHARED_LIBS` is OFF: `ggml/src/CMakeLists.txt:188-190` |
| `GGML_BACKEND_DIR` | "" | leave unset | — | Compile-time search dir; requires DL (`ggml/src/CMakeLists.txt:368-373`). Useless on Android because the install path is per-install |
| `GGML_CPU_ALL_VARIANTS` | OFF | **ON** | OFF | Requires DL and is mutually exclusive with `GGML_CPU_ARM_ARCH` (`ggml/src/CMakeLists.txt:487-492`) |
| `GGML_CPU_ARM_ARCH` | "" | unset (variants) | optional | Adds `-march=<value>` (`ggml-cpu/CMakeLists.txt:210-211`) |
| `GGML_NATIVE` | OFF when `CMAKE_CROSSCOMPILING` or `SOURCE_DATE_EPOCH` is set | **OFF** explicitly | OFF | `ggml/CMakeLists.txt:105-110,123` |
| `GGML_CPU_KLEIDIAI` | OFF | **ON** (arm64 only) | OFF (upstream script) | Fatal error unless the target is an AArch64 Linux/Android/Apple/Windows target (`ggml-cpu/CMakeLists.txt:631-642`) |
| `GGML_CPU_REPACK` | ON | ON | ON | Runtime Q4_0→Q4_x_x repack (`ggml/CMakeLists.txt:152`) |
| `GGML_OPENMP` | ON | **OFF** | OFF (script) | §4.5 |
| `GGML_LLAMAFILE` | ON when built via llama.cpp (`CMakeLists.txt:165-167`) | **OFF** | default | Docs: "llamafile does not appear to support Android" (`docs/android.md`) |
| `GGML_LTO` | OFF | optional | optional | Sets IPO for ggml targets only (`ggml/src/CMakeLists.txt:58-66`). The CPU feature probes are always `-fno-lto` (`ggml-cpu/CMakeLists.txt:12-16`) |
| `GGML_METAL` / `GGML_METAL_EMBED_LIBRARY` | ON on Apple / `=GGML_METAL` | — | ON / ON | `ggml/CMakeLists.txt:95-103,238-246` |
| `GGML_BLAS` (Apple vendor) / `GGML_ACCELERATE` | ON on Apple / ON | — | ON | `ggml/CMakeLists.txt:95-98,193-196` |
| `GGML_VULKAN` | OFF | OFF in v1 | — | §4.6 |
| `GGML_OPENCL` (+`_EMBED_KERNELS` ON, `_USE_ADRENO_KERNELS` ON, `_TARGET_VERSION` 300) | OFF | OFF in v1 | — | `ggml/CMakeLists.txt:265-270` |
| `GGML_HEXAGON` | OFF | OFF in v1 | — | `ggml/CMakeLists.txt:272` |
| `LLAMA_OPENSSL` | **ON** | **OFF** | OFF | `CMakeLists.txt:144`. Only matters with `LLAMA_BUILD_COMMON` (cpp-httplib, `vendor/CMakeLists.txt:9-11`) |
| `LLAMA_CURL` | — | n/a | n/a | **Deprecated and ignored**: `llama_option_depr(WARNING LLAMA_CURL)` (`CMakeLists.txt:195`) |
| `LLAMA_SUBPROCESS` | OFF on iOS/Android | default | default | `CMakeLists.txt:104-110`. It also forces `MTMD_VIDEO` OFF (`tools/mtmd/CMakeLists.txt:8-10`) |
| `LLAMA_BUILD_COMMON/TESTS/TOOLS/EXAMPLES/SERVER/APP` | `${LLAMA_STANDALONE}` (ON when top-level) | **all OFF** (see Q1 for COMMON) | all OFF | `CMakeLists.txt:129-136` |
| `LLAMA_BUILD_MTMD` | OFF | ON only if multimodal is in scope | ON (script) | Builds `tools/mtmd` without tools (`CMakeLists.txt:266-269`) |
| `LLAMA_BUILD_COMMIT` / `LLAMA_BUILD_NUMBER` | from git | pass explicitly | pass explicitly | `CMakeLists.txt:153-158`. ggml separately runs `git rev-parse` in its own dir (`ggml/CMakeLists.txt:13-40`), see §6.6 |

## 3. Backend inventory at this commit (`ggml/src/`, `ggml/src/CMakeLists.txt:589-605`)

`ggml-blas, -cann, -cpu, -cuda, -et, -hexagon, -hip, -metal, -musa, -opencl, -openvino, -rpc, -sycl, -virtgpu, -vulkan, -webgpu, -zdnn, -zendnn`.

- **No `ggml-qnn`, NNAPI, TFLite, CoreML or ANE backend exists.** I grepped `ggml/src` and `ggml/CMakeLists.txt` and found none.
  On Qualcomm the NPU path is **`ggml-hexagon`** (FastRPC to the cDSP/HTP).
- `ggml-zdnn` is for IBM Z mainframes (`docs/backend/zDNN.md`), `ggml-zendnn` for AMD EPYC, `ggml-et` for a RISC-V manycore
  accelerator (`docs/backend/ET.md`), `ggml-virtgpu` for VM API remoting, `ggml-openvino` for Intel. **None of them apply to phones.**
- `ggml-webgpu` needs Dawn (`docs/build.md` "WebGPU"). It is not a practical mobile path today (UNVERIFIED on Android).
- Runtime load order in DL mode: blas, zendnn, cann, cuda, hip, metal, rpc, sycl, vulkan, virtgpu, opencl, hexagon, musa, openvino,
  **cpu last**. After that, the `GGML_BACKEND_PATH` env var can load an out-of-tree backend (`ggml/src/ggml-backend-reg.cpp:578-605`).

---

## 4. Android

### 4.1 Baseline NDK command (upstream docs)
`docs/android.md` "Cross-compile CLI using Android NDK" and `docs/build.md:655-684` (KleidiAI):
```
cmake -S . -B build-android -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-28 \
  -DGGML_CPU_KLEIDIAI=ON -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_LLAMAFILE=OFF -DLLAMA_OPENSSL=OFF
```
The docs say: "Do not add a global `-march` flag unless you intentionally want to raise the baseline". KleidiAI's own CMake sets
per-kernel `-march` (`docs/build.md:684`). Without `GGML_NATIVE`, `GGML_CPU_ARM_ARCH` or `GGML_CPU_ALL_VARIANTS`, the generic CPU
backend compiles for the **armv8-a baseline**: no dotprod, fp16 or i8mm in ggml's own kernels (`ggml-cpu/CMakeLists.txt:209-256`).

Upstream CI and release use `-DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON -DGGML_OPENMP=OFF -DANDROID_PLATFORM=android-28`, plus
`-DCMAKE_INSTALL_RPATH='$ORIGIN' -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON` for the CLI tarball (`release.yml:510-524`). The plain NDK CI
job uses `-DGGML_CPU_ARM_ARCH=armv8.5-a+fp16+i8mm` with android-31 (`build-android.yml:84`).

**API level:** EXP-A compiled cleanly at `android-24`, which is Flutter's default minSdk. API 24 is therefore not a build blocker.

### 4.2 Runtime CPU-feature dispatch: `GGML_BACKEND_DL` + `GGML_CPU_ALL_VARIANTS`

Each variant is a separate `MODULE` library named `libggml-cpu-<tag>.so` (`ggml/src/CMakeLists.txt:381-392`,
`ggml-cpu/CMakeLists.txt:20-27`). The Android list is at `ggml/src/CMakeLists.txt:532-540`. The `-march` values below are taken from
EXP-A `compile_commands.json`.

| Variant (`libggml-cpu-…so`) | Features (CMake) | `-march` actually used | Target SoCs (indicative, UNVERIFIED mapping) |
|---|---|---|---|
| `android_armv8.0_1` | — | `armv8-a` | Cortex-A53/A73 era |
| `android_armv8.2_1` | DOTPROD | `armv8.2-a+dotprod` | — |
| `android_armv8.2_2` | DOTPROD FP16 | `armv8.2-a+dotprod+fp16` | A55/A75/A76/A77/A78 |
| `android_armv8.6_1` | DOTPROD FP16 I8MM | `armv8.6-a+dotprod+fp16+i8mm` | — |
| `android_armv9.0_1` | DOTPROD I8MM FP16 **SVE2** (no SVE flag) | `armv8.6-a+dotprod+fp16+i8mm+sve2` | Cortex-A510/A710/X2+ |
| `android_armv9.2_1` | DOTPROD I8MM FP16 SVE **SME** | `armv9.2-a+dotprod+fp16+sve+i8mm+sme` | — |
| `android_armv9.2_2` | DOTPROD I8MM FP16 SVE SVE2 SME | `armv9.2-a+dotprod+fp16+sve+i8mm+sve2+sme` | SME2-class (e.g. C1/Lumex-era) |

The flag mapping (DOTPROD/FP16/SVE→armv8.2-a, I8MM/SVE2→armv8.6-a, SME→armv9.2-a) is at `ggml-cpu/CMakeLists.txt:212-254`. Each
variant also defines `GGML_USE_<FEAT>`.

**Scoring** (`ggml/src/ggml-cpu/arch/arm/cpu-feats.cpp:6-39`): the score starts at 1. Each compiled-in feature must be present at
runtime, otherwise the score is 0. Weights: dotprod +2, fp16 +4, sve +8, i8mm +16, sve2 +32, sme +64. Runtime detection uses
`getauxval(AT_HWCAP/AT_HWCAP2)` and `prctl(PR_SVE_GET_VL)` (`ggml/src/ggml-feats.h:7-42,99`). The feature probe is compiled
**without** arch flags and with `-fno-lto`, so it cannot SIGILL (`ggml-cpu/CMakeLists.txt:1-18`). Every variant exports
`ggml_backend_score` and `ggml_backend_init` (checked with `llvm-nm -D` on EXP-A).

**Loader** (`ggml/src/ggml-backend-reg.cpp:480-571`):
- `ggml_backend_load_best(name)` scans the search paths with `fs::directory_iterator`. The paths are, in order:
  `GGML_BACKEND_DIR`, then `get_executable_path()` (`/proc/self/exe` on Linux, `:401-462`), then the cwd, or only the user path
  when one is given.
- For every `libggml-<name>-*.so` it finds, it `dlopen(RTLD_NOW|RTLD_LOCAL)`s the file (`ggml-backend-dl.cpp:34-37`), calls
  `ggml_backend_score`, and keeps the best. If none scores, it falls back to `libggml-<name>.so`.
- `ggml_backend_load(path)` on a single path rejects score 0 and checks `GGML_BACKEND_API_VERSION` (`:222-260`).
- In DL mode nothing is registered statically, so the app **must** call a load function before `llama_backend_init()`.

### 4.3 How `examples/llama.android` loads backends, and the Android packaging trap

Example structure:
- `lib/` is an AAR module with namespace `com.arm.aichat`. It contains:
  - a JNI library `ai-chat` (`lib/src/main/cpp/ai_chat.cpp`);
  - the Kotlin facade `AiChat` → `InferenceEngine` → `internal/InferenceEngineImpl.kt`;
  - a GGUF metadata reader.
- `app/` is a demo View-based app.

Settings:
- Gradle: AGP 8.13.2, Kotlin 2.3.0, Gradle 8.14.3 (`gradle/libs.versions.toml`, `gradle-wrapper.properties`).
- `compileSdk 36`, `minSdk 33`, `ndkVersion "29.0.13113456"` (an r29 pre-release build), CMake `3.31.6`,
  `abiFilters arm64-v8a, x86_64` (`lib/build.gradle.kts:8-19,45`).

CMake arguments passed by `lib/build.gradle.kts:22-35`:
- `-DBUILD_SHARED_LIBS=ON -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_COMMON=ON -DLLAMA_OPENSSL=OFF`
- `-DGGML_NATIVE=OFF -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON -DGGML_LLAMAFILE=OFF`

The wrapper `lib/src/main/cpp/CMakeLists.txt:18-31` sets, per ABI:
- **arm64-v8a:** `GGML_CPU_KLEIDIAI ON` and **`GGML_OPENMP ON`**;
- **x86_64:** both OFF.

It then does `add_subdirectory(<repo root>)` and links `llama llama-common android log` (`:33-56`).

Load sequence:
1. Kotlin reads `applicationInfo.nativeLibraryDir` (`InferenceEngineImpl.kt:65`).
2. On a single-thread dispatcher (`Dispatchers.IO.limitedParallelism(1)`, `:124`), it calls `System.loadLibrary("ai-chat")` and then
   `init(nativeLibDir)` (`:135-136`).
3. JNI then calls `ggml_backend_load_all_from_path(nativeLibDir)` followed by `llama_backend_init()` (`ai_chat.cpp:44-57`).

JNI surface: `init`, `load`, `prepare`, `systemInfo`, `benchModel`, `processSystemPrompt`, `processUserPrompt`, `generateNextToken`,
`unload`, `shutdown`. All are global-state `Java_com_arm_aichat_internal_InferenceEngineImpl_*` functions and all are annotated
`@FastNative` (`InferenceEngineImpl.kt:82-110`). **Do not copy `@FastNative` onto long-running calls such as prefill or decode**
(UNVERIFIED rationale: FastNative calls are not suspendable by GC).

**The packaging trap:** the app manifest sets `android:extractNativeLibs="true"` (`app/src/main/AndroidManifest.xml:7`). That
attribute is what makes the directory scan work.
- Since AGP 4.2, the attribute has been replaced by `packaging.jniLibs.useLegacyPackaging`.
- When the setting is unset and minSdk ≥ 23, `.so` files stay **uncompressed and page-aligned inside the APK and are not extracted**.
  `nativeLibraryDir` is then empty and `ggml_backend_load_all_from_path()` finds **no CPU backend**.
- Sources: AGP 4.2.0 release notes (https://developer.android.com/build/releases/agp-4-2-0-release-notes) and the `JniLibsPackaging`
  API reference (https://developer.android.com/reference/tools/gradle-api/com/android/build/api/dsl/JniLibsPackaging).
- The Flutter template minSdk is 24, so a Flutter app hits this case.

Options for Sherpa:
1. **(Recommended)** Write a custom loader in the JNI shim. Iterate a fixed, build-generated list from best to worst:
   `android_armv9.2_2, 9.2_1, 9.0_1, 8.6_1, 8.2_2, 8.2_1, 8.0_1`. Call `ggml_backend_load("libggml-cpu-android_<v>.so")` with a
   **bare file name**, and stop at the first non-NULL result. `ggml_backend_load` → `dlopen(bare name)`, and bionic resolves the bare
   name inside the app's linker namespace, including libraries stored in the APK (the same mechanism `System.loadLibrary` relies on).
   On-device behaviour is **UNVERIFIED**; test it on 2–3 SoCs. Apply the same approach to optional GPU backends (`libggml-opencl.so`,
   `libggml-vulkan.so`).
2. Set `packaging { jniLibs { useLegacyPackaging = true } }` and keep the upstream directory scan. This compresses the libs in the
   APK and extracts them at install, so installed size grows by about 13 MB.

Caveat: upstream `load_best` also `dlopen`s every variant before checking its score, and so does option 1 when it walks down the
list. Variant constructors are compiled with high `-march` flags. Upstream accepts this risk; it should still be part of Sherpa's
device testing (UNVERIFIED that no variant runs SVE/SME code in static initialisers).

### 4.4 KleidiAI
- With `GGML_CPU_KLEIDIAI=ON`, a single static `kleidiai` target (v1.24.0) is linked into **every** CPU variant
  (`ggml-cpu/CMakeLists.txt:682-702`). Each variant then carries all microkernels and chooses among them at runtime: EXP-A shows
  300 `kai_*` symbols, 187 of them SME, even in `android_armv8.0_1`.
- KleidiAI accelerates selected `MUL_MAT` paths for F32 and common quants. Dispatch depends on CPU features, tensor type and shape
  (`docs/build.md:704-712`).
- SVE kernels are enabled only when the runtime SVE vector length equals 32 bytes, which Android queries at runtime
  (`docs/build.md:710`).
- Confirmation in logs is `load_tensors: CPU_KLEIDIAI model buffer size = …` (`docs/build.md:694-700`).
- The debug override is `GGML_KLEIDIAI_SME=0|<n>`. Do not set it in production (`docs/build.md:714-726`).
- **Offline builds:** KleidiAI is fetched through `FetchContent_Populate` at configure time. Passing
  `-DFETCHCONTENT_SOURCE_DIR_KLEIDIAI=<extracted kleidiai-v1.24.0>` works; EXP-A/C/D used it with no network access to github.com.
  CMake 3.31 prints a CMP0169 deprecation warning about `FetchContent_Populate`, which is harmless.

### 4.5 OpenMP on Android (verified in EXP-B)
- The example turns OpenMP on for arm64. On NDK r29, CMake's FindOpenMP then resolves
  `OpenMP_omp_LIBRARY=<ndk>/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/21/lib/linux/aarch64/libomp.so`.
  `libggml-base.so` and every `libggml-cpu-*.so` then get **`NEEDED libomp.so`**, a library that is **not part of the Android
  platform**.
- Any app built this way must package `libomp.so` (1.23 MB; it is 16 KB aligned). Whether AGP copies it automatically is
  **UNVERIFIED**. The docs warn that it "must still be installed by CMake as a dependency, which is not supported at this time"
  (`docs/android.md`).
- Setting `-DOpenMP_omp_LIBRARY=…/libomp.a` relinks statically (verified: the NEEDED entry disappears). It also puts a separate
  OpenMP runtime into ggml-base **and** into each variant, i.e. two runtimes per process (behaviour UNVERIFIED).
- **Recommendation: `GGML_OPENMP=OFF`**, which uses ggml's own threadpool. This matches upstream CI, release and docs. Benchmark
  OpenMP later, and if it wins, ship it as `libomp.so` in jniLibs.

### 4.6 GPU / NPU backends on Android

| Backend | Build requirements | Runtime | Status for Sherpa |
|---|---|---|---|
| **Vulkan** (`GGML_VULKAN`) | `find_package(Vulkan COMPONENTS glslc REQUIRED)` and `find_package(SPIRV-Headers CONFIG REQUIRED)` (`ggml-vulkan/CMakeLists.txt:9-14`). `#include <vulkan/vulkan.hpp>` (`ggml-vulkan-types.h:26`). A **host** C++ compiler for `vulkan-shaders-gen` via ExternalProject; override with `GGML_VULKAN_SHADERS_GEN_TOOLCHAIN` (`ggml/CMakeLists.txt:275`). | Needs Vulkan instance ≥ **1.2** (`ggml-vulkan.cpp:5183-5186`). Qualcomm: coopmat only on Adreno Gen 6+ (`:16239-16241`) | NDK r29 ships `shader-tools/linux-x86_64/glslc` and the C headers (`vulkan.h`, `vulkan_core.h`) but **no `vulkan.hpp` and no SPIRV-Headers CMake config** (checked). External Vulkan-Hpp and SPIRV-Headers are required. **Not built here** (prerequisites missing). Defer to v2 |
| **OpenCL** (`GGML_OPENCL`) | `find_package(OpenCL REQUIRED)`, `find_package(Python3 REQUIRED)`; kernels embedded through a Python script (`ggml-opencl/CMakeLists.txt:1-2,31-58`). Docs: copy Khronos OpenCL-Headers into the NDK sysroot and build the OpenCL-ICD-Loader with the NDK (`docs/build.md:733-777`) | Links `libOpenCL.so` directly. Verified on Adreno 750/810/830/840 and X-Elite; "A6x GPUs in phones are likely not supported" (`docs/backend/OPENCL.md`). Kernel binary cache: `GGML_OPENCL_KERNEL_CACHE_DIR`; the default is `<temp>/llama.cpp/cl-cache`, which is unusable in app contexts with `TMPDIR` unset (`cl-program-cache.cpp:197-202,310`). **Set it to `context.cacheDir`** | Candidate v1.5 for Snapdragon. **Must be built as a DL backend**: a hard `NEEDED libOpenCL.so` in core libs would crash on non-Adreno devices. Apps targeting API 31+ must declare `<uses-native-library android:name="libOpenCL.so" android:required="false"/>` (vendor library rule: https://developer.android.com/guide/topics/manifest/uses-native-library-element; the libOpenCL name is my inference) |
| **Hexagon NPU** (`GGML_HEXAGON`) | Needs `HEXAGON_SDK_ROOT` and tools (`ggml-hexagon/CMakeLists.txt:1-20`). Builds skels `libggml-htp-v73/v75/v79/v81.so` via ExternalProject (`:62-84`). Recommended build: Docker `ghcr.io/snapdragon-toolchain/arm64-android:v0.7` with Hexagon SDK 6.6.0.0 and NDK r28b, preset `arm64-android-snapdragon` (android-34, `-march=armv8.7a+fp16+dotprod+i8mm … -flto`, OPENCL+HEXAGON ON, OPENMP OFF) (`docs/backend/snapdragon/README.md`, `CMakeUserPresets.json`) | `dlopen("libcdsprpc.so")` (`htp-drv.cpp:337`), runs as an **unsigned PD** (`DSPRPC_CONTROL_UNSIGNED_MODULE`, `ggml-hexagon.cpp:4135-4141`). Logs label it "experimental" (`:7884`). ~3.5 GB VA per session (README). The ExternalProject skel build is not 16 KB-aligned by the NDK (UNVERIFIED; the skels are DSP binaries) | Experimental. Needs `<uses-native-library android:name="libcdsprpc.so" android:required="false"/>` (my inference, UNVERIFIED on device). Defer |
| QNN / NNAPI | — | — | **Absent** at this commit |

### 4.7 16 KB page size
- **Play requirement:** "all apps targeting Android 15 (API level 35) and higher must support 16 KB memory page sizes on 64-bit devices
  on Google Play. **Starting February 1, 2027**, if your app updates don't support 16 KB memory page sizes, you won't be able to
  release these updates." (https://developer.android.com/guide/practices/page-sizes, last updated 2026-10-16). Flutter's
  targetSdk 36 is in scope.
- **NDK:** "r28 and higher compile 16 KB-aligned by default". r27 and lower need
  `-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384` (same page). NDK r28 CHANGELOG lines 17 and 61 say: "The default
  alignment of shared libraries for arm64-v8a and x86_64 is now 16k". The opt-out is `ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=OFF`,
  which re-adds `max-page-size=4096` (`<ndk r29>/build/cmake/flags.cmake:35-43`).
- **Verified:** with no flag at all, all 30 libraries in EXP-A/B/C/D show `LOAD … align 0x4000` (`llvm-readelf -lW`). The
  `plugin_ffi` template still hard-codes `-Wl,-z,max-page-size=16384` (`flutter/…/templates/plugin_ffi/src.tmpl/CMakeLists.txt.tmpl:21`).
  This is harmless and is a good belt-and-braces flag if anyone uses an r27 NDK.
- **AGP:** uncompressed libs need 16 KB zip alignment, which requires **AGP ≥ 8.5.1**. Flutter's AGP 9.1.0 is fine. `PAGE_SIZE` is
  undefined in 16 KB mode, so use `getpagesize()`/`sysconf`. To check: run `zipalign -c -P 16 -v 4 app.apk`, check
  `bundletool dump config` for `PAGE_ALIGNMENT_16K`, and check that every LOAD shows `2**14` (same page).

### 4.8 C++ STL
- NDK guidance: "If your application includes multiple shared libraries, you should use `libc++_shared.so`". A static runtime in
  several libraries is undefined behaviour, and "in practice crashes are very common". **CMake's default is `c++_static`**
  (https://developer.android.com/ndk/guides/cpp-support).
- The upstream example sets no STL, so it inherits `c++_static` across `libllama`, `libggml*`, `libllama-common` and `libai-chat`.
  EXP-B confirms there is no `libc++_shared` NEEDED, i.e. each library carries its own libc++ copy.
- Sherpa should use **`-DANDROID_STL=c++_shared`** for the multi-library DL layout and ship `libc++_shared.so` (1.37 MB stripped, r29).
- AGP packages `libc++_shared.so` automatically for externalNativeBuild with c++_shared. For prebuilt jniLibs it has to be copied
  in. Other Flutter plugins may ship their own copy; add `packaging { jniLibs { pickFirsts += "**/libc++_shared.so" } }` and make
  sure the newest NDK's copy wins (UNVERIFIED which copy pickFirst selects).
- The single-.so layout (EXP-C) is the NDK-blessed case for `c++_static`.

### 4.9 LTO, stripping, symbols
- `GGML_LTO=ON` turns into `-flto=thin` under NDK clang 21 (EXP-C/D `build.ninja`). It applies to ggml only. The 7 `*-feats`
  objects stay `-fno-lto`.
- EXP-D vs EXP-A: stripped size drops from 11.50 MB to **10.83 MB (−5.8%)**, and build time rises from 185 s to 297 s.
  `libllama.so` is barely affected (3.42 → 3.38 MB).
- The NDK toolchain compiles with **`-g` even in Release** (seen in `compile_commands.json`), and the linker emits a GNU build-id.
  Unstripped EXP-A output is 96.3 MB; with `--strip-debug` (symtab kept) it is 15.3 MB; with `--strip-unneeded` it is 12.9 MB.
- Play symbolication: set `android.buildTypes.release.ndk.debugSymbolLevel = SYMBOL_TABLE | FULL`. The symbols ride inside the AAB
  (APK builds produce `app/build/outputs/native-debug-symbols/<variant>/native-debug-symbols.zip`). The limit is 1.6 GB. "If a
  dependency's native libraries are already stripped, the debug information can't be recovered"
  (https://developer.android.com/build/include-native-symbols).
- So **put at least `--strip-debug` libraries in jniLibs** (SYMBOL_TABLE quality) and archive the full `-g` libraries keyed by
  build-id for `ndk-stack`. Release stripping happens in AGP and needs the NDK to be installed.

### 4.10 Cross-compile experiments (this session)
Host: 4 vCPU, `-j3`, Ninja and CMake 3.31.6 from the Android SDK, NDK r29 `29.0.14206865` (clang 21.0.0 r563880c),
KleidiAI from `FETCHCONTENT_SOURCE_DIR_KLEIDIAI`. Scripts are in the session scratchpad. Build dirs are under
`/opt/vendor-src/llama-android-build/`.

| Exp | Config | Time (configure+build) | Output (stripped `--strip-unneeded`) | NEEDED / notes |
|---|---|---|---|---|
| **A** `build-a-api24-cxxshared-noomp` | android-24, c++_shared, DL+ALL_VARIANTS+KleidiAI, OpenMP OFF, COMMON OFF, **MTMD ON** | 1 s + **185 s** | base 0.78, ggml 0.06, cpu variants 1.006–1.045 each (7× ≈ 7.2), llama 3.42, mtmd 1.37 → **12.87 MB** (11.50 without mtmd); gzip −9 ≈ 5.2 MB. Unstripped 96.3 MB | `libc++_shared.so libm libdl libc`; all LOAD 0x4000 |
| **B** `build-b-api28-cxxstatic-omp-common` | example-like: android-28, **c++_static**, **OpenMP ON**, **COMMON ON** | 2 s + **416 s** | base 1.09, ggml 0.67, cpu variants 1.63–1.67 each, llama 3.39, **llama-common 4.30** → **21.08 MB** | **`NEEDED libomp.so`** on base and cpu; static libc++ duplicated in every library |
| **C** `build-c-single-so-lto` | **single `libsherpa_llama.so`**: static ggml/llama, whole-archive, version-script export of `llama_* ggml_* gguf_*`, `--gc-sections`, c++_static, `GGML_LTO`, `GGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16`, KleidiAI, no DL | 2 s + **124 s** | **4.63 MB** (gzip 1.98 MB); unstripped 50.6 MB | `libm libdl libc` only; 255 `llama_*` + 887 `ggml_*` exported, 0 `std::` |
| **D** `build-d-api28-cxxshared-dl-lto` | A without MTMD, with `GGML_LTO=ON` | 2 s + **297 s** | **10.83 MB** | as A |
| cfg-x86_64 | configure only, ALL_VARIANTS | ok | 14 x86 variants (x64 … sapphirerapids) | emulator only |
| cfg-armv7 | configure only, armeabi-v7a + ALL_VARIANTS | configures (!) | picks the *armv8* Android variant list; `cpu-feats.cpp` is `#if __aarch64__` only, so no score function → **unsupported** (UNVERIFIED at compile time) | do not ship armeabi-v7a |

Vulkan was not built: `glslc` is present in the NDK, but Vulkan-Hpp and SPIRV-Headers are not.

---

## 5. iOS / Apple

### 5.1 Metal
- `GGML_METAL` defaults ON on Apple. `GGML_METAL_EMBED_LIBRARY` defaults to `${GGML_METAL}`. `GGML_METAL_TARGET_OS` is
  `macos|ios|xros|tvos` (`ggml/CMakeLists.txt:238-246`).
- **Embedded** (ON): every `kernels/*.metal` source has its headers concatenated in and is `.incbin`'d as text into
  `__DATA,__ggml_metallib` (`ggml-metal/CMakeLists.txt:76-143`). At init it is compiled **from source** with `newLibraryWithSource`,
  per kernel kind, in parallel (`ggml-metal-device.m:300-351,462-497`). The cost is a first-load shader compile on device (latency
  UNVERIFIED).
- **Not embedded:** `xcrun metal -O3` produces `default.metallib`, plus `ggml-tensor.metallib` when the SDK is ≥ 26.0 (tensor API,
  OS 26+) (`ggml-metal/CMakeLists.txt:162-240`). The library is looked up in `SWIFTPM_MODULE_BUNDLE` or `bundleForClass`
  (`ggml-metal-device.m:498-516`). The xcframework script copies `*.metallib` into the framework when EMBED is OFF
  (`build-xcframework.sh:172-178`).
- Recommendation: keep **EMBED ON** for v1 because it is simpler to package. Measure first-load time and switch to a precompiled
  metallib if it is slow (Q8).
- The simulator: `llama.swiftui` forces `n_gpu_layers = 0` under `targetEnvironment(simulator)` (`LibLlama.swift:66-69`). Do the
  same in Sherpa.

### 5.2 `build-xcframework.sh` anatomy
- **Minimum OS:** iOS **16.4**, macOS 13.3, visionOS 1.0, tvOS 16.4 (`:7-10`).
- **Defaults:** `BUILD_SHARED_LIBS=OFF`; `LLAMA_BUILD_{APP,COMMON,EXAMPLES,TOOLS,TESTS,SERVER}=OFF`; `LLAMA_BUILD_MTMD=ON`;
  `GGML_METAL=ON`; `GGML_METAL_EMBED_LIBRARY=${env:-ON}`; `GGML_BLAS_DEFAULT=ON`; `GGML_OPENMP=OFF`; `GGML_NATIVE=OFF`; `-g`;
  Xcode generator; codesigning off; `DEBUG_INFORMATION_FORMAT=dwarf-with-dsym` (`:12-23,62-88`). Per platform it adds
  `LLAMA_OPENSSL=OFF MTMD_VIDEO=OFF` (`:453-488`).
- **Builds:** `ios-sim` (arm64 and x86_64), `ios-device`, macOS, visionOS (+sim), tvOS (+sim). It takes positional build names,
  e.g. `./build-xcframework.sh ios-sim ios-device` (`:3-4,35-60`).
- **Merged:** `libllama.a, libggml.a, libggml-base.a, libggml-cpu.a, libggml-metal.a, libggml-blas.a, libmtmd.a, libvendor-hash.a`
  are combined with `libtool -static` (`:293-310`). The result is linked into a **dynamic** `llama.framework/llama` with `clang++
  -dynamiclib -Wl,-force_load … -framework Foundation -framework Metal -framework Accelerate`,
  `-install_name @rpath/llama.framework/llama` (`:372-379`).
- **Device post-processing:** `vtool -set-build-version ios 16.4 16.4` (`:382-411`), then a separate dSYM is generated and the binary
  is stripped with `strip -S` (`:413-447`).
- **Headers:** `llama.h, ggml.h, ggml-opt.h, ggml-alloc.h, ggml-backend.h, ggml-metal.h, ggml-cpu.h, ggml-blas.h, gguf.h, mtmd.h,
  mtmd-helper.h`. The module map is `framework module llama { umbrella "Headers"; link "c++"; link framework "Accelerate"/"Metal"/"Foundation" }`
  (`:160-192`).
- **Output:** `build-apple/llama.xcframework` with `-debug-symbols` per slice (`:636-644`).
- **Not included:** `llama-common` (no jinja chat templates and no `common_*` helpers; only `llama_chat_apply_template` in `llama.h`).
  This is relevant to Q1.
- **Upstream release xcframework:** the `ios-xcode` job runs `./build-xcframework.sh macos ios-device` "only macos and ios-device due
  to long build time" on `macos-26` with Xcode 26.4 (`release.yml:1660-1717`). **It has no iOS-simulator slice.** The SwiftPM
  `binaryTarget(url:…b5046…)` example in `docs/xcframework.md` points at these release zips.
- **Requires macOS + Xcode.** It cannot be built on this Linux host, so none of the above was executed here; it all comes from
  reading the source.

### 5.3 Accelerate / BLAS / CPU on iOS
- On Apple, `GGML_BLAS` defaults ON with vendor `Apple`, which builds the `ggml-blas` backend on Accelerate (`ggml/CMakeLists.txt:95-98`).
- `GGML_ACCELERATE=ON` links Accelerate into the CPU backend with `ACCELERATE_NEW_LAPACK` and `ACCELERATE_LAPACK_ILP64`
  (`ggml-cpu/CMakeLists.txt:64-77`).
- BLAS helps prompt processing only at batch > 32 (`docs/build.md:96-102`).
- The xcframework passes no `GGML_CPU_ARM_ARCH`, so ggml's generic CPU code uses Apple clang's default arm64 target.
  **UNVERIFIED** whether that includes dotprod for iOS 16.4.
- `GGML_CPU_ALL_VARIANTS` on Apple defines `apple_m1/m2_m3/m4` variants (`ggml/src/CMakeLists.txt:541-544`). They need DL and
  dlopen'd dylibs, which **is not viable on iOS** (App Store bundles frameworks only), so do not use them.
- KleidiAI is allowed on Apple arm64 (`ggml-cpu/CMakeLists.txt:632-638`) but is not enabled by the script. It is a possible later
  tweak (UNVERIFIED perf).
- Privacy manifest: the required-reason APIs I found (`stat`/`fstat`) are only on `__gnu_linux__`/`__linux__` paths
  (`ggml-cpu.c:644-705`, `llama-mmap.cpp:198-204`). That suggests llama.cpp adds no required-reason API usage on iOS. **UNVERIFIED;
  audit the final binary.**

### 5.4 Consuming the xcframework
- **SwiftPM (Flutter default):** in the plugin's `ios/<plugin>/Package.swift` add `.binaryTarget(name: "llama",
  path: "Frameworks/llama.xcframework")` and add `"llama"` to the plugin target's dependencies. The path must be inside the package
  root (standard SwiftPM rule; Apple's page could not be rendered here, so **UNVERIFIED** for the Flutter-generated package). For a
  dynamic framework, Xcode embeds and signs it when the product is linked (**UNVERIFIED** with Flutter's
  `FlutterGeneratedPluginSwiftPackage`; test it).
- **CocoaPods (keep for compatibility):** `s.vendored_frameworks = '<plugin>/Frameworks/llama.xcframework'`, `s.platform = :ios, '16.4'`.
  CocoaPods trunk becomes **read-only on Dec 2, 2026** and is in maintenance mode. Plugins should support both SPM and CocoaPods
  "until further notice". SPM has been the default since Flutter 3.44
  (https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-plugin-authors).
- **Deployment target:** the Flutter app template uses `IPHONEOS_DEPLOYMENT_TARGET = 15.0` (`templates/app/ios.tmpl/…pbxproj.tmpl:383`;
  Sherpa `app/ios/Runner.xcodeproj/project.pbxproj:363,490`). With the stock script the **app must be raised to ≥ 16.4**, or Sherpa
  rebuilds with a lower `IOS_MIN_OS_VERSION` (feasibility UNVERIFIED; Metal feature checks are runtime `supportsFamily` calls,
  `ggml-metal-device.m:1133-1145`).
- `llama.swiftui` embeds `../../build-apple/llama.xcframework` with CodeSignOnCopy and RemoveHeadersOnCopy
  (`project.pbxproj:20-51`) and wraps the C API in a Swift `actor LlamaContext` (`LibLlama.swift`).

---

## 6. Flutter 3.47.7 facts relevant to the native build

### 6.1 Android defaults (`flutter/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt:23-42`, `lib/src/android/gradle_utils.dart:36-73`)
- `compileSdkVersion 36`, `minSdkVersion 24`, `targetSdkVersion 36`, `ndkVersion "28.2.13676358"` (the AGP default NDK).
- Template Gradle **9.3.1**, AGP **9.1.0** (module 9.1.0), KGP **2.4.0**. Max known AGP is 9.2. Java ≥ 17.
- The current AGP is 9.4.0 (Sept 2026), and its default NDK is still 28.2.13676358
  (https://developer.android.com/build/releases/gradle-plugin).
- Sherpa's `app/android` matches the template: AGP 9.1.0, KGP 2.4.0, Gradle 9.3.1, `ndkVersion = flutter.ndkVersion`.
- Default AAB/APK ABIs are **`android-arm, android-arm64, android-x64`** (`lib/src/commands/build_appbundle.dart:43`,
  `build_apk.dart:72-73`). Sherpa must exclude `android-arm`, or ship it without local inference (§4.10 cfg-armv7).

### 6.2 AGP 9 built-in Kotlin: not used
- The template's `gradle.properties` sets `android.newDsl=false` and `android.builtInKotlin=false`
  (`templates/app/android.tmpl/gradle.properties.tmpl:3-6`).
- `settings.gradle.kts` declares `org.jetbrains.kotlin.android` with `apply false` (`settings.gradle.kts.tmpl:22-23`).
- The app's `build.gradle.kts` does not apply KGP. The Flutter Gradle plugin applies `kotlin-android` to every app and plugin
  subproject that lacks it whenever built-in Kotlin is disabled (`FlutterPluginUtils.kt:572-590`). Built-in Kotlin defaults to true
  only for AGP ≥ 9 when the property is unset (`:706-728`).
- The plugin template (`templates/plugin/android-kotlin.tmpl/build.gradle.kts.tmpl`) uses `buildscript` classpath AGP plus KGP and
  `plugins { id("com.android.library") }`.

### 6.3 iOS / SwiftPM
- The `swiftPackageManager` feature is enabled by default on stable (`lib/src/features.dart:233-240`).
- `flutter create --template=plugin` creates the SPM layout `ios/<name>/Package.swift`. `swift-tools-version 5.9`, a
  `FlutterFramework` path dependency and `.iOS("15.0")` come from the template. CocoaPods templates are used only when a `Classes/`
  directory already exists (`lib/src/commands/create.dart:990-1025`, `templates/plugin_swift_package_manager/ios.tmpl/…/Package.swift.tmpl`,
  `lib/src/macos/swift_packages.dart:10`, `lib/src/darwin/darwin.dart:79`).

### 6.4 `plugin_ffi` vs `package_ffi`
- `flutter create --template=plugin_ffi` prints: "The "plugin_ffi" template is deprecated … Use the "package_ffi" template instead"
  (`create.dart:303-310`).
- `plugin_ffi` uses Groovy `build.gradle` with `externalNativeBuild { cmake { path = "../src/CMakeLists.txt" } }` and
  `ndkVersion = android.ndkVersion` (`templates/plugin_ffi/android.tmpl/build.gradle.tmpl:38-43`). Its CMake has the 16 KB flag
  (§4.7). Its podspec sets `:ios, '15.0'`.

### 6.5 Native assets / build hooks (Dart 3.13.5)
- The `nativeAssets` feature is enabled by default on master, beta and stable (`lib/src/features.dart:205-212`).
- flutter_tools pins `hooks_runner 1.5.0`, `hooks 2.0.2`, `code_assets 1.2.1` (`packages/flutter_tools/pubspec.yaml:60-62`).
- The `package_ffi` template's pubspec uses `hooks ^2.0.0`, `code_assets ^1.1.0`, `native_toolchain_c ^0.19.0`,
  `ffigen ^20.1.1` (`templates/package_ffi/pubspec.yaml.tmpl`). Its `hook/build.dart` uses `CBuilder.library(...)`.
- pub.dev latest as of today: `hooks 2.2.0` (2026-08-18), `code_assets 2.1.0` (2026-09-16), `native_toolchain_c 0.19.5`,
  `ffigen 23.0.0`, `native_toolchain_cmake 0.3.2` (community, rainyl, "experimental"), `android_libcpp_shared 0.3.1`.
  The template's `code_assets ^1.1.0` is **one major version behind**.
- Supported link modes on Android and iOS: `DynamicLoadingBundled`, `DynamicLoadingSystem`, `LookupInProcess`, `LookupInExecutable`.
  Anything else throws "Unsupported asset link mode", so **there is no `StaticLinking`**
  (`lib/src/isolated/native_assets/android/native_assets.dart:76-93`, `ios/native_assets.dart:57-74`).
- On Android, bundled `.so` files are copied into jniLibs (`gradle/src/main/kotlin/tasks/CopyFlutterJniLibsTask.kt:69-73`). On iOS
  each dylib is wrapped in a framework with consistent names, and no `_sim` or arch suffixes are allowed
  (https://docs.flutter.dev/platform-integration/bind-native-code).

**Could native assets build llama.cpp for us?** Technically yes:
- A `hook/build.dart` using `native_toolchain_cmake` (it finds the NDK through `ANDROID_NDK_HOME`/`ANDROID_HOME`, uses Ninja only on
  Android, and is experimental) could run the CMake configure and build in §7.3.
- It would then emit one `CodeAsset(DynamicLoadingBundled)` per `.so`, including dummy asset IDs for the 7 CPU variants so that they
  get packaged.

Why not for Sherpa v1:
1. The assets are designed for **Dart `@Native` FFI**. Sherpa's inference lives in **Kotlin/Swift plugins**, which link
   llama.cpp natively. The hook output is not visible to the plugin's Gradle/CMake or SwiftPM link steps.
2. Every clean `flutter build` and every CI run recompiles llama.cpp: about 3–5 min per Android ABI, and Xcode builds with a cold
   cache take longer. A hash cache would have to be built by hand.
3. CMake orchestration of Metal embedding, KleidiAI fetch and variants would be re-done in Dart through an experimental third-party
   package.
4. iOS framework wrapping of several dylibs plus Metal needs care.

Revisit it if Sherpa moves inference to Dart FFI with `@Native` bindings. In that case, a hook that **downloads hash-verified
prebuilt artifacts** (the pattern the docs recommend) is the right shape, not a hook that compiles from source.

---

## 7. Recommended pinned, reproducible build layout for Sherpa

### 7.1 Tree
```
native/llama/
  llama.lock                  # LLAMA_COMMIT=0c1e57098bba43ac29e6e3b677cdceebdd22334f
                              # LLAMA_SRC_SHA256=<sha256 of the GitHub tarball>   (fill on first fetch)
                              # PYPI_SDIST=llama_cpp_python-0.3.36.tar.gz  PYPI_SHA256=832db069...c1a2e
                              # KLEIDIAI_TAG=v1.24.0 KLEIDIAI_MD5=2f02ebe29573d45813e671eb304f2a00
                              # NDK=29.0.14206865 CMAKE=3.31.6 XCODE=26.x IOS_MIN=16.4 ANDROID_MIN_SDK=<Q3>
  fetch.sh                    # resolves sources into $SHERPA_NATIVE_CACHE (default ~/.cache/sherpa-native), never into the repo
  CMakeLists.txt              # superproject: add_subdirectory(${LLAMA_CPP_SRC}) + sherpa_llama_jni target (Android)
  jni/sherpa_llama_jni.cpp    # thin JNI shim: backend loader (§4.3), model/ctx lifecycle, token streaming callbacks
  build_android.sh            # -> out/android/<abi>/{lib*.so}, out/android/symbols/<abi>/*.so (unstripped), manifest.json
  build_ios.sh                # -> out/ios/llama.xcframework (+ dSYMs), manifest.json
  patches/                    # optional *.patch applied in order (keep empty if possible)
  README.md                   # only if the team wants one
packages/sherpa_llama/        # Flutter plugin (Kotlin + Swift), method/event channels or Pigeon
  android/src/main/jniLibs/<abi>/  # gitignored; populated from out/android or a CI artifact
  ios/sherpa_llama/Package.swift   # .binaryTarget(path: "Frameworks/llama.xcframework")
  ios/sherpa_llama/Frameworks/     # gitignored; populated from out/ios or a CI artifact
  ios/sherpa_llama.podspec         # vendored_frameworks for CocoaPods users
```

### 7.2 `fetch.sh` contract
Resolution order:
1. **`LLAMA_CPP_SRC=/path/to/llama.cpp`**. Use the tree as is, after verifying `git rev-parse HEAD` when it is a git checkout, or a
   stamp file / `include/llama.h` hash otherwise. Warn on a mismatch, and fail if `SHERPA_STRICT=1`.
2. Cache hit at `$SHERPA_NATIVE_CACHE/llama.cpp-<commit>/`.
3. The GitHub archive `https://github.com/ggml-org/llama.cpp/archive/<commit>.tar.gz`, checked against sha256.
4. **The PyPI sdist mirror** `https://files.pythonhosted.org/packages/ec/e9/e7de2b0463ea3ffbf0ede6cb21b58c1258a8f6521aae45ca773a59fe7cf3/llama_cpp_python-0.3.36.tar.gz`
   (sha256 `832db069…c1a2e`). Extract `llama_cpp_python-0.3.36/vendor/llama.cpp`. This only works while the pin equals the commit
   that some llama-cpp-python release vendors; record that mapping in `llama.lock`.

KleidiAI: `KLEIDIAI_SRC` env var, then cache, then `gitlab.arm.com/kleidi/kleidiai/-/archive/v1.24.0/kleidiai-v1.24.0.tar.gz`, then
the GitHub release, all MD5-checked. The build passes `-DFETCHCONTENT_SOURCE_DIR_KLEIDIAI=…` so that **CMake never touches the network**.
Also pass `-DFETCHCONTENT_FULLY_DISCONNECTED=ON` (UNVERIFIED interplay with `FetchContent_Populate`; EXP-A worked without it).

### 7.3 `build_android.sh` (arm64-v8a; x86_64 optional for the emulator with `-DGGML_CPU_ALL_VARIANTS=OFF`)
```bash
cmake -S native/llama -B "$B" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-$MIN_SDK -DANDROID_STL=c++_shared \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_CPP_SRC="$SRC" \
  -DBUILD_SHARED_LIBS=ON -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON -DGGML_NATIVE=OFF \
  -DGGML_CPU_KLEIDIAI=ON -DFETCHCONTENT_SOURCE_DIR_KLEIDIAI="$KLEIDIAI" \
  -DGGML_OPENMP=OFF -DGGML_LLAMAFILE=OFF -DGGML_CCACHE=OFF -DGGML_LTO=ON \
  -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_TOOLS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF \
  -DLLAMA_BUILD_COMMIT="${COMMIT:0:7}" -DLLAMA_BUILD_NUMBER=0
cmake --build "$B" -j"${JOBS:-3}"
```
Post-steps:
- Copy `bin/*.so` and `<ndk>/…/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so`.
- Produce a `--strip-debug` copy for jniLibs, and keep the unstripped copy under `symbols/` keyed by `llvm-readelf -n` build-id.
- **Assert** `llvm-readelf -lW` shows LOAD align `0x4000` for every library, and that `NEEDED` ⊆ {libc, libm, libdl, liblog,
  libandroid, libc++_shared, own libs}. A stray `libomp.so` or `libOpenCL.so` fails the build.
- Generate `variants.txt` (the CPU variant list, best first) for the JNI loader.

### 7.4 `build_ios.sh`
- On macOS, run upstream `./build-xcframework.sh ios-sim ios-device` from the fetched tree. Use an out-of-tree copy because the
  script writes `build-*` dirs into its cwd and runs `rm -rf build-apple` (`:111-119`).
- Optional env: `GGML_METAL_EMBED_LIBRARY`. Patch `IOS_MIN_OS_VERSION` only if Q4 allows it. Decide `LLAMA_BUILD_MTMD` per Q2;
  the script hard-codes it ON.
- Output: `build-apple/llama.xcframework` plus per-slice dSYMs. Record `xcodebuild -version` and the sha256 of the zipped
  xcframework in `manifest.json`.
- If the plugin ever consumes it through `url:`, compute the SPM checksum with `swift package compute-checksum`.

### 7.5 Android integration choice

| | **Prebuilt `.so` in plugin `jniLibs` (recommended)** | `externalNativeBuild` in the plugin |
|---|---|---|
| App build time | ~0 (copy and strip) | +3–5 min per ABI per variant (debug and release) on clean builds (EXP-A 185 s, EXP-B 416 s at -j3) |
| Toolchain on every dev machine/CI | NDK only for AGP stripping | NDK r29, CMake 3.31.6 and Ninja, plus KleidiAI source or network at configure |
| Determinism | Artifacts hashed once in CI | Depends on each machine's NDK and CMake |
| Defaults to fight | none | AGP's `ANDROID_STL=c++_static`, `ANDROID_PLATFORM`=module minSdk, `ndkVersion` mismatch warning vs the app (Flutter checks plugin NDK > app NDK) |
| Iterating on the JNI shim | rebuild via script | native IDE support |

Hybrid: keep a Gradle property (e.g. `-Psherpa.llama.fromSource=true`) that switches the plugin to `externalNativeBuild { cmake {
path("../../../native/llama/CMakeLists.txt"); version = "3.31.6" } }`, with the same `arguments` as §7.3, for native developers.

App module settings:
- `ndkVersion = "29.0.14206865"`, which matches upstream CI, or keep 28.2.13676358; both default to 16 KB.
- `ndk { abiFilters += listOf("arm64-v8a") }`, plus `x86_64` for debug if wanted.
- `packaging { jniLibs { pickFirsts += "**/libc++_shared.so" } }`.
- `buildTypes.release.ndk.debugSymbolLevel = "SYMBOL_TABLE"`.
- Build with `flutter build appbundle --target-platform android-arm64`.
- Manifest: `<uses-native-library android:name="libOpenCL.so" android:required="false"/>` only once OpenCL ships.

### 7.6 Reproducibility
- Pin the NDK (`ndkVersion`, `ANDROID_NDK`), CMake 3.31.6 (`externalNativeBuild.cmake.version` / `cmake.dir`), Xcode (CI image)
  and every source hash. Use `SOURCE_DATE_EPOCH`, which also forces `GGML_NATIVE` OFF (`ggml/CMakeLists.txt:105`).
- **ggml runs `git rev-parse --short HEAD` and `git diff-index` in its own dir** (`ggml/CMakeLists.txt:13-40`). If the source tree
  sits inside the Sherpa git checkout without its own `.git`, ggml embeds *Sherpa's* commit and the `-dirty` flag. To avoid this,
  keep sources in `$SHERPA_NATIVE_CACHE` outside the repo, or set `GIT_CEILING_DIRECTORIES` for the build.
- Add `-ffile-prefix-map=$SRC=llama.cpp` to make paths in DWARF and `__FILE__` stable (UNVERIFIED effect on build-id equality).
- CI publishes `out/` as a versioned artifact (`sherpa-llama-<commit7>-<ndk>-<n>`), and the plugin's fetch step verifies its sha256.

---

## 8. Recommendations for Sherpa
1. **Pin** llama.cpp `0c1e57098bba…` with KleidiAI v1.24.0, NDK r29 `29.0.14206865`, CMake 3.31.6 and Xcode 26.x. Bump deliberately
   with a recorded diff of CMake options and the CPU variant list.
2. **Android:**
   - Build the DL multi-variant flag set from §7.3 with `ANDROID_STL=c++_shared`, `GGML_OPENMP=OFF`, `GGML_CPU_KLEIDIAI=ON`,
     `LLAMA_BUILD_*` OFF and `GGML_LTO=ON`.
   - Ship it as prebuilt jniLibs (`--strip-debug`) and archive the unstripped symbols.
   - Use the **bare-name variant loader** in the JNI shim (§4.3) instead of `ggml_backend_load_all_from_path(nativeLibraryDir)`.
3. **Keep EXP-C, the single static `.so` (4.6 MB), as a fallback build flavour.** Use it if the DL loader misbehaves on some OEM, or
   if APK size dominates. It loses SME/SVE2/i8mm in ggml's own kernels; KleidiAI still dispatches at runtime for supported ops.
4. **ABIs:** ship arm64-v8a only. Build AABs with `--target-platform android-arm64`, or detect and disable local inference elsewhere.
   x86_64 is for emulator dev only, without ALL_VARIANTS.
5. **iOS:**
   - Build `llama.xcframework` with upstream `build-xcframework.sh ios-sim ios-device` (Metal and embedded library ON, BLAS and
     Accelerate ON).
   - Vendor it in `packages/sherpa_llama/ios/sherpa_llama/Frameworks/` (gitignored, CI artifact). Expose it through an SPM
     `binaryTarget(path:)` and a podspec `vendored_frameworks`.
   - Raise the app's iOS deployment target to **16.4**, and force `n_gpu_layers=0` in the simulator.
6. **No GPU/NPU in v1.** Plan OpenCL/Adreno as a DL module (`libggml-opencl.so`, optional `uses-native-library`, cache dir set to
   `cacheDir`) after measuring CPU+KleidiAI. Vulkan needs Vulkan-Hpp and SPIRV-Headers vendored. Treat Hexagon as research only.
7. **Do not adopt native-assets hooks for llama.cpp in v1.** Revisit only if inference moves to Dart FFI, and then as a "download
   prebuilt, verify hash" hook.
8. **CI gates:** LOAD alignment 0x4000, the NEEDED allow-list, no `libomp`/`libOpenCL` NEEDED, a `zipalign -c -P 16` check on the
   APK, a size budget (arm64 jniLibs ≤ 14 MB stripped), and an exported-symbol diff for `llama.h` ABI drift.
9. **Copy patterns from the upstream example:** a single-thread dispatcher for all llama calls, and a log callback into `__android_log`.
   **Avoid** its global-state JNI, `@FastNative` on long calls, `c++_static` with multiple libraries, and `OPENMP ON`.

## 9. Risks
- **Unverified on-device behaviour of the bare-name `dlopen` loader** with uncompressed APK libs, and of variant dlopen on low-end
  CPUs (static initialisers built with high `-march`). Mitigate with device-farm tests on ≥ 1 armv8.0, 1 armv8.2+dotprod,
  1 armv9 (SVE2) and 1 SME2 device. EXP-C is the fallback.
- **APK size:** about 12.9 MB uncompressed arm64 native payload (DL build with libc++_shared), roughly 5 MB compressed download.
  The single-.so build costs 4.6 MB but has no runtime dispatch.
- **Upstream churn:** the variant names and lists (`ggml/src/CMakeLists.txt:532-540`), the `LLAMA_CURL` removal and the `0.x`
  versioning all change often. The JNI loader's variant list must come from the build (`variants.txt`), not be hard-coded.
- **Network at configure time:** KleidiAI (and BoringSSL if `LLAMA_BUILD_COMMON`+BoringSSL) are fetched by CMake. If the
  `FETCHCONTENT_SOURCE_DIR_*` override is missing in any path (for example the `externalNativeBuild` hybrid), builds break when
  offline.
- **libc++_shared conflicts** with other Flutter plugins that ship their own copy (pickFirst picks one, perhaps an older one).
- **iOS:** the min-iOS bump to 16.4 affects device reach. First-load Metal source compile latency comes from EMBED_LIBRARY. Nothing
  here was built on macOS, so the whole iOS section is source-read only. CocoaPods trunk freezes on Dec 2, 2026.
- **16 KB:** satisfied by default with NDK ≥ r28 and AGP ≥ 8.5.1. The risk returns only if someone builds with NDK ≤ r27, adds
  third-party 4 KB-aligned `.so` files, or uses Hexagon skels (DSP-side, UNVERIFIED). The Play cut-off for updates is **2027-02-01**.
- **Licensing/compliance:** the build embeds license texts (`cmake/license.cmake`; KleidiAI is Apache-2.0). The app's OSS notices
  must include llama.cpp (MIT), KleidiAI and the vendored deps (stb, miniaudio, nlohmann, …) for any target that is built in.

## 10. Open questions for the product owner
1. **Chat templating and tool-call parsing:** do they run in the Dart core (then libllama alone is enough, as in the xcframework),
   or do we need `llama-common` (jinja, chat parsers; +4.3 MB on Android, and not in the upstream xcframework)?
2. **Multimodal (`mtmd`) in v1?** +1.37 MB on Android, and it is already ON in the xcframework script.
3. **Android minSdk:** 24 (Flutter default, verified to compile), 28 (upstream CI) or higher? It affects the device floor and
   `ANDROID_PLATFORM`.
4. **iOS minimum:** accept 16.4 (upstream xcframework), or require a validated lower-min rebuild?
5. **Size vs speed:** is about 13 MB (runtime dispatch over 7 variants) acceptable, or do we prefer 4.6 MB with a fixed
   `armv8.2-a+dotprod+fp16` baseline?
6. **Snapdragon GPU/NPU acceleration** (OpenCL, Hexagon): which release, and which device list should we target?
7. **Artifact hosting:** commit binaries (Git LFS), use CI artifacts, or GitHub/GCS release assets? This decides how `fetch` works
   for app developers without macOS.
8. **Metal library:** keep embedded source (runtime compile) or precompile `default.metallib` (faster first load, more packaging)?

## 11. Verification log (10 most load-bearing claims)

| # | Claim | How verified | Result |
|---|---|---|---|
| 1 | Android ALL_VARIANTS builds 7 variants with the listed `-march` flags and score bits | Read `ggml/src/CMakeLists.txt:532-540`, `ggml-cpu/CMakeLists.txt:212-254`, `arch/arm/cpu-feats.cpp:6-39`. EXP-A `compile_commands.json` and `llvm-nm -D` (`ggml_backend_score`/`init` exported) | ✔ |
| 2 | `GGML_CPU_ALL_VARIANTS` requires `GGML_BACKEND_DL` and `BUILD_SHARED_LIBS`, and conflicts with `GGML_CPU_ARM_ARCH` | `ggml/src/CMakeLists.txt:188-190,487-492` | ✔ |
| 3 | NDK r29 output is 16 KB aligned with no flags | `llvm-readelf -lW` on all 30 `.so` files in EXP-A–D: every LOAD has `0x4000`. NDK r28 CHANGELOG:17,61. `flags.cmake:35-43` | ✔ |
| 4 | Play: updates without 16 KB support are blocked from 2027-02-01; AGP ≥ 8.5.1 needed for zip alignment | developer.android.com/guide/practices/page-sizes (updated 2026-10-16), quoted verbatim | ✔ (doc) |
| 5 | The upstream loader enumerates a directory; the example relies on `extractNativeLibs="true"`; AGP defaults to non-extracted libs for minSdk ≥ 23 | `ggml-backend-reg.cpp:480-571`, `ai_chat.cpp:44-57`, `InferenceEngineImpl.kt:65`, `app/AndroidManifest.xml:7`. AGP 4.2 notes and the JniLibsPackaging reference (via search) | ✔ code. Device behaviour of the bare-name alternative UNVERIFIED |
| 6 | `GGML_OPENMP=ON` on NDK r29 adds `NEEDED libomp.so` | EXP-B `llvm-readelf -d`, `CMakeCache.txt` `OpenMP_omp_LIBRARY=…/libomp.so`. Relink with `libomp.a` removes it | ✔ |
| 7 | KleidiAI is fetched from GitHub at configure time; `FETCHCONTENT_SOURCE_DIR_KLEIDIAI` works offline; the gitlab.arm.com archive has the identical MD5 | `ggml-cpu/CMakeLists.txt:646-680`. EXP-A/C/D configured and built with the override. `md5sum` = `2f02ebe2…2a00` | ✔ |
| 8 | xcframework: iOS 16.4 minimum; 8 static libs merged into a dynamic framework; Metal embedded; upstream release has no simulator slice | `build-xcframework.sh:7-23,293-379`, `release.yml:1695-1697` | ✔ source-read (not executed; needs macOS) |
| 9 | Flutter 3.47.7: compileSdk 36 / minSdk 24 / targetSdk 36 / NDK 28.2.13676358; AGP 9.1.0, Gradle 9.3.1, KGP 2.4.0; `builtInKotlin=false`; SPM and native assets on by default; `plugin_ffi` deprecated | `FlutterExtension.kt:23-42`, `gradle_utils.dart:36-69`, `gradle.properties.tmpl:3-6`, `FlutterPluginUtils.kt:572-590,706-728`, `features.dart:205-240`, `create.dart:303-310`. Sherpa `app/android` matches | ✔ |
| 10 | No QNN/NNAPI/CoreML backend; Hexagon is the experimental NPU path (unsigned PD, `libcdsprpc.so`, v73–v81 skels); Vulkan needs Vulkan-Hpp and SPIRV-Headers that the NDK lacks | `ls ggml/src`, `ggml/src/CMakeLists.txt:589-605`, `ggml-hexagon/CMakeLists.txt:62-84`, `ggml-hexagon.cpp:4135-4141,7884`, `htp-drv.cpp:337`, `ggml-vulkan/CMakeLists.txt:9-14`, `ggml-vulkan-types.h:26`. NDK sysroot listing | ✔ |
