// Pigeon definition for sherpa_litert (platform-channel mode).
//
// Regenerate from packages/sherpa_litert:
//   dart run pigeon --input pigeons/litert_api.dart
//
// Design rules (PLAN §2: no business logic in Kotlin):
// - Kotlin executes; Dart decides. The backend order, when to rebuild a
//   conversation, how to render the transcript, the prompted tool format,
//   error classification, the foreground-only rule and the memory-pressure
//   threshold are Dart policy (lib/src/**), unit-tested on the host. Kotlin
//   loads, tries backends in the order it is given, streams, cancels and
//   reports raw codes.
// - Every engine call runs on a dedicated executor in Kotlin, never on the
//   platform main thread. Host calls answer at once (@async replies come
//   from that executor); long work streams on the event channel.
// - Streaming: one event channel ([LiteRtEventApi.events]) carries batches
//   of one stream each. A stream may have [kStreamCredits] batches in flight;
//   Dart returns a credit per batch it delivered ([LiteRtHostApi.credit]).
//   Out of credits, Kotlin coalesces deltas up to a byte cap and then blocks
//   the engine's callback thread, which stops decoding (bounded buffering on
//   both sides, real backpressure).
// - Stream ids are minted in Dart and unique per app run; 0 is reserved for
//   global events (memory trim, engine released).
// - Channel mode, not JNI interop: event channels need it (R09 §4).
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/src/messages.pigeon.dart',
  dartPackageName: 'sherpa_litert',
  kotlinOut: 'android/src/main/kotlin/io/github/mihok/sherpa_litert/Messages.g.kt',
  kotlinOptions: KotlinOptions(package: 'io.github.mihok.sherpa_litert', errorClassName: 'SherpaLitertError'),
))
// ---------------------------------------------------------------------------
// Device and model facts (raw readings)

class PlatformInfoMsg {
  PlatformInfoMsg({
    required this.apiLevel,
    required this.supportedAbis,
    required this.nativeLibraryDir,
    required this.cacheDir,
    required this.liteRtAvailable,
    required this.mlKitAvailable,
  });

  int apiLevel;

  /// `Build.SUPPORTED_ABIS`, best first.
  List<String> supportedAbis;

  /// `Build.SOC_MANUFACTURER` / `Build.SOC_MODEL` (API 31+).
  String? socManufacturer;
  String? socModel;

  /// `applicationInfo.nativeLibraryDir` (NPU dispatch libraries live here).
  String nativeLibraryDir;

  /// `context.cacheDir` (LiteRT-LM's compiled-model cache).
  String cacheDir;

  /// The LiteRT-LM JNI library loaded (false on ABIs it does not ship).
  bool liteRtAvailable;
  String? liteRtError;

  /// ML Kit GenAI classes are present (the plugin always bundles them).
  bool mlKitAvailable;
}

/// `ModelInfo.from(path)` + `LlmCapability` of a `.litertlm` file.
class ModelInfoMsg {
  ModelInfoMsg({
    required this.modelType,
    required this.maxContextTokens,
    required this.dynamicContext,
    required this.vision,
    required this.audio,
    required this.textBackends,
    required this.supportsFunctionCalling,
    required this.supportsThinking,
    required this.speculativeDecoding,
    required this.fileBytes,
  });

  /// `llm`, `embedding` or `unknown`.
  String modelType;
  int maxContextTokens;
  bool dynamicContext;
  bool vision;
  bool audio;

  /// `supportedBackends(TEXT)`: `cpu`, `gpu`, `npu`.
  List<String> textBackends;

  /// `npuBrand(TEXT)` (`qualcomm`, `google_tensor`, ...) when the file is
  /// compiled for an NPU, else null.
  String? npuBrand;

  /// `socName(TEXT)`, e.g. `sm8750`, for SoC-specific NPU files.
  String? socName;
  String? minRuntimeVersion;
  bool supportsFunctionCalling;
  bool supportsThinking;
  bool speculativeDecoding;
  double? defaultTemperature;
  int? defaultTopK;
  double? defaultTopP;
  int fileBytes;
}

// ---------------------------------------------------------------------------
// LiteRT-LM engine

class LoadRequestMsg {
  LoadRequestMsg({
    required this.path,
    required this.backends,
    required this.vision,
    required this.audio,
    required this.benchmark,
  });

  String path;

  /// Backends to try, in order (`npu`, `gpu`, `cpu`); the first that
  /// initializes wins.
  List<String> backends;

  /// `EngineConfig.maxNumTokens` (the KV/context size). Null = model default.
  int? maxNumTokens;
  int? cpuThreads;
  String? cacheDir;

  /// Create a vision (GPU) / audio (CPU) backend for multimodal input.
  bool vision;
  bool audio;

  /// `ExperimentalFlags.enableBenchmark` (TTFT, prefill/decode counts).
  bool benchmark;
}

class LoadResultMsg {
  LoadResultMsg({
    required this.backend,
    required this.failures,
    required this.initMs,
    required this.reused,
  });

  /// The backend that initialized.
  String backend;

  /// `backend: message` for each backend that failed before it.
  List<String> failures;
  double initMs;

  /// The same engine was already loaded with this configuration.
  bool reused;

  /// Whether the model's chat template renders registered tools (a probe
  /// conversation with a dummy tool, `renderPrefaceIntoString`). Null when
  /// the probe failed. The metadata flag `supportsFunctionCalling` is not
  /// reliable: Qwen3-0.6B reports false yet calls tools natively, SmolLM2's
  /// template silently drops tools (host run, 2026-10-19).
  bool? templateRendersTools;
}

class ToolCallMsg {
  ToolCallMsg({required this.name, required this.argumentsJson});

  String name;

  /// A JSON object.
  String argumentsJson;
}

class ToolResponseMsg {
  ToolResponseMsg({required this.name, required this.responseJson});

  String name;

  /// Any JSON value (a string for plain text results).
  String responseJson;
}

/// One message in LiteRT-LM's conversation format.
class ChatMessageMsg {
  ChatMessageMsg({required this.role});

  /// `system`, `user`, `model` or `tool`.
  String role;
  String? text;
  List<ToolCallMsg>? toolCalls;
  List<ToolResponseMsg>? toolResponses;

  /// Inline images (user messages, vision models).
  List<Uint8List>? images;

  /// Image files (absolute paths).
  List<String>? imagePaths;

  /// Reasoning (`channels["thought"]`) of a model message.
  String? thought;
}

/// A native `Conversation` to create (replacing one with the same id).
class ConversationSpecMsg {
  ConversationSpecMsg({
    required this.conversationId,
    required this.history,
    required this.toolsJson,
    required this.enableResponseFormat,
  });

  String conversationId;
  String? systemInstruction;

  /// `initialMessages`.
  List<ChatMessageMsg> history;

  /// OpenAPI function descriptions (`{"name","description","parameters"}`),
  /// registered as `OpenApiTool`s with `automaticToolCalling = false`.
  List<String> toolsJson;

  /// All four set, or none (engine defaults).
  int? topK;
  double? topP;
  double? temperature;
  int? seed;
  bool enableResponseFormat;
}

class SendRequestMsg {
  SendRequestMsg({required this.streamId, required this.conversationId, required this.message});

  int streamId;
  String conversationId;
  ChatMessageMsg message;
  int? maxOutputTokens;

  /// `ThinkingConfig` for this message (null = conversation default).
  bool? enableThinking;
  int? thinkingBudget;

  /// `ResponseFormat.json(schema)`.
  String? responseSchemaJson;
}

// ---------------------------------------------------------------------------
// Gemini Nano (ML Kit GenAI Prompt API)

class NanoConfigMsg {
  NanoConfigMsg({required this.releaseStage, required this.preference});

  /// `ModelReleaseStage.STABLE` (0) / `PREVIEW` (1).
  int releaseStage;

  /// `ModelPreference.FAST` (1) / `FULL` (2).
  int preference;
}

class NanoStatusMsg {
  NanoStatusMsg({required this.featureStatus});

  /// `FeatureStatus`: 0 unavailable, 1 downloadable, 2 downloading,
  /// 3 available; -1 when `checkStatus` threw ([error] set).
  int featureStatus;
  String? baseModelName;
  int? tokenLimit;
  bool? systemPrompt;
  bool? thinking;
  bool? structuredOutput;
  bool? caching;
  ErrorMsg? error;
}

class NanoRequestMsg {
  NanoRequestMsg({
    required this.streamId,
    required this.config,
    required this.prompt,
    required this.enableThinking,
    required this.countTokens,
  });

  int streamId;
  NanoConfigMsg config;

  /// `SystemInstruction` (only when `isSystemPromptAvailable`).
  String? systemInstruction;
  String prompt;
  List<Uint8List>? images;
  double? temperature;
  int? topK;
  int? seed;
  int? maxOutputTokens;
  bool enableThinking;

  /// Count prompt (before) and output (after) tokens for usage.
  bool countTokens;
}

// ---------------------------------------------------------------------------
// Events

enum EventKind {
  // Generation streams.
  textDelta,
  reasoningDelta,
  toolCalls,

  /// Terminal: finished normally ([LiteRtEvent.stats]).
  done,

  /// Terminal: stopped by a cancel ([LiteRtEvent.detail] = the reason Dart
  /// gave, or `memory_pressure` for an onTrimMemory release).
  cancelled,

  /// Terminal: failed ([LiteRtEvent.error]).
  error,

  // Gemini Nano download streams.
  downloadStarted,
  downloadProgress,
  downloadCompleted,
  downloadFailed,

  // Global (stream 0).
  /// `onTrimMemory` ([LiteRtEvent.value] = level).
  trimMemory,

  /// The engine was closed ([LiteRtEvent.detail] = why).
  engineReleased,
}

class ErrorMsg {
  ErrorMsg({required this.source, required this.code, required this.message});

  /// `litert` (status code parsed from LiteRtLmJniException, or -1),
  /// `nano` (GenAiException.errorCode), `state`, `argument`, `io`, `host`.
  String source;
  int code;
  String message;
  int? retryAfterMs;
}

class GenerationStatsMsg {
  GenerationStatsMsg();

  /// LiteRT-LM `BenchmarkInfo` (null when benchmarking is off).
  int? prefillTokens;
  int? decodeTokens;
  double? timeToFirstTokenMs;
  double? prefillTokensPerSec;
  double? decodeTokensPerSec;

  /// `Conversation.getTokenCount()` before and after the turn.
  int? kvTokensBefore;
  int? kvTokensAfter;
  String? backend;

  /// Gemini Nano: `Candidate.finishReason` and token counts.
  int? finishReason;
  int? promptTokens;
  int? outputTokens;
}

class LiteRtEvent {
  LiteRtEvent({required this.kind});

  EventKind kind;
  String? text;
  List<ToolCallMsg>? toolCalls;
  GenerationStatsMsg? stats;
  ErrorMsg? error;
  int? value;
  String? detail;
}

/// Events of one stream (0 = global), in order.
class EventBatch {
  EventBatch({required this.streamId, required this.events});

  int streamId;
  List<LiteRtEvent> events;
}

// ---------------------------------------------------------------------------
// APIs

@HostApi()
abstract class LiteRtHostApi {
  @async
  PlatformInfoMsg platformInfo();

  /// `ModelInfo.from(path)`; does not load weights.
  @async
  ModelInfoMsg inspectModel(String path);

  /// Loads (or reuses) THE engine. A different path/config closes the old
  /// one first, with its conversations.
  @async
  LoadResultMsg loadEngine(LoadRequestMsg request);

  /// Closes every conversation and the engine (no-op when none).
  @async
  void releaseEngine(String reason);

  @async
  void openConversation(ConversationSpecMsg spec);

  @async
  void closeConversation(String conversationId);

  /// Starts a turn; everything else arrives on stream [SendRequestMsg.streamId].
  void sendMessage(SendRequestMsg request);

  /// Stops [streamId] at the next token (LiteRT `cancelProcess`, Nano job
  /// cancel); the stream ends with `cancelled` ([reason] echoed).
  void cancel(int streamId, String reason);

  void credit(int streamId, int batches);

  /// `onTrimMemory` level at or above which a running generation is stopped
  /// and the engine freed (0 = never). Dart policy; default 40.
  void setTrimPolicy(int releaseAtLevel);

  @async
  NanoStatusMsg nanoStatus(NanoConfigMsg config);

  /// Starts `download()`; progress arrives on stream [streamId].
  void nanoDownload(int streamId, NanoConfigMsg config);

  @async
  void nanoWarmup(NanoConfigMsg config);

  void nanoGenerate(NanoRequestMsg request);

  /// `ActivityManager.getMyMemoryState().importance == IMPORTANCE_FOREGROUND`.
  bool isAppInForeground();
}

@EventChannelApi()
abstract class LiteRtEventApi {
  EventBatch events();
}
