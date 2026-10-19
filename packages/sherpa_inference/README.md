# sherpa_inference

On-device inference for Sherpa: a Flutter FFI plugin over `sherpa_engine` (llama.cpp behind a versioned C
ABI, [`native/engine/include/sherpa_engine.h`](../../native/engine/include/sherpa_engine.h)). It provides the
`LlamaCppProvider` (a core `ModelProvider`), exact token counting, model lifecycle with admission control, an
inference scheduler, first-use autotune and a persistent prefix (KV) cache.

Background: [`docs/PLAN.md`](../../docs/PLAN.md) "Local inference engine" and findings 10–12;
[`docs/research/04-llamacpp-api.md`](../../docs/research/04-llamacpp-api.md) (R04),
[`06-ios-native.md`](../../docs/research/06-ios-native.md) §5–6 (R06),
[`07-android-native.md`](../../docs/research/07-android-native.md) §2 (R07),
[`11-agent-context-safety.md`](../../docs/research/11-agent-context-safety.md) §9.6 (R11).

## Layers

```
LlamaCppProvider ── InferenceScheduler (priorities, preemption)
      │           └─ EngineTokenCounter + WarmingContextManager (exact counts, off the UI isolate)
      ▼
ModelLifecycleManager ── admission (se_estimate_memory × MemoryMonitor) · one warm model ·
      │                  pressure/background policy · crash forensics · PrefixCacheStore · Autotuner
      ▼
EngineHost (interface) ── FfiEngineHost: worker isolate (blocking calls) + pump isolate (events)
      │                └─ (next) Android :inference process host over Binder/Pigeon
      ▼
lib/src/ffi: hand-written bindings (39 se_* functions), library loader
```

No FFI call runs on the UI isolate. The one opt-in exception is `EngineTokenCounter(useSyncTokenizer: true)`
for runners that live on a background isolate.

## EngineHost contract (summary; the doc comment on `EngineHost` is normative)

| Group | Methods |
|---|---|
| lifecycle | `kind`, `epoch`, `events` (`EngineHostCrashed`, `EngineHostRestarted`), `start()`, `systemInfoJson()`, `dispose()` |
| models | `loadModel(options, cancel, onProgress)`, `freeModel`, `estimateMemory(model, session)` |
| sessions | `createSession`, `freeSession`, `resetSession`, `setThreads`, `sessionInfoJson`, `sessionMemory` |
| generation | `generate(session, requestJson) → Stream<EngineEvent>`, `cancelGeneration(session)` |
| tokens | `tokenize`, `detokenize`, `countChatTokens`, `countBatch` (many counts in one hop), `syncTokenizer(model)` (nullable) |
| state | `saveState(session, path) → bytes`, `loadState(session, path) → tokens` |
| LoRA / bench | `loadLora`, `freeLora`, `setLoras`, `bench(model, config, cancel)` |

* **Never blocks the caller**; native work runs on a background isolate (FFI host) or in another process.
* **Handles** are opaque (`ModelRef`/`SessionRef`/`LoraRef`) and tagged with the host `epoch`; a host that lost
  native state bumps the epoch and rejects old handles with `StaleHandleException`.
* **Events** are flat `EngineEvent`s (a copy of `se_event`; the same shape crosses isolate ports and Binder).
  `generate` is cold and single-subscription; events arrive in order, adjacent deltas may be coalesced
  (`EventCoalescer`, ~16 ms windows, the first delta immediately), none is dropped; the stream ends after exactly
  one FINISH (preceded by USAGE and PERF). **Pause = backpressure:** at most 4 batches are in flight per stream;
  then the pump stops polling, the engine's event ring (`event_capacity`, default 256) fills and its worker
  blocks between tokens (proven by the integration test with an 8-slot ring: the engine's `decode_ms` includes
  the pause). **Cancel** (unsubscribe or `cancelGeneration`) is `se_cancel`, observed between tokens and inside
  prefill; a later `generate` on the session queues until the old one drained.
* **Crashes:** a dying worker fails every in-flight call/stream with `EngineCrashedException` (→
  `ProviderException(engineCrashed)`, retryable), emits `EngineHostCrashed`, restarts, emits
  `EngineHostRestarted`. `nativeStateLost: true` (process host) means reload; the lifecycle manager does it on the
  next acquire. The in-process host cannot outlive a native crash; it is reported on the next start.
* Events are **polled** (`se_poll_events`); `se_set_event_callback` is never used from Dart: the event is valid
  only during a synchronous call on the engine's thread, which no Dart callback type honours (header comment;
  this supersedes PLAN's earlier `NativeCallable.listener` note). The engine's log callback stays NULL for the
  same reason (stderr / logcat `sherpa_engine`).

## Provider behaviour

* Request mapping (`EngineRequestMapper`): OpenAI-shaped JSON for `se_generate_start` — system prompt, messages
  with tool calls (exact raw argument text unless repaired), tool results (`tool_call_id` + `name`, errors flagged
  in-band), `reasoning_content` only for this provider's own replies, tools with a conservative schema clean-up,
  `tool_choice`, `parallel_tool_calls` only for ≥ 8B models whose template supports it (R11 §9.6.2),
  `enable_thinking` + reasoning budgets (low 512 / medium 2048 / high unlimited), sampling (GGUF
  `general.sampling.*` fills unset values), `max_tokens`, `stop`, `json_schema` (dropped with a notice when tools
  are active — the engine rejects the combination), `continue_final_message` when the request ends with an
  assistant message, `cache_prompt: true`, `params.extra` merged last.
* Event mapping (`EngineEventMapper`): deltas; `ToolCallComplete` with parsed (or repaired → `repaired: true`)
  arguments; `UsageUpdate` with `inputTokens = prompt − cached`, `cacheReadTokens = cached`; `PerfSample` (TTFT,
  prefill/decode t/s, draft acceptance, backend); `ProviderNotice('prompt_progress')`; one `Finish`.
  Errors: `SE_ERR_OOM`/`SE_ERR_CONTEXT_CREATE` → `outOfMemory`, `SE_ERR_CONTEXT_FULL` → `contextOverflow`,
  template/grammar/parse/arg → `invalidRequest`, crash → `engineCrashed`, admission refusal → `outOfMemory` with
  the reason, missing library/ABI mismatch → `unsupported` ("engine unavailable").
* Capabilities from `se_model_info_json` + the live session: `contextLength` = the session's real n_ctx,
  `toolCallFormat` jsonGrammar / prompted / none from the template classification, reasoning optional when the
  template supports thinking, vision from mmproj, `historyPolicy: appendOnly`, `supportsPromptCache`, tokenizer
  family, quantization, `ramEstimateBytes` = session memory. `info.location` is `onDevice`.
* A generation the lifecycle stops (iOS backgrounding, critical memory) ends with `Finish(pause)`; the agent loop
  continues it later (the next request ends with the partial reply → `continue_final_message`).
* Priorities: `stream()` infers foreground vs tool follow-up (last message is a tool result);
  `provider.withPriority(InferencePriority.background)` for compaction/summaries.

## Lifecycle, scheduler, autotune, prefix cache

* **Admission** (`planAdmission`): budget = fresh `MemoryMonitor.sample()` availability × platform fraction
  (iOS 0.6 per R06 §5, Android/other 0.75) − 128 MiB margin, ×0.8 under moderate pressure, 0 under critical,
  plus the Android 17 anonymous-memory cap (mapped weights exempt). Keeps the preferred context lowering KV
  f16 → q8_0 (q4_0 only for sessions without tools); otherwise takes the largest context that fits across KV
  types, solved from the dry run's per-token KV cost and verified; otherwise refuses ("needs X MB at a N-token
  context, about Y MB available"). The plan is made before loading (mmapped weights would count as used).
* **Pressure:** critical → stop the generation at a token boundary, persist the prefix, unload; moderate →
  recreate the session smaller when idle (f16→q8_0, then half the context).
* **Background:** `BackgroundPolicy.pauseAndPersist` (iOS: stop, persist, unload; `acquire` waits for the
  foreground), `persistOnly` (Android with a foreground service), `none`.
* **Forensics:** `EngineForensics(dir)` holds the engine's crash breadcrumb (`se_init_params`) and a phase file
  written before load/generate/state I/O/bench. `start()` reports `EngineCrashReport` ("The on-device engine
  crashed while generating a reply with X (8192-token context).") and halves that model's context for future
  loads (`downgradeFor` / `clearDowngrade`). `onPhase` delivers ≤ 128-byte summaries for Android's
  `setProcessStateSummary`.
* **Scheduler:** one queue, foreground > tool follow-up > background, FIFO within; a more urgent job cancels
  background work (default policy) — prompt because `se_cancel` is; a preempted job without output is re-queued,
  otherwise it fails with a retryable `overloaded`. `state`/`changes` for the UI.
* **Autotune:** per (device, OS, app, engine, model) — staged `se_bench` sweep over threads 1..performance cores
  (≤ 8), `n_batch`/`n_ubatch` 128/256/512 and KV × flash attention (f16/off, f16/on, q8_0/on), filtered by the
  memory budget, minimizing the time of a 512-prompt/150-generated-token turn (3 % ties → fewer threads, smaller
  KV). Persisted in a `KeyValueStore`; any version change re-tunes; `setOverrides` for power users. Run it as
  background work (`lifecycle.autotune(modelId)`); threads apply at once, the rest at the next load.
* **Prefix cache:** state files keyed by (conversation, model identity, LoRA set, n_ctx, KV layout), validated by
  a per-message fingerprint (a changed transcript invalidates), LRU budget **1 GiB / 12 files** by default (a
  full 8k q8_0 context of a 4B model is ~0.6 GB; typical chats 60–300 MB; a single state over half the budget is
  not kept). Saved when another conversation takes the session, before unloads and on backgrounding; restored on
  the first request of a conversation after a switch, reload or relaunch.

## Packaging

**Android** (`android/build.gradle.kts`): an FFI plugin (`ffiPlugin: true`, no plugin class, no native build)
whose only job is `sourceSets.main.jniLibs.srcDir(native/llama/out/android/jniLibs)` — override with
`-Psherpa.engineJniLibs=<dir>` or `SHERPA_ENGINE_JNILIBS`. The `.so` files are never committed; without them the
build succeeds with a warning and the provider reports "engine unavailable". Libraries stay uncompressed and
16 KB-aligned in the APK; the engine `dlopen`s its CPU variant by bare name (no `extractNativeLibs`). Verified
here with a scratch app: the debug APK contains all 12 engine libraries under `lib/arm64-v8a/` (stored, 16 KB-aligned), and builds without them.
The Android `:inference` process host will load the same `.so` from the same jniLibs.

**iOS** (`ios/sherpa_inference/Package.swift` + `ios/sherpa_inference.podspec`): `native/llama/build_ios.sh`
(macOS only, not run here) produces `SherpaEngine.xcframework` (dynamic `SherpaEngine.framework` per slice,
exports only `se_*`); `tool/link_ios_engine.sh` copies it into `ios/sherpa_inference/Frameworks/` (gitignored —
SwiftPM refuses binary targets outside the package root). SwiftPM uses a `.binaryTarget` and CocoaPods
`vendored_frameworks`, both only when the xcframework exists, so the app builds either way. Dart opens
`SherpaEngine.framework/SherpaEngine` (falls back to the process image if an integrator links it statically).
**Unverified here** (no macOS): run `flutter build ios` in CI.

**Host tests:** `tool/build_host_engine.sh` builds a shared engine (`BUILD_SHARED_LIBS=ON`) into
`/opt/vendor-src/sherpa-engine-build/host-shared/`; tests find it via `SHERPA_ENGINE_LIB` (default: that path)
and the model via `SHERPA_TEST_MODEL` (default `/opt/models/Qwen3-0.6B-Q4_K_M.gguf`), and skip cleanly
without either. `SHERPA_TEST_THREADS` (default 2).

```sh
cd packages/sherpa_inference
flutter test                                # unit + integration (integration skips without engine/model)
flutter test test/unit                      # no engine needed
SHERPA_ENGINE_LIB=/path/libsherpa_engine.so flutter test test/integration
```

## Integrating (app)

```dart
final forensics = EngineForensics(Directory('${support.path}/engine'));
final host = FfiEngineHost(crashBreadcrumbPath: forensics.engineBreadcrumbPath);
final lifecycle = ModelLifecycleManager(
  host: host,
  memory: platformMemoryMonitor,                    // sherpa_platform
  device: deviceProfile,                            // sherpa_platform snapshot → DeviceProfile
  forensics: forensics,
  store: jsonDocumentKeyValueStore,                 // KeyValueStore over sherpa_data's JsonDocumentStore
  prefixCache: PrefixCacheStore(directory: Directory('${caches.path}/kv')),
  autotuner: Autotuner(host: host, store: ..., environment: AutotuneEnvironment(...)),
  backgroundPolicy: Platform.isIOS ? BackgroundPolicy.pauseAndPersist : BackgroundPolicy.persistOnly,
  onPhase: (r) => platform.setProcessStateSummary(r.compactSummary),   // Android
);
final crash = await lifecycle.start();              // show crash?.description once
lifecycle.register(LocalModelSpec(id: ..., path: ..., identity: 'sha256:…', trainContext: ...));
final provider = LlamaCppProvider(lifecycle: lifecycle);
AgentRunner(
  provider: provider, modelId: id,
  counter: provider.tokenCounter(id),
  contextManager: WarmingContextManager(ladderContextManager), ...);
// app lifecycle: paused → lifecycle.onAppBackground(); resumed → lifecycle.onAppForeground()
// compaction/summarizer: provider.withPriority(InferencePriority.background)
// after the first reply on a new model: lifecycle.autotune(id) inside scheduler background work
```

Android app module: `packaging { jniLibs { pickFirsts += "**/libc++_shared.so" } }` (keep `abiFilters
arm64-v8a`); build `native/llama/build_android.sh` before `flutter build apk`. iOS: run `build_ios.sh` and
`tool/link_ios_engine.sh` before `flutter build ios`.

## Known gaps

* iOS packaging and the progress callback path on device are unverified (no macOS/devices here).
* Vision (mmproj) needs a `SHERPA_ENGINE_MTMD` engine build; images are dropped with a notice until then.
* LoRA: loaded per spec at load time; no hot-swap API on the provider yet.
* Speculative decoding is not enabled by default (`SessionConfig.speculative`); no policy picks n-gram/MTP yet.
* Per-message token counts are template renders of the message alone (slight overcount vs. the full render);
  `countPromptTokens` is exact.
