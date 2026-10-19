// Pigeon definition for sherpa_apple_ml (platform-channel mode, R06 §11.2).
//
// Regenerate from packages/sherpa_apple_ml:
//   dart run pigeon --input pigeons/apple_ml_api.dart
//
// Design rules:
// - Swift owns tensors, sessions and OS lifecycles only. Every decision that
//   can be made in Dart is made in Dart and unit-tested on the host against a
//   fake of this API (PLAN §2): which history mode to use (append, rebuild,
//   continue), message mapping, JSON-schema → Foundation Models schema
//   conversion (sent here as a small IR), reasoning-tag splitting, error and
//   finish-reason mapping, admission and availability verdicts.
// - Request/response calls are `@async` host methods that return as soon as
//   the work is accepted (or finished, for loads); token streams arrive on ONE
//   event channel as [AmEventBatch]es tagged with a generation id.
// - Flow control: Swift coalesces deltas (~16 ms) and keeps at most 4 batches
//   per generation outstanding; Dart returns one credit per delivered batch
//   ([AppleMlHostApi.ack]) and none while the consumer is paused, so the
//   channel buffer is bounded (text keeps coalescing natively meanwhile).
// - Channel mode, not FFI: Pigeon 29's native-interop mode rejects event
//   channels (CHANGELOG 29.0.8).
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.pigeon.dart',
    dartPackageName: 'sherpa_apple_ml',
    swiftOut: 'ios/sherpa_apple_ml/Sources/sherpa_apple_ml/Messages.g.swift',
    swiftOptions: SwiftOptions(errorClassName: 'SherpaAppleMlError'),
  ),
)
enum AmEngine { mlx, foundationModels }

/// Raw device facts; every verdict built from them is Dart policy.
class AmPlatformInfo {
  AmPlatformInfo({
    required this.osVersion,
    required this.isSimulator,
    required this.hasMetalDevice,
    required this.mlxCompiled,
    required this.fmCompiled,
    required this.appActive,
    required this.procAvailableBytes,
    required this.physicalMemoryBytes,
    required this.thermalState,
    required this.lowPowerMode,
  });

  /// `UIDevice.systemVersion`, e.g. "27.0.1".
  String osVersion;
  bool isSimulator;

  /// `MTLCreateSystemDefaultDevice() != nil`.
  bool hasMetalDevice;

  /// The plugin was built with mlx-swift-lm (SwiftPM). False for the
  /// CocoaPods build, which cannot carry MLX.
  bool mlxCompiled;

  /// The SDK had the FoundationModels framework (`canImport`).
  bool fmCompiled;

  /// `UIApplication.applicationState == .active`.
  bool appActive;

  /// `os_proc_available_memory()`: limit minus footprint (R06 §5).
  int procAvailableBytes;
  int physicalMemoryBytes;

  /// MLX `GPU.maxRecommendedWorkingSetBytes()`, when MLX is compiled in.
  int? recommendedWorkingSetBytes;

  /// Raw `ProcessInfo.ThermalState` (0 nominal … 3 critical).
  int thermalState;
  bool lowPowerMode;
}

/// Why `SystemLanguageModel.default` cannot be used (R06 §3.1).
enum AmFmUnavailableReason {
  none,

  /// iOS < 26.
  osTooOld,

  /// Built with an SDK without FoundationModels.
  frameworkMissing,
  deviceNotEligible,
  appleIntelligenceNotEnabled,

  /// Downloading, or other system reasons.
  modelNotReady,

  /// A reason this build does not know (the enum is @frozen today, but the
  /// OS may add cases later).
  unknown,
}

class AmFmAvailability {
  AmFmAvailability({required this.available, required this.reason, required this.localeSupported});

  bool available;
  AmFmUnavailableReason reason;

  /// `SystemLanguageModel.contextSize` (4096 on device today).
  int? contextSize;

  /// `supportsLocale(Locale.current)`.
  bool localeSupported;
}

class AmMlxLoadRequest {
  AmMlxLoadRequest({
    required this.modelId,
    required this.directory,
    required this.cacheLimitBytes,
    required this.memoryLimitFraction,
  });

  String modelId;

  /// Local directory with config.json, *.safetensors and the tokenizer.
  /// MLX never downloads: the app's download manager put it there.
  String directory;

  /// `Memory.cacheLimit` (R06 §2.9 suggests 20–64 MB on iOS).
  int cacheLimitBytes;

  /// `Memory.memoryLimit` = fraction × (os_proc_available_memory + MLX
  /// active memory), measured just before the load.
  double memoryLimitFraction;
}

class AmMlxModelInfo {
  AmMlxModelInfo({
    required this.modelId,
    required this.reasoningImplicitEnds,
    required this.reasoningAlwaysOn,
    required this.reasoningPrimed,
    required this.weightsBytes,
    required this.loadMs,
    required this.memoryLimitBytes,
    required this.cacheLimitBytes,
    required this.procAvailableBytes,
  });

  String modelId;
  String? modelType;

  /// Resolved `ModelConfiguration.toolCallFormat` raw value (json, qwen3_5,
  /// gemma4, llama3, …); null = the model has no known tool-call format.
  String? toolCallFormat;

  /// `ModelConfiguration.reasoningConfig`, flattened.
  String? reasoningStart;
  String? reasoningEnd;
  List<String> reasoningImplicitEnds;

  /// `.templateFlag(key:defaultOn:)`.
  String? reasoningToggleKey;
  bool? reasoningToggleDefaultOn;
  bool reasoningAlwaysOn;

  /// The chat template pre-fills the opening reasoning delimiter when
  /// thinking is on (Qwen3.5, DeepSeek-R1): the stream starts inside the
  /// span. Measured at load by rendering a one-message probe and checking
  /// the decoded prompt tail (what mlx-swift-lm seeds its own
  /// ReasoningEventEmitter with).
  bool reasoningPrimed;

  /// MLX active memory added by the load (weights).
  int weightsBytes;
  int loadMs;
  int memoryLimitBytes;
  int cacheLimitBytes;

  /// `os_proc_available_memory()` after the load.
  int procAvailableBytes;
}

/// How the native side must treat its session state for this request (the
/// decision is Dart's HistoryPlanner).
enum AmHistoryMode {
  /// Keep the native session and append [AmMlxGenerateRequest.pending]
  /// (KV cache / transcript stay warm).
  append,

  /// Drop the native session and start a new one from `history`, then send
  /// `pending`.
  rebuild,

  /// MLX: continue a reply that was paused at a token boundary: render
  /// `history` with a generation prompt, then append `partialAssistant`'s
  /// tokens and generate (no ChatSession; the next turn rebuilds).
  continueAssistant,

  /// MLX: start a session from the prompt cache at `cachePath` (fragment
  /// continuation, see README) and send `pending`.
  restoreCache,
}

class AmToolCallWire {
  AmToolCallWire({required this.id, required this.name, required this.argumentsJson});

  String id;
  String name;
  String argumentsJson;
}

/// One chat message as the native engines see it. Roles: system, user,
/// assistant, tool.
class AmWireMessage {
  AmWireMessage({required this.role, required this.content});

  String role;
  String content;
  List<AmToolCallWire>? toolCalls;

  /// Tool results: the call answered and the tool's name.
  String? toolCallId;
  String? toolName;
}

class AmSampling {
  AmSampling();

  double? temperature;
  double? topP;
  int? topK;
  double? minP;
  double? repetitionPenalty;
  int? repetitionContextSize;
  double? presencePenalty;
  double? frequencyPenalty;
  int? maxTokens;
  int? seed;
}

/// mlx-swift-lm `GenerateParameters` KV fields (R06 §2.4). Use either
/// [kvScheme] or [kvBits] (+ group size / start), never the typed cache.
class AmKvConfig {
  AmKvConfig();

  int? kvBits;
  int? kvGroupSize;
  int? quantizedKVStart;
  String? kvScheme;
  int? maxKVSize;
  int? prefillStepSize;
}

class AmMlxGenerateRequest {
  AmMlxGenerateRequest({
    required this.generationId,
    required this.modelId,
    required this.sessionKey,
    required this.ephemeral,
    required this.mode,
    required this.history,
    required this.pending,
    required this.sampling,
    required this.kv,
  });

  String generationId;
  String modelId;

  /// Native session handle (the Sherpa session id, or a one-off key).
  String sessionKey;

  /// Drop the native session when the generation ends.
  bool ephemeral;
  AmHistoryMode mode;

  /// System prompt (ChatSession `instructions`).
  String? instructions;
  List<AmWireMessage> history;
  List<AmWireMessage> pending;
  String? partialAssistant;

  /// OpenAI-style function tools as JSON (`ToolSpec` array).
  String? toolsJson;
  AmSampling sampling;
  AmKvConfig kv;

  /// Chat-template switch (e.g. `enable_thinking`), when the model has one.
  String? thinkingKey;
  bool? thinkingEnabled;

  /// [AmHistoryMode.restoreCache]: the `.safetensors` prompt cache.
  String? cachePath;
}

class AmFmTool {
  AmFmTool({required this.name, required this.summary, required this.schemaJson});

  String name;

  /// The tool's description (named `summary` because Swift reserves
  /// `description`).
  String summary;

  /// Schema IR (lib/src/fm/fm_schema.dart) that Swift maps 1:1 onto
  /// `DynamicGenerationSchema` / `GenerationSchema(root:dependencies:)`.
  String schemaJson;
}

class AmFmGenerateRequest {
  AmFmGenerateRequest({
    required this.generationId,
    required this.sessionKey,
    required this.ephemeral,
    required this.mode,
    required this.history,
    required this.prompt,
    required this.tools,
    required this.sampling,
    required this.greedy,
  });

  String generationId;
  String sessionKey;
  bool ephemeral;

  /// append or rebuild (a `Transcript` built from [history]).
  AmHistoryMode mode;
  String? instructions;
  List<AmWireMessage> history;

  /// The new user turn (`streamResponse(to:)`).
  String prompt;
  List<AmFmTool> tools;

  /// Guided generation: schema IR for `streamResponse(to:schema:)`.
  String? responseSchemaJson;
  AmSampling sampling;
  bool greedy;
}

/// Dart's answer to an [AmEventKind.toolRequest].
class AmToolResult {
  AmToolResult({required this.callId, required this.output, required this.isError});

  String callId;
  String output;
  bool isError;
}

enum AmEventKind {
  /// Coalesced text (MLX: raw chunks incl. reasoning tags; FM: snapshot
  /// diffs).
  text,

  /// MLX: a parsed tool call (`Generation.toolCall`).
  toolCall,

  /// MLX: `Generation.rejectedToolCall` (code = reason).
  rejectedToolCall,

  /// FM: `Tool.call` is suspended until Dart answers with
  /// `fmSubmitToolResults`.
  toolRequest,

  /// Token counts and timings.
  info,

  /// Terminal: code = stop | length | cancelled | refusal | guardrail.
  finished,

  /// Terminal: stopped at a token boundary because the app is leaving the
  /// foreground (code = reason).
  paused,

  /// Terminal: code = error kind (see lib/src/common/errors.dart).
  error,

  /// Not terminal: the GPU gate is closed (app not active); generation waits.
  waiting,
  notice,

  /// Global (generation id ''): memory warning handled natively.
  memoryWarning,

  /// Global: app activity changed (code = active | inactive | background).
  lifecycle,
}

class AmEvent {
  AmEvent({required this.kind});

  AmEventKind kind;
  String? text;
  int? index;
  String? callId;
  String? toolName;
  String? argumentsJson;
  String? code;
  String? message;
  int? promptTokens;
  int? cachedPromptTokens;
  int? generationTokens;
  int? reasoningTokens;
  double? promptTimeSec;
  double? generateTimeSec;
  int? rejectedToolCalls;
  int? recoveredToolCalls;
  int? proposedDraftTokens;
  int? acceptedDraftTokens;
  int? bytes;
}

class AmEventBatch {
  AmEventBatch({required this.generationId, required this.seq, required this.events});

  /// '' for global events (no credit needed).
  String generationId;

  /// Per generation, from 0; echoed in [AppleMlHostApi.ack].
  int seq;
  List<AmEvent> events;
}

@HostApi()
abstract class AppleMlHostApi {
  AmPlatformInfo platformInfo();

  @async
  AmFmAvailability fmAvailability();

  /// Loads (or returns the already loaded) model. Runs off the main thread.
  @async
  AmMlxModelInfo mlxLoad(AmMlxLoadRequest request);

  @async
  void mlxUnload(String modelId);

  /// Accepts the generation; events follow on the channel.
  @async
  void mlxGenerate(AmMlxGenerateRequest request);

  @async
  int mlxCountTokens(String modelId, String text);

  /// `ChatSession.saveCache(to:)`; false when the session has no cache yet.
  @async
  bool mlxSavePromptCache(String sessionKey, String path);

  @async
  void fmGenerate(AmFmGenerateRequest request);

  /// Resumes the suspended `Tool.call`s of [generationId].
  void fmSubmitToolResults(String generationId, List<AmToolResult> results);

  /// `LanguageModelSession.prewarm` (skipped natively in the background).
  void fmPrewarm(String? instructions);

  /// Stops at the next token boundary; ends with `finished(cancelled)`.
  void cancel(String generationId);

  /// One flow-control credit for batch [seq] of [generationId].
  void ack(String generationId, int seq);

  /// Pauses every MLX generation at a token boundary (`paused` events), e.g.
  /// for thermal-critical policy decided in Dart.
  void interruptAll(String reason);

  @async
  void dropSession(AmEngine engine, String sessionKey);
}

@EventChannelApi()
abstract class AppleMlEventApi {
  AmEventBatch events();
}
