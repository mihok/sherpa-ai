# sherpa_litert

Android-only Flutter plugin with two on-device `ModelProvider`s for Sherpa:

| Provider | Engine | Models | Provider id / kind |
|---|---|---|---|
| `LiteRtLmProvider` | LiteRT-LM `com.google.ai.edge.litertlm:litertlm-android:0.18.0` | `.litertlm` files (CPU/GPU; NPU for SoC-specific files) | `litert_lm` / `ProviderKind.localLiteRt` |
| `GeminiNanoProvider` | ML Kit GenAI Prompt API `com.google.mlkit:genai-prompt:1.0.0-beta4` (AICore) | Gemini Nano, model id `gemini-nano` | `gemini_nano` / `ProviderKind.localSystem` |

Both report `ExecutionLocation.onDevice`. On iOS, desktop and in host tests the Dart classes compile and
report `AvailabilityState.unsupported` (`UnsupportedLiteRtBackend`); nothing crashes.

This is a separate plugin from `sherpa_inference`, so the llama.cpp FFI plugin stays lean.

## Versions (verified 2026-10-19)

The versions were checked on Google Maven via `group-index.xml` and the POM `last-modified` header. The APIs were checked with `javap` on the AARs and against the v0.18.0 Kotlin sources.

- `litertlm-android` **0.18.0**, published 2026-10-06. It is the latest stable release; earlier ones run 0.17.1, 0.17.0, 0.16.1 and so on.
  - Its POM pulls in gson 2.14.0, kotlin-reflect 2.4.0 and kotlinx-coroutines-android 1.11.0.
  - The AAR ships `jni/{arm64-v8a,x86_64}/liblitertlm_jni.so` and has `minSdk` 24.
  - A desktop artifact also exists: `litertlm-jvm` 0.18.0, with linux-x86_64/aarch64, darwin-aarch64 and windows JNI libraries.
- `genai-prompt` **1.0.0-beta4**, published 2026-07-21. It is the latest release, a beta "not subject to any SLA or deprecation policy".
  - It depends on `genai-common` 1.0.0-beta4, play-services-basement/tasks and ML Kit `common` 18.11.0.
  - It also depends on `datatransport`/`firebase-encoders`, so ML Kit's usage logging ships with it. Prompts and outputs stay on the device ("processed locally").
  - Its manifest adds the AICore `BIND_SERVICE` permission and a `<queries>` entry; `minSdk` is 26.

## Dart API

```dart
import 'package:sherpa_litert/sherpa_litert.dart';

// LiteRT-LM: register library models by id + absolute path.
final lm = LiteRtLmProvider(
  foreground: AppForeground.from(() => fs.isForeground, fs.changes), // or default WidgetsAppForeground()
  models: [LiteRtModelSpec(id: libraryModel.id, path: absPath, displayName: libraryModel.displayName,
      contextLength: libraryModel.defaultContextLength, vision: false)],
  options: const LiteRtLmOptions(releaseAtTrimLevel: 40, maxLiveConversations: 1),
);
lm.register(spec); lm.unregister(id);
await lm.forgetConversation(sessionId);                         // chat deleted: close its native conversation
final ProviderAvailability a = await lm.availability(absPath); // available | unsupported(+reason, code)
final LiteRtModelInfo info = await lm.inspect(absPath);          // ModelInfo.from, no weights loaded
await lm.release();                                             // free the engine now
LiteRtLmProvider.supportsFile(path);                            // *.litertlm
LiteRtLmProvider.supportsFormat(ModelFormat.litert);            // library format routing

// Gemini Nano
final nano = GeminiNanoProvider(options: const GeminiNanoOptions(maxOutputTokens: 1024));
final ProviderAvailability s = await nano.status();  // available | downloadable | downloading | unsupported
await for (final u in nano.download()) { /* NanoDownloadStarted/Progress(fraction)/Completed/Failed */ }
await nano.warmup();
```

`ProviderAvailability` has a `state`, a stable `code` and a one-sentence English `reason` for the UI, plus a `details` map.

- LiteRT-LM codes: `ok`, `not_android`, `plugin_missing`, `runtime_missing`, `unsupported_format`, `file_missing`, `inspect_failed`, `not_an_llm`, `runtime_too_old`, `wrong_soc`.
- Gemini Nano codes: `downloadable`, `downloading`, `aicore_unavailable`, `feature_not_found` (this includes unlocked bootloaders), `aicore_binding_failed`, `needs_system_update`, `aicore_incompatible`, `not_supported`, `status_error`.

Both providers share one Pigeon backend (`SherpaLitert.backend`) and one stream-id space (`LiteRtLmProvider.routerFor`).

## Design

### Threading and backpressure

- **Kotlin threads:**
  - Every LiteRT-LM call runs on one dedicated thread, `sherpa-litert-engine`.
  - Gemini Nano work runs on the `sherpa-nano` dispatcher; `sherpa-nano-worker` is ML Kit's `workerExecutor`.
  - Pigeon's suspend host handlers switch threads at once, so the platform main thread never blocks.
- **Event stream:** one event channel carries `EventBatch`es, each belonging to one stream.
  - Kotlin coalesces deltas for about one frame and sends the first batch at once, for time to first token.
  - A stream may have 4 batches in flight. Dart returns one credit per batch it delivered to an unpaused listener.
  - Without credits, Kotlin buffers up to 64 KiB and then **blocks the engine's callback thread**, which stops decoding.
  - Pausing the Dart subscription therefore applies real backpressure. Cancel unblocks the thread and the terminal event always arrives.

### History and branch policy

**LiteRT-LM keeps the conversation natively. The provider mirrors it, verifies it, and rebuilds it on divergence.**

- **What the native conversation holds.** A native `Conversation` caches one exact transcript prefix and its KV cache.
  - After each clean turn, the provider records fingerprints of what that conversation holds: history, then the sent message, then the reply as it streamed.
- **When it is reused.** A request reuses the conversation only when three things are unchanged:
  - its history (everything before the message to send) matches the recorded prefix;
  - the system prompt and tools match;
  - the sampler matches.
  
  Only the new message is then sent, so the KV cache is reused and usage reports the reused tokens as `cacheReadTokens`.
- **When it is rebuilt.** Any other request closes the conversation and recreates it with `initialMessages` set to the request's history. This covers:
  - an edit;
  - a branch switch;
  - a retry;
  - a compaction overlay;
  - a changed tool list;
  - a different chat;
  - an interrupted turn (cancel, pause or error).
  
  The provider never patches native state in place.
- **What the host run showed.** It confirms why an interrupted turn has to rebuild: after `cancelProcess()`, the same LiteRT-LM conversation answers every later turn with "cancelled" at once.
- **Capabilities.** The provider reports `HistoryPolicy.appendOnly` and `supportsPromptCache: true`. That keeps the context manager appending, but mutable requests are still correct (they just rebuild).
- **Continuing a paused reply.** LiteRT-LM has no "continue" call. When a request ends with an assistant message, the provider sends a short continue nudge after it, with notice `continue_prompted`.

**Gemini Nano is stateless.** The Prompt API has no conversation, so every request renders the full transcript into one prompt.

- History is `mutable` and edits need nothing special.
- A single plain user message is sent as-is.
- A paused reply is left as an open `Assistant:` turn for the model to continue.

### Tool calling

- **Format: native or prompted.** Native LiteRT-LM function calling is used when the model's chat template renders tools.
  - Tools become `OpenApiTool`s with `automaticToolCalling = false`. Calls come back in `Message.toolCalls`, and Dart runs the tool loop.
  - Results go back as `tool` messages, ordered like the calls, because LiteRT-LM calls have no ids.
- **How "renders tools" is decided.** At load, a probe conversation with a dummy tool is rendered with `renderPrefaceIntoString`. The metadata flag `supportsFunctionCalling()` is not trusted:
  - Qwen3-0.6B reports `false`, yet it called tools natively on the host.
  - SmolLM2's template silently drops tools, tool calls and tool responses.
  - Before the first load, the provider uses the metadata flag.
- **Prompted fallback.** Otherwise, and always for Gemini Nano, the prompted JSON envelope is used: `{"tool_calls":[{"name":…,"arguments":{…}}]}`.
  - The instructions go in the system prompt, and results come back wrapped as untrusted data.
  - A streaming parser in Dart holds back only what may be an envelope.
  - Arguments, prompted and native alike, go through the strict shared parser (`package:sherpa_providers/tool_arguments.dart`, `ToolArgumentsRepair`), like every other tool-call path in Sherpa:
    - almost-JSON is repaired and the call is marked `repaired`, which forces approval for tools that are not read-only;
    - a key sent twice (in the arguments or in the call itself), leaked chat-template tokens (`<|"|>`) and ambiguous unquoted values in broken JSON make the call invalid (`argumentsError`): it is never run, and the agent loop tells the model.
- **Ids and indexes.** Each call gets a fresh `call_…` id. Parallel calls get distinct indexes, and the turn ends with `Finish(toolCalls)`.

### Background, memory and errors

- **LiteRT-LM.**
  - It may run in the background, kept alive by sherpa_platform's foreground service.
  - `onTrimMemory` at or above `releaseAtTrimLevel` (default `TRIM_MEMORY_BACKGROUND` = 40) stops a running turn at the next token: the reply ends with `Finish(pause, rawReason: 'memory_pressure')`. The engine is then freed.
  - The next request waits for the foreground before it reloads.
- **Gemini Nano is foreground only.**
  - AICore answers `BACKGROUND_USE_BLOCKED`, even inside a foreground service.
  - A request made in the background fails with `ProviderErrorKind.unsupported` and a clear message (`kNanoBackgroundMessage`), and nothing is sent.
  - A reply that is running when the app leaves stops at once with `Finish(pause, rawReason: 'background')`. The continuation the agent loop sends next waits for the foreground.
- **Error mapping, Gemini Nano:**
  - `BUSY` becomes `overloaded` (retryable, with AICore's delay).
  - The per-app battery quota becomes `rateLimited` (retryable).
  - `REQUEST_TOO_LARGE` becomes `contextOverflow`.
- **Error mapping, LiteRT-LM:**
  - absl `RESOURCE_EXHAUSTED` or allocation failures become `outOfMemory`.
  - A too-long input becomes `contextOverflow`.
  - `INTERNAL` becomes `engineCrashed` (retryable).
  - A "cancelled" the provider did not request becomes `engineCrashed`, and the retry rebuilds the conversation.

### Capabilities (honest)

- **LiteRT-LM:**
  - `contextLength` = the spec's value, else 8192, capped by `ModelInfo.maxContextTokens()`. This is also the `EngineConfig.maxNumTokens` used.
  - The tool format is `native` or `prompted`, as described above.
  - `vision` only when both the spec and the file enable it.
  - `reasoning: optional` when the file declares thinking. The `thought` channel is streamed as reasoning either way.
  - The tokenizer family is guessed from the file name (Gemma, Qwen, Phi, Llama 3 for SmolLM, Mistral, LFM).
- **Gemini Nano:**
  - `contextLength` = `getTokenLimit()` (4000 when unknown) + the output cap (default 1024). AICore limits input and output separately, and the core subtracts the output reserve.
  - Tools use the prompted format. `vision` is off by default (`GeminiNanoOptions.vision`).
  - The tokenizer family is `gemma` (an estimate).

## Integrating (app side)

- **Dependency.** Add `sherpa_litert` to the app's pubspec. No manifest edits are needed: the plugin's manifest declares `<uses-native-library libOpenCL.so / libvndksupport.so required=false>`, which the GPU backend needs.
- **Pick a provider by format.** `LiteRtLmProvider.supportsFormat(model.format)` is true for `ModelFormat.litert` and routes to LiteRT-LM; GGUF goes to `LlamaCppProvider`.
- **Show availability in the UI.** Use `availability(path)` for library models and `nano.status()` for the Gemini Nano row.
- **NPU.** NPU files additionally need the vendor dispatch libraries (`litert-npu-runtime-*`, R07 §1.3) in the APK. They are not bundled; without them the NPU backend fails and the provider falls back with notice `backend_fallback`.
- **ABIs.** The app's `defaultConfig.ndk.abiFilters += "arm64-v8a"` does **not** take effect: the Flutter Gradle plugin resets `abiFilters` to `armeabi-v7a, arm64-v8a, x86_64`. Without a fix, the 26 MB x86_64 `liblitertlm_jni.so` ships too. Add to the app:
  ```kotlin
  packaging { jniLibs { excludes += "lib/x86_64/liblitertlm_jni.so" } }
  ```
  An alternative is the Flutter property `disable-abi-filtering=true` plus the app's own filters.

### APK size (measured on a scratch app, release, `--target-platform android-arm64`)

| | APK file | download (apkanalyzer) | dex |
|---|---|---|---|
| Flutter baseline | 15.3 MB | 7.0 MB | 0.36 MB |
| + sherpa_litert | 66.4 MB | 28.4 MB | 1.98 MB |
| of which `lib/x86_64/liblitertlm_jni.so` (excludable) | 26.4 MB stored | ~10.7 MB | |
| of which `lib/arm64-v8a/liblitertlm_jni.so` | 22.2 MB stored (uncompressed, mmapped in place) | ~9.7 MB | |

With x86_64 excluded, expect about **+24.7 MB installed and +11 MB download** (an estimate: the subtraction, not a separate build). The Sherpa app's own debug arm64 APK (`flutter build apk --debug --target-platform android-arm64`, 2026-10-19) measured 233,526,238 bytes without the exclude and 207,156,922 bytes with it (−26.4 MB, the stored x86_64 library); `zipalign -c -P 16 -v 4` passes on both. R8 (release) shrinks ML Kit, coroutines, gson and kotlin-reflect. `consumer-rules.pro` keeps `com.google.ai.edge.litertlm.**`, about 78 KB of dex, because its JNI calls back into Kotlin classes.

### Storage

`EngineConfig.cacheDir` is the app's `cacheDir`, as the docs recommend: it speeds up the second load. On the CPU backend, LiteRT-LM writes an XNNPACK weight cache there of roughly the model's size. On the host it wrote 131 MB for the 143 MB SmolLM2 file. Android may reclaim it, but storage and device-fit estimates should count it.

### 16 KB pages

- `liblitertlm_jni.so` LOAD segments are aligned at `0x4000`, checked with `llvm-readelf -lW`.
- `zipalign -c -P 16 -v 4` passes on both the debug and the release APK.
- The plugin has no native code of its own.

## Verification

- **Dart:** `flutter test --no-pub --concurrency=2` (104 tests). The tests run against `FakeLiteRtBackend` (`package:sherpa_litert/testing.dart`) and cover:
  - request and event mapping;
  - native and prompted tool calls, the template probe, and the strict parser's refusals (duplicate keys, template tokens, ambiguous values) on both paths;
  - `forgetConversation` closing a deleted chat's conversation;
  - cancel (by token, by subscription, and by grace timeout);
  - errors and the branch/rebuild policy;
  - memory-pressure pause and reload;
  - the Gemini Nano foreground-only refusal, the pause when backgrounded, and the wait before a continuation;
  - status and download;
  - credits and backpressure;
  - the unsupported platform.
- **Kotlin:** JVM tests with fakes over `LmRuntime`/`LmEngine`/`LmConversation` and `NanoClient` (`StreamHubTest`, `LmControllerTest`, `NanoControllerTest`; 32 tests). Run them from an app's `android/` directory with `./gradlew :sherpa_litert:testDebugUnitTest`.
- **Real LiteRT-LM engine, on the host only (linux-x86_64, CPU).** The plugin's `LiteRtRuntime` and `LmController` were compiled unchanged against `litertlm-jvm` 0.18.0 and run with SmolLM2-135M and Qwen3-0.6B from `litert-community`, with SHA-256 matching the Hub. The run covered:
  - load with GPU→CPU fallback;
  - streaming deltas and `initialMessages` rehydration;
  - KV reuse across turns;
  - cancel, and the conversation stuck in "cancelled" afterwards;
  - rebuild;
  - credits and backpressure;
  - `onTrimMemory(40)` release;
  - native tool calls (Qwen3).
- **Never ran on a device:** the Android build of the engine, the GPU and NPU backends, every Gemini Nano/AICore path, the event channel, Pigeon, the `onTrimMemory` delivery and the foreground checks.
