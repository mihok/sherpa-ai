# 07: Android native layer (Kotlin plugins): on-device inference, memory/perf, background, WebView, OS integration

Research date: 2026-10-18. Platform baseline: Android 16 (API 36, plus minor SDK 36.1 "BAKLAVA_1") is current. The Android 17 (API 37, `CINNAMON_BUN`) SDK is installed locally.
Sherpa baseline as of this repo: Flutter stable 3.47.7, AGP 9.1.0, Kotlin 2.4.0. `minSdk`, `targetSdk` and `ndkVersion` come from the Flutter defaults: 24, 36 and 28.2.13676358 (`app/android/app/build.gradle.kts`, `settings.gradle.kts`).

How this was verified. API levels come from `/opt/android-sdk/platforms/android-37.0/data/api-versions.xml`, read with a small parser. NDK facts come from the NDK r29 headers and sysroot. Library surfaces come from `javap` on the actual AARs pulled from `dl.google.com/android/maven2`. Versions come from Maven `group-index.xml` and POM `last-modified` headers. Product guidance comes from developer.android.com, ai.google.dev, developers.google.com, developer.chrome.com, docs.flutter.dev, raw.githubusercontent.com and the Hugging Face API.
Anything not verified this way is marked **UNVERIFIED**.

---

## 0. Key facts at a glance

| Topic | Fact | Source |
|---|---|---|
| LiteRT-LM | `com.google.ai.edge.litertlm:litertlm-android:0.18.0` (2026-10-06). AAR `minSdkVersion 24`. ABIs arm64-v8a and x86_64. `liblitertlm_jni.so` has LOAD align `0x4000`, so it is 16 KB-ready | Maven group-index, AAR manifest, `llvm-readelf -lW` |
| LiteRT-LM API | `Engine` → `Conversation` (high level, tools, thinking, `ResponseFormat` constrained decoding) / `Session` (raw prefill/decode) | `javap` of 0.18.0 |
| MediaPipe LLM Inference | "**maintenance-only mode** … migrate to LiteRT-LM". Last version `tasks-genai:0.10.35` (2026-04-27) | ai.google.dev, Maven |
| LiteRT (classic models + NPU) | `com.google.ai.edge.litert:litert:2.3.0`. NPU runtimes ship as Maven artifacts from 2.3.0: `litert-npu-runtime-{qualcomm,mediatek,google-tensor,intel-openvino}:2.3.0`. NPU needs `minSdk 31`, arm64 only | Maven, ai.google.dev/edge/litert/next/npu |
| Play for On-device AI | Beta. **≤1.5 GB per AI pack** (compressed) and ≤4 GB total per app version. Packs hold models only, no code. `com.google.android.play:ai-delivery:0.2.0-beta01` (docs still show 0.1.1-alpha01) | developer.android.com/google/play/on-device-ai, Maven |
| Gemini Nano | `com.google.mlkit:genai-prompt:1.0.0-beta4` (2026-07-21). Beta, no SLA. `minSdk 26`. Input <4000 tokens, output ≤4096. **Foreground-only: `BACKGROUND_USE_BLOCKED` even from a foreground service (FGS)**. No tool-calling API | ML Kit docs, release notes, AAR |
| NNAPI | Deprecated in Android 15 (API 35). The NDK header uses `__NNAPI_DEPRECATED_IN(35)` with "migrate to TFlite" | NDK r29 `NeuralNetworks.h`, NDK guide |
| onTrimMemory | Only `TRIM_MEMORY_UI_HIDDEN` (20) and `TRIM_MEMORY_BACKGROUND` (40) remain. `RUNNING_*`, `MODERATE` and `COMPLETE` were deprecated in API 35 ("Apps are not notified of this level since API level 34"). `onLowMemory()` was deprecated in API 35 too | api-versions.xml, reference |
| Android 17 memory limiter | Per-app limits based on device RAM, for example "**2 GB foreground / 1 GB background on 4 GB devices**". The kill shows up as `REASON_OTHER` with a description containing `"MemoryLimiter:AnonSwap"` | behavior-changes-all (17), memory-budgets doc, blog 2026-08-19 |
| FGS | `dataSync` and `mediaProcessing` get 6 h per 24 h each, then `Service.onTimeout(int,int)` (API 35). `specialUse` needs `<property android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE">` and Play review. `shortService` runs for about 3 min | FGS docs, Play Help 13392821 |
| ADPF | Java `PerformanceHintManager` (31), `setThreads` (34), `setPreferPowerEfficiency` + `WorkDuration` (35). `SystemHealthManager.getCpuHeadroom/getGpuHeadroom` (36). `PowerManager.addThermalHeadroomListener` (36) | api-versions.xml |
| 16 KB | Play page: "Starting **February 1, 2027**, if your app updates don't support 16 KB … you won't be able to release these updates". AGP ≥8.5.1 + NDK ≥r28 align by default | developer.android.com/guide/practices/page-sizes |
| Play target API | Since 2026-08-31, new apps and updates must target API 36 | developer.android.com/google/play/requirements/target-sdk |
| Android 17 LAN | `ACCESS_LOCAL_NETWORK` (dangerous, API 37) is mandatory for `targetSdk 37` apps talking to LAN hosts (Ollama or LM Studio on a desktop) | behavior-changes-17, permission reference |

---

## 1. On-device inference runtimes

### 1.1 LiteRT-LM (recommended primary Android engine for `.litertlm` models)

**Coordinates and packaging (verified).**
```kotlin
implementation("com.google.ai.edge.litertlm:litertlm-android:0.18.0") // pin; docs suggest latest.release, avoid in prod
// JVM desktop variant: com.google.ai.edge.litertlm:litertlm-jvm:0.18.0
```
- Version history on Google Maven runs 0.8.0, 0.9.x, 0.10.x … 0.17.1, 0.18.0. The POM `last-modified` for 0.18.0 is 2026-10-06.
- POM dependencies: `com.google.code.gson:gson:2.14.0`, `org.jetbrains.kotlin:kotlin-reflect:2.4.0` (used by `@Tool` reflection) and `kotlinx-coroutines-android:1.11.0`.
- AAR contents: `classes.jar` plus `jni/{arm64-v8a,x86_64}/liblitertlm_jni.so` (arm64 is about 22 MB). There is no armeabi-v7a.
  - NEEDED libraries: `libandroid`, `libz`, `libGLESv2`, `libGLESv3`, `libEGL`, `liblog`, `libdl`, `libm`, `libc`.
  - All three LOAD segments have `Align 0x4000`, so the library is 16 KB compatible.
- `uses-sdk minSdkVersion=24`.
- Release v0.18.0 adds:
  - EmbeddingGemma 2 (multimodal embeddings, `EmbeddingEngine`)
  - the `ModelInfo` introspection API
  - dynamic KV-cache growth on NPU
  - attention-mask pruning on GPU
  
  Source: [LiteRT-LM README](https://raw.githubusercontent.com/google-ai-edge/LiteRT-LM/main/README.md).

**API surface (from `javap` of 0.18.0; package `com.google.ai.edge.litertlm`).**

- **`Engine(EngineConfig) : AutoCloseable`**
  - `initialize()`. The guide says it "can take … up to 10 seconds", so always call it off the main thread.
  - `isInitialized()`, `createConversation(ConversationConfig = default)`, `createSession(SessionConfig = default)`, `close()`.
  - Static: `Engine.setNativeMinLogSeverity(LogSeverity)`.
- **`EngineConfig`** fields:
  - `modelPath: String`
  - `backend: Backend`, `visionBackend: Backend?`, `audioBackend: Backend?`
  - `maxNumTokens: Int?`, `maxNumImages: Int?`
  - `cacheDir: String?`. Pass `context.cacheDir.path`; it speeds up the second load.
  - `activationDataType: ActivationDataType?`
- **`Backend`**:
  - `Backend.CPU(threadCount: Int? = null, …)`
  - `Backend.GPU()`
  - `Backend.NPU(nativeLibraryDir: String = …)`. On Android, pass `context.applicationInfo.nativeLibraryDir`.
- **GPU manifest requirement** (from the Android guide). Put this inside `<application>`:
  ```xml
  <uses-native-library android:name="libvndksupport.so" android:required="false"/>
  <uses-native-library android:name="libOpenCL.so" android:required="false"/>
  ```
  Which GPU API (OpenCL or GLES) is used on devices without vendor OpenCL, such as Mali or PowerVR Pixels, is **UNVERIFIED**. The JNI library links GLES/EGL, which suggests a fallback.
- **`Conversation : AutoCloseable`**:
  - `sendMessage(String | Contents | Message, extraContext: Map<String,Any>?, RepetitionPenaltyConfig?, NoRepeatNgramConfig?, SuppressTokensConfig?, maxOutputTokens: Int?, ThinkingConfig?, ResponseFormat?) : Message`
  - `sendMessageAsync(…, MessageCallback)` (callback with `onMessage`, `onDone`, `onError`)
  - `sendMessageAsync(…) : Flow<Message>`
  - `cancelProcess()`, `getTokenCount()`, `getBenchmarkInfo()` (init time, TTFT, prefill/decode token counts and tok/s), `isAlive()`, `close()`
- **`ConversationConfig`** fields:
  - `systemInstruction: Contents?`
  - `initialMessages: List<Message>` (rehydrates history, which matters for the Dart-owned transcript)
  - `tools: List<ToolProvider>`, `automaticToolCalling: Boolean`
  - `samplerConfig: SamplerConfig(topK, topP, temperature, seed)`
  - `channels: List<Channel(name,start,end)>`, `extraContext`
  - `loraConfig: LoraConfig(loraPath, audioLoraPath)`
  - `prefillPrefaceOnInit`, `maxOutputToken`
  - `thinkingConfig: ThinkingConfig(enableThinking, thinkingTokenBudget)` (-1 = unlimited, 0 = off)
  - `enableResponseFormat: Boolean`, `enableSpeculativeDecoding: Boolean?`, `chatTemplate: String?`
- **`Session`** (low level):
  - `runPrefill(List<InputData>)`, `runDecode(): String`
  - `generateContent(List<InputData>)`, `generateContentStream(List<InputData>, ResponseCallback)`
  - `cancelProcess()`
  - Config: `SessionConfig(samplerConfig, loraConfig, enableSpeculativeDecoding)`.
- **`Message(role, contents, toolCalls: List<ToolCall(name, arguments: Map)>, channels: Map<String,String>)`**.
  - Factories: `Message.user/model/tool(...)`.
  - Content types: `Content.Text`, `ImageBytes`, `ImageFile`, `AudioBytes`, `AudioFile`, `ToolResponse(name, response)`.
  - Reasoning text arrives in `message.channels["thought"]`.
- **Tools**, two ways:
  1. `class X : ToolSet { @Tool(description=…) fun f(@ToolParam(description=…) p: String, …) }`. This uses Kotlin reflection to build an OpenAPI schema. Parameter types: String, Int, Boolean, Float, Double, or List of these.
  2. `OpenApiTool { getToolDescriptionJsonString(); execute(paramsJsonString) }`.

  Register with `tools = listOf(tool(x))`. With `automaticToolCalling = false`, the model's calls appear in `message.toolCalls`. Reply with `Message.tool(Contents.of(Content.ToolResponse(name, json)))`.
- **Constrained decoding**: `ResponseFormat.json(schemaJsonString)`, `ResponseFormat.json(Map)` and `ResponseFormat.regex(pattern)`. Pass it per call; the config flag is `enableResponseFormat`. The overview says tool use has "constrained decoding for improved accuracy".
- **MTP / speculative decoding**: `@OptIn(ExperimentalApi::class) ExperimentalFlags.enableSpeculativeDecoding = true`. It is "universally recommended for all tasks on GPU backends" for Gemma 4 MTP drafters.
- **Introspection**: `ModelInfo.from(path)` gives:
  - `maxContextTokens()`, `isDynamicContext()`, `inputModalities()`
  - `supportedBackends(Modality)`, `npuBrand(Modality)` (`QUALCOMM | GOOGLE_TENSOR | MEDIATEK | INTEL | SAMSUNG`), `socName(Modality)`, `minRuntimeVersion()`

  `LlmCapability` adds `supportsFunctionCalling()`, `supportsThinking()`, `hasSpeculativeDecodingSupport()` and `defaultSamplerParams()`.
- **Errors**: `LiteRtLmJniException` (native) and `IllegalStateException` (lifecycle).

Source: [LiteRT-LM Android guide](https://ai.google.dev/edge/litert-lm/android).

**`.litertlm` format.** It is "a single unified container that packages your TFLite models, tokenizer files, external weights, and associated model metadata".
- Section types: `LlmMetadata` (proto), `SP_Tokenizer` or HF `tokenizer.json`, and `TFLiteModel` with `model_type` = `prefill_decode | prefill | decode | embedder`, plus optional `backend_constraint` (`cpu/gpu/npu`) and `prefer_activation_type`.
- System metadata gets an auto-generated `uuid` and `creation_timestamp`, "used by the runtime … to manage compiled cache invalidation".
- Tooling: `pip install litert-lm-builder`. Commands: `litert-lm-builder toml|unpack` and `litert-lm-peek`.
- Source: [LiteRT-LM File Builder](https://ai.google.dev/edge/litert-lm/file_builder).
- Sherpa should treat `.litertlm` as an opaque file and use `ModelInfo.from()` to decide the backend and context budget before calling `Engine.initialize()`.

**NPU with LiteRT-LM.**
- NPU models are **SoC-specific files**, for example `gemma-4-E2B-it_qualcomm_sm8750.litertlm`, `…_Google_Tensor_G5.litertlm` and `…_Google_Tensor_G6.litertlm`.
- The guide's NPU tables list:
  - Gemma3-1B for Qualcomm SM8750, SM8650 and SM8550
  - Gemma3-1B for MediaTek MT6989 and MT6991
  - Gemma4-E2B for Tensor G6, plus Gemma3-1B for Tensor G5 and G6

  The guide warns that "new support for NPUs is being added regularly". Select the file by `ro.soc.model` (Kotlin: `Build.SOC_MODEL`, API 31).
- Source: [Run LLMs using LiteRT-LM (NPU)](https://ai.google.dev/edge/litert/next/litert_lm_npu).
- The vendor dispatch libraries must sit in `nativeLibraryDir` (see §1.3 for packaging).

**Models (Hugging Face `litert-community`; checked via the HF API on 2026-10-18).**

| Repo | Gating / license | Notable files (size) |
|---|---|---|
| `litert-community/gemma-4-E2B-it-litert-lm` | not gated, apache-2.0 | `gemma-4-E2B-it.litertlm` 2.59 GB; `-gpu.litertlm` 2.01 GB; NPU: `_qualcomm_sm8750` 3.02 GB, `_Google_Tensor_G5` 3.11 GB, `_G6` 3.31 GB |
| `litert-community/gemma-4-E4B-it-litert-lm` | not gated, apache-2.0 | `gemma-4-E4B-it.litertlm`, `-gpu.litertlm` |
| `litert-community/Qwen3-0.6B` | not gated, apache-2.0 | `Qwen3-0.6B.litertlm`, `…mediatek.mt6993.litertlm` |
| `litert-community/Gemma3-1B-IT` | **gated=auto, Gemma license** (needs an HF token) | `…q4_ekv4096.litertlm` plus legacy `.task` |
| `google/gemma-3n-E2B-it-litert-lm` | **gated=manual** | `gemma-3n-E2B-it-int4.litertlm` |

Other repos: Qwen2.5-1.5B and 0.5B, Qwen3-1.7B, 4B and 8B, Qwen3.5-0.8B, 2B and 4B, Phi-4-mini, DeepSeek-R1-Distill-Qwen-1.5B, SmolLM2/3, LFM2.5-1.2B, Ministral-3-3B, FunctionGemma, EmbeddingGemma 2, whisper-tiny and moonshine-tiny.

Official benchmark ([LiteRT-LM overview](https://ai.google.dev/edge/litert-lm/overview)), Gemma4-E2B on an S26 Ultra:

| Backend | Prefill | Decode | TTFT | Peak CPU memory |
|---|---|---|---|---|
| CPU | 557 tok/s | 47 tok/s | 1.8 s | 1733 MB |
| GPU | 3808 tok/s | 52 tok/s | 0.3 s | **676 MB** |

The Gemma 4 model card notes that on supported devices Gemma 4 is also "available through Android AI Core as Gemini Nano".

**Flutter story.** Google's "Flutter" path for LiteRT-LM is community-maintained. `flutter_gemma` (final 1.11.4) has moved to **`flutter_edge_ai` 2.4.0** (2026-10-16, needs Flutter ≥3.44). Sherpa should still own a thin Kotlin plugin (§9) for lifecycle, FGS, memory and thermal control.

### 1.2 MediaPipe LLM Inference API: do not adopt
"⚠️ The MediaPipe LLM Inference API is in maintenance-only mode. We recommend migrating your Android projects to LiteRT-LM Android (Kotlin) API."
- The docs still show `tasks-genai:0.10.27`; the latest on Maven is `0.10.35` (2026-04-27). It uses `.task` bundles.
- `com.google.ai.edge.localagents:localagents-fc:0.1.0` (function calling on MediaPipe) is superseded by the LiteRT-LM tools API.
- Source: [MediaPipe LLM Inference for Android](https://ai.google.dev/edge/mediapipe/solutions/genai/llm_inference/android).

### 1.3 LiteRT `CompiledModel` + NPU (embedders, ASR, classifiers, and the LLM NPU runtime libraries)

**Maven (2026-10-06):**
```kotlin
implementation("com.google.ai.edge.litert:litert:2.3.0")      // depends on litert-api:2.3.0; minSdk 24
implementation("com.google.ai.edge.litert:litert-gpu:2.3.0")
```
NPU runtimes are separate Maven AARs from 2.3.0 on ("litert_npu_runtime_libraries.zip is only available for releases before 2.3.0"):
- `litert-npu-runtime-qualcomm:2.3.0`. It contains only `libLiteRtDispatch_Qualcomm.so` and `libLiteRtCompilerPlugin_Qualcomm.so`, and its manifest declares `<uses-native-library android:name="libcdsprpc.so" android:required="false"/>`.
  - The QAIRT/QNN HTP libraries (`libQnnHtp.so`, `libQnnHtpV79Skel.so`, …) are fetched separately with `fetch_qualcomm_library.sh`.
  - They are packaged as **Play Feature Delivery modules per Hexagon arch**: `qualcomm_runtime_v69/v73/v75/v79/v81`.
- `litert-npu-runtime-mediatek`, `-google-tensor` and `-intel-openvino`, all at 2.3.0.

**Build constraints:**
- "API level 31+ is required for NPU support" (`minSdk = 31`).
- "NPU only supports arm64-v8a".
- `packaging { jniLibs { useLegacyPackaging = true } }` is "needed for Qualcomm NPU runtime libraries".
- A device-targeting config is required.

**Vendors:**

| Vendor | AOT compilation | On-device (JIT) compilation |
|---|---|---|
| Google Tensor | yes | not yet |
| Qualcomm AI Engine Direct | yes | yes |
| MediaTek NeuroPilot | yes | yes |
| Intel OpenVINO | yes | yes |
| Samsung Exynos AI LiteCore | yes | yes |

AOT is recommended for large models. The JIT cache (`Environment::OptionTag::CompilerCacheDir`) is invalidated when the plugin version, build fingerprint, model or options change. The doc's example: ResNet-152 init took 7465 ms when compiling and 198 ms from cache.

**Kotlin API (javap 2.3.0, `com.google.ai.edge.litert`):**
- `CompiledModel.create(context.assets, "model.tflite", CompiledModel.Options(Accelerator.NPU, Accelerator.GPU))`. This gives an automatic fallback chain.
- Buffers and execution: `createInputBuffers()`, `createOutputBuffers()`, `run(in, out)`, `TensorBuffer.writeFloat/readFloat`.
- Environment and deployment: `Environment.create(BuiltinNpuAcceleratorProvider(context))`, `NpuCompatibilityChecker.{Qualcomm,Mediatek,GoogleTensor,Samsung}.isDeviceSupported()`, `ModelProvider.staticModel(...)`, `deployment.AiPackModelProvider(context, pack, path){…}`, `ModelSelector(...).selectModel(env)`.
- Zero-copy input is possible via `TensorBuffer::CreateFromAhwb` (C++).

Source: [NPU acceleration with LiteRT](https://ai.google.dev/edge/litert/next/npu).

### 1.4 Play for On-device AI (PODAI) and AI packs (beta)
- **Gradle.** Each pack module uses:
  ```kotlin
  plugins { id("com.android.ai-pack") }
  aiPack {
      packName = "x"
      dynamicDelivery { deliveryType = "install-time" | "fast-follow" | "on-demand" }
  }
  ```
  The app module adds `android { assetPacks += ":x" }`. Requires **AGP ≥ 8.8**.
- **Device targeting** requires AGP ≥ 8.10 and `android.experimental.enableDeviceTargetingConfigApi=true`.
  - The XML is `<config:device-targeting-config>` → `<config:device-group name>` → `<config:device-selector>`.
  - Selector properties: `device_ram min_bytes/max_bytes`, `system-on-chip manufacturer="QTI" model="SM8750"`, `included_device_ids`/`excluded_device_ids` (`build_brand`, `build_device`, ≤10000), and `required_system_features`/`forbidden_system_features` (≤100).
  - A group has at most 5 selectors. The first matching group wins; "other" is the implicit default.
- **Runtime library**: `com.google.android.play:ai-delivery` (docs 0.1.1-alpha01; Maven latest **0.2.0-beta01**). `AiPackManager` provides:
  - `getPackLocation(name)?.assetsPath()`, `getPackLocations()`
  - `getPackStates(list)`, `fetch(list)`
  - `registerListener(AiPackStateUpdateListener)` with statuses `PENDING`, `DOWNLOADING`, `WAITING_FOR_WIFI` and `REQUIRES_USER_CONFIRMATION`
  - `showConfirmationDialog()`. Downloads over 200 MB on mobile data need user consent; sideloaded apps get `REQUIRES_USER_CONFIRMATION`.
  
  Never cache pack paths across launches.
- **Limits**: "Individual AI packs can be up to 1.5GB, based on their compressed download sizes. The maximum cumulative app size … 4GB." "AI packs only contain models. Java/Kotlin and native libraries are not allowed." "Models … should only be used by your apps."
- **Sherpa implication.** A Gemma 4 E2B `.litertlm` is 2.0–3.3 GB, so it **does not fit a single AI pack**. Splitting a pack into chunks and re-concatenating doubles transient storage and is untested (**UNVERIFIED** whether LiteRT-LM can open split files; the API takes a single `modelPath`).
  - PODAI suits small models: FunctionGemma (289 MB), EmbeddingGemma 2 (165–485 MB), Qwen3-0.6B (about 0.6 GB), Gemma3-1B q4 (about 0.66 GB).
  - Big LLMs need a self-hosted or HF download via a UIDT job (§4.4).
- Source: [Play for On-device AI](https://developer.android.com/google/play/on-device-ai).

### 1.5 Gemini Nano via ML Kit GenAI Prompt API (AICore)

```kotlin
implementation("com.google.mlkit:genai-prompt:1.0.0-beta4")      // 2026-07-21; beta, "not subject to any SLA or deprecation policy"
// Structured output (typed): KSP + com.google.mlkit:genai-schema:1.0.0-alpha1 / genai-schema-compiler:1.0.0-alpha1
```

**AAR manifest.**
- `minSdkVersion 26`, `targetSdkVersion 35`.
- `<uses-permission android:name="com.google.android.apps.aicore.service.BIND_SERVICE"/>`.
- `<queries><package android:name="com.google.android.aicore"/></queries>`.

**API (javap of `GenerativeModel`; Kotlin suspend functions; Java callers use `GenerativeModelFutures.from(...)`).**
- Client: `Generation.getClient()` or `getClient(GenerationConfig)`. `GenerationConfig` carries a `workerExecutor` and a `ModelConfig`; `ModelConfig.builder()` sets `ModelReleaseStage.STABLE|PREVIEW` and `ModelPreference.FAST|FULL`.
- Availability:
  - `checkStatus(): Int` returns `FeatureStatus.UNAVAILABLE | DOWNLOADABLE | DOWNLOADING | AVAILABLE`.
  - `download(): Flow<DownloadStatus>` emits `DownloadStarted`, `DownloadProgress(totalBytesDownloaded)`, `DownloadCompleted` and `DownloadFailed(e)`.
  - `warmup()`.
- Model limits: `getBaseModelName()` (for example nano-v2, v3 or v4), `getTokenLimit()`, `countTokens(request)`.
- Generation:
  - `generateContent(String | GenerateContentRequest)`
  - `generateContentStream(...) : Flow<GenerateContentResponse>` (`chunk.candidates[0].text`)
  - `generateContent(GenerateTypedContentRequest<T>)` for structured output
- Feature probes: `isStructuredOutputFeatureAvailable()`, `isSystemPromptAvailable()`, `isThinkingModeAvailable()`, `isCachingFeatureAvailable()`.
- Context caching: `getCaches()` (`create/get/list/delete CachedContext`), `clearImplicitCaches()`. Cleanup: `close()`.
- `GenerateContentRequest.Builder` fields: `temperature`, `seed`, `topK`, `candidateCount`, `maxOutputTokens`, `systemInstruction: SystemInstruction`, `promptPrefix`, `cachedContextName`, `enableThinking`.
- **Image input**: `generateContentRequest(ImagePart(bitmap), TextPart(prompt)) { … }`. Multi-image support arrived in the 2026-07-14 release (which also added structured output, system instructions, thinking mode and a 4K output limit).
- **No tool/function-calling API exists** in the ML Kit Prompt API (no tool classes in the AAR). Sherpa must implement tool use with prompt plus structured output (JSON schema) on top of it.

**Hard constraints** (from the [ML Kit GenAI overview](https://developers.google.com/ml-kit/genai) and [Prompt API get-started](https://developers.google.com/ml-kit/genai/prompt/android/get-started)):
- "Input must be under 4000 tokens". Avoid outputs above 4K tokens.
- "AICore enforces an inference quota per app". The errors are `ErrorCode.BUSY` (back off exponentially) and `PER_APP_BATTERY_USE_QUOTA_EXCEEDED` (daily-type quota).
- "**GenAI API inference is permitted only when the app is the top foreground application. Using the API when the app is not in the foreground, including using a foreground service, will result in an `ErrorCode.BACKGROUND_USE_BLOCKED` response.**"
- "Not supported on devices with an unlocked bootloader" (`606-FEATURE_NOT_FOUND`). Freshly set-up devices may need minutes to hours for AICore to fetch its config. Errors include `601-BINDING_FAILURE`.

**Devices** (Prompt API, current page):

| Model | Devices |
|---|---|
| nano-v2 | Honor Magic V5/7/7 Pro, iQOO 13, Razr 60 Ultra, OnePlus 13/13s, Find N5, POCO F7 Ultra/F8/X7/X8 Pro, realme GT 7 Pro, Galaxy Z Fold7/TriFold, vivo X200 FE/T4 Ultra, Xiaomi 14T Pro/15/15T/15 Ultra/17/17 Ultra/Pad Mini |
| nano-v3 | Pixel 9 and 10 families, Galaxy S26/S26+/S26 Ultra, OnePlus 15/15R, Find X8/X9, vivo X200/X300, Xperia 1 VIII, … |
| nano-v4 | Pixel 11 family, Galaxy Z Flip8/Fold8/Fold8 Ultra |

Note that the Galaxy S25 has the feature-specific APIs but is not on the Prompt API list.

The legacy experimental SDK `com.google.ai.edge.aicore:aicore:0.0.1-exp02` should not be used.

### 1.6 NNAPI: deprecated, do not use
- "NNAPI is deprecated … available on all Android devices running Android 8.1 (API level 27) or higher, but was deprecated in Android 15."
- The NDK r29 `NeuralNetworks.h` marks APIs `__NNAPI_DEPRECATED_IN(35)` with the message "NN API is deprecated. Users should migrate to TFlite."
- Use LiteRT GPU/NPU (CompiledModel) instead.
- Source: [NNAPI guide](https://developer.android.com/ndk/guides/neuralnetworks).

### 1.7 llama.cpp (GGUF) on Android GPUs: realities
- **CPU is the dependable path.** Use `-DGGML_CPU_KLEIDIAI=ON` (arm64-v8a only), `-DGGML_NATIVE=OFF`, `-DGGML_OPENMP=OFF`, `-DGGML_LLAMAFILE=OFF`, `-DLLAMA_OPENSSL=OFF` and `-DANDROID_PLATFORM=android-28`.
  - KleidiAI dispatches dotprod, i8mm, SVE and SME/SME2 kernels at runtime.
  - The `examples/llama.android` binding "supports hardware acceleration up to SME2" and enables KleidiAI automatically.
  - Sources: [llama.cpp build.md](https://raw.githubusercontent.com/ggml-org/llama.cpp/master/docs/build.md), [android.md](https://raw.githubusercontent.com/ggml-org/llama.cpp/master/docs/android.md).
- **OpenCL backend (Qualcomm Adreno only, in practice).**
  - Verified on Adreno 750, 810, 830, 840, X1-85 and X2-90. "A6x GPUs in phones are likely not supported due to the outdated driver and compiler."
  - Quant types: Q1_0, Q4_0, Q4_1, Q5_0, Q5_1, Q8_0, Q4_K, Q5_K, Q6_K, MXFP4 and IQ4_NL.
  - Kernel cache is controlled by `GGML_OPENCL_KERNEL_CACHE_DIR`. Point it at `context.cacheDir`.
  - The build links against a Khronos ICD-loader stub; at runtime it needs the **vendor** `libOpenCL.so` (`/vendor/lib64`).
  - Apps targeting API 31+ can load non-NDK vendor libraries only if declared with `<uses-native-library android:name="libOpenCL.so" android:required="false"/>`. Without the declaration, "Non-NDK native shared libraries … aren't accessible by default". With `required="true"`, Play blocks install on devices lacking the library.
  - Sources: [OPENCL.md](https://raw.githubusercontent.com/ggml-org/llama.cpp/master/docs/backend/OPENCL.md), [`<uses-native-library>`](https://developer.android.com/guide/topics/manifest/uses-native-library-element).
  - Bundling the ICD loader `libOpenCL.so` inside the APK under the same name is fragile, because it would shadow or fail to find vendor ICDs. **UNVERIFIED**; prefer `dlopen("libOpenCL.so")` behind a capability check.
- **Vulkan backend.** Field reports say it is frequently *slower than CPU* on Adreno and Mali, with driver-specific breakage:
  - #20603 (Mar 2026, Adreno 740): a regression to 6–10 tok/s, slower than CPU, plus gibberish with Qwen3.5.
  - Discussion #9464: about 15× slower than CPU on Mali, and Adreno failing to load.
  - #7351: much higher RAM use on an S24+, causing swapping.
  
  These come from GitHub search snippets; github.com could not be fetched, so details are **UNVERIFIED**. Recommendation: ship Vulkan disabled by default and gate it on an on-device micro-benchmark.
- **Hexagon backend** (`GGML_HEXAGON=ON`, Hexagon SDK 6.6, `libggml-htp-v73/75/79/81.so` over FastRPC `cdsp`) exists. Whether it runs inside an unprivileged Play app (unsigned PD, `libcdsprpc.so` access) is **UNVERIFIED**. Source: [snapdragon README](https://raw.githubusercontent.com/ggml-org/llama.cpp/master/docs/backend/snapdragon/README.md).
- Pixel 10/11 (Tensor G5/G6) GPUs are not Adreno (believed to be PowerVR on G5; **UNVERIFIED**), so the llama.cpp OpenCL backend does not apply. Use LiteRT-LM GPU or NPU or Gemini Nano there.

---

## 2. Memory: signals, limits, kill forensics

### 2.1 `ComponentCallbacks2.onTrimMemory(level)` (verified in api-versions.xml)

| Constant | Value | Status |
|---|---|---|
| `TRIM_MEMORY_UI_HIDDEN` | 20 | **live** |
| `TRIM_MEMORY_BACKGROUND` | 40 | **live** |
| `TRIM_MEMORY_RUNNING_MODERATE` / `RUNNING_LOW` / `RUNNING_CRITICAL` | 5 / 10 / 15 | deprecated API 35 ("not notified … since API level 34") |
| `TRIM_MEMORY_MODERATE` / `TRIM_MEMORY_COMPLETE` | 60 / 80 | deprecated API 35 (same) |
| `ComponentCallbacks.onLowMemory()` | n/a | deprecated API 35 |

Practical consequences:
- **On API 34+ there is no in-foreground "running low" signal.** Do not wait for `RUNNING_CRITICAL` to unload a model.
- Use `UI_HIDDEN` to drop UI caches. For a running inference job, keep the model only if an FGS keeps the process perceptible.
- Use `BACKGROUND` to release KV cache and close `Engine`/`Conversation`, or the llama.cpp context, when not actively generating.
- Compare with `>=` and do not test exact values. `ActivityManager.getMyMemoryState(RunningAppProcessInfo).lastTrimLevel` (API 16) gives the current level.

Source: [ComponentCallbacks2](https://developer.android.com/reference/android/content/ComponentCallbacks2).

### 2.2 Device and process memory APIs
- **`ActivityManager.MemoryInfo`** via `getMemoryInfo(mi)`:
  - `availMem` (1) and `threshold` (1; "the threshold of availMem at which we consider memory to be low and start killing background services")
  - `lowMemory` (1), `totalMem` (16; kernel-visible RAM)
  - **`advertisedMem` (34)**: the retail RAM figure, which may exceed `totalMem` because of TEE carve-outs. Use it for marketing-tier bucketing such as "8 GB device".
  - **`freeMem` (37)**: raw free RAM, excluding reclaimable memory.
  - Admission control for a model: `projectedPeak = weights_resident + kv_cache + runtime_overhead` must be below `min(availMem - threshold, memoryLimiterCeiling)`. **UNVERIFIED** heuristic; tune empirically.
- **`getMemoryClass()` (5) and `getLargeMemoryClass()` (11)** are **Dalvik/ART heap** limits in MB. `android:largeHeap="true"` affects only "a large Dalvik heap" (manifest doc). It does **not** raise native (malloc/mmap) limits used by llama.cpp or LiteRT, so leave it off; it only hides Java leaks.
- **`isLowRamDevice()` (19)**: "generally means something with 1GB or less". Treat as "no local LLM".
- **`Debug.getNativeHeapAllocatedSize()` (1)**: "allocated memory in the native heap", meaning malloc arenas. It excludes file-backed `mmap` weights and GPU/DMA-BUF buffers, so it under-reports inference memory (**UNVERIFIED** nuance; follows from Linux semantics).
  - For real accounting read `/proc/self/status` (`VmRSS`, `RssAnon`, `RssFile`, `VmSwap`) or `/proc/self/smaps_rollup`.
  - `getProcessMemoryInfo()` is "significantly limited" in sample rate since Q.
- **`ProfilingManager`** (35): `requestProfiling(PROFILING_TYPE_HEAP_PROFILE | JAVA_HEAP_DUMP | …)`. Triggers came in 36. API 37 adds `TRIGGER_TYPE_OOM` and `TRIGGER_TYPE_ANOMALY`; the latter fires on memory-limiter hits.

### 2.3 Android 17 per-app memory limiter (new and important for local LLMs)
- "Android 17 introduces app memory limits based on the device's total RAM." It is rolling out "starting with Pixel" and to "an increasing number of manufacturers … from 4GB to 16GB+ devices" ([blog 2026-08-19](https://android-developers.googleblog.com/2026/08/app-broader-memory-limits.html)).
- Example ceilings: "2 GB in the foreground and 1 GB in the background on 4 GB devices" ([app memory budgets](https://developer.android.com/topic/performance/memory/app-memory-budgets)).
- The metric is **anonymous RSS + swap**. When the limit is hit, the app is first forced into zRAM (jank), then "terminated".
- Detection:
  - `ApplicationExitInfo.getReason() == REASON_OTHER` and `getDescription()` contains `"MemoryLimiter:AnonSwap"`.
  - `TRIGGER_TYPE_ANOMALY` heap dumps.
  - adb: `am memory-limiter status`, `am memory-limiter ignore <uid>|none|all`, `am memory-limiter manual <pid> <MB>|max|none`.
  - Source: [Android 17 behavior changes (all apps)](https://developer.android.com/about/versions/17/behavior-changes-all).
- Implications for Sherpa:
  - **CPU-backend LLMs whose weights end up in anonymous memory are the risk.** For example, LiteRT-LM CPU peaks at 1.7 GB for Gemma4-E2B, and llama.cpp with `--no-mmap` or repacked or KleidiAI-converted weights also lands in anonymous memory.
  - Prefer **file-backed `mmap`** weights, which are clean pages and evictable, and GPU backends. The GPU peak CPU memory is 676 MB for E2B.
  - Whether DMA-BUF/GPU allocations count toward the limiter is **UNVERIFIED**. The budgets doc says GPU-backed bitmaps and DMA-BUF "are accounted outside your app's heap and memory budget", but it is talking about budgets, not the limiter.
- **`<memory-budget android:maxMb android:state="perceptible|background"/>`** comes with Android 17 QPR2 (API 37.2). It is a voluntary cap that triggers targeted reclaim, not a kill. **Do not declare a budget below the LLM working set**: that just thrashes swap. At most, declare a `background` budget for the UI process.

### 2.4 Detecting low-memory-killer (LMK) kills post hoc
- `ActivityManager.getHistoricalProcessExitReasons(packageName, pid=0, maxNum)` (30) returns `List<ApplicationExitInfo>`.
- Check `REASON_LOW_MEMORY` (30) only if `ActivityManager.isLowMemoryKillReportSupported()` (30). Otherwise an LMK kill looks like `REASON_SIGNALED` + `getStatus()==SIGKILL`.
- Also useful: `getPss()`, `getRss()`, `getImportance()`, `getTimestamp()`, `getDescription()`, `REASON_FREEZER` (33), and `getAnrInfo()` (37).
- **`ActivityManager.setProcessStateSummary(byte[])`** (30) is read back via `ApplicationExitInfo.getProcessStateSummary()`.
  - "Maximum length is 128 bytes". No PII. Calls may be throttled.
  - Recommended encoding: `{v, modelIdHash, backend, ctxTokens, phase(load|prefill|decode|idle), fgState}`. Write it at each phase change. On next launch, downgrade the model, context or backend automatically when the last exit was an LMK or MemoryLimiter kill during inference.

### 2.5 Process topology (recommendation, partially **UNVERIFIED**)
Consider hosting inference in a separate process (`<service android:process=":llm">`). Memory-limiter and LMK actions then hit the `:llm` process rather than the Flutter UI process. The limiter commands take a pid, which suggests per-process limits; **UNVERIFIED**.

Costs:
- Stream tokens over Binder (AIDL `oneway` callbacks) or a `SharedMemory` ring buffer.
- Engine state is lost on a kill; rebuild via `initialMessages`.

---

## 3. Performance: ADPF, thermal, cores

### 3.1 Java ADPF (verified API levels)
- `context.getSystemService(PerformanceHintManager::class.java)` (31) → `createHintSession(int[] tids, long initialTargetWorkDurationNanos)` (31). It returns `null` "if hint session is not supported on this device or the tid doesn't belong to the application". `getPreferredUpdateRateNanos()` (31).
- `Session` methods:
  - `updateTargetWorkDuration(long)` (31), `reportActualWorkDuration(long)` (31)
  - `reportActualWorkDuration(WorkDuration)` (35; CPU/GPU/total/start timestamps)
  - `setThreads(int[])` (34), `setPreferPowerEfficiency(boolean)` (35), `close()`
- **`SystemHealthManager`** (36): `getCpuHeadroom(CpuHeadroomParams?)` and `getGpuHeadroom(GpuHeadroomParams?)` return a value in [0,100] or `NaN`.
  - Each call does "at least one synchronous binder transaction … >1ms", so call off critical threads.
  - Throws `UnsupportedOperationException` if unsupported. Related: `getCpuHeadroomMinIntervalMillis()`, `getCpuHeadroomCalculationWindowRange()`.
  - Params: `CPU_HEADROOM_CALCULATION_TYPE_MIN|AVERAGE`.
- Applying ADPF to LLM decode is an **UNVERIFIED** pattern, so benchmark it:
  1. Create one session with the decode worker TIDs (`Process.myTid()` from each worker).
  2. Set target = per-token budget, for example `1e9 / targetTokPerSec`.
  3. Report each token's wall time.
  4. Use `setPreferPowerEfficiency(true)` during background or agent runs and `false` for interactive streaming.

### 3.2 NDK ADPF / thermal / headroom
- **`android/performance_hint.h`** in NDK r29:
  - `APerformanceHint_getManager/createSession/updateTargetWorkDuration/reportActualWorkDuration/closeSession` (33)
  - `setThreads` (34)
  - `setPreferPowerEfficiency`, `reportActualWorkDuration2`, `AWorkDuration_*` (35)
- The NDK reference also lists `APerformanceHint_createSessionUsingConfig`, `ASessionCreationConfig_*`, `APerformanceHint_notifyWorkloadIncrease/Spike/Reset`, `isFeatureSupported` and `borrowSessionFromJava`.
  - These are absent from the r29 sysroot, which stops at API 35. Their API level (36) is **UNVERIFIED** locally.
  - NDK **r30** is the current LTS.
  - Source: [NDK APerformanceHint](https://developer.android.com/ndk/reference/group/a-performance-hint).
- **`android/thermal.h`**:
  - `AThermal_acquireManager`, `getCurrentThermalStatus`, `register/unregisterThermalStatusListener` (30)
  - `AThermal_getThermalHeadroom(mgr, forecastSeconds)` (31), `getThermalHeadroomThresholds` (35)
  - `AThermal_register/unregisterThermalHeadroomListener` (36)
- **System health** (NDK ref): `ASystemHealth_getCpuHeadroom/getGpuHeadroom`, `ACpuHeadroomParams_*`, `AGpuHeadroomParams_*`, all API 36.

### 3.3 Thermal (Java)
- `PowerManager.getCurrentThermalStatus()` (29) returns `THERMAL_STATUS_NONE|LIGHT|MODERATE|SEVERE|CRITICAL|EMERGENCY|SHUTDOWN`. Listen with `addThermalStatusListener(executor, l)` (29).
- `getThermalHeadroom(forecastSeconds 0..60)` (30). A value of 1.0 means `SEVERE` throttling. There is "no benefit to calling this function more frequently than about once per second"; calling faster returns `NaN`. Forecasting starts after a few samples.
- `getThermalHeadroomThresholds()` (35). `addThermalHeadroomListener(executor, OnThermalHeadroomChangedListener)` (36), with callback `onThermalHeadroomChanged(float headroom, float forecastHeadroom, int forecastSeconds, Map<Integer,Float> thresholds)`.
- Suggested policy (**UNVERIFIED** thresholds):

  | Condition | Action |
  |---|---|
  | headroom(10 s) ≥ 0.85 or status ≥ `MODERATE` | Reduce threads, throttle decode with sleeps, disable MTP |
  | status ≥ `SEVERE` | Pause the agent loop, prefer Nano or cloud, or switch to a smaller model |

### 3.4 Finding big cores and affinity
- Sysfs is readable by apps. AOSP sepolicy has `r_dir_file(domain, sysfs_devices_system_cpu)` (`private/domain.te`) and `genfscon sysfs /devices/system/cpu u:object_r:sysfs_devices_system_cpu:s0` (`private/genfs_contexts`). Vendors can relabel subnodes (**UNVERIFIED** per device).
- Read the following:
  - `/sys/devices/system/cpu/cpuN/cpu_capacity` (if present, the scheduler capacity 0–1024)
  - otherwise `/sys/devices/system/cpu/cpuN/cpufreq/cpuinfo_max_freq`
  - `/sys/devices/system/cpu/cpufreq/policyX/related_cpus` (clusters)
  - `/sys/devices/system/cpu/possible|online`
- `sched_setaffinity(tid, sizeof(cpu_set_t), &set)` from the NDK (bionic) works on your own threads. Android guidance says "generally best to avoid manually setting CPU affinities". Pinning disables the scheduler's load and thermal placement ([AGI thread scheduling](https://developer.android.com/agi/sys-trace/threads-scheduling)).
- Sherpa recommendation: don't pin. Set the llama.cpp `n_threads` to the count of prime + big cores (exclude the lowest-capacity cluster). Re-evaluate on thermal changes.
- Background processes are confined by cpusets, often to little cores, and affinity cannot exceed the cpuset. **UNVERIFIED** (vendor `init.rc`).

---

## 4. Background execution for inference and downloads

### 4.1 FGS types (API 34+ mandatory type plus a per-type permission)
- Manifest: `android:foregroundServiceType="…"` plus `FOREGROUND_SERVICE` and the type permission. Pass the type in `startForeground(id, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_…)` (API 29 overload).
- Type constants from api-versions:
  - `DATA_SYNC` (29)
  - `SHORT_SERVICE`, `SPECIAL_USE`, `HEALTH`, `REMOTE_MESSAGING`, `SYSTEM_EXEMPTED` (34)
  - `MEDIA_PROCESSING` (35)
  - `NONE` deprecated (34)
- Fit for on-device LLM inference (Sherpa analysis):

| Type | Fit | Notes |
|---|---|---|
| `shortService` | **Best for "finish the current reply after the user leaves"** | No type permission. About 3 minutes. Can't start other FGS, not sticky. `onTimeout(int)` (34) / `onTimeout(int,int)` (35) then `stopSelf()` |
| `specialUse` | **Best honest type for long agent runs** | `FOREGROUND_SERVICE_SPECIAL_USE` (normal\|appop). Needs `<property android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE" android:value="On-device LLM inference for a user-started agent task"/>`. "These values … are reviewed when you submit your app in the Google Play Console." Play: "In limited scenarios … you may declare … TYPE_SPECIAL_USE. All foreground service types are subject to review." |
| `dataSync` | Tempting ("Local processing: Other … user-initiated work … encryption, resizing") but semantically about data transfer or processing | `FOREGROUND_SERVICE_DATA_SYNC`. **6 h / 24 h** for `targetSdk 35+`; the timer resets when the user foregrounds the app. Can't launch from `BOOT_COMPLETED` (15+). Exhausting the limit throws `ForegroundServiceStartNotAllowedException` "Time limit already exhausted" |
| `mediaProcessing` (35) | Poor: Play's use case is "Media transcoding" | Same 6 h / 24 h separate bucket. Using it for LLM inference is a policy risk |
| `microphone` | Only for voice capture while backgrounded | While-in-use permission. Can't be started from the background |

- Play Console declaration (Monitor and improve → App content). For each type, describe the functionality, the user impact if deferred or interrupted, and supply a **video link** showing the user triggering it. Sources: [Play Help 13392821](https://support.google.com/googleplay/android-developer/answer/13392821), [FGS types](https://developer.android.com/develop/background-work/services/fgs/service-types), [FGS timeouts](https://developer.android.com/develop/background-work/services/fgs/timeout).
- Testing: `adb shell am compat enable FGS_INTRODUCE_TIME_LIMITS <pkg>` and `adb shell device_config put activity_manager data_sync_fgs_timeout_duration <ms>` (use `media_processing_fgs_timeout_duration` for the other bucket).
- **Gemini Nano (ML Kit) cannot run from any FGS** (§1.5). Background agent runs must use LiteRT-LM, llama.cpp or the cloud.

### 4.2 Starting an FGS from the background
- Apps targeting 31+ get `ForegroundServiceStartNotAllowedException` unless an exemption applies:
  - transitioning from a visible activity
  - a user action on a notification, widget or bubble
  - a high-priority FCM message (check `RemoteMessage.getPriority()==PRIORITY_HIGH`)
  - an exact alarm for a user-requested action
  - battery-optimization exemption
  - `SYSTEM_ALERT_WINDOW` (on 15+, only with a visible overlay)
  - boot / `MY_PACKAGE_REPLACED` (with type restrictions)
  - Companion Device Manager permissions
- While-in-use types (camera, mic, location) can't be created from the background at all.
- Pattern: start the `specialUse`/`shortService` FGS **while the Flutter activity is still resumed**, for example as soon as an agent run begins, not on `onPause`.
- Source: [restrictions on bg start](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start).

### 4.3 Android 16 job quota change
"Jobs that are executing concurrently with a foreground service will adhere to the job runtime quota". The same holds for jobs started while the app is top that continue after it becomes invisible. "If you're leveraging jobs for user initiated data transfer, consider using user initiated data transfer jobs instead."

Diagnostics: `JobParameters.getStopReason()` (31), `STOP_REASON_TIMEOUT_ABANDONED` (36), `JobScheduler.getPendingJobReasons(jobId)` and `getPendingJobReasonsHistory(jobId)` (36), and `getPendingJobReasonStats` (37).

### 4.4 Model downloads: user-initiated data transfer (UIDT) jobs (API 34)
```xml
<uses-permission android:name="android.permission.RUN_USER_INITIATED_JOBS"/>  <!-- normal -->
<service android:name=".ModelDownloadJobService" android:permission="android.permission.BIND_JOB_SERVICE" android:exported="false"/>
```
```kotlin
val job = JobInfo.Builder(JOB_ID, ComponentName(ctx, ModelDownloadJobService::class.java))
    .setUserInitiated(true)                                   // API 34
    .setRequiredNetwork(NetworkRequest.Builder()
        .addCapability(NET_CAPABILITY_INTERNET).addCapability(NET_CAPABILITY_NOT_METERED).build())
    .setEstimatedNetworkBytes(modelBytes, 0)                  // API 28; also updateEstimatedNetworkBytes() (34)
    .build()
// In onStartJob: setNotification(params, id, notif, JobService.JOB_END_NOTIFICATION_POLICY_DETACH)  (API 34)
```
- It "must be scheduled while the application is visible to the user". It starts immediately, can run long "as system conditions allow", and several can run concurrently.
- Implement HTTP Range resume and check SHA-256 after the download.
- **WorkManager 2.12.0 has no UIDT support**. There is no `setUserInitiated` in `work-runtime-2.12.0.aar`; it has `setExpedited` and `setForeground`.
  - Use raw `JobScheduler` on API 34+.
  - Below 34, use a WorkManager `CoroutineWorker` with `setForeground(ForegroundInfo(id, notif, FOREGROUND_SERVICE_TYPE_DATA_SYNC))`. You must merge `<service android:name="androidx.work.impl.foreground.SystemForegroundService" android:foregroundServiceType="dataSync" tools:node="merge"/>`, because WorkManager's own manifest declares no type ([long-running workers](https://developer.android.com/develop/background-work/background-tasks/persistent/how-to/long-running)).
- Source: [UIDT](https://developer.android.com/develop/background-work/background-tasks/uidt).

---

## 5. 16 KB page size
- **Requirement**: "all apps targeting Android 15 (API level 35) and higher must support 16 KB memory page sizes on 64-bit devices on Google Play. **Starting February 1, 2027**, if your app updates don't support 16 KB … you won't be able to release these updates" ([page-sizes](https://developer.android.com/guide/practices/page-sizes)).
  - Earlier milestones: Nov 1, 2025, with a Play Console extension to May 31, 2026. These come from secondary sources only (forums, Qt blog) and are **UNVERIFIED**.
- **Defaults that align**:
  - "AGP version 8.5.1 or higher and NDK version r28 or higher … 16 KB compatible by default". AGP 8.5.1+ zip-aligns uncompressed `.so` at 16 KB.
  - NDK r28+ links with 16 KB max-page-size.
  - r27 and lower need `-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384`.
  - Sherpa is on AGP 9.1.0 and NDK 28.2.13676358, so it is compliant by default, provided every **prebuilt** `.so` is also aligned. LiteRT-LM 0.18.0 is verified aligned.
- **Verification commands** (build-tools ≥ 35.0.0; local `zipalign` 36.1.0 supports `-P 4|16|64`):
  ```bash
  zipalign -c -P 16 -v 4 app-release.apk                      # "Verification successful"
  $NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objdump -p lib.so | grep LOAD   # align 2**14 or more
  $NDK/.../llvm-readelf -lW lib.so | grep 'LOAD\|RELRO'       # also check (VirtAddr+MemSiz)%0x4000 for GNU_RELRO sharing a RW LOAD
  check_elf_alignment.sh app.apk                              # cs.android.com/.../system/extras/tools/check_elf_alignment.sh
  bundletool dump config --bundle=app.aab | grep alignment    # expect PAGE_ALIGNMENT_16K
  adb shell getconf PAGE_SIZE                                 # 16384 on a 16 KB device
  ```
- **Test targets**:
  - Emulator images "Google APIs Experimental 16 KB Page Size ARM 64 v8a" and "… Intel x86_64 Atom" (Android 15+).
  - Developer option "Boot with 16KB page size" on Pixel 8/8 Pro/8a (15 QPR1+), Pixel 9/9 Pro/9 Pro XL (15 QPR2+) and Pixel 9a (16+).
  - Cuttlefish, and Samsung Remote Test Lab.
- **Compat mode and code hygiene**:
  - The package manager runs 4 KB-aligned apps in "16 KB backcompat mode" and shows a warning. The manifest `android:pageSizeCompat` forces it on or off.
  - Android 17 adds `adb shell setprop bionic.linker.16kb.app_compat.enabled fatal` to abort on any incompatible binary. **Use this in CI device runs.**
  - Remove `PAGE_SIZE` assumptions and use `sysconf(_SC_PAGESIZE)`. Audit llama.cpp `mmap` offset alignment and any custom allocator.

---

## 6. WebView sandbox for untrusted (model-generated) HTML

### 6.1 Settings (platform `android.webkit.WebSettings`; API levels verified)
```kotlin
with(webView.settings) {
    javaScriptEnabled = needsJs                 // off unless the artifact needs it
    allowFileAccess = false                     // default false only when targeting R+ (true for Q-)
    allowContentAccess = false                  // DEFAULT IS TRUE, so set explicitly
    // setAllowFileAccessFromFileURLs / setAllowUniversalAccessFromFileURLs are deprecated (30); leave false
    domStorageEnabled = false                   // default false; enable only if needed (then use a dedicated Profile)
    // databaseEnabled: deprecated API 35 (WebSQL removal); don't touch
    setGeolocationEnabled(false)                // default TRUE
    javaScriptCanOpenWindowsAutomatically = false // default false
    setSupportMultipleWindows(false)
    mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
    blockNetworkLoads = true                    // see caveat in 6.2
    mediaPlaybackRequiresUserGesture = true
    safeBrowsingEnabled = true                  // API 26; default on where supported
}
WebSettingsCompat.setDownloadFaviconsEnabled(webView.settings, false) // webkit 1.17
```
- `WebView.startSafeBrowsing(...)` is **deprecated in API 37**.
- Also set:
  - `WebChromeClient.onPermissionRequest { it.deny() }`
  - `onGeolocationPermissionsShowPrompt → callback(origin,false,false)`
  - `onCreateWindow → false`
  - a `DownloadListener` that ignores downloads
  - `WebViewClient.shouldOverrideUrlLoading` → `true`, routing external links to Custom Tabs
- Implement `onRenderProcessGone` (API 26). androidx.webkit 1.17 lints for it. Return `true` and destroy the WebView instead of crashing the app.

### 6.2 Blocking network
- `WebViewClient.shouldInterceptRequest(view, WebResourceRequest)` (21) "is invoked for a variety of URL schemes (http(s):, data:, file:…)" but "**not** … for javascript: URLs, blob: URLs, or … file:///android_asset/… In the case of redirects, this is only called for the initial resource URL" ([WebViewClient](https://developer.android.com/reference/android/webkit/WebViewClient)).
- Strategy: allow only the synthetic sandbox origin and answer everything else with a `403` `WebResourceResponse`.
- Add a **CSP response header** on the served document, for example:
  ```
  default-src 'none'; img-src data: blob: https://sandbox.example.invalid; style-src 'unsafe-inline' …; script-src 'unsafe-inline' …; connect-src 'none'; frame-src 'none'; form-action 'none'
  ```
  The header CSP covers `fetch`, XHR, WebSocket and `EventSource`, which interception may not see.
- WebRTC data channels are not governed by `connect-src`. Whether WebView exposes `RTCPeerConnection` without a permission prompt is **UNVERIFIED**. Mitigate by injecting a document-start script that deletes `RTCPeerConnection`, `webkitRTCPeerConnection` and `RTCDataChannel`, plus `navigator.sendBeacon`.
- Whether `blockNetworkLoads=true` still lets intercepted (synthetic-origin) requests through is **UNVERIFIED**; test it. If it breaks the asset loader, rely on interception plus CSP.

### 6.3 Origin semantics (critical for the JS bridge)
- `loadDataWithBaseURL(baseUrl, …)`: "If a valid HTTP or HTTPS base URL is not specified … content … will have a `window.origin` value of `"null"`. This must not be considered to be a trusted origin … malicious content can also create frames with a null origin."
- `loadData()` uses a `data:` URL (opaque origin). "Content loaded via loadData … will not have a valid origin, and thus cannot be sent messages securely" via `postWebMessage`.
- Therefore serve untrusted HTML from a **dedicated HTTPS origin** using `WebViewAssetLoader` (`DEFAULT_DOMAIN = "appassets.androidplatform.net"`; `Builder().setDomain(...).addPathHandler("/artifact/", handler)`; `InternalStoragePathHandler(context, dir)`), or a custom `shouldInterceptRequest`.
  - Use a distinct host per trust level, for example `sandbox.appassets.androidplatform.net`, never the same origin as any privileged UI.

### 6.4 Bridge APIs (androidx.webkit; latest stable `androidx.webkit:webkit:1.17.1`, 2026-09-23; `1.18.0-rc01` 2026-10-07; minSdk 24)
- Always gate on `WebViewFeature.isFeatureSupported(...)`. Relevant flags: `WEB_MESSAGE_LISTENER`, `DOCUMENT_START_SCRIPT`, `POST_WEB_MESSAGE`, `CREATE_WEB_MESSAGE_CHANNEL`, `WEB_MESSAGE_ARRAY_BUFFER`, `MULTI_PROFILE`, `JS_INJECTION_IN_FRAME_AND_WORLD`, `SAFE_BROWSING_ENABLE`, `WEB_VIEW_RENDERER_TERMINATE` and `GET_WEB_VIEW_RENDERER`.
- `WebViewCompat.addWebMessageListener(webView, "sherpa", setOf("https://sandbox.appassets.androidplatform.net"), listener)` (webkit 1.3.0).
  - Rule format: `SCHEME "://" [HOSTNAME_PATTERN [":" PORT]]`. Accepts `https://*.example.com`, IP literals, `my-scheme://` and `"*"`. "If a wildcard "*" is provided, it will inject the JavaScript object to all frames."
  - `onPostMessage(view, WebMessageCompat, sourceOrigin, isMainFrame, JavaScriptReplyProxy)`. **Validate `sourceOrigin` and `isMainFrame` on every message.** Replies go through `replyProxy.postMessage(String | ByteArray)`.
- `WebViewCompat.addDocumentStartJavaScript(webView, script, allowedOriginRules): ScriptHandler` (`ScriptHandler.remove()`).
- webkit 1.16.0 adds:
  - `addJavaScriptOnEvent(webView, script, INJECTION_EVENT_DOCUMENT_START|END, rules, JavaScriptExecutionWorld)`
  - `getExecutionWorld(webView, name)`
  - `addWebMessageListener(webView, name, rules, world, listener)`
  - `JavaScriptReplyProxy.executeJavaScript`
  
  These let the bridge live in an **isolated world** that page scripts can't monkey-patch.
- `WebViewCompat.postWebMessage(webView, WebMessageCompat, targetOrigin)` and `createWebMessageChannel(webView)`. Never use a `"*"` target.
- **Profiles**: `ProfileStore.getInstance().getOrCreateProfile("untrusted")` then `WebViewCompat.setProfile(webView, "untrusted")`. Do this before the first navigation.
  - Each profile has its own `CookieManager`, `WebStorage`, `GeolocationPermissions`, `ServiceWorkerController` and `HttpCache` (1.17). `deleteProfile(name)` wipes it.
  - webkit 1.18.0-alpha01 adds `Profile#setCrossOriginIsolatedAllowlist` (for SharedArrayBuffer opt-in).
- Avoid `addJavascriptInterface` (API 1) for untrusted content, because it is exposed to every frame and origin.

---

## 7. OAuth, App Links, predictive back

### 7.1 Custom Tabs / Auth Tab (`androidx.browser:browser:1.10.0`, 2026-03-25, minSdk 23)
```kotlin
val launcher = AuthTabIntent.registerActivityResultLauncher(activity) { r: AuthTabIntent.AuthResult ->
    when (r.resultCode) { AuthTabIntent.RESULT_OK -> handle(r.resultUri); /* RESULT_CANCELED, RESULT_VERIFICATION_FAILED, RESULT_VERIFICATION_TIMED_OUT */ }
}
AuthTabIntent.Builder().setEphemeralBrowsingEnabled(true).build()
    .launch(launcher, authUri, /*redirectScheme*/ "io.github.mihok.sherpa")          // or launch(launcher, uri, redirectHost, redirectPath) for https
```
- "Auth Tab is supported by Chrome browser versions 137 and later". "Fallback to Custom Tabs is automatic". The fallback returns `RESULT_CANCELED` when the tab closes, and the redirect then arrives at your Activity intent, so handle both paths.
- Probe support with `CustomTabsClient.isAuthTabSupported(ctx, pkg)` and `isEphemeralBrowsingSupported`.
- HTTPS redirects need Digital Asset Links verification.
- Use PKCE (S256) and `state`. Never use a WebView for OAuth.
- Source: [Auth Tab guide](https://developer.chrome.com/docs/android/custom-tabs/guide-auth-tab).

### 7.2 App Links
- Use `<intent-filter android:autoVerify="true">` with `https` scheme plus host, and host `/.well-known/assetlinks.json` (`delegate_permission/common.handle_all_urls` + SHA-256 fingerprints). Include the Play App Signing key.
- Debug with `adb shell pm verify-app-links --re-verify <pkg>` and `pm get-app-links [--user cur] <pkg>`. Query state with `DomainVerificationManager` (31).
- Android 15+ adds **Dynamic App Links** (`dynamic_app_link_components` rules in assetlinks.json; periodic re-fetch on API 35+), which change routing without an app update.
- Sources: [verify App Links](https://developer.android.com/training/app-links/verify-android-applinks), [about](https://developer.android.com/training/app-links/about).

### 7.3 Predictive back (Android 16 + Flutter 3.47)
- Android 16 behaviour for `targetSdk 36` apps on 16+ devices: "predictive back system animations (back-to-home, cross-task, and cross-activity) are enabled by default. Additionally, `onBackPressed` is not called and `KeyEvent.KEYCODE_BACK` is not dispatched anymore". Opt out with `android:enableOnBackInvokedCallback="false"` (application or activity).
- Flutter 3.47 docs say to add `android:enableOnBackInvokedCallback="true"` to `<application>` (needed for opt-in on Android 13–15 devices) and to use `PopScope(canPop:, onPopInvokedWithResult:)`. `WillPopScope` is deprecated.
- Since Flutter 3.38, "the default page transition on Android is now `PredictiveBackPageTransitionBuilder`".
- The stable template manifest (and Sherpa's current manifest) **does not** set the attribute.
- Kotlin plugin activities, for example a native WebView host, must use `OnBackPressedDispatcher` / `OnBackInvokedCallback`. API 36 adds `PRIORITY_SYSTEM_NAVIGATION_OBSERVER`.
- Sources: [Flutter predictive back](https://docs.flutter.dev/platform-integration/android/predictive-back), [Android 16 changes](https://developer.android.com/about/versions/16/behavior-changes-16).

---

## 8. Assistant and OS surfaces

### 8.1 Live Updates (the Android counterpart of iOS Live Activities)
- APIs (api-versions):
  - `Notification.ProgressStyle` (36): segments, points, tracker/start/end icons, `setProgressIndeterminate`
  - `Notification.FLAG_PROMOTED_ONGOING` (36), `Notification.hasPromotableCharacteristics()` (36), `NotificationManager.canPostPromotedNotifications()` (36)
  - `Settings.ACTION_APP_NOTIFICATION_PROMOTION_SETTINGS` (36). The guide calls it `ACTION_MANAGE_APP_PROMOTED_NOTIFICATIONS`; that name does not exist in the SDK.
  - `Notification.Builder.setShortCriticalText(String)` (36) for the status-bar chip text
  - **`Manifest.permission.POST_PROMOTED_NOTIFICATIONS`** (36.1, normal\|appops), `Notification.Builder.setRequestPromotedOngoing(boolean)` (36.1) and `EXTRA_REQUEST_PROMOTED_ONGOING` (36.1). Check `Build.VERSION.SDK_INT_FULL >= VERSION_CODES_FULL.BAKLAVA_1`.
  - `Notification.MetricStyle` and semantic colour styles (37)
- `NotificationCompat` in `androidx.core:core:1.19.1` already has `ProgressStyle`, `setRequestPromotedOngoing` and `setShortCriticalText`.
- Requirements:
  - Standard, BigText, Call, Progress or Metric style
  - ongoing, with `contentTitle`
  - no custom `RemoteViews`, not a group summary, not colorized
  - channel importance above MIN
  - both `POST_NOTIFICATIONS` (33, runtime) and `POST_PROMOTED_NOTIFICATIONS`
- Policy: use it for "ongoing, user-initiated, and time-sensitive" activities. "Inappropriate uses: Ads, promotions, **chat messages, alerts** …". A user-started multi-step agent task with progress ("Thinking…" placeholders are explicitly suggested) fits; ordinary chat replies do not. Don't repost after the user dismisses it (`setDeleteIntent`).
- Source: [Live updates](https://developer.android.com/develop/ui/views/notifications/live-update).

### 8.2 AppFunctions (on-device MCP-like tools)
- Platform `android.app.appfunctions.AppFunctionManager` (36):
  - `executeAppFunction(ExecuteAppFunctionRequest, executor, CancellationSignal, OutcomeReceiver)`, `isAppFunctionEnabled(...)`, `setAppFunctionEnabled(...)`
  - Added in 37: `searchAppFunctions(AppFunctionSearchSpec,…)`, `observeAppFunctions(...)`, `registerAppFunction(s)(...)` (runtime registration), `getAppFunctionStates(...)`, `AppFunctionUriGrant`
- Permissions: `EXECUTE_APP_FUNCTIONS` (36, normal, but "allowlist checks for AppFunctions API access are enforced at runtime") and `BIND_APP_FUNCTION_SERVICE` (36).
- Jetpack: `androidx.appfunctions:appfunctions:1.0.0-alpha13` plus `ksp("androidx.appfunctions:appfunctions-compiler:1.0.0-alpha13")` (2026-10-07). There are also `appfunctions-service` (alpha09) and `appfunctions-testing`.
  - **alpha13 renames `@AppFunction` → `@AppFunctionDeclaration`** and adds `@AppFunctionAccessLevel`. Docs snippets still show `@AppFunction(isDescribedByKDoc = true)`, `@AppFunctionSerializable` and `AppFunctionService` with `@AppFunctionServiceEntryPoint`.
- Status: "experimental preview … As of May 2026, AppFunctions integration with Gemini is in a private preview with trusted testers". Only "a limited number of apps and system agents can access the entire pipeline". An Early Access Program exists.
- Testing: `adb shell cmd app_function list-app-functions`.
- Sherpa angles:
  1. As a **provider**, expose `startAgentTask(goal)` and `askSherpa(prompt)` so system agents can call Sherpa. Cheap; ship it behind a flag.
  2. As a **caller**, invoking other apps' AppFunctions as tools would be ideal for an agent harness, but the runtime allowlist likely blocks third-party callers today (**UNVERIFIED**).
- Source: [AppFunctions overview](https://developer.android.com/ai/appfunctions).

### 8.3 Other Android 17 items that touch Sherpa
- **`ACCESS_LOCAL_NETWORK`** (37, *dangerous*, NEARBY_DEVICES group) is mandatory for `targetSdk 37` apps that discover or connect to LAN hosts, such as a user's Ollama, llama-server or LM Studio. Wi-Fi/Ethernet count as local; cellular and VPN do not.
- **Background audio hardening**: when targeting 37, background playback, audio focus or volume changes (for example TTS of agent output) require a running FGS plus while-in-use conditions.
- **Dedicated Assistant volume stream** (`USAGE_ASSISTANT`).
- **ECH** is on by default in platform TLS stacks.

---

## 9. Recommendations for Sherpa

1. **Engine strategy (Android)**, with one Kotlin plugin `sherpa_native_llm` exposing a uniform Dart API (`load`, `generateStream`, `cancel`, `tokenCount`, `unload`, `capabilities`):
   - **Tier A: Gemini Nano** (ML Kit `genai-prompt:1.0.0-beta4`). Use it only in the foreground, for short, cheap tasks (summaries, classification, title generation) within 4000 input tokens. Never use it for background agent steps.
   - **Tier B: LiteRT-LM 0.18.0**, the default local agent engine.
     - Use `Conversation` with `automaticToolCalling=false` and `OpenApiTool` schemas generated from Sherpa's Dart tool registry, so the Dart core keeps owning the tool loop, approvals and checkpoints.
     - Use `ResponseFormat.json(schema)` for structured steps and `ThinkingConfig` budgets.
     - Use the GPU backend first (lower anonymous memory), CPU as fallback, and NPU only when `ModelInfo.npuBrand/socName` matches the device's `Build.SOC_MODEL`.
   - **Tier C: llama.cpp** for arbitrary GGUF. Run on CPU with KleidiAI by default, use OpenCL only on an Adreno 7xx/8xx allowlist after a self-benchmark, and leave Vulkan off.
   - **Skip** MediaPipe LLM Inference and NNAPI.
2. **Model distribution.**
   - Big LLMs (>1.5 GB) download from HF or Sherpa's CDN via a **UIDT job** on API 34+. Use a WorkManager `dataSync` foreground worker on 24–33. Support resume and SHA-256 checks, and store under `noBackupFilesDir`.
   - Small helpers (embedder, FunctionGemma, ASR) can use PODAI AI packs (on-demand) if Play is the only channel.
   - Gated repos (Gemma 3/3n) need user-supplied HF tokens. Prefer the ungated Gemma 4 (Apache-2.0) or Qwen3 repos.
3. **Memory governance.**
   - Do admission control before `Engine.initialize()`: compare `advertisedMem`/`totalMem` buckets, `availMem - threshold`, and the Android 17 limiter ceiling (assume about 50% of RAM in the foreground and 25% in the background until measured).
   - Release resources on `TRIM_MEMORY_BACKGROUND`. Write a 128-byte `setProcessStateSummary` at each inference phase and auto-downgrade after `REASON_LOW_MEMORY`, `SIGKILL` or `MemoryLimiter:AnonSwap` exits.
   - Evaluate an `android:process=":llm"` inference service.
   - Keep `largeHeap` off.
4. **Background policy.**
   - Start a `shortService` FGS when the user leaves mid-reply, so the current turn finishes within about 3 minutes.
   - Long-running autonomous runs use a `specialUse` FGS with the subtype "On-device LLM inference for user-started agent task", a Play declaration and a video. Show a Live Update with `ProgressStyle` for multi-step tasks only.
   - Don't use `mediaProcessing`.
   - Always implement `onTimeout(int,int)`.
5. **Performance and thermal.** Run a `ThermalGovernor` in Kotlin:
   - inputs: `addThermalStatusListener`, `getThermalHeadroom(10)` at 1 Hz or less, and `addThermalHeadroomListener` on 36+
   - knobs: decode pacing, thread count, backend or model swap
   - an optional ADPF hint session around decode, behind an experiment flag

   Pick llama.cpp thread counts from `cpu_capacity` clusters. Don't pin.
6. **Build hygiene.**
   - CI gate: `zipalign -c -P 16 -v 4`, `check_elf_alignment.sh` over all `.so` files, `bundletool dump config | grep PAGE_ALIGNMENT_16K`, and an Android 17 emulator run with `bionic.linker.16kb.app_compat.enabled fatal`.
   - Pin NDK r28.2+ (r30 LTS when Flutter moves).
   - Declare `<uses-native-library>` for `libOpenCL.so`, `libvndksupport.so` and `libcdsprpc.so`, all with `required="false"`.
7. **WebView artifacts.**
   - Use a dedicated `Profile("untrusted")`.
   - Serve content via `WebViewAssetLoader` at an `https://sandbox.appassets.androidplatform.net` origin with a strict CSP header, and deny all other requests in `shouldInterceptRequest`.
   - Bridge with `addWebMessageListener` in an isolated `JavaScriptExecutionWorld` with exact-origin rules, validating `sourceOrigin`/`isMainFrame`.
   - Use the settings from §6.1, `onRenderProcessGone` recovery, and no `addJavascriptInterface`.
8. **Auth and links.** Use Auth Tab (`browser:1.10.0`) with a custom-scheme redirect and PKCE, falling back automatically to Custom Tabs. Use verified App Links for `https` callbacks once a domain exists.
9. **Predictive back.** Add `android:enableOnBackInvokedCallback="true"`, migrate all `WillPopScope` to `PopScope`, and use `OnBackPressedDispatcher` in native activities.
10. **Assistant integration.** Prototype AppFunctions (provider side) behind a flag on API 36+. Track the `@AppFunctionDeclaration` rename. Plan for `ACCESS_LOCAL_NETWORK` before moving to `targetSdk 37`.

## 10. Risks

- **Android 17 memory limiter**: CPU-backend LLMs on 4–6 GB devices may be swapped or killed even in the foreground. OEM rollout varies, and whether GPU/DMA-BUF memory counts is **UNVERIFIED**.
- **Gemini Nano constraints**: foreground-only, per-app quota, beta API with no SLA, nano-v2/v3/v4 quality drift, and no tool calling. Unlocked-bootloader devices (developers, enthusiasts) fail.
- **Play review**:
  - `specialUse` for "LLM inference" may be rejected or require iteration.
  - `dataSync` misuse is a policy risk.
  - Live Updates misuse can get the promotion permission revoked by users.
- **PODAI limits**: the 1.5 GB per-pack limit excludes mainstream LLMs, and PODAI is still beta (`ai-delivery 0.2.0-beta01`).
- **NPU fragmentation**: per-SoC model files (3+ GB each), separate vendor runtime libraries (Qualcomm QAIRT licensing and size, per-Hexagon-version feature modules), `minSdk 31`, and NPU model coverage limited to a few SoCs.
- **GPU fragmentation**: llama.cpp OpenCL is Adreno-only and Vulkan is often slower than CPU or buggy. LiteRT-LM GPU behaviour on Mali, PowerVR and Xclipse without vendor OpenCL is **UNVERIFIED**.
- **LiteRT-LM API churn**: pre-1.0, with `@ExperimentalApi` flags. The tool-reflection path pulls `kotlin-reflect` (a POM dependency) and likely needs R8 keep rules for `@Tool` classes (**UNVERIFIED** which). Prefer `OpenApiTool` to avoid reflection.
- **16 KB**: any third-party prebuilt `.so` (vendor NPU libraries, OpenCL ICD, tokenizers) can break compliance. After 2027-02-01, Play blocks updates.
- **WebView**: interception doesn't cover `blob:` and `javascript:` URLs, WebRTC or redirects. CSP plus script hardening is defense in depth, not proof. WebView feature availability depends on the WebView APK version (`isFeatureSupported`).
- **AppFunctions**: experimental and allowlisted, with alpha renames; caller access is likely unavailable.
- **NDK APIs for API 36** (`ASystemHealth_*`, `notifyWorkload*`) need a newer NDK than the local r29, so check r30 headers before use.

## 11. Open questions for the product owner

1. Is Play the only Android distribution channel? This decides whether PODAI, Play Feature Delivery (NPU runtimes) and Play-only declarations are acceptable or whether to self-host everything.
2. Should agent runs continue in the background for long periods (minutes to hours)? If yes, do you accept a `specialUse` FGS with Play review risk, or should background runs fall back to the cloud?
3. Minimum device tier for local LLMs: for example ≥8 GB `advertisedMem` for 2B-class models and ≥12 GB for 4B. Should 4–6 GB devices be Nano or cloud only?
4. Which local model families are first-class? (Gemma 4 E2B/E4B Apache-2.0, Qwen3, or BYO GGUF.) Will we ask users for HF tokens for gated models?
5. Is NPU support (per-SoC model downloads of about 3 GB plus vendor libraries) worth the matrix cost in v1, or should v1 be GPU/CPU only?
6. Is `minSdk` staying at 24? NPU needs 31, UIDT 34, ADPF power-efficiency 35 and headroom 36. Should those be runtime-gated only?
7. Should Sherpa expose AppFunctions (be callable by Gemini and other agents) in v1, and apply for the EAP?
8. When should `targetSdk` move to 37? It triggers `ACCESS_LOCAL_NETWORK` prompts for LAN model servers, background-audio hardening and the widget memory limit.
9. Live Updates: which agent tasks qualify as "user-initiated, ongoing, time-sensitive"? Approve copy and UX for promoted notifications.
10. WebView artifacts: must they ever fetch network resources (images, CDNs)? If yes, define a per-artifact allowlist and approval UX; the default would be fully offline.

## 12. Verification log (the 10 most load-bearing claims)

| # | Claim | How verified | Result |
|---|---|---|---|
| 1 | LiteRT-LM is `com.google.ai.edge.litertlm:litertlm-android`, latest 0.18.0, minSdk 24, arm64 lib 16 KB-aligned | `dl.google.com/android/maven2/com/google/ai/edge/litertlm/group-index.xml`; POM `last-modified` 2026-10-06; AAR `AndroidManifest.xml`; `llvm-readelf -lW` showing LOAD Align `0x4000` | Verified |
| 2 | LiteRT-LM exposes `Engine`, `Conversation`, `Session`, `ResponseFormat.json/regex`, `OpenApiTool`/`ToolSet`, `ThinkingConfig`, `Backend.NPU(nativeLibraryDir)`, `ModelInfo` | `javap` on `classes.jar` from the 0.18.0 AAR, plus ai.google.dev/edge/litert-lm/android | Verified |
| 3 | MediaPipe LLM Inference is maintenance-only | ai.google.dev/edge/mediapipe/solutions/genai/llm_inference/android banner | Verified |
| 4 | ML Kit Prompt API is `genai-prompt:1.0.0-beta4`, minSdk 26, input <4000 tokens, blocked in background even with FGS, no tools API | Maven group-index/POM; AAR manifest; javap `GenerativeModel`; developers.google.com/ml-kit/genai (Background usage) and the prompt get-started page | Verified |
| 5 | Only `TRIM_MEMORY_UI_HIDDEN`/`BACKGROUND` remain; others are deprecated in 35 and not delivered since 34 | `api-versions.xml` (37) shows `deprecated="35"`; ComponentCallbacks2 reference text | Verified |
| 6 | `dataSync`/`mediaProcessing` get 6 h/24 h with `onTimeout(int,int)` (API 35); `specialUse` needs `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` and Play review | FGS timeout and types pages; `api-versions.xml` (`onTimeout(II)V` since 35; `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` since 34); Play Help 13392821 | Verified |
| 7 | ADPF/thermal API levels: `createHintSession` 31, `setThreads` 34, `setPreferPowerEfficiency` 35, `getCpuHeadroom` 36, `addThermalHeadroomListener` 36, `getThermalHeadroom` 30 | `api-versions.xml` (37); NDK r29 `performance_hint.h`/`thermal.h`; NDK reference pages | Verified (the API level of the NDK API-36 hint functions is not verified) |
| 8 | 16 KB: Play blocks non-compliant updates from 2027-02-01; AGP 8.5.1+/NDK r28+ align by default; `zipalign -c -P 16` | developer.android.com/guide/practices/page-sizes; local `zipalign` 36.1.0 usage text | Verified (earlier Nov 2025 / May 2026 dates from secondary sources only) |
| 9 | Android 17 per-app memory limiter; kills report `REASON_OTHER` + `"MemoryLimiter:AnonSwap"`; example ceilings 2 GB/1 GB on 4 GB devices | behavior-changes-all (17); app-memory-budgets page; Android Developers Blog 2026-08-19 | Verified |
| 10 | PODAI AI packs ≤1.5 GB each, ≤4 GB total, models only; `ai-delivery` latest 0.2.0-beta01; Gemma-4-E2B `.litertlm` = 2.0–3.3 GB (does not fit) | developer.android.com/google/play/on-device-ai; Maven `com/google/android/play/group-index.xml`; HF API `?blobs=true` sizes | Verified |

Also verified, outside the top 10:
- Live Updates API levels (`POST_PROMOTED_NOTIFICATIONS`/`setRequestPromotedOngoing` = 36.1; `ProgressStyle` = 36; `MetricStyle` = 37; settings action name `ACTION_APP_NOTIFICATION_PROMOTION_SETTINGS`)
- `EXECUTE_APP_FUNCTIONS` is normal with a runtime allowlist
- `ACCESS_LOCAL_NETWORK` is dangerous, API 37
- WebView null-origin semantics (WebView reference)
- WorkManager 2.12.0 lacks UIDT (AAR class scan)
- Flutter 3.47.7 stable with template targetSdk 36, NDK 28.2.13676358, AGP 9.1.0 (flutter/flutter `stable` branch sources)
