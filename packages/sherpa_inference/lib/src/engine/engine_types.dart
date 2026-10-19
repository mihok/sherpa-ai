import 'package:meta/meta.dart';

import '../ffi/bindings.dart';

/// KV cache element types (`se_kv_type`; ggml type ids, stable because they
/// are part of the GGUF format).
enum KvType {
  /// Engine default (f16).
  engineDefault(-1, 'default'),
  f32(0, 'f32'),
  f16(1, 'f16'),
  q4_0(2, 'q4_0'),
  q4_1(3, 'q4_1'),
  q5_0(6, 'q5_0'),
  q5_1(7, 'q5_1'),
  q8_0(8, 'q8_0'),
  iq4Nl(20, 'iq4_nl'),
  bf16(30, 'bf16');

  const KvType(this.code, this.label);

  /// The `se_kv_type` value.
  final int code;
  final String label;

  /// A quantized V cache needs flash attention (header se_session_params
  /// type_v; R04 §0.6).
  bool get isQuantized => switch (this) {
        f32 || f16 || bf16 || engineDefault => false,
        _ => true,
      };

  /// Precision rank used by policies: higher is better.
  int get precisionRank => switch (this) {
        f32 => 9,
        f16 || bf16 || engineDefault => 8,
        q8_0 => 6,
        q5_1 || q5_0 => 4,
        q4_1 || q4_0 || iq4Nl => 2,
      };

  static KvType byLabel(String label) =>
      values.firstWhere((t) => t.label == label, orElse: () => label == 'default' ? engineDefault : f16);
}

/// `flash_attn`: -1 auto, 0 off, 1 on.
enum FlashAttention {
  auto(-1),
  off(0),
  on(1);

  const FlashAttention(this.code);
  final int code;
}

/// `se_spec_type`.
enum SpeculativeMode {
  auto(-1),
  none(0),
  ngram(1),
  draft(2),
  mtp(3);

  const SpeculativeMode(this.code);
  final int code;
}

/// `se_load_mode`.
enum LoadMode {
  auto(-1),
  none(0),
  mmap(1),
  mlock(2),
  mmapMlock(3),
  directIo(4);

  const LoadMode(this.code);
  final int code;
}

/// Options for `se_model_load` / `se_estimate_memory`.
@immutable
final class ModelLoadOptions {
  const ModelLoadOptions({
    required this.path,
    this.modelId,
    this.nGpuLayers = -1,
    this.loadMode = LoadMode.auto,
    this.useExtraBuffers = true,
    this.vocabOnly = false,
    this.loadMtp = false,
    this.chatTemplateOverride,
    this.mmprojPath,
    this.draftModelPath,
  });

  final String path;

  /// Identity recorded in state files and checked on load (e.g.
  /// `sha256:<hex>`). Null = the engine's quick fingerprint (header
  /// se_model_params.model_id).
  final String? modelId;
  final int nGpuLayers;
  final LoadMode loadMode;

  /// Weight repack buffers (KleidiAI / CPU_REPACK / AMX).
  final bool useExtraBuffers;
  final bool vocabOnly;
  final bool loadMtp;
  final String? chatTemplateOverride;
  final String? mmprojPath;
  final String? draftModelPath;

  ModelLoadOptions copyWith({bool? vocabOnly, int? nGpuLayers, String? draftModelPath}) => ModelLoadOptions(
        path: path,
        modelId: modelId,
        nGpuLayers: nGpuLayers ?? this.nGpuLayers,
        loadMode: loadMode,
        useExtraBuffers: useExtraBuffers,
        vocabOnly: vocabOnly ?? this.vocabOnly,
        loadMtp: loadMtp,
        chatTemplateOverride: chatTemplateOverride,
        mmprojPath: mmprojPath,
        draftModelPath: draftModelPath ?? this.draftModelPath,
      );
}

/// Options for `se_session_create` (and the estimate dry run). Zero / null
/// means "engine default" exactly as in the header.
@immutable
final class SessionConfig {
  const SessionConfig({
    this.nCtx = 0,
    this.nBatch = 0,
    this.nUbatch = 0,
    this.nThreads = 0,
    this.nThreadsBatch = 0,
    this.typeK = KvType.engineDefault,
    this.typeV = KvType.engineDefault,
    this.flashAttention = FlashAttention.auto,
    this.nOutputsMax = 0,
    this.swaFull = -1,
    this.seed = kSeSeedRandom,
    this.speculative = SpeculativeMode.none,
    this.specMaxDraft = 0,
    this.eventCapacity = 0,
  });

  /// 0 = 4096 capped at n_ctx_train; padded to a multiple of 256.
  final int nCtx;
  final int nBatch;
  final int nUbatch;
  final int nThreads;
  final int nThreadsBatch;
  final KvType typeK;
  final KvType typeV;
  final FlashAttention flashAttention;
  final int nOutputsMax;
  final int swaFull;
  final int seed;
  final SpeculativeMode speculative;
  final int specMaxDraft;

  /// Event ring slots; 0 = 256. A full ring blocks the engine worker, which
  /// is how a paused Dart stream becomes real backpressure.
  final int eventCapacity;

  /// Flash attention as the engine will resolve it for this config (a
  /// quantized V cache forces it on with `auto`).
  bool get requiresFlashAttention => typeV.isQuantized;

  SessionConfig copyWith({
    int? nCtx,
    int? nBatch,
    int? nUbatch,
    int? nThreads,
    int? nThreadsBatch,
    KvType? typeK,
    KvType? typeV,
    FlashAttention? flashAttention,
    int? seed,
    SpeculativeMode? speculative,
  }) =>
      SessionConfig(
        nCtx: nCtx ?? this.nCtx,
        nBatch: nBatch ?? this.nBatch,
        nUbatch: nUbatch ?? this.nUbatch,
        nThreads: nThreads ?? this.nThreads,
        nThreadsBatch: nThreadsBatch ?? this.nThreadsBatch,
        typeK: typeK ?? this.typeK,
        typeV: typeV ?? this.typeV,
        flashAttention: flashAttention ?? this.flashAttention,
        nOutputsMax: nOutputsMax,
        swaFull: swaFull,
        seed: seed ?? this.seed,
        speculative: speculative ?? this.speculative,
        specMaxDraft: specMaxDraft,
        eventCapacity: eventCapacity,
      );

  /// KV layout label used in cache keys and diagnostics, e.g. `q8_0/q8_0`.
  String get kvLabel => '${(typeK == KvType.engineDefault ? KvType.f16 : typeK).label}/'
      '${(typeV == KvType.engineDefault ? KvType.f16 : typeV).label}';

  @override
  String toString() => 'SessionConfig(n_ctx $nCtx, batch $nBatch/$nUbatch, threads $nThreads/$nThreadsBatch, '
      'kv $kvLabel, fa ${flashAttention.name})';
}

/// `se_memory_estimate`: the no-alloc dry run (or a live session's real
/// allocations).
@immutable
final class MemoryEstimate {
  const MemoryEstimate({
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

  final int nCtx;
  final int nCtxSeq;
  final bool flashAttention;
  final int modelBytes;

  /// File-backed (mmap) share of [modelBytes]: reclaimable clean pages that
  /// the Android 17 limiter does not count (R07 §2.3).
  final int modelMappedBytes;
  final int kvBytes;
  final int computeBytes;
  final int outputBytes;
  final int totalBytes;
  final int kvBytesPerToken;
  final int fileBytes;

  /// Anonymous (non file-backed) memory: what process limiters count.
  int get anonymousBytes => totalBytes - modelMappedBytes;

  /// Everything except the KV cache (weights, compute, logits).
  int get fixedBytes => totalBytes - kvBytes;

  @override
  String toString() => 'MemoryEstimate(n_ctx $nCtx, total ${_mib(totalBytes)}, model ${_mib(modelBytes)} '
      '(${_mib(modelMappedBytes)} mapped), kv ${_mib(kvBytes)}, compute ${_mib(computeBytes)})';
}

String _mib(int b) => '${(b / (1024 * 1024)).toStringAsFixed(1)} MiB';

/// `se_bench_params`.
@immutable
final class BenchConfig {
  const BenchConfig({
    this.nThreads = 0,
    this.nThreadsBatch = 0,
    this.nBatch = 0,
    this.nUbatch = 0,
    this.nCtx = 0,
    this.nPrompt = 0,
    this.nGen = 0,
    this.nReps = 0,
    this.typeK = KvType.engineDefault,
    this.typeV = KvType.engineDefault,
    this.flashAttention = FlashAttention.auto,
  });

  final int nThreads;
  final int nThreadsBatch;
  final int nBatch;
  final int nUbatch;
  final int nCtx;
  final int nPrompt;
  final int nGen;
  final int nReps;
  final KvType typeK;
  final KvType typeV;
  final FlashAttention flashAttention;
}

/// `se_bench_result`.
@immutable
final class BenchResult {
  const BenchResult({
    required this.nPrompt,
    required this.nGen,
    required this.nThreads,
    required this.promptTokensPerSec,
    required this.genTokensPerSec,
    required this.promptMs,
    required this.genMs,
  });

  final int nPrompt;
  final int nGen;
  final int nThreads;
  final double promptTokensPerSec;
  final double genTokensPerSec;
  final double promptMs;
  final double genMs;
}

/// `se_event_type` as an enum.
enum EngineEventType {
  textDelta(SeEventType.textDelta),
  reasoningDelta(SeEventType.reasoningDelta),
  toolCallStart(SeEventType.toolCallStart),
  toolCallArgsDelta(SeEventType.toolCallArgsDelta),
  toolCallDone(SeEventType.toolCallDone),
  usage(SeEventType.usage),
  perf(SeEventType.perf),
  finish(SeEventType.finish),
  error(SeEventType.error),
  promptProgress(SeEventType.promptProgress),

  /// An event type this app does not know (a newer engine); ignored.
  unknown(0);

  const EngineEventType(this.code);
  final int code;

  static EngineEventType of(int code) => switch (code) {
        SeEventType.textDelta => textDelta,
        SeEventType.reasoningDelta => reasoningDelta,
        SeEventType.toolCallStart => toolCallStart,
        SeEventType.toolCallArgsDelta => toolCallArgsDelta,
        SeEventType.toolCallDone => toolCallDone,
        SeEventType.usage => usage,
        SeEventType.perf => perf,
        SeEventType.finish => finish,
        SeEventType.error => error,
        SeEventType.promptProgress => promptProgress,
        _ => unknown,
      };
}

/// One engine event, a flat copy of `se_event` (strings copied out of the
/// engine's buffers). Flat on purpose: the same shape crosses isolate ports
/// here and Binder/Pigeon in the Android process host.
///
/// Field meanings per type are exactly the header's (se_event_type):
/// text/reasoning deltas carry [text]; tool-call events [index], [id],
/// [name] and argument [text]; USAGE token counts; PERF timings and
/// [name] = backend; FINISH [code] = se_finish_reason, [name] = reason,
/// [text] = final assistant message JSON; ERROR [code] = se_status,
/// [text] = message (always followed by FINISH(error)).
@immutable
final class EngineEvent {
  const EngineEvent({
    required this.type,
    this.generationId = 0,
    this.index = -1,
    this.code = 0,
    this.text = '',
    this.id = '',
    this.name = '',
    this.promptTokens = 0,
    this.cachedTokens = 0,
    this.completionTokens = 0,
    this.nDrafted = 0,
    this.nAccepted = 0,
    this.progressDone = 0,
    this.progressTotal = 0,
    this.ttftMs = 0,
    this.prefillTps = 0,
    this.decodeTps = 0,
    this.draftAcceptRate = 0,
    this.prefillMs = 0,
    this.decodeMs = 0,
  });

  const EngineEvent.text(this.text, {this.generationId = 0})
      : type = EngineEventType.textDelta,
        index = -1,
        code = 0,
        id = '',
        name = '',
        promptTokens = 0,
        cachedTokens = 0,
        completionTokens = 0,
        nDrafted = 0,
        nAccepted = 0,
        progressDone = 0,
        progressTotal = 0,
        ttftMs = 0,
        prefillTps = 0,
        decodeTps = 0,
        draftAcceptRate = 0,
        prefillMs = 0,
        decodeMs = 0;

  final EngineEventType type;
  final int generationId;
  final int index;
  final int code;
  final String text;
  final String id;
  final String name;
  final int promptTokens;
  final int cachedTokens;
  final int completionTokens;
  final int nDrafted;
  final int nAccepted;
  final int progressDone;
  final int progressTotal;
  final double ttftMs;
  final double prefillTps;
  final double decodeTps;
  final double draftAcceptRate;
  final double prefillMs;
  final double decodeMs;

  bool get isFinish => type == EngineEventType.finish;

  /// A copy with [text] replaced (used when coalescing deltas).
  EngineEvent withText(String text) => EngineEvent(
        type: type,
        generationId: generationId,
        index: index,
        code: code,
        text: text,
        id: id,
        name: name,
        promptTokens: promptTokens,
        cachedTokens: cachedTokens,
        completionTokens: completionTokens,
        nDrafted: nDrafted,
        nAccepted: nAccepted,
        progressDone: progressDone,
        progressTotal: progressTotal,
        ttftMs: ttftMs,
        prefillTps: prefillTps,
        decodeTps: decodeTps,
        draftAcceptRate: draftAcceptRate,
        prefillMs: prefillMs,
        decodeMs: decodeMs,
      );

  @override
  String toString() => switch (type) {
        EngineEventType.textDelta || EngineEventType.reasoningDelta => '${type.name}(${_q(text)})',
        EngineEventType.toolCallStart => 'toolCallStart($index, $id, $name)',
        EngineEventType.toolCallArgsDelta => 'toolCallArgsDelta($index, ${_q(text)})',
        EngineEventType.toolCallDone => 'toolCallDone($index, $id, $name, $text)',
        EngineEventType.usage => 'usage(prompt $promptTokens, cached $cachedTokens, completion $completionTokens)',
        EngineEventType.perf => 'perf(ttft ${ttftMs.toStringAsFixed(0)} ms, pp ${prefillTps.toStringAsFixed(1)}, '
            'tg ${decodeTps.toStringAsFixed(1)} t/s, $name)',
        EngineEventType.finish => 'finish($name)',
        EngineEventType.error => 'error(${SeStatus.name(code)}: $text)',
        EngineEventType.promptProgress => 'promptProgress($progressDone/$progressTotal)',
        EngineEventType.unknown => 'unknown',
      };

  static String _q(String s) => s.length > 40 ? '"${s.substring(0, 40)}…"' : '"$s"';
}

/// Coalesces engine events for delivery without losing any information.
///
/// Adjacent text deltas, adjacent reasoning deltas and adjacent argument
/// deltas of the same tool call are concatenated; consecutive prompt
/// progress events keep only the latest (the counters are cumulative).
/// Every other event is kept as is and in order. Concatenation of deltas is
/// lossless: consumers only ever append them.
abstract final class EventCoalescer {
  static void append(List<EngineEvent> pending, EngineEvent e) {
    if (pending.isNotEmpty) {
      final last = pending.last;
      if (last.type == e.type && last.generationId == e.generationId) {
        switch (e.type) {
          case EngineEventType.textDelta || EngineEventType.reasoningDelta:
            pending[pending.length - 1] = last.withText(last.text + e.text);
            return;
          case EngineEventType.toolCallArgsDelta when last.index == e.index:
            pending[pending.length - 1] = last.withText(last.text + e.text);
            return;
          case EngineEventType.promptProgress:
            pending[pending.length - 1] = e;
            return;
          default:
            break;
        }
      }
    }
    pending.add(e);
  }
}

/// Engine and runtime description returned by [EngineHost.start].
@immutable
final class EngineInfo {
  const EngineInfo({
    required this.abiVersion,
    required this.version,
    required this.systemInfoJson,
    required this.hostKind,
    this.libraryLocator,
  });

  final int abiVersion;

  /// `se_version_string()`.
  final String version;

  /// `se_system_info_json()`.
  final String systemInfoJson;
  final EngineHostKind hostKind;
  final String? libraryLocator;
}

enum EngineHostKind {
  /// Dart FFI into the engine inside the app process (iOS, host tests,
  /// Android fallback).
  inProcessFfi,

  /// The engine isolated from the app in Android's `:inference` process
  /// ([ProcessEngineHost]: a bound service in a private process of the app's
  /// own uid — not `android:isolatedProcess`, which could not open the
  /// model files).
  isolatedProcess,

  /// A test double.
  fake,
}

/// Opaque handle to a native object owned by a host. [epoch] is the host
/// incarnation that created it: a host that loses native state (the Android
/// `:inference` process died) bumps its epoch and refuses older handles with
/// [StaleHandleException].
@immutable
abstract base class EngineHandle {
  const EngineHandle(this.id, this.epoch);

  final int id;
  final int epoch;

  @override
  bool operator ==(Object other) =>
      other is EngineHandle && other.runtimeType == runtimeType && other.id == id && other.epoch == epoch;

  @override
  int get hashCode => Object.hash(runtimeType, id, epoch);

  @override
  String toString() => '$runtimeType(#$id@$epoch)';
}

final class ModelRef extends EngineHandle {
  const ModelRef(super.id, super.epoch);
}

final class SessionRef extends EngineHandle {
  const SessionRef(super.id, super.epoch);
}

final class LoraRef extends EngineHandle {
  const LoraRef(super.id, super.epoch);
}

/// A loaded model: its handle and `se_model_info_json()`.
@immutable
final class EngineModel {
  const EngineModel({required this.ref, required this.infoJson, required this.options});

  final ModelRef ref;
  final String infoJson;
  final ModelLoadOptions options;
}

/// A created session: its handle and `se_session_info_json()` right after
/// creation (resolved n_ctx, KV types, flash attention, threads...).
@immutable
final class EngineSession {
  const EngineSession({required this.ref, required this.model, required this.config, required this.infoJson});

  final SessionRef ref;
  final ModelRef model;
  final SessionConfig config;
  final String infoJson;
}

// ---------------------------------------------------------------------------
// Errors

/// A failed engine call: the `se_status` and `se_last_error()` message.
final class EngineException implements Exception {
  const EngineException(this.code, this.message);

  final int code;
  final String message;

  String get codeName => SeStatus.name(code);

  @override
  String toString() => 'EngineException($codeName): $message';
}

/// The engine (or the isolate / process hosting it) died while a call or a
/// generation was in flight. The host restarts itself; see [EngineHost].
final class EngineCrashedException implements Exception {
  const EngineCrashedException(this.message);

  final String message;

  @override
  String toString() => 'EngineCrashedException: $message';
}

/// A handle from an earlier host incarnation was used after a restart.
final class StaleHandleException implements Exception {
  const StaleHandleException(this.handle);

  final EngineHandle handle;

  @override
  String toString() => 'StaleHandleException: $handle belongs to a previous engine instance';
}

// ---------------------------------------------------------------------------
// Host lifecycle events

@immutable
sealed class EngineHostEvent {
  const EngineHostEvent(this.epoch);

  final int epoch;
}

/// The engine host lost its worker (isolate exit, process death). Every
/// in-flight call and generation of that worker failed with
/// [EngineCrashedException].
final class EngineHostCrashed extends EngineHostEvent {
  const EngineHostCrashed(super.epoch, this.reason, {required this.nativeStateLost});

  final String reason;

  /// True when models and sessions are gone (the handles of [epoch] are now
  /// stale). False for the in-process host, whose native objects survive a
  /// Dart isolate restart.
  final bool nativeStateLost;
}

/// The host is serving again, possibly under a new [epoch].
final class EngineHostRestarted extends EngineHostEvent {
  const EngineHostRestarted(super.epoch);
}
