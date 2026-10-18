# 06 — iOS native capabilities for on-device LLM inference

Research digest for **Sherpa**, an open agent harness: Flutter UI, pure-Dart core, and Swift native plugins for local inference.
Compiled 2026-10-18. Every claim was checked against developer.apple.com (the DocC JSON at `developer.apple.com/tutorials/data/documentation/...`), official GitHub repos read via `raw.githubusercontent.com`, Swift Package Index (SPI) and pub.dev, unless it is marked otherwise.

Legend:
- **✅** verified against a primary source today.
- **[2nd]** comes only from a secondary source, such as a forum post by a non-Apple developer, a blog, or a third-party article.
- **UNVERIFIED** means no primary source was found. Treat it as a hypothesis to test on device.

> **Correction to the brief.** The brief says iOS 26 is current. It is not. Per developer.apple.com/news/releases ✅, these have shipped: **Xcode 27 (27A266a) on Sep 14, 2026**, **iOS 27.0.1 (24A446) on Sep 28, 2026** and **Xcode 27.1 (27A9275) on Oct 15, 2026**. **iOS 27.2 beta 4 (24B5110a)** came out Oct 13, 2026. iOS 26.6.2 (Sep 8, 2026) is the last iOS 26 release on iPhone.
>
> This digest therefore treats **iOS 27 as current** and **iOS 26 as the floor for "new" APIs**. iOS 27 changes several conclusions:
> - Foundation Models gains a public `LanguageModel` protocol and Private Cloud Compute (PCC).
> - Foundation Models adapters are dropped.
> - The new **Core AI** framework arrives.
> - There is a new background Neural Engine (ANE) entitlement.
> - MetricKit gets a new `MetricManager` API.
> - Building with the iOS 27 SDK requires the UIScene lifecycle.

---

## 0. TL;DR

1. **MLX is the primary local engine.** Use `mlx-swift-lm` **3.32.3**, which needs mlx-swift 0.32.3, **iOS 17+** and **swift-tools 6.2** (so Xcode 26 or later). It has a mature `ChatSession` with:
   - streaming as `String` or as `Generation` events;
   - tool-call parsing for about 13 model formats;
   - KV-cache quantization (`kvBits`, `kvScheme`: affine, turbo, varn) and a rotating cache (`maxKVSize`);
   - prompt-cache save and load to `.safetensors`;
   - `fork(history:)`;
   - **speculative decoding, which has shipped** (`SpeculativeDecodingConfig`);
   - grammar-constrained output (`MLXGuidedGeneration`, using xgrammar).
2. **Memory APIs moved.** `GPU.set(cacheLimit:)` and `GPU.set(memoryLimit:)` are **deprecated**. Use `Memory.cacheLimit`, `Memory.memoryLimit`, `Memory.clearCache()` and `Memory.snapshot()`. `memoryLimit` defaults to 1.5 × `recommendedMaxWorkingSetSize`.
3. **The GPU is off-limits in the background, with one exception.** Metal rejects command buffers submitted from the background (`MTLCommandBufferError.Code.notPermitted`). MLX's **default error handler prints the error and exits the process**, so a backgrounded MLX generation that isn't wrapped in `withError` becomes a crash. The only legal background GPU path is `BGContinuedProcessingTask` with `.gpu`. That needs the "Background GPU Access" entitlement and a device where `BGTaskScheduler.supportedResources.contains(.gpu)` is true. Apple DTS said in Sep 2025 that this is **only iPads with M3 or later and no iPhone** [2nd, an Apple DTS forum post].
4. **Apple Foundation Models is an optional, secondary provider.** Facts that set its role:
   - The on-device context is **4,096 tokens**.
   - The model changes with OS versions: 26.0–26.3, 26.4 and 27.0 each ship a different one.
   - **Adapters are unsupported as of OS 27.**
   - From iOS 27 there is `LanguageModel`/`LanguageModelExecutor` for custom models, `PrivateCloudComputeLanguageModel` (32K context, daily quota, needs a managed entitlement and the Small Business Program), and `ToolCallingMode`.
   - It does run in the background, subject to rate limits.

   Use it for cheap sub-tasks, not as the main agent brain.
5. **Memory reality.** `com.apple.developer.kernel.increased-memory-limit` helps only "on some device models" ✅. Developers report a **~6 GB per-process cap even on 12 GB iPhones** [2nd]. Always size models from `os_proc_available_memory()` at runtime.
6. **Flutter.** SwiftPM is the default since **Flutter 3.44**; Flutter 3.47 is the current stable release. The **CocoaPods trunk becomes read-only on Dec 2, 2026** ✅. Use **Pigeon 29.0.10** in platform-channel mode with `@EventChannelApi` for token streams. Pigeon's experimental FFI mode cannot do event channels. Flutter has **no official Liquid Glass** yet: `cupertino_ui` 1.1.3 has no glass material [2nd], so community packages are the only route.
7. **Sherpa's app currently targets iOS 15.0.** That is incompatible with any MLX or ExecuTorch SwiftPM dependency, which need iOS 17. Raising the deployment target is a prerequisite.

---

## 1. Platform baseline (Oct 2026)

| Item | Fact | Source |
|---|---|---|
| Current OS | iOS 27.0.1 (24A446), Sep 28, 2026. iOS 27.2 beta 4 (24B5110a), Oct 13. | ✅ https://developer.apple.com/news/releases/ |
| Current Xcode | Xcode 27.1 (27A9275), Oct 15, 2026. Xcode 27.2 beta 3 (27B5038j). | ✅ same page |
| UIScene lifecycle | "In the next major release following iOS 26, UIScene lifecycle will be required when building with the latest SDK; otherwise, your app won't launch." Sherpa's `app/ios/Runner` already has `SceneDelegate.swift` and a `UIApplicationSceneManifest`, so it complies. | ✅ https://developer.apple.com/documentation/technotes/tn3187-migrating-to-the-uikit-scene-based-life-cycle |
| Metal toolchain | Since Xcode 26 it is a separate component (Xcode › Settings › Components, or `xcodebuild -downloadComponent MetalToolchain`). Builds that compile Metal fail without it. MLX compiles `.metal` sources, so CI must install it. | Core AI doc ✅ ("isn't installed by default"); exact command [2nd] from forums 802155 and 787221 |
| Xcode 27 host | Apple-silicon only. | [2nd] https://verygood.ventures/blog/wwdc-2026-through-a-flutter-lens/ |
| Simulator | MLX cannot evaluate on the iOS Simulator: it lacks the needed `MTLGPUFamily`. Use a device or "Mac (Designed for iPad)". | ✅ mlx-swift `Documentation.docc/Articles/running-on-ios.md` |

---

## 2. MLX Swift and mlx-swift-lm

### 2.1 Versions and SwiftPM
- **mlx-swift-lm 3.32.3** is the latest release, published about 18 days before SPI's last update on Oct 16, 2026. It is MIT-licensed and tested on Swift 6.1–6.4 ✅ https://swiftpackageindex.com/ml-explore/mlx-swift-lm
- **mlx-swift 0.32.3** ✅ https://swiftpackageindex.com/ml-explore/mlx-swift. The two version numbers are aligned.
- `Package.swift` ✅ https://raw.githubusercontent.com/ml-explore/mlx-swift-lm/main/Package.swift
  - `// swift-tools-version: 6.2`; platforms `.macOS(.v14), .iOS(.v17), .tvOS(.v17), .visionOS(.v1)`.
  - Products: `MLXLLM`, `MLXVLM`, `MLXLMCommon`, `MLXEmbedders`, `MLXRerankers`, `MLXHuggingFace` (macros), `MLXFoundationModels`, `MLXGuidedGeneration`, `MLXScriptedLM`, `BenchmarkHelpers`, `IntegrationTestHelpers`.
  - Dependencies: `mlx-swift .upToNextMinor(from: "0.32.3")` and `swift-syntax "602.0.0"..<"604.0.0"`. swift-syntax is only for the `MLXHuggingFaceMacros` macro target.
  - **Trait** `FoundationModelsIntegration` is on by default. It only does something when you compile with the iOS/macOS/visionOS **27 SDK**; otherwise `MLXFoundationModels` compiles to an empty module.
  - `MLXCXGrammar` vendors xgrammar C++17 and uses `.unsafeFlags(["-w"])`. This is allowed for version-pinned dependencies because SwiftPM disables the unsafe-flags check for manifests at tools version 6.2 or later ✅ (`swift-package-manager/Sources/PackageLoading/PackageBuilder.swift`: "unsafe flags check disabled in 6.2").
- Installation, per the README ✅:
  ```swift
  .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.32.3")),
  .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),   // only if using HubClient
  .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),  // Tokenizers
  ```
- **3.x is a breaking change from 2.x.** `Downloader`, `Tokenizer` and `TokenizerLoader` are now protocols, which breaks the hard dependency on the Hugging Face Hub. ✅ `Libraries/MLXLMCommon/Documentation.docc/upgrade.md`
- Example apps (LLMEval, MLXChatExample, LLMBasic) live in `ml-explore/mlx-swift-examples`. The libraries moved to mlx-swift-lm. LLMEval ships `com.apple.developer.kernel.increased-memory-limit = true` ✅ `Applications/LLMEval/LLMEval.entitlements`.

### 2.2 Loading
Source: ✅ `Libraries/MLXLMCommon/ModelFactory.swift`, `README.md`, `Documentation.docc/using.md`, `Libraries/MLXLLM/LLMModelFactory.swift`.
- Loading functions:
  - `LLMModelFactory.shared.loadContainer(from: any Downloader, using: any TokenizerLoader, configuration: ModelConfiguration, useLatest: Bool = false, progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }) async throws -> ModelContainer`
  - `loadContainer(from directory: URL, using: any TokenizerLoader) async throws -> ModelContainer`. Loads from a local directory with no downloader. **This is what Sherpa needs if downloads are native or Dart-driven.**
  - Free functions: `loadModel(from:using:id:)` and `loadModelContainer(from:using:id:)`, plus `loadModelContainer(from: URL, using:)`.
- `Downloader` protocol: `func download(id: String, revision: String?, matching patterns: [String], useLatest: Bool, progressHandler: @Sendable @escaping (Progress) -> Void) async throws -> URL`.
- The macros (`#hubDownloader()`, `#huggingFaceTokenizerLoader()`, `#huggingFaceLoadModelContainer(configuration:)`) are only a convenience. Using them pulls in a Swift macro plugin and therefore swift-syntax. Xcode macro-trust prompts and the CI `-skipMacroValidation` flag are UNVERIFIED but likely friction. **Prefer a hand-written `TokenizerLoader` that wraps swift-transformers.**
- `ModelConfiguration(id: "mlx-community/…")` or `(directory:)`.
  - `toolCallFormat` is nil by default and is then auto-resolved from the model id, the `model_type` and the tokenizer's chat template.
  - `reasoningConfig` is also auto-resolved.
- `ModelContainer` is a `public final class ModelContainer: Sendable` that wraps a `SerialAccessContainer<ModelContext>`:
  - `perform { context in … }` (the overloads that take `(model, tokenizer)` are deprecated);
  - `prepare(input:)`;
  - `generate(input:parameters:wiredMemoryTicket:tools:) async throws -> AsyncStream<Generation>`;
  - `encode`, `decode` and `applyChatTemplate(messages:)`;
  - `cacheStatus(parameters:)`.

### 2.3 ChatSession: the main API
Source: ✅ `Libraries/MLXLMCommon/ChatSession.swift`.
```swift
public final class ChatSession {            // not thread-safe: one task at a time
  public init(_ model: ModelContainer, instructions: String? = nil,
              speculativeDecoding: SpeculativeDecodingConfig? = nil,
              generateParameters: GenerateParameters = .init(),
              components: GenerationComponents = .init(),          // e.g. a custom LogitProcessor
              processing: UserInput.Processing = .init(resize: CGSize(width: 512, height: 512)),
              additionalContext: [String: any Sendable]? = nil,
              tools: [ToolSpec]? = nil,
              toolDispatch: (@Sendable (ToolCall) async throws -> String)? = nil)
  // also: init(_:instructions:history: [Chat.Message], …)   -> "prompt re-hydration"
  //       init(…, promptCache: …) / init(…, cache: [KVCache], state:)  -> restore a saved prefix
  func respond(to: String, role:, image:/images:, video:, audio:) async throws -> String
  func respond(to messages: [Chat.Message]) async throws -> String      // e.g. tool results, keeps the KV cache
  func streamResponse(to: String, …) -> AsyncThrowingStream<String, Error>
  func streamResponse(to messages: [Chat.Message]) -> AsyncThrowingStream<String, Error>
  func streamDetails(to: String, …) -> AsyncThrowingStream<Generation, Error>
  func streamDetails(to messages: [Chat.Message]) -> AsyncThrowingStream<Generation, Error>
  func fork(history: [Chat.Message]? = nil) async -> ChatSession        // copy-on-write cache branch
  func saveCache(to url: URL) async throws                              // raw KV + model state, no transcript
  func clear() async; func synchronize() async; func cacheStatus() async throws -> KVCacheStatus
}
public enum Generation { case chunk(String), info(GenerateCompletionInfo), toolCall(ToolCall), rejectedToolCall(RejectedToolCall) }
```
- `Chat.Message` provides `.system(_:)`, `.user(_:images:videos:audios:)`, `.assistant(_:toolCalls:)` and `.tool(_:id:name:)`. Roles are `user`, `assistant`, `system` and `tool` ✅ `Chat.swift`.
- `GenerateCompletionInfo` carries `promptTokenCount`, `generationTokenCount`, `promptTime`, `generateTime`, `tokensPerSecond`, `promptTokensPerSecond`, `stopReason`, `acceptedDraftTokens`, `rejectedToolCallCount` and `cacheEfficiency` ✅ `Evaluate.swift`.
- **Agent loop pattern for Sherpa:**
  - Keep **one `ChatSession` per conversation** and leave `toolDispatch = nil`.
  - Consume `streamDetails`, forward `.toolCall` to Dart, then continue with `streamDetails(to: [.tool(result, id:, name:)])`. This keeps the KV cache warm. The doc warns that re-initialising from history re-prefills the whole transcript.
  - With automatic dispatch configured, dispatch "is fail-closed: only calls naming a function declared in `tools` can reach this callback."

### 2.4 GenerateParameters (sampling and KV cache)
Source: ✅ `Evaluate.swift`. Defaults:
```text
maxTokens nil, maxKVSize nil, kvCache (typed config) nil, kvBits nil, kvGroupSize 64, quantizedKVStart 0, kvScheme nil,
temperature 0.6, topP 1.0, topK 0, minP 0, logProbabilities nil, repetitionPenalty nil (ctx 20),
presencePenalty nil (ctx 20), frequencyPenalty nil (ctx 20), prefill: PrefillParameters(), seed nil, toolCallPolicy .init()
```
- **`maxKVSize`** switches full-attention layers to `RotatingKVCache`. It keeps the first 4 tokens when the size allows, so it is a sliding window. Mamba, SSM and GDN layers don't count against it.
- **KV quantization:** set `kvBits` (4 or 8) together with `kvGroupSize` and `quantizedKVStart`, or set **`kvScheme`**:
  - `"affine4"` and `"affine8"`;
  - TurboQuant: `"turbo0v4"` is the safest; **`"turbo8v3"` is the recommended default**; also `"turbo8v2"`, `"turbo4"`, …;
  - variance-normalised `"varn"`, `"varn4"`, `"varn2"` and tiled variants.

  Don't combine the typed `kvCache:` with the legacy fields.
- `prefill.stepSize` (the old `prefillStepSize` is deprecated) sets peak activation memory during prefill. Lower it on low-RAM devices. Prefill now uses balanced chunking by default.
- `seed` gives reproducible sampling. `logProbabilities` is reported only by `TokenIterator`; speculative iterators ignore it.

### 2.5 Prompt cache save and load
Source: ✅ `KVCache.swift`.
- `savePromptCache(url:cache:metadata:state:)` writes a `.safetensors` file whose layout is compatible with Python mlx-lm.
- `loadPromptCacheSnapshot(url:) -> PromptCacheSnapshot { cache, metadata, state }` is the preferred loader. `loadPromptCache(url:)` returns a `([KVCache], [String:String])` tuple and rejects files that carry model state.
- Helpers: `makePromptCache(...)`, `canTrimPromptCache`, `trimPromptCache(_:numTokens:)`.
- Caveat: a raw cache carries no transcript. Persist the messages separately.
- **Sherpa use:** precompute and persist the KV cache for the static prefix (system prompt and tool schemas) per model hash and per tool-set hash. Restore it with the `promptCache` initializer, and use `fork(history: [])` for sub-agents that share instructions and tools.

### 2.6 Tool calling
Source: ✅ `Tool/Tool.swift`, `Tool/ToolCall.swift`, `Tool/ToolCallFormat.swift`.
- `ToolSpec = [String: any Sendable]`, the OpenAI-style `{"type":"function","function":{name,description,parameters}}`. It maps 1:1 to a Dart-side JSON schema, so Dart can send the schema to Swift unchanged.
- `Tool<Input: Codable, Output: Codable>(name:description:parameters:[ToolParameter], handler:)` and `ToolCall.execute(with:)` provide typed helpers.
- `ToolCall { function: { name, arguments: [String: JSONValue] }, id: String? }`.
- `ToolCallFormat` cases: `json`, `lfm2`, `xml_function`, `qwen3_5`, `glm4`, `gemma`, `gemma4`, `kimi_k2`, `minimax_m2`, `atem`, `mistral`, `llama3`, `gpt_oss`.
- `GenerateParameters.toolCallPolicy` defaults to "conservative recovery and permissive argument validation". Rejected calls surface as `Generation.rejectedToolCall`.

### 2.7 Guided generation, reasoning and VLMs
- `MLXGuidedGeneration` constrains any MLX model to a **JSON Schema or EBNF** using xgrammar. It has no FoundationModels dependency and no OS floor beyond iOS 17 ✅ `Package.swift` comments and README. Use it for strict tool-argument JSON on small models.
- `reasoningConfig` is resolved per model, and `GenerateCompletionInfo.reasoningTokenCount` is reported. `MLXVLM` handles image, video and audio input through `UserInput`.

### 2.8 Speculative decoding: shipped
Source: ✅ `ChatSession.swift`, `SpeculativeDecoding.swift`.
- `SpeculativeDecodingConfig(draftModel: ModelContainer, numDraftTokens: Int = 5, memoryPolicy: SpeculativeDecodingMemoryPolicy? = nil)`.
- A deferred variant, `init(draftModelBytes:numDraftTokens:memoryPolicy:loadDraftModel:)`, loads the draft only if the memory policy admits it. `.recommendedWorkingSet` falls back to normal decoding when main plus draft exceed `GPU.maxRecommendedWorkingSetBytes()`.
- Both models must share a tokenizer vocabulary. `SpeculativeDecodingTelemetry` exposes counts of proposed and accepted tokens.
- On iPhone, a 0.6B draft for a 4B target costs about 0.4 GB extra, and whether it pays off under thermal limits is **UNVERIFIED**, so benchmark it.

### 2.9 Memory controls
Source: ✅ mlx-swift `Source/MLX/Memory.swift`, `GPU+Metal.swift`, `running-on-ios.md`.
- `Memory.cacheLimit: Int` (get and set) is the buffer-recycling pool. It takes effect on the next deallocation; call `Memory.clearCache()` to free immediately. The docs suggest about 20 MB for LLMs on iOS ("`MLX.Memory.cacheLimit = 20 * 1024 * 1024`"). One developer avoided jetsam by cutting the cache from 512 MB to 64 MB [2nd, forum 834805].
- `Memory.memoryLimit: Int`: "Calls to malloc will wait on scheduled tasks if the limit is exceeded. The memory limit defaults to 1.5 times the maximum recommended working set size."
- `Memory.snapshot()` returns `activeMemory`, `cacheMemory` and `peakMemory`. `GPU.deviceInfo()` returns `architecture`, `maxBufferSize`, `maxRecommendedWorkingSetSize` and `memorySize`; `GPU.maxRecommendedWorkingSetBytes()` is also available.
- **Deprecated:** `GPU.set(cacheLimit:)` ("use Memory.cacheLimit property"), `GPU.set(memoryLimit:relaxed:)`, `GPU.cacheLimit`, `GPU.memoryLimit`, `GPU.snapshot()`, `GPU.clearCache()`, and `Memory.withWiredLimit` (the sync variant is a no-op).
- **Wired memory:** `WiredMemoryManager` and `WiredMemoryTicket` come from MLX. MLXLMCommon adds `WiredSumPolicy`, `WiredMaxPolicy` and `WiredFixedPolicy`, plus `WiredMemoryTicket.withWiredLimit(ticket) { … }` and `kind: .reservation` for weights. "Policy-only mode defaults to true on unsupported backends." Treat it as admission control only on iOS; whether wired limits can be changed on iOS is **UNVERIFIED**, and it is likely not possible.
- Weight bytes: sum `nbytes` of the parameters, or the sizes of the `.safetensors` files. Measured: **Qwen3-4B 4-bit ≈ 2.26 GB** resident ✅ `Documentation.docc/wired-memory.md`.

### 2.10 Error handling (critical on iOS)
- mlx-swift: "The default error handler will simply print out the error, then exit." ✅ `Source/MLX/ErrorHandler.swift`.
- Use `try withError { … }` or `try await withError { … }` to turn MLX errors into Swift `throws`. A Metal command-buffer failure becomes the MLX error `"[METAL] Command buffer execution failed: …"` ✅ `ml-explore/mlx mlx/backend/metal/device.cpp`. Backgrounding during generation therefore kills the process unless it is wrapped. A whisper.cpp report says iOS 26.2 crashes apps whose in-flight GPU work is revoked [2nd].

### 2.11 Models (mlx-community)
- Registered architectures ✅ `LLMModelFactory.swift`:
  - Llama family: llama, mistral, mistral3, mixtral.
  - Qwen family: qwen2, qwen3_moe, qwen3_next, qwen3_5, qwen3_5_moe, qwen3_8, qwen3_8_moe.
  - Gemma family: gemma, gemma2, gemma3, gemma3_text, gemma3n, gemma4, gemma4_text, gemma4_unified.
  - phi, phi3, phimoe, smollm3, lfm2, lfm2_moe, granite, granitemoehybrid, gpt_oss, glm4 and its moe variants, deepseek_v2 and v3, olmo2 and 3, olmoe, exaone4, ernie4_5, nemotron_h, mamba2, jamba, falcon_h1, bitnet, and others.
- `LLMRegistry` presets that suit phones:
  - `mlx-community/Qwen3-0.6B-4bit`, `Qwen3-1.7B-4bit`, `Qwen3-4B-4bit` (about 2.26 GB);
  - `Qwen3.5-2B-4bit`;
  - `gemma-3-1b-it-qat-4bit` (`LLMRegistry.gemma3_1B_qat_4bit`);
  - `gemma-3n-E2B/E4B-it-lm-4bit`, `gemma-4-e2b-it-4bit`, `gemma-4-e4b-it-4bit`;
  - `Llama-3.2-1B/3B-Instruct-4bit`, `SmolLM3-3B-4bit`, `LFM2-1.2B-4bit`, `granite-3.3-2b-instruct-4bit`, `exaone-4.0-1.2b-4bit`.
- Embeddings use `EmbedderModelFactory.shared` and `EmbedderRegistry`, for example `.nomic_text_v1_5` ✅ `Libraries/MLXEmbedders/README.md`. `MLXRerankers` also exists.

### 2.12 MLXFoundationModels bridge (iOS 27 SDK)
- `MLXLanguageModel` conforms to `FoundationModels.LanguageModel`, so `LanguageModelSession(model: mlxModel)` gets `@Generable` output, `Tool`s and streaming.
- Capabilities are declared explicitly as `[.guidedGeneration]` (the default), `.toolCalling`, `.reasoning` and `.vision`. `availability` returns `.available`, `.downloading` or `.unavailable(...)`.
- Build it with `MLXLanguageModel(configuration:capabilities:weightsLocation:load:)` or `#huggingFaceLanguageModel(...)`. It is gated by `@available(iOS 27…)` ✅ `Libraries/MLXFoundationModels/README.md`.
- **Relevance:** this is optional, but it would let one Swift "FM provider" code path serve both Apple's model and MLX models. Sherpa's agent loop lives in Dart, so the plain `ChatSession` path is simpler. Revisit if the iOS floor reaches 27.

---

## 3. Apple Foundation Models framework (optional built-in provider)

Framework availability: iOS, iPadOS, Mac Catalyst, macOS and visionOS **26.0**; watchOS 27.0 ✅ https://developer.apple.com/documentation/foundationmodels

### 3.1 Availability and devices
- `SystemLanguageModel.default.availability` returns `.available` or `.unavailable(reason)`. Reasons: `.deviceNotEligible`, `.appleIntelligenceNotEnabled`, `.modelNotReady` (downloading, or other system reasons). `isAvailable: Bool` ✅ …/systemlanguagemodel, …/availability-swift.enum/unavailablereason.
- Apple Intelligence devices (support page dated Sep 14, 2026): **iPhone 15 Pro and Pro Max, all iPhone 16 and later, iPhone Air, iPad mini (A17 Pro), iPads with M1 or later**. It needs up to 8 GB of storage, or up to **14 GB** on iPhone 17 Pro/Pro Max, iPhone Air and M4 iPads with at least 12 GB ✅ https://support.apple.com/en-us/121115. Region and language gating also applies: `supportedLanguages` and `supportsLocale(_:)`.
- **The model is versioned with the OS.** There are "3 model versions that align with: 26.0–26.3, 26.4, 27.0" ✅. Version Sherpa's prompts for each.

### 3.2 Session API
```swift
let session = LanguageModelSession(model: SystemLanguageModel.default, tools: [...], instructions: "...")
let r = try await session.respond(to: prompt, options: GenerationOptions(samplingMode: .greedy, temperature: nil, maximumResponseTokens: 512))
for try await snapshot in session.streamResponse(to: prompt) { /* snapshot.content = FULL partial so far */ }
session.prewarm(promptPrefix: Prompt("..."))   // "only use prewarm when you have a window of at least 1 second"
session.transcript; session.isResponding; session.usage (27)
```
✅ …/languagemodelsession, …/prewarm(promptprefix:), …/generationoptions.
- **Streaming yields snapshots, not deltas:** `ResponseStream` is "an async sequence of snapshots of partially generated content." The Swift bridge must diff consecutive snapshots before emitting token deltas to Dart.
- `GenerationOptions`: `init(samplingMode:temperature:maximumResponseTokens:)`. `init(…toolCallingMode:)` is iOS 27. `sampling:` is deprecated in favour of `samplingMode`.
- New in iOS 27:
  - `ContextOptions(reasoningLevel: .light, .moderate or .deep)`, which applies to reasoning-capable models;
  - `metadata:` overloads;
  - `DynamicProfile` and `Profile` for runtime tools and instructions;
  - `SessionProperty`;
  - image `Attachment`s (multimodal);
  - the Vision `OCRTool` and `BarcodeReaderTool` ✅ updates/foundationmodels.

### 3.3 Tools and bridging Dart tool schemas
- `protocol Tool<Arguments, Output>: Sendable` has `name`, `description`, `parameters: GenerationSchema`, `includesSchemaInInstructions`, and `func call(arguments: Arguments) async throws -> Output`. `Arguments` conforms to `ConvertibleFromGeneratedContent`; `Output` conforms to `PromptRepresentable` ✅ …/tool.
- Apple's guidance: keep it to **3–5 tools per request** and short descriptions, because tool definitions consume context ✅ "Managing the context window".
- **Runtime schemas:** `DynamicGenerationSchema` has object, array (`arrayOf:minimumElements:maximumElements:`), `anyOf`, `referenceTo` and `type:guides:` forms. Pass it to `GenerationSchema(root:dependencies:) throws`. `GeneratedContent` conforms to `Generable`, has `init(json:)` and `jsonString` ✅.
- A Dart JSON schema can therefore be bridged like this (sketch, not compiled, **UNVERIFIED**):
  ```swift
  @available(iOS 26.0, *)
  struct DartTool: Tool {
    let name: String; let description: String; let parameters: GenerationSchema   // built from the JSON schema via DynamicGenerationSchema
    let invoke: @Sendable (String) async throws -> String                          // JSON args -> Dart -> result text
    func call(arguments: GeneratedContent) async throws -> String { try await invoke(arguments.jsonString) }
  }
  ```
- iOS 27 `GenerationOptions.ToolCallingMode` is `.allowed`, `.disallowed` or `.required`. With `.required` "you must define an exit condition…".

### 3.4 Guided generation
- The `@Generable(description:)` and `@Guide(description:)` macros, plus guides such as `.range(1...10)`, `.minimum`, `.maximum`, `.minimumCount`, `.maximumCount` and `.anyOf`.
- `respond(to:generating:includeSchemaInPrompt:options:)` and `respond(to:schema:…)` take a `GenerationSchema` and return `GeneratedContent`. Schemas consume tokens.

### 3.5 Context window and token counting
- "Apple's on-device foundation model has a context window of **4096 tokens per session**." Exceeding it throws `LanguageModelError.contextSizeExceeded` (iOS 27) or `LanguageModelSession.GenerationError.exceededContextWindowSize` (iOS 26). The guidance is to start a new session, rehydrate with `init(model:tools:transcript:)` and retry ✅ "Managing the context window".
- `contextSize: Int` is `@backDeployed(before: iOS 26.4)` and available from 26.0. `tokenCount(for: Instructions) async throws -> Int` is **iOS 26.4+** ✅.
- PCC context is **32K** ✅ "Adding server-side intelligence with Private Cloud Compute".

### 3.6 Adapters are dead on OS 27
- The Adapter Training Toolkit page says: "Version 26.0.0 is the last release of this toolkit and is not compatible with macOS, iOS, iPadOS, or visionOS 27 and later" ✅ https://developer.apple.com/apple-intelligence/foundation-models-adapter/
- An Apple staff forum reply (Jun 2026) says: "we're no longer supporting adapters as of OS 27" [Apple staff, forum 831314].
- The iOS 26 `SystemLanguageModel.Adapter` docs pages now return 404.
- **Don't build on adapters.** For custom models, Apple points to Core AI (§4.2).

### 3.7 iOS 27 additions relevant to Sherpa
- `protocol LanguageModel: Sendable` has `capabilities: LanguageModelCapabilities` (`.toolCalling`, `.guidedGeneration`, `.reasoning`), `associatedtype Executor: LanguageModelExecutor` and `executorConfiguration`.
- `LanguageModelExecutor` has `init(configuration:)`, `prewarm(model:transcript:)` and `respond(to: LanguageModelExecutorGenerationRequest, model:, streamingInto: LanguageModelExecutorGenerationChannel) async throws` ✅ …/languagemodel, …/languagemodelexecutor.
- `PrivateCloudComputeLanguageModel()` has `availability` (`.systemNotReady`), `quotaUsage` (`isLimitReached`, `status`, `limitIncreaseSuggestion.show()`, `resetDate`) and `Error.quotaLimitReached`. It needs the managed entitlement **`com.apple.developer.private-cloud-compute`** ✅.
- PCC eligibility: "Enrolled in the App Store Small Business Program", "fewer than 2 million first-time app downloads", and the entitlement assigned. There is no cloud API cost now; "expanded access … for a fee in the future". If the threshold is exceeded you must "migrate … within 6 months" ✅ https://developer.apple.com/private-cloud-compute/
- `LanguageModelError` cases: `contextSizeExceeded`, `rateLimited`, `refusal`, `timeout`, `guardrailViolation`, `unsupportedCapability` and `unsupportedTranscriptContent`. On iOS 26, fall back to `LanguageModelSession.GenerationError` ✅.
- `CoreAILanguageModel`, from the `apple/coreai-models` `CoreAILM` product, and `MLXLanguageModel` bring open-weight models into `LanguageModelSession` ✅ updates/foundationmodels.

### 3.8 Background behaviour
- iOS 26 `GenerationError.rateLimited`: "This error will only happen if your app is running in the background and exceeds the system defined rate limit" ✅. The system model **is usable from the background**, because it runs out of process and so isn't subject to the app's GPU ban, but it is rate-limited. `prewarm` may not load assets "if your app is running in the background".

---

## 4. Core ML, Core AI, ANE, ExecuTorch, embeddings, STT and TTS

### 4.1 Core ML (still supported)
- Core ML is a long-lived API (iOS 11+). Its last feature drop was June 2024 (iOS 18): `MLTensor`, `MLState` stateful prediction (which holds the KV cache), multifunction programs and Core ML Tools 8 compression ✅ updates/coreml.
- The Core ML overview now says: "If your app integrates AI models using the latest architectures and inference techniques, see Core AI." Core ML is effectively legacy for new neural nets.

### 4.2 Core AI (new in iOS 27)
- Availability: iOS, iPadOS, macOS, tvOS, visionOS and watchOS **27.0** ✅ https://developer.apple.com/documentation/coreai
- `.aimodel` format and API:
  - `AIModel(contentsOf:options:) async` specialises the model for the device, which "can take a significant amount of time";
  - `model.loadFunction(named:) -> InferenceFunction?`;
  - `InferenceFunctionDescriptor`, `NDArray` with `MutableView` and `View`, `ComputeStream`, `ComputeUnitKind`, `AIModelCache`, `SpecializationOptions`;
  - ahead-of-time compilation with `coreai-build`;
  - the Metal Toolchain is required in Xcode.
- It runs on the CPU, GPU or ANE, and the choice is automatic based on how the model was exported.
- **`apple/coreai-models`** needs iOS/macOS 27 and Xcode 27. Products: `CoreAILM`, `CoreAISpeech`, `CoreAIDiffusion`, `CoreAISegmentation`, `CoreAIObjectDetection`, …
  - LLM export: `uv run coreai.llm.export Qwen/Qwen3-0.6B --platform iOS`. The iOS default compression is `4bit_weight_palettized_group32`.
  - `CoreAILanguageModel(resourcesAt:) async` conforms to FM `LanguageModel` ✅ README, `models/README.md`, `Package.swift`.
  - The repo also ships Claude Code skills (`/plugin marketplace add …coreai-models`).
- **For Sherpa:** Core AI is an iOS 27-only, ANE-capable path. Its pull is better energy and thermals for embeddings, STT and small LLMs, and **it is the only engine that can legally run inference in the background on iPhone** (with the ANE entitlement, §6.2). **Re-evaluate it in 2027**; MLX stays primary for model breadth.

### 4.3 ExecuTorch (PyTorch)
- `main` is version **1.6.0** in development. SwiftPM uses branches named `swiftpm-<version>`; the docs' example is `swiftpm-1.4.1`, and nightlies look like `swiftpm-1.5.0.20260909`. **Minimum iOS 17 / macOS 14** ✅ `docs/source/using-executorch-ios.md`.
- Frameworks: `executorch`, `executorch_llm`, `backend_coreml`, **`backend_mlx`** (iOS experimental), `backend_xnnpack`, `kernels_llm`, `kernels_optimized`, `kernels_quantized`, `kernels_torchao`. Backends need `-force_load`/whole-archive linking for static registration.
- **The MPS backend is gone from `main`.** It no longer appears in the backends table, and `backends/apple/mps/*` returns 404. The MLX backend has replaced it ✅ `docs/source/backends-overview.md`.
- The Core ML backend needs iOS 16+ and runs fp32/fp16 on CPU, GPU or ANE ✅ `backends/coreml/coreml-overview.md`.
- The LLM runners `TextRunner` and `MultimodalRunner` (`import ExecuTorchLLM`) are **experimental** ✅ `docs/source/llm/run-on-ios.md`.
- **Verdict:** only worth it if Sherpa wants the same `.pte` on Android and iOS. MLX has broader LLM coverage on iOS.

### 4.4 Embeddings
- Options:
  - `MLXEmbedders` (GPU), e.g. `nomic_text_v1_5`;
  - `NLContextualEmbedding` (iOS 17+; BERT-style contextual vectors; call `requestAssets` first) ✅;
  - `NLEmbedding`;
  - a Core AI or Core ML export (ANE).
- MLX is the fastest to ship. An ANE export is UNVERIFIED for quality and speed.

### 4.5 Speech-to-text
- **SpeechAnalyzer** is a `final actor` (iOS 26+). Its modules:
  - `SpeechTranscriber(locale:preset:)` or `(locale:transcriptionOptions:reportingOptions:attributeOptions:)` for "normal conversation and general purposes". `SpeechTranscriber.isAvailable` is a hardware check;
  - `DictationTranscriber`, "compatible with older devices";
  - `SpeechDetector` (VAD).
- Assets go through `AssetInventory.assetInstallationRequest(supporting:)` then `.downloadAndInstall()`. Locale reservations use `reserve(locale:)` and `maximumReservedLocales`. Assets are system-managed and shared across apps ✅ …/speech, …/speechtranscriber, …/assetinventory.
- June 2026 additions: `AssetInputSequenceProvider`, `CaptureInputSequenceProvider` and `AnalyzerInputConverter` ✅ updates/speech.
- `SFSpeechRecognizer` (iOS 10+) is the fallback below iOS 26.
- Open-source alternative: argmax `WhisperKit`, now in the `argmax-oss-swift` package (with TTSKit and SpeakerKit). It needs iOS 16+ and uses Core ML/ANE ✅ `argmaxinc/WhisperKit` `Package.swift` and README.

### 4.6 Text-to-speech
- `AVSpeechSynthesizer` offers `speak(_:)`, `write(_:toBufferCallback:)` and `write(_:toBufferCallback:toMarkerCallback:)` for streaming PCM, plus `usesApplicationAudioSession` and `requestPersonalVoiceAuthorization` ✅ …/avfaudio/avspeechsynthesizer.

---

## 5. Memory

| API / entitlement | Facts | Source |
|---|---|---|
| `com.apple.developer.kernel.increased-memory-limit` (Bool) | iOS 15+, visionOS 2.5. "Core features of your app may perform better by exceeding the default app memory limit **on supported devices**… make sure your app still behaves correctly if additional memory isn't available… only available on some device models. Call `os_proc_available_memory`." It must be in the provisioning profile; an entitlements-file entry alone doesn't work. Verify the App Store build actually carries it (DTS). | ✅ entitlement doc; [Apple DTS] forums 770868 and 685084 |
| `com.apple.developer.kernel.increased-debugging-memory-limit` | "by design … will never be included in release builds". It gave about +512 MB on a 12 GB iPhone in testing. **Never rely on it.** | [Apple DTS] forum 770868; [2nd] forum 834805 |
| `com.apple.developer.kernel.extended-virtual-addressing` | iOS 14+. Gives a larger **address space**, not more RAM ("games that memory map assets to stream to the GPU"). In one report it didn't change the 6 GB cap. Only useful when mmapping multi-GB weights, which is the llama.cpp style. | ✅ entitlement doc; [2nd] forum 834805 |
| `os_proc_available_memory() -> size_t` | iOS 13+. Returns "the current memory limit minus the memory footprint", or 0 when over the limit. Advisory: don't cache it, and it's cheaper than `task_info`. | ✅ …/os/os_proc_available_memory |
| `UIApplication.didReceiveMemoryWarningNotification` | No `userInfo`. | ✅ |
| `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue:)` | Starts inactive, so call `activate()`. Events: `.normal`, `.warning`, `.critical`, `.all`. | ✅ |
| `MTLDevice.recommendedMaxWorkingSetSize: UInt64` | iOS 16+. "how much memory … this GPU device can allocate without affecting its runtime performance." MLX bases its cache and limits on it. | ✅ |

**Approximate jetsam limits.** These are all **[2nd] or UNVERIFIED**; Apple publishes no table. Measure with `os_proc_available_memory()` plus `task_vm_info.phys_footprint`.

| Device RAM | Example devices | Observed foreground limit | With increased-memory-limit |
|---|---|---|---|
| 4 GB | iPhone 12, 12 mini | ~2.1 GB ("ActiveHard 2098 MB") [2nd, forum 688973] | unknown |
| 6 GB | iPhone 12 Pro – 15 / 15 Plus | UNVERIFIED (assume ~3 GB) | UNVERIFIED |
| 8 GB | iPhone 15 Pro, 16 / 16 Pro Max | UNVERIFIED | **~6,144 MB** (16 Pro Max) [2nd, forum 834805, Jun 2026] |
| 12 GB | iPhone 17 Pro Max | — | **~6,144 MB**; ~6,656 MB with the debugging entitlement (dev only) [2nd] |
| 16 GB | iPad Air M-series | ~5–6 GB (App Store build) | ~15 GB in a dev build; DTS suspects a signing issue in the App Store build [2nd/DTS, forum 770868] |
| WKWebView WebContent | any iPhone | ~1.5 GB "soft" limit; ActiveHard 2048 MB seen on a 12 GB iPhone 17 Pro. **The entitlement doesn't apply** (WebKit WONTFIX). | [2nd] WebKit Bugzilla 277848 and 274637; forum 823061 |

DTS also warns that limits on a dedicated test device are "often … MUCH better than you'll get on a real world device".

**Budget rule (proposal):**

    weights + KV + activations ≤ 0.6 × os_proc_available_memory()

Measure after launch, then re-check before each model load.

---

## 6. Background execution

### 6.1 The GPU rule
- Metal docs: "iOS and tvOS restrict a background app's access to the GPU… If a Metal command queue tries to schedule command buffers after the app moves in the background, the system prevents those commands from executing."
- After entering the background, "if Metal sees a new command buffer from your app, it returns an error, rather than scheduling the command buffer". The command buffer's `status` is `.error` and its `error` is `MTLCommandBufferError.Code.notPermitted`, which means "a process doesn't have access to a GPU device".
- Required behaviour: stop committing on deactivation, and in `applicationDidEnterBackground` call `waitUntilScheduled()` on the last buffer ✅ https://developer.apple.com/documentation/metal/preparing-your-metal-app-to-run-in-the-background
- **Consequence for MLX:** `generate` must be paused at `sceneWillResignActive` or `willResignActiveNotification`, and must run under `withError`; otherwise the process exits (§2.10).

### 6.2 BGContinuedProcessingTask (iOS/iPadOS 26+, Mac Catalyst 26)
- It starts in the foreground, "only in response to someone's action", and the system shows its progress in a **system Live Activity** with a cancel button.
- `BGContinuedProcessingTaskRequest(identifier:title:subtitle:)`. The identifier is prefixed with the bundle ID.
- Fields: `strategy` is `.queue` (the default) or `.fail`; `requiredResources` is `.gpu`; `title`/`subtitle`; `task.updateTitle(_:subtitle:)`.
- Progress is reported through `ProgressReporting` (`task.progress`): "The system prioritizes the termination of tasks that reflect minimal or no progress."
- Expiration arrives via `task.expirationHandler`. Note: "The system cancels any running tasks if a person closes the app in the app switcher, but the app doesn't receive an indication."
- What it can do in the background: the network, intensive CPU work (Core Image, Vision, Accelerate), and the GPU "on supported devices" ✅ https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados
- **GPU access** needs all of the following ✅ …/resources/gpu and …/com.apple.developer.background-tasks.continued-processing.gpu:
  - `if BGTaskScheduler.supportedResources.contains(.gpu) { request.requiredResources = .gpu }`;
  - the **Background GPU Access** entitlement `com.apple.developer.background-tasks.continued-processing.gpu = true` (iOS/iPadOS 26);
  - a supported device: "Not all devices support background GPU use".
- DTS (Kevin Elliott, Sep 2025): "currently only supported on iPad's with an M3 or better (and not supported on any iPhone)". No extra approval is needed [Apple DTS, forum 801229]. iPhone 15 Pro and 16 Pro report `false` [2nd, forum 816774, Feb 2026]. **iOS 27 status is UNVERIFIED**, so check at runtime.
- **New in iOS 27:** the **Background Inference** entitlement `com.apple.developer.background-tasks.continued-processing.inference` "lets your app's critical inference work finish on the Neural Engine… The system also requires the entitlement for **any Neural Engine access while your app is in the background**, regardless of whether it's running a continued background task. You can perform inference with Core AI, Core ML, or Metal Performance Shaders Graph" ✅. **This is a behaviour change:** without it, background ANE use (Core ML embeddings, WhisperKit) on iOS 27 is presumably refused.
- Info.plist: add the identifiers to `BGTaskSchedulerPermittedIdentifiers`. A wildcard suffix (`<bundle>.agentrun.*`) for dynamic IDs is described by community sources citing WWDC25 session 227 [2nd]. A forum thread reports "No launch handler registered" with wildcard IDs on a beta [2nd, forum 799126]. **Test it.**

### 6.3 Other background tools
- `beginBackgroundTask(withName:expirationHandler:)` is for finishing work: `applicationDidEnterBackground` "has five seconds". "Choosing background strategies" cites "up to 30 seconds". Read `backgroundTimeRemaining`. It returns `.invalid` if not possible ✅ …/extending-your-app-s-background-execution-time.
- `BGProcessingTaskRequest` (`requiresExternalPower`, `requiresNetworkConnectivity`) needs the `processing` background mode. It runs "only when the device is idle… terminates any background processing tasks … when the user starts using the device" ✅. It has no GPU (iOS 26). It suits re-indexing embeddings on the CPU or the ANE (the latter needs the iOS 27 entitlement, UNVERIFIED).
- **App Intents `LongRunningIntent` (iOS 27)** inherits `ProgressReportingIntent`. Call `performBackgroundTask(options: LongRunningTaskOptions, operation:)` (with an optional `onCancel:`) and pass **`LongRunningTaskOptions.requiresGPU`**. "the system gives tasks 30 seconds … unless you use the methods of this protocol". Progress must be reported regularly ✅ …/appintents/longrunningintent. Device support for `.requiresGPU` is UNVERIFIED; presumably it matches §6.2.
- **The Dart isolate keeps running** while the process has background time (a BG task or assertion), so the Dart agent loop, tool calls and remote-LLM calls can continue. Only *local GPU* inference must pause.

### 6.4 Model downloads
- Background `URLSession` ✅ https://developer.apple.com/documentation/foundation/downloading-files-in-the-background:
  - Create it with `URLSessionConfiguration.background(withIdentifier:)`. Use one session with many tasks; a rate limiter delays tasks started from the background, and the delay "increases each time the system resumes or relaunches your app".
  - `sessionSendsLaunchEvents = true`; `isDiscretionary` defaults to false. "transfers started while your app is in the background … the system assumes this property is true".
  - Set `countOfBytesClientExpectsToReceive` and optionally `earliestBeginDate`.
  - Implement `application(_:handleEventsForBackgroundURLSession:completionHandler:)` and `urlSessionDidFinishEvents(forBackgroundURLSession:)`. Move the file inside `urlSession(_:downloadTask:didFinishDownloadingTo:)` before returning.
  - Limits: HTTP(S) only, redirects are always followed (relevant for HF CDN redirects), and a delegate is required.
- Resume ✅ …/pausing-and-resuming-downloads: `cancel(byProducingResumeData:)`, or `NSURLSessionDownloadTaskResumeData` in the error's `userInfo`, then `downloadTask(withResumeData:)`. "downloads that use a background configuration will handle resumption automatically."
- `allowsCellularAccess` (default true), `allowsExpensiveNetworkAccess` and `allowsConstrainedNetworkAccess` (iOS 13) should be bound to a user "Wi-Fi only" setting. These were not re-verified today.
- Whether HF's signed, expiring CDN URLs survive long resumes is **UNVERIFIED**.
- **Background Assets, Apple-hosted (iOS 26+):**
  - "Apple-Hosted Background Assets hosts **up to 200GB of compressed assets**… on all platforms except watchOS". It is available "for apps on TestFlight or the App Store" and is meant for ML models, among other things.
  - Needs a **Background Download app extension** (Apple-Hosted, Managed template) with **App Groups**. Info.plist keys: `BAHasManagedAssetPacks`, `BAUsesAppleHosting`, `BAAppGroupID`.
  - API: the `actor AssetPackManager` with `.shared`, `assetPack(withID:)` (deprecated in 27 → `manifest`), `ensureLocalAvailability(of:requireLatestVersion:)`, `statusUpdates(forAssetPackWithID:)`, `contents(at:)` (memory-mapped `Data`), `descriptor(for:)`, `url(for:)`, `checkForUpdates()` and `remove(assetPackWithID:)`.
  - Download policies are essential (before first launch), prefetch, or on-demand. The extension adopts StoreKit `StoreDownloaderExtension` ✅ …/backgroundassets, …/assetpackmanager, …/downloading-apple-hosted-asset-packs.
  - **Use this only for Sherpa-curated default models**, and only if the model licences allow redistribution. User-chosen Hugging Face models still use `URLSession`.
- Storage hygiene (standard practice, not re-verified): put weights in Application Support with `isExcludedFromBackup = true`. Use file protection `.completeUntilFirstUserAuthentication` (or weaker) so background tasks can read weights while the device is locked.

---

## 7. Thermal and power
- `ProcessInfo.processInfo.thermalState` is `.nominal`, `.fair`, `.serious` or `.critical`. `thermalStateDidChangeNotification`: "you must access the thermalState prior to registering". The guidance for `.critical` is to "Reduce usage of the CPU, GPU, and I/O … to the minimum level required for user interaction" ✅.
- `isLowPowerModeEnabled` is paired with the `NSProcessInfoPowerStateDidChange` notification. Low Power Mode means "Reducing CPU and GPU performance… Pausing discretionary and background activities" ✅.
- Proposed policy:

  | State | Action |
  |---|---|
  | nominal / fair | full speed |
  | serious | prefer a smaller model or Foundation Models; lower prefill step; throttle decode with sleeps between tokens; disable speculative decoding |
  | critical | pause local generation at a token boundary, persist the KV cache, offer a remote provider |
  | Low Power Mode | default to the smaller model and no background prefetch |

---

## 8. System surfaces

- **Live Activities (ActivityKit, iOS 16.1+):**
  - Start in the foreground with `Activity.request(attributes:content:pushType:)` (or with `style:`; `alertConfiguration:start:` schedules one).
  - Update with `update(_:)` or `update(_:alertConfiguration:)`. Requires `NSSupportsLiveActivities = YES` and a widget extension (SwiftUI).
  - An activity lasts up to **8 h** active, plus up to 4 h on the Lock Screen (12 h maximum). Static plus dynamic data **≤ 4 KB** ✅ …/displaying-live-data-with-live-activities.
  - `BGContinuedProcessingTask` already provides a system progress UI, so a custom Live Activity is only needed for richer state, such as an agent step name or a token count.
- **App Intents and App Shortcuts:** `AppShortcutsProvider` (iOS 16+) ✅. iOS 26 adds `IntentModes` (`supportedModes`) ✅. iOS 27 adds `LongRunningIntent`, `CancellableIntent`, `UndoableIntent`, `IntentExecutionTargets` and Apple Intelligence "app schema domains" ✅ updates/appintents. Flutter has no official App Intents integration (flutter/flutter#170589) [2nd], so write the intents in Swift and call into the Dart engine.
- **Control widgets:** `ControlWidget` (iOS 18+; macOS/watchOS 26) ✅ for actions in Control Center, the Lock Screen and the Action Button, e.g. "Ask Sherpa".
- **ASWebAuthenticationSession** (iOS 12+):
  - `init(url:callback:completionHandler:)` with `ASWebAuthenticationSession.Callback.customScheme(_:)` or **`.https(host:path:)`**. These are **iOS 17.4+**; the host "must be a member of a domain associated with the app".
  - `prefersEphemeralWebBrowserSession` (iOS 13+) must be set before `start()`; "Safari always respects the request".
  - Also: `presentationContextProvider`, `additionalHeaderFields`, `canStart`.
  - The older `init(url:callbackURLScheme:completionHandler:)` is deprecated ✅ …/aswebauthenticationsession.
  - HTTPS callbacks reportedly need the **`webcredentials:`** associated-domain service and an AASA file that isn't served behind a redirect [2nd, Auth0 and forums]. Use it for MCP or provider OAuth, with ephemeral sessions turned on.

---

## 9. WKWebView sandbox for untrusted HTML

**Primitives** (all ✅ developer.apple.com/documentation/webkit/...):
- `WKContentRuleListStore.default().compileContentRuleList(forIdentifier:encodedContentRuleList:) async throws -> WKContentRuleList?` (iOS 11+), then `configuration.userContentController.add(list)`.
  - A block-all rule: `[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]`.
  - Resource types WebKit understands include `document`, `script`, `font`, `raw`, **`websocket`**, **`fetch`**, `other`, `media`, `popup`, **`ping`**, `csp-report`. A rule with no `resource-type` applies to all of them ✅ WebKit `Source/WebCore/loader/ResourceLoadInfo.cpp`.
- `WKWebsiteDataStore.nonPersistent()` (iOS 9+) keeps data in memory only.
- `loadHTMLString(_:baseURL:)`. **Origin semantics:**
  - `baseURL: nil` → WebKit substitutes `aboutBlankURL()` ✅ (`WebPage::loadData`: `if (loadParameters.baseURLString.isEmpty()) baseURL = aboutBlankURL();`). A top-level about:blank document with no opener gets an **opaque ("null") origin**: no storage APIs, and requests carry `Origin: null` (standard web semantics; not device-tested, UNVERIFIED on WebKit).
  - `baseURL: about:blank` is effectively the same.
  - `baseURL: https://x` → the page **is** that origin: it can read and write that origin's storage in the data store, and relative URLs resolve to the network. Avoid this.
  - Custom scheme `sherpa-sandbox://doc/` with a `WKURLSchemeHandler` registered via `setURLSchemeHandler(_:forURLScheme:)` (iOS 11+) → a stable tuple origin. Every subresource on that scheme is served or denied by your handler. You can't register `http` or `https`, and calling it twice is a programmer error. WebKit registers a non-HTTP base URL's scheme as "handled by scheme handler" ✅ same file.
- `WKScriptMessageHandlerWithReply` handles `userContentController(_:didReceive:replyHandler:)` from JS via `window.webkit.messageHandlers.<name>.postMessage()` ✅. Register it in a **named `WKContentWorld.world(name:)`** (iOS 14+), not `.page`, so page scripts can't tamper with the bridge's JS. Remember that "the content world doesn't apply to the current document or DOM".
- `limitsNavigationsToAppBoundDomains` (iOS 14+) works with the Info.plist key `WKAppBoundDomains` (up to 10 domains). Once app-bound domains are enabled, non-app-bound pages lose `evaluateJavaScript`, user scripts, `messageHandlers` and cookie APIs. "HTML strings … are always treated as app bound domains" [webkit.org blog 10882]. **It adds little for the sandbox case.**
- `javaScriptCanOpenWindowsAutomatically` defaults to **false on iOS** ✅. Also implement a `WKUIDelegate` that returns nil from `createWebViewWith`.
- `WKWebpagePreferences.allowsContentJavaScript` (iOS 14+) turns JS off. `isLockdownModeEnabled` (iOS 16+) forces Lockdown Mode for this view.
- **New in iOS 26.4:** `securityRestrictionMode: WKSecurityRestrictionMode` with `.none`, `.maximizeCompatibility` (JIT off, more MTE coverage, *separate isolated WebContent processes*) or `.lockdown`. It applies to main-frame navigations ✅.
- `isInspectable` (iOS 16.4+) defaults to false. Keep it false in release builds.

**CSP:**
- WebKit enforces `<meta http-equiv="Content-Security-Policy">` (standard behaviour). `ContentSecurityPolicyResponseHeaders` reads `Content-Security-Policy` from any `ResourceResponse`, with no scheme check ✅ WebKit source. A CSP header on an `HTTPURLResponse` from a `WKURLSchemeHandler` should therefore be enforced, but this is **UNVERIFIED on device**.
- CSP covers neither top-level navigation, WebRTC nor DNS prefetch. Cancel navigations in `decidePolicyFor` and keep JS off to make WebRTC moot.

**Recommended configuration** (sketch):
```swift
let block = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
let rules = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "sherpa.blockall", encodedContentRuleList: block)
let cfg = WKWebViewConfiguration()
cfg.websiteDataStore = .nonPersistent()
if let rules { cfg.userContentController.add(rules) }
cfg.defaultWebpagePreferences.allowsContentJavaScript = false          // default for artifacts/previews
if #available(iOS 26.4, *) { cfg.defaultWebpagePreferences.securityRestrictionMode = .maximizeCompatibility }
cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
let wv = WKWebView(frame: .zero, configuration: cfg); wv.isInspectable = false
// navigationDelegate: allow only the initial load; cancel everything else. Handle webViewWebContentProcessDidTerminate.
wv.loadHTMLString("<!doctype html><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'\">" + untrusted, baseURL: nil)
```
- If interactive JS is required, use a custom-scheme origin. Add a rule-list exception for that scheme only; whether content rules apply to custom schemes is **UNVERIFIED**. Combine it with a CSP header, a named content world for the bridge, and `.lockdown`.
- Write this as Sherpa's own native platform view (`UiKitView`) rather than using `webview_flutter`, which doesn't expose content rule lists (UNVERIFIED for the latest `webview_flutter_wkwebview`).

---

## 10. Observability
- **`OSSignposter`** (iOS 15+) ✅ …/os/ossignposter:
  - `init(subsystem:category:)`, `makeSignpostID()`;
  - `beginInterval(_:id:_:) -> OSSignpostIntervalState`, `endInterval(_:_:_:)`, `withIntervalSignpost(_:id:around:)`, `emitEvent(_:id:)`.
  - Instrument `model.load`, `prefill`, `decode` (one event per N tokens), `tool.call`, `fm.respond` and `download`.
  - Instruments now has a **Foundation Models** template and a **Core AI** instrument and gauge ✅.
- **MetricKit:**
  - iOS 27 adds **`MetricManager`** with `metricReports` and `diagnosticReports` async sequences (`MetricReport`, `DiagnosticReport` are Codable and Sendable), `logHandle(category:)` and `trackLaunchTask`.
  - **`MXMetricManager` is deprecated in 27.2** ✅ …/metrickit, …/mxmetricmanager, updates/metrickit.
  - Useful metrics: `MemoryExceptionDiagnostic` (jetsam), `HangTimeMetric`, `CPUExceptionDiagnostic`, `CPUTimeMetric`, `GPUTimeMetric`, `PeakMemoryMetric`, `ForegroundTerminationMetric`, `TotalBackgroundTimeMetric`.
  - Metric reports arrive at most daily; diagnostics arrive immediately (iOS 15+).
  - Use `MXMetricManager` on iOS 26 and `MetricManager` on iOS 27+.

---

## 11. Flutter-specific

### 11.1 Plugins and SwiftPM
- "As of the 3.44 release, Flutter uses Swift Package Manager to manage iOS and macOS native dependencies." It is on by default; `flutter config --no-enable-swift-package-manager` reverts it ✅ https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-plugin-authors
- Plugin layout: `ios/<plugin_name>/Package.swift`, `Sources/<plugin_name>/`. Depend on `.package(name: "FlutterFramework", path: "../FlutterFramework")`. Put `PrivacyInfo.xcprivacy` under `Sources/<plugin_name>` with `.process(...)`, and load it with `Bundle.module` inside `#if SWIFT_PACKAGE`.
- "Flutter plugins should support both Swift Package Manager and CocoaPods until further notice… the **CocoaPods registry permanently becomes read-only on December 2, 2026**" ✅.
- The current stable is **Flutter 3.47.0** ("documentation … reflects Flutter 3.47") ✅ docs.flutter.dev/release/release-notes.
- **The plugin's `Package.swift` must declare `.iOS("17.0")`** to depend on mlx-swift-lm. The template default is 13.0, and Sherpa's Runner is at 15.0.
- MLX plus swift-syntax makes clean builds take a while. Cache `.build` and DerivedData in CI.

### 11.2 Pigeon
- **Pigeon 29.0.10** (pub.dev, Oct 15, 2026; Dart SDK `^3.11.0`) ✅.
- `@HostApi()` with `@async` generates Swift `async` signatures (Pigeon 28+), and `@FlutterApi()` handles callbacks. `@TaskQueue` runs handlers off the main thread, with platform channels only.
- **`@EventChannelApi()`** is supported on the Swift, Kotlin and Dart generators ✅ pigeon README.
- Pigeon 29's **Native Interop (FFI/JNI) mode is experimental** and rejects event channels, ProxyApis, sealed classes and `@TaskQueue` ✅ CHANGELOG 29.0.0 and 29.0.8.
- **Use platform-channel mode** with an `@EventChannelApi` for token, tool-call and progress streams. Batch tokens every ~16–33 ms to cut channel overhead, and send large blobs as `Uint8List`.

### 11.3 Liquid Glass
- **There is no official Flutter implementation** [2nd]:
  - flutter/flutter#170310 is still open at P3.
  - Cupertino was split out into **`cupertino_ui`**; 1.1.3 shipped Oct 14, 2026 ✅ pub.dev, "no glass" per a single third-party article [2nd].
  - The Flutter blog (Sep 9, 2026) says official Liquid Glass work is "in progress", via a `liquid_glass` branch with unmerged PRs [2nd, issoh.co.jp].
- Options:
  - `liquid_glass_widgets` 1.13.0, shader-based and cross-platform ✅ pub.dev;
  - `native_liquid_glass` 0.3.1 or `liquid_glass_native` 0.3.1, which embed real UIKit or SwiftUI glass as platform views (iOS 26+) ✅ pub.dev;
  - a BackdropFilter approximation.
- iOS 27 adds a user Liquid Glass tint slider [2nd], so a shader imitation will drift from the system look.

---

## 12. Recommendations for Sherpa

1. **Platform floor.** Raise `IPHONEOS_DEPLOYMENT_TARGET` from 15.0 to **17.0**, which is the MLX and ExecuTorch floor. Consider 18.0. Gate iOS 26 features (FM, SpeechAnalyzer, BG continued tasks, Background Assets) and iOS 27 features (PCC, Core AI, LanguageModel, MetricManager, LongRunningIntent) with `#available`. Build with **Xcode 27.1** (the iOS 27 SDK; UIScene is already adopted) on Apple-silicon CI with the Metal Toolchain installed.
2. **Plugin topology.** Create one SwiftPM-first, Pigeon-based plugin, `sherpa_native_ios`, with a podspec until CocoaPods is dropped. It holds these Swift actors:
   - `MlxEngine`
   - `AppleFmProvider`
   - `ResourceMonitor` (memory, thermal and power)
   - `BackgroundCoordinator`
   - `ModelDownloader` (background `URLSession`)
   - `SandboxWebView` (a platform view)

   The Dart core owns conversation state, tool registry and policy. Swift owns tensors and OS lifecycles only.
3. **MLX engine.**
   - Pin `mlx-swift-lm .upToNextMinor(from: "3.32.3")`.
   - Load from **local directories** (`loadContainer(from: URL, using:)`) with a hand-written `TokenizerLoader` over swift-transformers. Skip the MLXHuggingFace macros.
   - Use one `ChatSession` per conversation with `streamDetails`, `tools: [ToolSpec]` from Dart and **manual tool dispatch to Dart**.
   - Set `Memory.cacheLimit` to about 32–64 MB.
   - Set `maxKVSize` and `kvScheme` by tier: `"turbo8v3"`, or `kvBits: 8` as the conservative start.
   - Wrap every generate in `withError`.
   - Persist and restore static-prefix prompt caches, and use `fork(history:)` for sub-agents.
   - Add `MLXGuidedGeneration` for strict JSON tool arguments on models under 2B.
4. **Device tiers (proposal; validate on devices).** Compute the tier from `os_proc_available_memory()` after launch, with increased-memory-limit enabled.

   | Available memory | Default model | Notes |
   |---|---|---|
   | < 2.5 GB | Qwen3-0.6B or 1.7B-4bit, or gemma-3-1b-qat-4bit | |
   | 2.5–4 GB | Qwen3-1.7B or 3B-class 4-bit | |
   | ≥ 5 GB | Qwen3-4B-4bit (~2.3 GB), gemma-4-e4b-it-4bit | |
   | ≥ 6 GB | 8B 4-bit allowed (~4.5 GB) | with warnings |

   Treat speculative decoding as an opt-in experiment.
5. **Lifecycle contract.** On `sceneWillResignActive`:
   1. Stop scheduling MLX work at a token boundary.
   2. Synchronise.
   3. Persist the KV cache and transcript.

   On a memory warning or critical pressure, call `Memory.clearCache()`; if still critical, unload the model and tell Dart. For user-initiated long agent runs, submit a **`BGContinuedProcessingTask`**. In the background:
   - keep the Dart loop, tools and remote providers going;
   - request `.gpu` only when `supportedResources.contains(.gpu)` (M3+ iPads);
   - on iPhone, either pause local inference and resume in the foreground, or hand the step to FM or a remote model, as a product decision.
6. **Foundation Models provider** (iOS 26+, optional):
   - Use it for summaries, titles, classification, memory extraction and tool-argument repair. Its 4K context and per-OS model changes rule it out as the main agent model.
   - Bridge Dart JSON schemas through `DynamicGenerationSchema`, and keep it to 3–5 tools.
   - Diff snapshots into deltas.
   - Call `prewarm(promptPrefix:)` when the composer gains focus.
   - Branch error handling between iOS 26 and 27.
   - Add PCC behind a flag only if Sherpa qualifies (Small Business Program and under 2M downloads), and show its quota UI.
7. **Downloads.**
   - Use a native background `URLSession` driven from Dart: one session, many tasks, persisted resume data, "Wi-Fi only" bound to `allowsExpensiveNetworkAccess`.
   - Exclude weights from backup and use `completeUntilFirstUserAuthentication` protection.
   - If licensing allows, ship one curated default model as an **Apple-hosted Background Assets pack** (essential or prefetch policy). This keeps the IPA small and lets the model update without an app release.
8. **WebView sandbox.** Follow §9: `nonPersistent`, block-all rule list, JS off by default, `baseURL: nil`, CSP meta, `securityRestrictionMode` (26.4+), navigation cancelled, `isInspectable = false`, and a handler for WebContent crashes. For JS-enabled artifacts, add a custom scheme, a named content world and Lockdown mode.
9. **Speech.**
   - STT: SpeechAnalyzer with SpeechTranscriber on iOS 26+, falling back to `DictationTranscriber` when `isAvailable` is false, and `SFSpeechRecognizer` (on-device) on 17–25.
   - TTS: `AVSpeechSynthesizer.write(_:toBufferCallback:)` for streaming.
   - Request the iOS 27 **background inference entitlement** only if ANE models run in the background.
10. **Observability.** Add OSSignposter intervals around every engine stage. Use MetricKit (`MXMetricManager` on iOS 26, `MetricManager` on 27+) and forward `MemoryExceptionDiagnostic` and hang reports into Sherpa's Dart telemetry, opt-in.
11. **Thermal and power.** Implement the §7 policy in `ResourceMonitor` and expose it to Dart as a stream.
12. **System surfaces, phase 2.** App Shortcuts or App Intents ("Ask Sherpa", "Continue last run") in Swift, a Control widget, and a Live Activity only if the system BG-task UI isn't enough. Use `ASWebAuthenticationSession` with `.https` callbacks (17.4+) and ephemeral sessions for OAuth.
13. **Core AI watch item.** Prototype `CoreAILanguageModel` and Core AI embeddings on iOS 27 for energy and background ANE use. Don't make it a dependency until the iOS floor is 27.

## 13. Risks
- **No background GPU on iPhone** (DTS, Sep 2025; iOS 27 unknown). Local agent runs stall when the app is backgrounded. If MLX isn't wrapped in `withError`, the app **exits**, and whisper.cpp reports crashes on GPU revocation on iOS 26.2 [2nd].
- **Jetsam.**
  - About a 6 GB cap even on 12 GB iPhones [2nd]; real-world headroom is lower than on test devices (DTS).
  - Entitlements can silently be missing from App Store builds (codesigning).
  - The debugging entitlement never ships.
  - WKWebView has its own ~1.5–2 GB limit.
- **API churn.** mlx-swift-lm moves fast: 3.x broke 2.x, minor releases are frequent, and there is a large model registry. FM changes every OS release (three model versions within iOS 26–27, adapters removed, error types reworked in 27).
- **Toolchain.** Swift 6.2 or later is required, plus the Metal Toolchain, swift-syntax build time, possible macro-validation friction (UNVERIFIED), and Apple-silicon-only Xcode 27 [2nd].
- **Flutter ecosystem.** CocoaPods becomes read-only on Dec 2, 2026, so plugins carry a dual-support burden. Pigeon FFI is experimental. There is no official Liquid Glass and no official App Intents bridge.
- **Foundation Models.**
  - 4K context.
  - Availability gating by device, region, the user's Apple Intelligence setting and model download.
  - Guardrail refusals.
  - Background rate limits.
  - PCC eligibility, daily quotas, and a 6-month forced migration if Sherpa outgrows the Small Business Program or 2M downloads.
- **Background-task fragility.**
  - Users can cancel a BG task from the system UI.
  - Swiping the app away cancels it without a callback.
  - Low-progress tasks are killed first.
  - Wildcard identifiers have reported bugs [2nd].
- **Background Assets.** Needs an app extension and an App Group inside a Flutter Runner project, works only on TestFlight or the App Store, and model licences must permit Apple hosting and redistribution.
- **WebView.** Content blockers don't cover WebRTC or DNS prefetch, and CSP doesn't cover navigation. JS-enabled untrusted HTML remains the riskiest surface.
- **App Review.** Downloading model weights is data and should be fine. Agent features that download and execute scripts may conflict with guideline 2.5.2 (UNVERIFIED interpretation).

## 14. Open questions for the product owner
1. Minimum iOS: 17 (the MLX floor), 18, or 26 (which removes many fallbacks)? What is the minimum device RAM: do we support 4 GB iPhones?
2. When the user leaves the app mid-run on iPhone, which behaviour do we want? Options: pause and notify, hand off to Apple FM, hand off to a remote provider, or CPU-only MLX (slow; UNVERIFIED feasibility).
3. Should Apple Foundation Models ship as a provider in v1? Do we qualify for **PCC**: are we enrolled in the Small Business Program and expecting under 2M downloads? Are we comfortable with Apple's daily-quota UI?
4. Which default model(s) do we curate, and do their licences (Gemma, Qwen, Llama) allow us to redistribute them via Apple-hosted Background Assets?
5. Can untrusted HTML artifacts ever run JavaScript, or are they render-only?
6. How faithful must the design be to iOS 26/27 Liquid Glass? Shader imitation, a few native platform views, or a neutral Sherpa style?
7. Is iPad a first-class target? M3+ iPads can keep GPU inference running in the background.
8. Do we want opt-in on-device telemetry (MetricKit diagnostics, signpost summaries)?
9. How should gated Hugging Face models and user tokens work: Keychain storage, a per-model auth UX?
10. Is Core AI (iOS 27+) on the 2027 roadmap as a second engine for energy and background ANE use?

## 15. Verification log (load-bearing claims re-checked today against primary sources)

| # | Claim | Primary source re-checked | Result |
|---|---|---|---|
| 1 | iOS 27 has shipped: iOS 27.0.1 (24A446) on Sep 28, 2026; iOS 27.2 beta 4 on Oct 13; Xcode 27.1 on Oct 15 | developer.apple.com/news/releases (re-fetched, grepped "iOS 27.0.1 (24A446)" and "iOS 27.2 beta 4") | ✅ **Corrected the brief's premise** that iOS 26 is current |
| 2 | mlx-swift-lm needs swift-tools 6.2 and `.iOS(.v17)`, depends on mlx-swift `.upToNextMinor(from: "0.32.3")`; latest release 3.32.3 | raw `ml-explore/mlx-swift-lm/main/Package.swift` (re-fetched) and SPI | ✅ |
| 3 | `GPU.set(cacheLimit:)` is deprecated in favour of `Memory.cacheLimit`; `memoryLimit` defaults to 1.5 × `recommendedMaxWorkingSetSize` | raw mlx-swift `GPU+Metal.swift` line 121 ("use Memory.cacheLimit property") and `Memory.swift` | ✅ |
| 4 | FM on-device context is 4,096 tokens; PCC is 32K; `contextSize` is backDeployed before 26.4 | DocC JSON for managing-the-context-window ("window of 4096 tokens per session"), the PCC article ("larger 32K-token context size") and contextSize (`@backDeployed(before: iOS 26.4…)`) | ✅ |
| 5 | Background GPU needs `.gpu` plus the entitlement, and "Not all devices support background GPU use" | DocC JSON `bgcontinuedprocessingtaskrequest/resources/gpu` (re-fetched) | ✅; the device list (M3+ iPads only) is still DTS forum-only, so it is labelled [Apple DTS] |
| 6 | Metal refuses background command buffers ("if Metal sees a new command buffer … it returns an error") with `.notPermitted` | DocC JSON for preparing-your-metal-app-to-run-in-the-background (re-fetched) | ✅ |
| 7 | MLX's default error handler exits the process | raw mlx-swift `ErrorHandler.swift` ("…print out the error, then exit.") and mlx `device.cpp` ("[METAL] Command buffer execution failed") | ✅ |
| 8 | increased-memory-limit is "only available on some device models"; `os_proc_available_memory` returns limit minus footprint | DocC JSON for the entitlement (re-fetched) and `os_proc_available_memory` | ✅; the ~6 GB cap figures stay [2nd] |
| 9 | The iOS 27 Background Inference entitlement is required "for any Neural Engine access while your app is in the background" | DocC JSON `com.apple.developer.background-tasks.continued-processing.inference` (re-fetched) | ✅ |
| 10 | `loadHTMLString(_, baseURL: nil)` loads as about:blank | raw WebKit `WebPage.cpp` (`baseURL = aboutBlankURL();`, 1 match) | ✅; the opaque-origin consequence is standard semantics, not device-tested, so it is marked UNVERIFIED |
| 11 | Flutter uses SwiftPM by default since 3.44; the CocoaPods trunk is read-only on Dec 2, 2026 | docs.flutter.dev for-plugin-authors (re-fetched and grepped) | ✅ |
| 12 | The iOS 27 SDK requires the UIScene lifecycle | TN3187 DocC JSON ("In the next major release following iOS 26, UIScene lifecycle will be required…") | ✅; the Sherpa Runner already has a SceneDelegate |
| 13 | FM adapters are unsupported on OS 27 | foundation-models-adapter page ("Version 26.0.0 is the last release … not compatible with … 27") and an Apple staff forum reply | ✅ |

No load-bearing claim turned out wrong on re-check. The one correction is the brief's assumption about the OS version. Device-level figures (jetsam limits, background-GPU device list, wildcard BG identifiers, HTTPS callback `webcredentials`) remain explicitly labelled as [2nd] or UNVERIFIED.
