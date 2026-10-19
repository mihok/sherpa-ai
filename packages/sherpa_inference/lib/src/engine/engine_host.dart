import 'package:sherpa_core/sherpa_core.dart';

import 'engine_types.dart';

/// The boundary between Sherpa's Dart code and one running sherpa_engine.
///
/// Two implementations exist (or are planned) and everything above this
/// interface — provider, lifecycle, scheduler, autotune, prefix cache — is
/// written against it only:
///
/// * [FfiEngineHost]: the engine in this process via Dart FFI, every
///   blocking call on a long-lived background isolate and event polling on a
///   second one. Used on iOS, in host tests and as the Android fallback.
/// * [ProcessEngineHost]: the same `.so` in a bound `:inference` service
///   (Pigeon → AIDL/Binder → JNI), so a native crash restarts the engine
///   instead of killing the app (PLAN "Local inference engine").
///   [createDefaultEngineHost] picks it on Android.
///
/// ## Contract
///
/// **Threading.** Every method may be called from the UI isolate and must
/// never block it: implementations run the native work elsewhere (a
/// background isolate, another process). Methods are safe to call
/// concurrently; calls on one session are serialized by the host in arrival
/// order. A call that the engine refuses because the session is generating
/// fails with `EngineException(SE_ERR_BUSY)` (header "Threading"): callers
/// decide whether to wait or cancel.
///
/// **Handles.** Models, sessions and LoRA adapters are opaque
/// [EngineHandle]s tagged with the host [epoch]. Model handles are immutable
/// and shareable; freeing a model while sessions use it is safe (the
/// engine reference-counts). Never use a handle after freeing it.
///
/// **Generation.** [generate] returns a *cold, single-subscription* stream:
/// the engine starts on listen (`se_generate_start`). It delivers every
/// engine event in order — adjacent deltas may arrive coalesced
/// ([EventCoalescer]) but nothing is dropped — and ends after exactly one
/// [EngineEventType.finish] event, which is preceded by USAGE and PERF (and
/// by ERROR when the reason is `error`). A refused start (busy session,
/// malformed JSON) is a stream error ([EngineException]). Pausing the
/// subscription is backpressure: the host stops pulling once a small,
/// bounded number of batches are buffered, the engine's event ring fills and
/// its worker blocks between tokens, so a paused consumer stops the decode
/// instead of growing a queue. Cancelling the subscription cancels the
/// generation (`se_cancel`, observed between tokens and inside prefill) and
/// releases the session as soon as the engine reaches FINISH; a later
/// [generate] on the same session waits for that. [cancelGeneration] cancels
/// without unsubscribing (the stream then ends with FINISH(cancelled)).
///
/// **Crashes.** If the worker hosting the engine dies, every pending call
/// and every open generation stream fails with [EngineCrashedException]
/// (which the provider maps to `ProviderException(engineCrashed)`), [events]
/// emits [EngineHostCrashed], and the host restarts itself and emits
/// [EngineHostRestarted]. When [EngineHostCrashed.nativeStateLost] is true
/// (out-of-process host) the epoch changes, older handles throw
/// [StaleHandleException], and owners (the lifecycle manager) reload models
/// on next use. The in-process host cannot survive a native crash (it takes
/// the app down); the engine's crash breadcrumb (`se_init_params`) and the
/// lifecycle manager's phase file report it on the next start.
///
/// **Blocking calls** ([loadModel], [estimateMemory], [bench],
/// [saveState], [loadState], [createSession]) can take seconds. [loadModel]
/// and [bench] accept a [CancellationToken]; cancelling makes them fail
/// with `EngineException(SE_ERR_CANCELLED)` promptly.
abstract interface class EngineHost {
  EngineHostKind get kind;

  /// Current incarnation; handles from other epochs are stale.
  int get epoch;

  /// Lifecycle notifications (crash, restart). Broadcast.
  Stream<EngineHostEvent> get events;

  /// Opens the engine, initializes backends once per process
  /// (`se_backend_init`, with the crash breadcrumb path) and returns version
  /// and system info. Idempotent. Throws `EngineUnavailableException` when
  /// the engine library is missing or speaks another ABI.
  Future<EngineInfo> start();

  Future<String> systemInfoJson();

  Future<EngineModel> loadModel(
    ModelLoadOptions options, {
    CancellationToken? cancel,
    void Function(double progress)? onProgress,
  });

  Future<void> freeModel(ModelRef model);

  /// No-alloc dry run of a load plus session (`se_estimate_memory`).
  Future<MemoryEstimate> estimateMemory(ModelLoadOptions model, SessionConfig session);

  Future<EngineSession> createSession(ModelRef model, SessionConfig config);

  Future<void> freeSession(SessionRef session);

  /// Drops the token history and clears the KV cache.
  Future<void> resetSession(SessionRef session);

  Future<void> setThreads(SessionRef session, int nThreads, int nThreadsBatch);

  Future<String> sessionInfoJson(SessionRef session);

  /// Real allocations of a live session (`se_session_memory`).
  Future<MemoryEstimate> sessionMemory(SessionRef session);

  /// Starts a generation from an OpenAI-shaped chat request (the JSON of
  /// `se_generate_start`). See the class comment for the stream contract.
  Stream<EngineEvent> generate(SessionRef session, String requestJson);

  /// Requests cancellation of the session's running generation. Returns
  /// immediately; SE_OK semantics when nothing runs.
  Future<void> cancelGeneration(SessionRef session);

  Future<List<int>> tokenize(ModelRef model, String text, {bool addSpecial = false, bool parseSpecial = false});

  Future<String> detokenize(ModelRef model, List<int> tokens, {bool renderSpecial = false});

  /// Prompt tokens of a chat request rendered through the model's template.
  Future<int> countChatTokens(ModelRef model, String requestJson);

  /// Counts for many texts / requests in one hop (token-counter warm-up).
  /// Each entry is the count, or a negative `se_status` for that item.
  Future<List<int>> countBatch(ModelRef model, {List<String> texts = const [], List<String> chatRequests = const []});

  /// Writes the session's KV cache + token history to [path] (atomic).
  /// Returns the file size in bytes.
  Future<int> saveState(SessionRef session, String path);

  /// Restores a file written by [saveState]; returns the restored token
  /// count. `SE_ERR_STATE_MISMATCH` when it belongs to another model, LoRA
  /// set, KV layout or a larger context.
  Future<int> loadState(SessionRef session, String path);

  Future<LoraRef> loadLora(ModelRef model, String path);

  Future<void> freeLora(LoraRef lora);

  /// Replaces the session's whole adapter set.
  Future<void> setLoras(SessionRef session, List<(LoraRef, double)> loras);

  Future<BenchResult> bench(ModelRef model, BenchConfig config, {CancellationToken? cancel});

  /// A synchronous tokenizer usable in the caller's isolate, or null when
  /// the host cannot offer one (an out-of-process engine). The in-process
  /// host returns direct FFI calls into the thread-safe tokenizer; callers
  /// that must keep FFI off the UI isolate don't use it (see
  /// `EngineTokenCounter`).
  SyncTokenizer? syncTokenizer(ModelRef model);

  /// Frees everything and stops the workers.
  Future<void> dispose();
}

/// Synchronous token counting for one model. Implementations must be cheap,
/// bounded leaf calls (tokenization is O(text); the template render takes
/// the model's template mutex briefly).
abstract interface class SyncTokenizer {
  int countText(String text);

  int countChat(String requestJson);
}
