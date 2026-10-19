// Pigeon definition for the Android out-of-process engine host
// (ProcessEngineHost ⇄ SherpaInferencePlugin ⇄ InferenceService in the
// private `:inference` process).
//
// Regenerate from packages/sherpa_inference:
//   dart run pigeon --input pigeons/inference_api.dart
//
// Design:
// - ONE message schema for both hops. Dart builds an [EngineCall]; the
//   main-process plugin forwards it to the service unchanged, serialized with
//   the codec Pigeon generates for this file (a StandardMessageCodec, pure
//   JVM code: nothing Flutter initializes in the service process). The
//   service answers with [InferenceMessage]s that travel the same way back
//   and are pushed to Dart on one ordered event channel. No hand-written
//   mapping in between, so the Dart host, the plugin and the service cannot
//   disagree about a field.
// - Calls are fire-and-forget on the platform side (`send`); every reply,
//   progress report, generation batch and host lifecycle change arrives on
//   [InferenceEventApi.inferenceMessages] in order. Pending-call bookkeeping,
//   epochs, credits, crash handling and restart backoff are Dart policy
//   (process_engine_host.dart), unit-tested on the host; Kotlin only binds,
//   forwards and reports raw exit records (PLAN §2).
// - Channel mode (not Pigeon's JNI interop): event channels and TaskQueues
//   are needed (R09 §4).
// - Handles are opaque ids minted by the service (never native pointers).
// - iOS has no process host; there is no Swift output.
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/src/engine/process_messages.pigeon.dart',
  dartPackageName: 'sherpa_inference',
  kotlinOut: 'android/src/main/kotlin/io/github/mihok/sherpa_inference/Messages.g.kt',
  kotlinOptions: KotlinOptions(package: 'io.github.mihok.sherpa_inference', errorClassName: 'SherpaInferenceError'),
))
// ---------------------------------------------------------------------------
// Value types (mirror engine_types.dart; integers are the header's codes)

/// `ModelLoadOptions` / `se_model_params`.
class ModelOptionsMsg {
  ModelOptionsMsg({
    required this.path,
    required this.nGpuLayers,
    required this.loadMode,
    required this.useExtraBuffers,
    required this.vocabOnly,
    required this.loadMtp,
  });

  String path;
  String? modelId;
  int nGpuLayers;
  int loadMode;
  bool useExtraBuffers;
  bool vocabOnly;
  bool loadMtp;
  String? chatTemplateOverride;
  String? mmprojPath;
  String? draftModelPath;
}

/// `SessionConfig` / `se_session_params` (0 = engine default).
class SessionConfigMsg {
  SessionConfigMsg({
    required this.nCtx,
    required this.nBatch,
    required this.nUbatch,
    required this.nThreads,
    required this.nThreadsBatch,
    required this.typeK,
    required this.typeV,
    required this.flashAttention,
    required this.nOutputsMax,
    required this.swaFull,
    required this.seed,
    required this.speculative,
    required this.specMaxDraft,
    required this.eventCapacity,
  });

  int nCtx;
  int nBatch;
  int nUbatch;
  int nThreads;
  int nThreadsBatch;
  int typeK;
  int typeV;
  int flashAttention;
  int nOutputsMax;
  int swaFull;

  /// uint32 (`SE_SEED_RANDOM` = 0xFFFFFFFF).
  int seed;
  int speculative;
  int specMaxDraft;
  int eventCapacity;
}

/// `BenchConfig` / `se_bench_params`.
class BenchConfigMsg {
  BenchConfigMsg({
    required this.nThreads,
    required this.nThreadsBatch,
    required this.nBatch,
    required this.nUbatch,
    required this.nCtx,
    required this.nPrompt,
    required this.nGen,
    required this.nReps,
    required this.typeK,
    required this.typeV,
    required this.flashAttention,
  });

  int nThreads;
  int nThreadsBatch;
  int nBatch;
  int nUbatch;
  int nCtx;
  int nPrompt;
  int nGen;
  int nReps;
  int typeK;
  int typeV;
  int flashAttention;
}

/// `se_memory_estimate`.
class MemoryEstimateMsg {
  MemoryEstimateMsg({
    required this.nCtx,
    required this.nCtxSeq,
    required this.flashAttention,
    required this.modelBytes,
    required this.modelMappedBytes,
    required this.kvBytes,
    required this.computeBytes,
    required this.outputBytes,
    required this.totalBytes,
    required this.kvBytesPerToken,
    required this.fileBytes,
  });

  int nCtx;
  int nCtxSeq;
  bool flashAttention;
  int modelBytes;
  int modelMappedBytes;
  int kvBytes;
  int computeBytes;
  int outputBytes;
  int totalBytes;
  int kvBytesPerToken;
  int fileBytes;
}

/// `se_bench_result`.
class BenchResultMsg {
  BenchResultMsg({
    required this.nPrompt,
    required this.nGen,
    required this.nThreads,
    required this.promptTokensPerSec,
    required this.genTokensPerSec,
    required this.promptMs,
    required this.genMs,
  });

  int nPrompt;
  int nGen;
  int nThreads;
  double promptTokensPerSec;
  double genTokensPerSec;
  double promptMs;
  double genMs;
}

/// Reply to [StartCall].
class EngineInfoMsg {
  EngineInfoMsg({required this.abiVersion, required this.version, required this.systemInfoJson, required this.pid});

  int abiVersion;
  String version;
  String systemInfoJson;

  /// The service process (diagnostics, `EngineInfo.libraryLocator`).
  int pid;
}

/// Reply to [LoadModelCall] / [CreateSessionCall]: the new handle and its
/// `*_info_json`.
class HandleInfoMsg {
  HandleInfoMsg({required this.handle, required this.infoJson});

  int handle;
  String infoJson;
}

/// One engine event, a flat copy of `se_event` (`EngineEvent`).
class EngineEventMsg {
  EngineEventMsg({
    required this.type,
    required this.generationId,
    required this.index,
    required this.code,
    required this.text,
    required this.id,
    required this.name,
    required this.promptTokens,
    required this.cachedTokens,
    required this.completionTokens,
    required this.nDrafted,
    required this.nAccepted,
    required this.progressDone,
    required this.progressTotal,
    required this.ttftMs,
    required this.prefillTps,
    required this.decodeTps,
    required this.draftAcceptRate,
    required this.prefillMs,
    required this.decodeMs,
  });

  int type;
  int generationId;
  int index;
  int code;
  String text;
  String id;
  String name;
  int promptTokens;
  int cachedTokens;
  int completionTokens;
  int nDrafted;
  int nAccepted;
  int progressDone;
  int progressTotal;
  double ttftMs;
  double prefillTps;
  double decodeTps;
  double draftAcceptRate;
  double prefillMs;
  double decodeMs;
}

/// A raw `ApplicationExitInfo` of the `:inference` process (API 30+), plus
/// a bounded, redacted tombstone excerpt for native crashes (API 31+).
class ProcessExitMsg {
  ProcessExitMsg({
    required this.pid,
    required this.reason,
    required this.reasonName,
    required this.classification,
    required this.status,
    required this.timestampMs,
  });

  int pid;

  /// `ApplicationExitInfo.REASON_*`.
  int reason;
  String reasonName;

  /// Stable name (ExitDecoder.kt): nativeCrash, crash, lowMemory,
  /// likelyLowMemory, memoryLimiter, signaled, anr, excessiveResourceUsage,
  /// exitSelf, userStopped, freezer, system, other, unknown.
  String classification;

  /// Exit code, or the signal number for signaled / native-crash exits.
  int status;
  String? details;
  int? importance;
  int? pssBytes;
  int? rssBytes;
  int timestampMs;

  /// What the service last passed to `setProcessStateSummary`.
  Uint8List? processStateSummary;

  /// Signal, abort message, cause and top frames of the crashing thread
  /// (paths reduced to file names; no registers, memory or logs).
  String? tombstone;
}

// ---------------------------------------------------------------------------
// Calls: Dart → service (each answered by CallResult/CallError unless noted)

sealed class EngineCall {}

/// Opens the engine library in the service process (dlopen + ABI check)
/// and runs `se_backend_init`. Idempotent. Result: [EngineInfoMsg].
class StartCall extends EngineCall {
  StartCall({required this.library});

  /// Bare name inside the APK (`libsherpa_engine.so`) or an absolute path.
  String library;
  String? crashBreadcrumbPath;
  String? backendDir;
}

/// Result: String (`se_system_info_json`).
class SystemInfoCall extends EngineCall {}

/// Result: [HandleInfoMsg]. Progress arrives as [LoadProgress] when
/// [progress] is set. [cancelId] (0 = none) names an `se_canceller` that
/// [CancelCall] trips.
class LoadModelCall extends EngineCall {
  LoadModelCall({required this.options, required this.cancelId, required this.progress, required this.phaseTag});

  ModelOptionsMsg options;
  int cancelId;
  bool progress;

  /// Short, non-identifying model tag for `setProcessStateSummary`.
  String phaseTag;
}

class FreeModelCall extends EngineCall {
  FreeModelCall({required this.model});

  int model;
}

/// Result: [MemoryEstimateMsg].
class EstimateMemoryCall extends EngineCall {
  EstimateMemoryCall({required this.model, required this.session});

  ModelOptionsMsg model;
  SessionConfigMsg session;
}

/// Result: [HandleInfoMsg].
class CreateSessionCall extends EngineCall {
  CreateSessionCall({required this.model, required this.config});

  int model;
  SessionConfigMsg config;
}

class FreeSessionCall extends EngineCall {
  FreeSessionCall({required this.session});

  int session;
}

class ResetSessionCall extends EngineCall {
  ResetSessionCall({required this.session});

  int session;
}

class SetThreadsCall extends EngineCall {
  SetThreadsCall({required this.session, required this.nThreads, required this.nThreadsBatch});

  int session;
  int nThreads;
  int nThreadsBatch;
}

/// Result: String.
class SessionInfoCall extends EngineCall {
  SessionInfoCall({required this.session});

  int session;
}

/// Result: [MemoryEstimateMsg].
class SessionMemoryCall extends EngineCall {
  SessionMemoryCall({required this.session});

  int session;
}

/// Starts a generation stream (no CallResult): [StreamStarted] or
/// [StreamFailed], then [EventBatch]es until one with `last`. The service
/// sends at most `kStreamCredits` batches ahead of [CreditCall]s.
class GenerateCall extends EngineCall {
  GenerateCall({required this.streamId, required this.session, required this.requestJson});

  int streamId;
  int session;
  String requestJson;
}

/// Fire-and-forget: the consumer took [n] batches of [streamId].
class CreditCall extends EngineCall {
  CreditCall({required this.streamId, required this.n});

  int streamId;
  int n;
}

/// Fire-and-forget: the consumer is gone; cancel, drain and discard.
class CancelStreamCall extends EngineCall {
  CancelStreamCall({required this.streamId});

  int streamId;
}

/// Fire-and-forget `se_cancel`: the stream (if any) ends with
/// FINISH(cancelled).
class CancelSessionCall extends EngineCall {
  CancelSessionCall({required this.session});

  int session;
}

/// Fire-and-forget: trips the canceller of a running load/bench.
class CancelCall extends EngineCall {
  CancelCall({required this.cancelId});

  int cancelId;
}

/// Result: Int32List.
class TokenizeCall extends EngineCall {
  TokenizeCall({required this.model, required this.text, required this.addSpecial, required this.parseSpecial});

  int model;
  String text;
  bool addSpecial;
  bool parseSpecial;
}

/// Result: String.
class DetokenizeCall extends EngineCall {
  DetokenizeCall({required this.model, required this.tokens, required this.renderSpecial});

  int model;
  Int32List tokens;
  bool renderSpecial;
}

/// Result: int.
class CountChatCall extends EngineCall {
  CountChatCall({required this.model, required this.requestJson});

  int model;
  String requestJson;
}

/// Result: Int32List (count or negative `se_status` per item; texts first).
class CountBatchCall extends EngineCall {
  CountBatchCall({required this.model, required this.texts, required this.chatRequests});

  int model;
  List<String> texts;
  List<String> chatRequests;
}

/// Result: int (file size in bytes).
class SaveStateCall extends EngineCall {
  SaveStateCall({required this.session, required this.path});

  int session;
  String path;
}

/// Result: int (restored tokens).
class LoadStateCall extends EngineCall {
  LoadStateCall({required this.session, required this.path});

  int session;
  String path;
}

/// Result: int (LoRA handle).
class LoadLoraCall extends EngineCall {
  LoadLoraCall({required this.model, required this.path});

  int model;
  String path;
}

class FreeLoraCall extends EngineCall {
  FreeLoraCall({required this.lora});

  int lora;
}

class SetLorasCall extends EngineCall {
  SetLorasCall({required this.session, required this.loras, required this.scales});

  int session;
  List<int> loras;
  List<double> scales;
}

/// Result: [BenchResultMsg].
class BenchCall extends EngineCall {
  BenchCall({required this.model, required this.config, required this.cancelId});

  int model;
  BenchConfigMsg config;
  int cancelId;
}

/// Frees everything; the reply comes after the last handle is gone.
class ShutdownCall extends EngineCall {}

/// Debuggable builds only: makes the service process die the given way
/// (`abort`, `segv`, `kill`, `exit`) to exercise crash handling on a device.
class DebugCrashCall extends EngineCall {
  DebugCrashCall({required this.mode});

  String mode;
}

// ---------------------------------------------------------------------------
// Messages: service / plugin → Dart, in order

sealed class InferenceMessage {}

class CallResult extends InferenceMessage {
  CallResult({required this.requestId});

  int requestId;
  Object? value;
}

/// [code] is an `se_status` (SE_ERR_UNSUPPORTED for "engine unavailable").
class CallError extends InferenceMessage {
  CallError({required this.requestId, required this.code, required this.message});

  int requestId;
  int code;
  String message;
}

class LoadProgress extends InferenceMessage {
  LoadProgress({required this.requestId, required this.progress});

  int requestId;
  double progress;
}

class StreamStarted extends InferenceMessage {
  StreamStarted({required this.streamId, required this.generationId});

  int streamId;
  int generationId;
}

/// A refused start (busy, malformed JSON) or a stream ended by the service
/// (session freed).
class StreamFailed extends InferenceMessage {
  StreamFailed({required this.streamId, required this.code, required this.message});

  int streamId;
  int code;
  String message;
}

/// Coalesced events of one generation, in order; [last] = contains FINISH.
class EventBatch extends InferenceMessage {
  EventBatch({required this.streamId, required this.events, required this.last});

  int streamId;
  List<EngineEventMsg> events;
  bool last;
}

enum HostStatusKind {
  /// The service is bound and attached ([HostStatus.pid] set).
  connected,

  /// The bind attempt failed (no service in the manifest, refused, timed
  /// out); [HostStatus.detail] says why. Nothing is bound.
  bindFailed,

  /// The service process died (binder death / disconnect). Every in-flight
  /// call of that connection is lost. Nothing is rebound automatically.
  disconnected,

  /// Follows [disconnected] within a few seconds: the exit record of the
  /// dead process ([HostStatus.exit], null when none was found).
  exitInfo,
}

/// Connection lifecycle, reported by the main-process plugin.
class HostStatus extends InferenceMessage {
  HostStatus({required this.kind, required this.connection});

  HostStatusKind kind;
  int connection;
  int? pid;
  String? detail;
  ProcessExitMsg? exit;
}

/// How the main process binds the service (Context.BIND_* flags).
enum BindPolicy {
  /// Base binding `BIND_AUTO_CREATE | BIND_NOT_PERCEPTIBLE` (an idle engine
  /// may be reclaimed before perceptible work), plus a second
  /// `BIND_AUTO_CREATE | BIND_IMPORTANT` binding while work is in flight
  /// (foreground level and top-app CPU scheduling while the UI is in front;
  /// the importance of the app's foreground service otherwise).
  adaptive,

  /// `BIND_AUTO_CREATE` only (plain importance inheritance, capped at
  /// visible); busy bindings add `BIND_IMPORTANT`.
  inherit,

  /// Always `BIND_AUTO_CREATE | BIND_IMPORTANT`.
  important,
}

@HostApi()
abstract class InferenceHostApi {
  /// Starts a fresh connection (tearing down any previous one, e.g. after a
  /// hot restart) and returns its id. The outcome arrives as [HostStatus]
  /// `connected` or `bindFailed`. Never blocks: binding happens on the
  /// plugin's IPC thread.
  int connect(BindPolicy policy);

  /// Ships [call] to the service of [connection] (one oneway Binder
  /// transaction; large payloads go through SharedMemory). Throws
  /// `SherpaInferenceError('not_connected')` when [connection] is not live.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void send(int connection, int requestId, EngineCall call);

  /// Raises (busy) or lowers the service's importance (see [BindPolicy]).
  void setBusy(int connection, bool busy);

  /// Unbinds [connection] (idle or dispose). No [HostStatus] follows.
  void disconnect(int connection);
}

@EventChannelApi()
abstract class InferenceEventApi {
  InferenceMessage inferenceMessages();
}
