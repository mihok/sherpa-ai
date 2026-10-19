# sherpa_apple_ml

iOS-only Flutter plugin with two on-device `ModelProvider`s for Sherpa
(PLAN §2 layer 3/4, R06 §2–3):

| Provider | Engine | Models |
|---|---|---|
| `MlxProvider` (id `mlx`) | mlx-swift-lm **3.32.3** on mlx-swift **0.32.3** (Metal GPU) | MLX-format directories from `mlx-community` that the app downloaded |
| `AppleFoundationModelsProvider` (id `apple_fm`) | Apple Foundation Models, `SystemLanguageModel.default` | the system model, iOS 26+ with Apple Intelligence |

Swift owns tensors, sessions and OS lifecycles only; every decision that can
be made in Dart is made in Dart and unit-tested on the host against a fake of
the Pigeon layer (`package:sherpa_apple_ml/testing.dart`).

> **Status: nothing here has run on iOS, and no Xcode build has finished
> yet.** The Swift code was written from Apple's DocC, the mlx-swift(-lm)
> and swift-transformers sources at the pinned tags, and type-checked on
> Linux against hand-written stand-in modules (see "Verification"). The
> first real compile (macOS CI, Xcode 26.6 / iOS 26.5 SDK) failed in
> `FoundationModelsEngine.swift` on three iOS 27 SDK symbols; those are
> fixed, and Xcode stopped there, so later files are still unchecked.

Versions (checked 2026-10-19 with `git ls-remote --tags`): mlx-swift-lm
3.32.3 (`3b339ad`, 2026-09-30) and mlx-swift 0.32.3 (`1960120`,
2026-09-30) are the latest tags, matching R06 §2.1; swift-transformers
1.3.5 is the latest. `Package.swift` pins mlx-swift-lm and mlx-swift
`.upToNextMinor`, swift-transformers `from: "1.3.0"`.

## Wiring (for the app)

```dart
// Availability for the UI (both never throw; off iOS: unsupported/notIos).
final a = await MlxProvider.availability(layout.libraryPath(model.loadPath)); // dir or a file in it
final s = await AppleFoundationModelsProvider.status();
// a.status: available | downloadable | unsupported; a.reason (AppleMlReason); a.message; a.details

// Providers (one of each per process; both share the native event stream).
final mlx = MlxProvider(models: [
  for (final m in library.models.where((m) => m.format == ModelFormat.mlx && m.usable))
    MlxModelSpec(
      id: m.id,
      directory: layout.libraryPath(m.loadPath),
      displayName: m.displayName,
      preferredContext: m.defaultContextLength ?? 8192,
      toolCalling: true,
    ),
]);
final fm = AppleFoundationModelsProvider();
// A library model:  ModelChoice(providerId: 'mlx', modelId: m.id)
// Apple's model:    ModelChoice(providerId: 'apple_fm', modelId: AppleFoundationModelsProvider.systemModelId)

mlx.register(spec) / mlx.unregister(id);        // library changes
await mlx.forgetConversation(sessionId);         // chat deleted (also fm.forgetConversation)
await mlx.interrupt('thermal_critical');         // optional policy hook → Finish(pause)
await mlx.unload();                              // free the weights (e.g. switching to llama.cpp)
await fm.prewarm(instructions: systemPrompt);    // composer focused, ≥ 1 s before a request (helps a NEW, tool-less chat)
mlx.nativeEvents                                 // memoryWarning / lifecycle (diagnostics)
```

`ModelRequest.cache.sessionId` must be the Sherpa session id: it keys the
native session. Requests without one get a one-off native session.

## Design

### Threading
Flutter delivers host calls on the main thread. Sync calls only read cheap
state or start a `Task`; async calls are `Task { @MainActor in try await … }`
(Pigeon 29) that immediately await an engine **actor** (`MlxEngine`,
`FoundationModelsEngine`), so loading, prefill and decoding never run on main.
Events go through a per-generation `GenerationPump`: text coalesces, batches
flush every ~16 ms (structural/terminal events at once) and **at most 4
batches are in flight**; Dart returns one credit per delivered batch and none
while the subscriber is paused (or, for Foundation Models, while a turn waits
for tool results), so the channel buffer is bounded. One shared
`EventRouter` per backend demultiplexes the single event channel.
Limitation: pausing the subscriber stops *delivery*, not MLX decoding —
`ChatSession` streams are unbounded and expose no backpressure hook.

### History policy (`HistoryPlanner`)
Sherpa's transcript is a tree (edits/retries branch; compaction and
truncation are overlays). MLX `ChatSession` and FM `LanguageModelSession` each
hold one linear transcript plus KV/model state. Per Sherpa session Dart keeps
fingerprints of what the native session holds and decides per request:

* **append** — the native transcript is a prefix of the request and what
  follows is appendable. MLX accepts any roles ending in user/tool (tool
  results, a foreign provider's reply plus a new question): `ChatSession`
  re-renders the template every turn and reuses the longest common token
  prefix, so a changed system prompt, tool list or thinking switch is still
  an append (`instructions`/`tools`/`additionalContext` are updated in place).
  FM accepts exactly one user prompt; its instructions and tools are fixed at
  init, so they are part of the session key.
* **rebuild** — anything else (branch, edited/compacted/truncated message,
  another model, native state lost): MLX `ChatSession(history:)`, FM
  `LanguageModelSession(model:tools:transcript:)` with a `Transcript` built
  from history (instructions + tool definitions, prompts, responses, tool
  calls, tool outputs; `Transcript(entries:)` and every entry initializer are
  public on iOS 26). A rebuild re-prefills the whole prompt.
* **continueAssistant** — the request ends with an assistant message: the
  agent loop continues a reply paused at a token boundary. MLX renders the
  history with a generation prompt, appends the partial reply's tokens and
  generates with `generateTask` (no `ChatSession`); the next turn rebuilds, and
  the paused part plus its continuation are sent as one assistant turn. FM
  cannot continue a reply: it rebuilds with everything and a short user turn
  (`FmProviderConfig.continuePrompt`, with a notice).

After a generation Dart commits what the native side recorded, or
invalidates the session when it did not (cancel, pause, error, rejected tool
call, empty reply — `ChatSession` does not record those). If Swift dropped a
session (memory warning) or the model (MLX error), it says so (global event,
or `sessionLost` / `modelUnloaded` from `mlxGenerate`) and Dart rebuilds and
retries once.

### Tools
* **MLX:** OpenAI-style `ToolSpec`s from Dart (schema annotation keywords
  dropped), rendered by the model's chat template, parsed by mlx-swift-lm's
  format parsers (json, qwen3_5, gemma4, llama3, …). Manual dispatch
  (`toolDispatch == nil`): the reply ends with `Finish(toolCalls)` and the
  results are appended next turn, keeping the KV cache warm.
  `ToolCallComplete`s are sent when the reply ends, because only the final
  `GenerateCompletionInfo.recoveredToolCallCount` says mlx-swift-lm repaired a
  call; then every call of that reply is `repaired: true` (forces approval for
  non-read-only tools). `Generation.rejectedToolCall` becomes a notice plus,
  when the tool is known, a call with `argumentsError`, so the loop tells the
  model instead of running anything. Capability: `ToolCallFormat.prompted`
  (no grammar constrains the output).
* **Foundation Models:** each Sherpa tool becomes a `DartTool: Tool` whose
  `parameters` come from `FmSchemaConverter` (Dart: JSON Schema →
  `DynamicGenerationSchema` IR; Swift maps it 1:1 and calls
  `GenerationSchema(root:dependencies:)`). Unsupported constructs (dynamic
  keys, untyped values, numeric enums, `allOf`) degrade with a
  `fm_schema_lossy` notice. When the model calls a tool, `Tool.call`
  **suspends** in a `ToolBroker` continuation and the call is streamed to
  Dart; after a 150 ms settle window (parallel calls) the Dart stream ends
  with `Finish(toolCalls)`. The agent loop executes it (approvals, MCP, …).
  The next request — the same history plus that assistant message plus a
  result for every open call — resumes the **same** native call
  (`fmSubmitToolResults`) and streams the rest of the reply. Tool errors go
  back as text (`[tool error] …`) so the model can recover; a request that
  does not answer the calls cancels the native turn and rebuilds; an
  unanswered turn expires after 5 min. At most 5 tools are offered (Apple's
  3–5 guidance; extras are dropped with a notice).

### Errors
MLX's default error handler prints and **exits the process** (R06 §2.10).
Every MLX entry point runs inside `withError { }` (task-local handler →
Swift `throw`), and a process-wide handler installed once with the
(deprecated, but only process-wide) `setErrorHandler` records errors raised
outside any task scope (e.g. Metal completion threads) instead of exiting;
the engine checks that relay after every token, fails the generation, drops
the model and tells Dart (`modelUnloaded`). Swift classifies errors into
codes (`lib/src/common/errors.dart`): out of memory (MLX "Insufficient
Memory"), engine error, unsupported/model-not-found (`ModelFactoryError`),
context overflow (FM `GenerationError.exceededContextWindowSize`), rate
limited, busy, …; FM refusals and guardrail violations end with
`Finish(refusal / contentFilter)`. The iOS 27 error types
(`LanguageModelError`, `LanguageModelSession.Error`,
`SystemLanguageModel.Error`, `GeneratedContent.ParsingError`) are not
handled: the app builds with the iOS 26 SDK, which does not declare them, and
apps built with Xcode 26 keep receiving `GenerationError` (DocC
deprecation note on `GenerationError`). When moving to Xcode 27, map them
behind a compile-time SDK check, including `concurrentRequests` → busy,
`assetsUnavailable` → assetsUnavailable and `ParsingError` → server.

### Background, memory, thermal
* **No background GPU on iPhone** (PLAN finding 11). A `GpuGate` closes on
  `willResignActive` (while the GPU is still usable) and opens on
  `didBecomeActive`. Closing it cancels every MLX generation at a token
  boundary inside a `beginBackgroundTask` assertion, waits for
  `ChatSession.synchronize()` / the generation task, synchronizes
  `Stream.gpu`, and reports `paused` → Dart `Finish(pause, rawReason:
  'app_inactive')`. The agent loop's continuation request waits natively
  (cancellable) until the app is active again, with a
  `waiting_for_foreground` notice. Loads wait too.
* **Foundation Models is not paused**: the system model runs out of process
  and is usable in the background, rate-limited (`rateLimited`, retryable);
  prewarm is skipped in the background.
* **Prewarm** warms a tool-less `LanguageModelSession` with the given
  instructions and keeps it: the next request that starts a new native
  session with the same instructions, no history and no tools uses it
  (once). The KV prefix `prewarm(promptPrefix:)` computes belongs to that
  session object; a request with tools builds its own session (tools are
  fixed at init and bound to the Sherpa session id), so for it prewarm can
  at most leave the model assets loaded.
* **Waiting on the gate is cancellable at any point**: a generation
  cancelled (or paused) before its waiter is registered throws at once
  instead of waiting for the next `didBecomeActive`, so `pauseAll` /
  `unloadAll` and the background assertion are not held up.
* **Memory:** Dart admission (`MlxAdmission`, R06 §5 rule: weights + KV +
  overhead ≤ 0.6 × `os_proc_available_memory()`) picks `maxKVSize` (shrunk in
  256-token steps, refused below the minimum context) before loading; that
  context is what the context manager is told. Swift sets
  `Memory.cacheLimit` (32 MB default) and `Memory.memoryLimit` (0.9 × what
  the process may still allocate plus what MLX holds) at load. KV defaults to
  8-bit (R11: tool sessions stay at q8); `kvScheme` (e.g. `turbo8v3`) is
  available per model. On a memory warning Swift calls `Memory.clearCache()`,
  drops idle sessions' KV caches and tells Dart which (ledgers invalidated).
* **Thermal:** no automatic policy here; the app can call
  `mlx.interrupt('thermal_critical')` from sherpa_platform's thermal signal
  (R06 §7).

### Prompt caches
mlx-swift-lm 3.32.3 can save a session's KV cache (`ChatSession.saveCache`,
Python-compatible `.safetensors`) and restore it (`loadPromptCacheSnapshot` +
`ChatSession(promptCache:)`), but **a restored cache carries no transcript**
("fragment-based continuation … not suitable for conversation-aware
structured tool continuations"). `MlxProvider.savePromptCache(sessionId,
path)` is implemented; restoring is **opt-in and experimental**
(`MlxProviderConfig.restorePromptCaches`): only for a tool-less rebuild whose
history is exactly the saved prefix and whose new input is one user message,
and the session is rebuilt from history on the following turn. Templates that
inject a default system prompt or date header (Qwen2.5, Llama 3.2) render a
fragment wrongly, which is why it is off by default. (`fork(history:)`, named
in R06 §2.3, does not exist in 3.32.3.)

### Reasoning
`ChatSession` streams reasoning inline. Swift reports the model's
`reasoningConfig` delimiters and whether the chat template pre-fills the
opening delimiter (`reasoningPrimed`, measured at load by rendering a probe
and checking the prompt tail); Dart's `ThinkSplitter` routes text into
`ReasoningDelta`/`TextDelta`. `ReasoningEffort.off` turns the template switch
(`enable_thinking`) off; budgets are not mapped.

## Packaging

* **SwiftPM** (`ios/sherpa_apple_ml/Package.swift`, Flutter's default since
  3.44): MLX + Foundation Models. Needs Xcode 26+ (mlx-swift-lm is
  swift-tools 6.2) and the Metal Toolchain component in CI
  (`xcodebuild -downloadComponent MetalToolchain`). Only `MLXLLM`,
  `MLXLMCommon`, `MLX` and `Tokenizers` are linked — no `MLXHuggingFace`
  macros (no swift-syntax build), no `Downloader`: models load from a local
  directory with a hand-written swift-transformers tokenizer bridge
  (`AutoTokenizer.from(modelFolder:)` reads local files only). MLX cannot run
  on the Simulator.
* **CocoaPods** (`ios/sherpa_apple_ml.podspec`): **Foundation Models only.**
  CocoaPods cannot carry MLX — neither mlx-swift nor mlx-swift-lm ships a
  podspec and the trunk has no MLX, MLXLLM, MLXLMCommon, swift-transformers or
  Tokenizers pod (checked 2026-10-19); the trunk turns read-only on
  2026-12-02. MLX sources are compiled out (`#if canImport(MLXLLM)`) and
  `MlxProvider.availability` reports `unsupported / notCompiled`.
* **Foundation Models** is imported under `#if canImport(FoundationModels)`,
  created only under `if #available(iOS 26.0, *)` and used only from
  `@available(iOS 26.0, *)` types, so it is weak-linked and the app runs on
  iOS 17 (podspec: `weak_frameworks`). Only iOS 26 SDK API is used: CI's
  Xcode 26.6 ships the iOS 26.5 SDK, and an iOS 27 symbol (`usage`,
  `LanguageModelError`, `GenerationOptions(samplingMode:)`) does not exist
  at compile time even behind `#available(iOS 27.0, *)`.
* Android/desktop: no native code; every class compiles and reports
  unsupported (`UnsupportedAppleMlBackend`).

## Regenerating Pigeon code

```sh
cd packages/sherpa_apple_ml
dart run pigeon --input pigeons/apple_ml_api.dart
```

## Verification

```sh
cd packages/sherpa_apple_ml && flutter test --no-pub --concurrency=2
dart analyze --fatal-infos packages/sherpa_apple_ml
SWIFTC=/path/to/swift-6.2.1/usr/bin/swiftc packages/sherpa_apple_ml/tool/typecheck_swift.sh
```

The type-check builds stand-in modules from `tool/swift_standins/` (Flutter,
UIKit, Metal, `os`, MLX, MLXLMCommon, MLXLLM, Tokenizers, FoundationModels)
and type-checks the plugin in three configurations: SwiftPM (everything),
CocoaPods (no MLX modules) and an old SDK (no FoundationModels). The MLX and
Tokenizers stand-ins copy the public declarations the plugin uses from the
pinned tags' sources (signatures, labels, defaults, `Sendable`); the
FoundationModels stand-in copies the DocC declarations re-fetched on
2026-10-19 (each cites its DocC JSON page) and models the **iOS 26.5 SDK**
of CI's Xcode 26.6: symbols DocC lists as iOS 27.0 or
`@backDeployed(before: iOS 27.0)` are left out, because Linux ignores
`@available` and would otherwise accept them (that is how
`GenerationOptions(samplingMode:)`, `LanguageModelSession.usage` and
`LanguageModelError` passed here and failed in CI; with the current
stand-in the CI build's code fails with the same three errors).
Flutter/UIKit mirror the ObjC headers and iOS 26 isolation. They cannot
prove: real SDK shapes beyond what was transcribed (e.g. the String
`PromptBuilder`/`InstructionsBuilder` expressions; whether the iOS 26 SDK
gives `GenerationOptions(sampling:)` a default, inferred, the plugin always
passes it), iOS 26.x availability (Linux ignores it), linking, or runtime
behaviour.

## Known gaps

* No Xcode build has finished yet (the first CI build stopped at the
  three iOS 27 symbols in `FoundationModelsEngine.swift`, now fixed); never
  run on a device, simulator or the real frameworks.
* MLX: no vision/audio (MLXVLM), no MLXGuidedGeneration for `jsonSchema`,
  no stop strings, no thinking budgets, no speculative decoding, no forced
  tool choice; tokens are counted natively only via `countTokens` (no
  synchronous `TokenCounter`).
* Decoding is not paused by subscriber backpressure (delivery is).
* Pausing waits for the current token; a long prefill in progress may not
  stop before the app is backgrounded (the process-wide error handler then
  prevents the exit, and the model is reloaded).
* FM: streaming snapshots are diffed; a snapshot that rewrites text already
  sent is reported with a notice, not retracted. Guided-generation output is
  sent once at the end. Whether a transcript-initialized session also
  re-adds tool definitions itself is unverified. No PCC, no
  `ToolCallingMode`, no reasoning levels (iOS 27). **Usage is not
  reported** (Swift sends no `info` event, so the provider emits no
  `UsageUpdate`): `LanguageModelSession.usage` is iOS 27 SDK API and the app
  builds with the iOS 26 SDK. Prewarm only helps new tool-less sessions
  (above); warming a session with tools would need `fmPrewarm` to take the
  session id and tool definitions.
* Prompt-cache restore is experimental and off by default (above).
