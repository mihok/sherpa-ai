import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';
import 'package:sherpa_platform/sherpa_platform.dart' show DeviceSnapshot;

import 'perf_stats.dart';

/// Speculative decoding as the lab offers it.
enum SpeculativeChoice {
  off('Off', SpeculativeMode.none),

  /// Self-speculation from n-grams of the context: no extra model.
  ngram('N-gram', SpeculativeMode.ngram),

  /// A separate small draft model from the library.
  draft('Draft model', SpeculativeMode.draft);

  const SpeculativeChoice(this.label, this.mode);

  final String label;
  final SpeculativeMode mode;

  static SpeculativeChoice of(SpeculativeMode? mode) => switch (mode) {
        SpeculativeMode.ngram => ngram,
        SpeculativeMode.draft => draft,
        _ => off,
      };
}

/// One configuration the lab can measure, compare and apply.
///
/// Zero threads or batch sizes mean "engine default" (all performance
/// cores; 512), exactly as in `SessionConfig`. K and V use the same type,
/// as everywhere else in Sherpa.
@immutable
final class LabConfig {
  const LabConfig({
    this.nThreads = 0,
    this.nBatch = 0,
    this.nUbatch = 0,
    this.kv = KvType.f16,
    this.flashAttention = FlashAttention.auto,
    this.speculative = SpeculativeChoice.off,
    this.draftModelId,
  });

  factory LabConfig.fromCandidate(TuningCandidate c, {SpeculativeChoice speculative = SpeculativeChoice.off}) => LabConfig(
        nThreads: c.nThreads,
        nBatch: c.nBatch,
        nUbatch: c.nUbatch,
        kv: _plainKv(c.typeK),
        flashAttention: c.flashAttention,
        speculative: speculative,
      );

  /// The parameters a session was (or will be) created with.
  factory LabConfig.fromSession(SessionConfig c) => LabConfig(
        nThreads: c.nThreads,
        nBatch: c.nBatch,
        nUbatch: c.nUbatch,
        kv: _plainKv(c.typeK),
        flashAttention: c.flashAttention,
        speculative: SpeculativeChoice.of(c.speculative),
      );

  factory LabConfig.fromJson(JsonMap j) => LabConfig(
        nThreads: j.optInt('nThreads') ?? 0,
        nBatch: j.optInt('nBatch') ?? 0,
        nUbatch: j.optInt('nUbatch') ?? 0,
        kv: KvType.byLabel(j.opt<String>('kv') ?? 'f16'),
        flashAttention: FlashAttention.values.where((f) => f.name == j.opt<String>('fa')).firstOrNull ?? FlashAttention.auto,
        speculative:
            SpeculativeChoice.values.where((s) => s.name == j.opt<String>('spec')).firstOrNull ?? SpeculativeChoice.off,
        draftModelId: j.opt<String>('draft'),
      );

  static KvType _plainKv(KvType t) => t == KvType.engineDefault ? KvType.f16 : t;

  final int nThreads;
  final int nBatch;
  final int nUbatch;
  final KvType kv;
  final FlashAttention flashAttention;
  final SpeculativeChoice speculative;

  /// Library id of the draft model ([SpeculativeChoice.draft] only).
  final String? draftModelId;

  /// Needs a real generation to measure: `se_bench` decodes synthetic
  /// tokens without sampling, so it cannot speculate.
  bool get needsGeneration => speculative != SpeculativeChoice.off;

  /// Why the engine would refuse this combination, or null.
  String? get invalidReason {
    if (kv.isQuantized && flashAttention == FlashAttention.off) {
      return 'A ${kv.label} KV cache needs flash attention (set it to on or auto).';
    }
    if (nUbatch > 0 && nBatch > 0 && nUbatch > nBatch) return 'The micro-batch can’t be larger than the batch.';
    if (speculative == SpeculativeChoice.draft && draftModelId == null) return 'Pick a draft model.';
    return null;
  }

  TuningCandidate get candidate => TuningCandidate(
        nThreads: nThreads,
        nBatch: nBatch,
        nUbatch: nUbatch,
        typeK: kv,
        typeV: kv,
        flashAttention: flashAttention,
      );

  /// [base] (context, seed) with this config's threads, batches, KV, flash
  /// attention and speculative mode.
  SessionConfig applyTo(SessionConfig base) =>
      candidate.applyTo(base).copyWith(speculative: speculative.mode);

  /// The user override that pins this config ([Autotuner.setOverrides]).
  AutotuneOverrides get overrides => AutotuneOverrides(
        nThreads: nThreads > 0 ? nThreads : null,
        nBatch: nBatch > 0 ? nBatch : null,
        nUbatch: nUbatch > 0 ? nUbatch : null,
        typeK: kv,
        typeV: kv,
        flashAttention: flashAttention,
      );

  LabConfig copyWith({
    int? nThreads,
    int? nBatch,
    int? nUbatch,
    KvType? kv,
    FlashAttention? flashAttention,
    SpeculativeChoice? speculative,
    String? draftModelId,
    bool clearDraft = false,
  }) =>
      LabConfig(
        nThreads: nThreads ?? this.nThreads,
        nBatch: nBatch ?? this.nBatch,
        nUbatch: nUbatch ?? this.nUbatch,
        kv: kv ?? this.kv,
        flashAttention: flashAttention ?? this.flashAttention,
        speculative: speculative ?? this.speculative,
        draftModelId: clearDraft ? null : draftModelId ?? this.draftModelId,
      );

  JsonMap toJson() => compact({
        'nThreads': nThreads,
        'nBatch': nBatch,
        'nUbatch': nUbatch,
        'kv': kv.label,
        'fa': flashAttention.name,
        'spec': speculative.name,
        'draft': draftModelId,
      });

  /// "4 threads · batch 512/256 · KV q8_0 · flash auto · n-gram".
  String get summary => [
        nThreads > 0 ? '$nThreads thread${nThreads == 1 ? '' : 's'}' : 'auto threads',
        'batch ${nBatch > 0 ? nBatch : 'auto'}/${nUbatch > 0 ? nUbatch : 'auto'}',
        'KV ${kv.label}',
        'flash ${flashAttention.name}',
        if (speculative != SpeculativeChoice.off) speculative.label.toLowerCase(),
      ].join(' · ');

  @override
  bool operator ==(Object other) =>
      other is LabConfig &&
      other.nThreads == nThreads &&
      other.nBatch == nBatch &&
      other.nUbatch == nUbatch &&
      other.kv == kv &&
      other.flashAttention == flashAttention &&
      other.speculative == speculative &&
      other.draftModelId == draftModelId;

  @override
  int get hashCode => Object.hash(nThreads, nBatch, nUbatch, kv, flashAttention, speculative, draftModelId);

  @override
  String toString() => 'LabConfig($summary)';
}

/// What one benchmark measures.
@immutable
final class BenchSpec {
  const BenchSpec({this.promptTokens = 256, this.genTokens = 64, this.reps = 3});

  /// The A/B default: short runs, many of them.
  const BenchSpec.comparison({this.promptTokens = 128, this.genTokens = 32, this.reps = 5});

  factory BenchSpec.fromJson(JsonMap j) => BenchSpec(
        promptTokens: j.optInt('pp') ?? 256,
        genTokens: j.optInt('tg') ?? 64,
        reps: j.optInt('reps') ?? 3,
      );

  static const List<int> promptChoices = [64, 128, 256, 512, 1024];
  static const List<int> genChoices = [16, 32, 64, 128];
  static const List<int> repChoices = [1, 2, 3, 5, 8, 10];

  final int promptTokens;
  final int genTokens;

  /// Measured repetitions. The engine adds one warm-up run in front.
  final int reps;

  /// `se_bench_params.n_reps`: the first is a warm-up when > 1.
  int get engineReps => math.min(100, reps + 1);

  BenchSpec copyWith({int? promptTokens, int? genTokens, int? reps}) => BenchSpec(
        promptTokens: promptTokens ?? this.promptTokens,
        genTokens: genTokens ?? this.genTokens,
        reps: reps ?? this.reps,
      );

  JsonMap toJson() => {'pp': promptTokens, 'tg': genTokens, 'reps': reps};

  @override
  bool operator ==(Object other) =>
      other is BenchSpec && other.promptTokens == promptTokens && other.genTokens == genTokens && other.reps == reps;

  @override
  int get hashCode => Object.hash(promptTokens, genTokens, reps);
}

/// How a run was measured.
enum BenchMethod {
  /// `se_bench`: synthetic tokens from an empty KV, no sampling.
  bench,

  /// A real greedy generation on a temporary session (speculative configs).
  generation,
}

/// The turn the "time per agent turn" figure assumes (the autotune POLICY:
/// ~512 new prompt tokens over a cached prefix, ~150 generated).
const AutotuneWorkload kLabWorkload = AutotuneWorkload();

/// One measurement: one engine bench call (or one generation).
@immutable
final class RepSample {
  const RepSample({
    required this.prefillTps,
    required this.decodeTps,
    required this.ttftMs,
    this.peakMemoryBytes,
    this.baselineMemoryBytes,
    this.thermalBefore,
    this.thermalAfter,
    this.draftAcceptRate,
    this.promptTokens,
    this.genTokens,
    this.backend,
  });

  factory RepSample.fromJson(JsonMap j) => RepSample(
        prefillTps: j.optDouble('pp') ?? 0,
        decodeTps: j.optDouble('tg') ?? 0,
        ttftMs: j.optDouble('ttft') ?? 0,
        peakMemoryBytes: j.optInt('peak'),
        baselineMemoryBytes: j.optInt('base'),
        thermalBefore: _thermal(j.opt<String>('tBefore')),
        thermalAfter: _thermal(j.opt<String>('tAfter')),
        draftAcceptRate: j.optDouble('accept'),
        promptTokens: j.optInt('nPrompt'),
        genTokens: j.optInt('nGen'),
        backend: j.opt<String>('backend'),
      );

  static ThermalLevel? _thermal(String? name) => ThermalLevel.values.where((t) => t.name == name).firstOrNull;

  final double prefillTps;
  final double decodeTps;

  /// Measured for generations; for `se_bench`, the prompt time plus one
  /// decode step (what a reply's first token would take).
  final double ttftMs;

  /// Highest app memory seen while it ran (in-process engines only).
  final int? peakMemoryBytes;
  final int? baselineMemoryBytes;

  /// Null where the platform does not report thermal state.
  final ThermalLevel? thermalBefore;
  final ThermalLevel? thermalAfter;
  final double? draftAcceptRate;
  final int? promptTokens;
  final int? genTokens;
  final String? backend;

  /// Seconds for the [kLabWorkload] turn at these speeds.
  double get turnSeconds {
    if (prefillTps <= 0 || decodeTps <= 0) return double.infinity;
    return kLabWorkload.promptTokens / prefillTps + kLabWorkload.genTokens / decodeTps;
  }

  JsonMap toJson() => compact({
        'pp': prefillTps,
        'tg': decodeTps,
        'ttft': ttftMs,
        'peak': peakMemoryBytes,
        'base': baselineMemoryBytes,
        'tBefore': thermalBefore?.name,
        'tAfter': thermalAfter?.name,
        'accept': draftAcceptRate,
        'nPrompt': promptTokens,
        'nGen': genTokens,
        'backend': backend,
      });
}

/// One benchmark as kept in the history.
@immutable
final class BenchRun {
  const BenchRun({required this.at, required this.config, required this.spec, required this.method, required this.sample});

  factory BenchRun.fromJson(JsonMap j) => BenchRun(
        at: DateTime.parse(j.req<String>('at')),
        config: LabConfig.fromJson(j.obj('config')),
        spec: BenchSpec.fromJson(j.obj('spec')),
        method: BenchMethod.values.where((m) => m.name == j.opt<String>('method')).firstOrNull ?? BenchMethod.bench,
        sample: RepSample.fromJson(j.obj('sample')),
      );

  final DateTime at;
  final LabConfig config;
  final BenchSpec spec;
  final BenchMethod method;
  final RepSample sample;

  JsonMap toJson() => {
        'at': at.toUtc().toIso8601String(),
        'config': config.toJson(),
        'spec': spec.toJson(),
        'method': method.name,
        'sample': sample.toJson(),
      };
}

/// The metrics an A/B comparison reports.
enum AbMetric {
  turn('Time per agent turn', 's', higherIsBetter: false),
  decode('Decode', 'tok/s', higherIsBetter: true),
  prefill('Prefill', 'tok/s', higherIsBetter: true),
  ttft('First token', 'ms', higherIsBetter: false);

  const AbMetric(this.label, this.unit, {required this.higherIsBetter});

  final String label;
  final String unit;
  final bool higherIsBetter;

  double of(RepSample s) => switch (this) {
        turn => s.turnSeconds,
        decode => s.decodeTps,
        prefill => s.prefillTps,
        ttft => s.ttftMs,
      };
}

/// A finished A/B comparison.
@immutable
final class AbResult {
  AbResult({required this.a, required this.b, required this.aSamples, required this.bSamples, required this.method})
      : metrics = {
          for (final m in AbMetric.values)
            m: MetricComparison(
              a: Summary.of(aSamples.map(m.of)),
              b: Summary.of(bSamples.map(m.of)),
              higherIsBetter: m.higherIsBetter,
            ),
        };

  final LabConfig a;
  final LabConfig b;
  final List<RepSample> aSamples;
  final List<RepSample> bSamples;
  final BenchMethod method;
  final Map<AbMetric, MetricComparison> metrics;

  /// The verdict: time per agent turn, which weighs prefill and decode the
  /// way an agent step on a phone does.
  MetricComparison get headline => metrics[AbMetric.turn]!;

  Winner get winner => headline.winner;

  LabConfig? get winningConfig => switch (winner) {
        Winner.a => a,
        Winner.b => b,
        Winner.none => null,
      };
}

/// Whether a config fits this phone's memory at the model's context.
@immutable
final class FitCheck {
  const FitCheck({
    required this.config,
    required this.contextTokens,
    this.estimate,
    this.budget,
    this.invalidReason,
    this.addedBackBytes = 0,
  });

  final LabConfig config;
  final int contextTokens;
  final MemoryEstimate? estimate;
  final MemoryBudget? budget;

  /// The engine would refuse the combination itself.
  final String? invalidReason;

  /// The loaded model's own memory, counted as available (it is freed
  /// before this config would load).
  final int addedBackBytes;

  bool get fits => invalidReason == null && (estimate == null || budget == null || budget!.admits(estimate!));

  /// The sentence shown when it doesn't fit (or is invalid).
  String? get problem {
    if (invalidReason != null) return invalidReason;
    if (fits) return null;
    final e = estimate!;
    final b = budget!;
    final have = b.totalBytes == null ? 'an unknown amount' : _mb(b.totalBytes!);
    final capped = b.anonymousCapBytes != null && e.anonymousBytes > b.anonymousCapBytes!;
    return 'Won’t fit: it needs about ${_mb(e.totalBytes)} at a $contextTokens-token context, and about $have is '
        'available${capped ? ' (and the per-app limit is ${_mb(b.anonymousCapBytes!)})' : ''}.';
  }
}

String _mb(int bytes) => '${(bytes / (1024 * 1024)).round()} MB';

/// A library model that could serve as a draft for speculative decoding.
@immutable
final class DraftOption {
  const DraftOption({required this.modelId, required this.label, required this.path, this.paired = false});

  final String modelId;
  final String label;

  /// Absolute path of the GGUF.
  final String path;

  /// Shipped with this model (`LibraryModel.draftPath`).
  final bool paired;
}

/// The engine as the lab describes it.
@immutable
final class EngineDescription {
  const EngineDescription({
    required this.version,
    required this.hostKind,
    this.system,
    this.cpuBackendFeatures = const {},
  });

  final String version;
  final EngineHostKind hostKind;
  final EngineSystemInfo? system;

  /// `se_system_info_json().cpu_backend_features` (compile-time features
  /// of the loaded CPU variant, e.g. KLEIDIAI, REPACK, DOTPROD).
  final Map<String, String> cpuBackendFeatures;

  bool get kleidiAi => cpuBackendFeatures.keys.any((k) => k.toUpperCase().contains('KLEIDIAI'));

  String get hostLabel => switch (hostKind) {
        EngineHostKind.inProcessFfi => 'In the app process',
        EngineHostKind.isolatedProcess => 'Separate :inference process',
        EngineHostKind.fake => 'Test engine',
      };

  /// "CPU (android_armv8.2_2), KleidiAI".
  String get backendLabel {
    final s = system;
    final names = s == null || s.backends.isEmpty ? const ['CPU'] : s.backends;
    final variant = s?.cpuVariant ?? '';
    return [
      '${names.join(', ')}${variant.isEmpty ? '' : ' ($variant)'}',
      if (kleidiAi) 'KleidiAI',
    ].join(' · ');
  }
}

/// What the session uses now (live) or will use at the next load (plan).
@immutable
final class CurrentSettings {
  const CurrentSettings({
    required this.config,
    required this.contextTokens,
    required this.loaded,
    this.flashAttentionOn,
    this.estimate,
    this.liveMemory,
    this.notes = const [],
    this.refusal,
  });

  final LabConfig config;
  final int contextTokens;

  /// The model is warm (values are the live session's).
  final bool loaded;

  /// Flash attention as the engine resolved it (`auto` becomes on or off).
  final bool? flashAttentionOn;

  /// `se_estimate_memory` for these settings (the load-time dry run when
  /// loaded).
  final MemoryEstimate? estimate;

  /// The live session's real allocations (`se_session_memory`).
  final MemoryEstimate? liveMemory;

  /// Admission's decisions ("context reduced to 4096 tokens to fit").
  final List<String> notes;

  /// Admission refuses to load the model right now.
  final String? refusal;
}

/// Everything the lab's overview shows for one model.
@immutable
final class PerfOverview {
  const PerfOverview({
    required this.modelId,
    required this.modelName,
    required this.memory,
    required this.engine,
    required this.defaults,
    required this.overrides,
    required this.current,
    required this.budget,
    required this.toolCalling,
    this.device,
    this.profile,
    this.speculative,
    this.addedBackBytes = 0,
    this.drafts = const [],
  });

  final String modelId;
  final String modelName;
  final DeviceSnapshot? device;
  final MemoryState memory;
  final EngineDescription engine;

  /// The stored profile with overrides applied (null = never tuned here).
  final AutotuneProfile? profile;
  final TuningCandidate defaults;
  final AutotuneOverrides overrides;

  /// The lab-chosen speculative mode (null = off).
  final SpeculativeMode? speculative;
  final CurrentSettings current;

  /// What a load is admitted against now.
  final MemoryBudget budget;
  final int addedBackBytes;
  final bool toolCalling;
  final List<DraftOption> drafts;

  bool get hasOverrides => !overrides.isEmpty || speculative != null;

  /// The settings the model loads with: the tuned profile (with
  /// overrides), or, before tuning, what admission plans from the app's
  /// session defaults (the lifecycle uses the autotuner's defaults only
  /// once a profile exists).
  LabConfig get tuned {
    final p = profile;
    if (p == null) return current.config;
    return LabConfig.fromCandidate(p.candidate, speculative: SpeculativeChoice.of(speculative));
  }
}

/// Where a lab job is in the scheduler.
enum LabJobPhase {
  /// Queued behind other on-device work.
  waiting,
  running,

  /// A chat reply took the engine; the job runs again once it is idle.
  paused,
}

/// Progress of a running sweep ("Re-run autotune").
@immutable
final class AutotuneProgress {
  const AutotuneProgress({required this.done, required this.total, this.last, this.lastResult});

  final int done;
  final int total;
  final TuningCandidate? last;
  final BenchResult? lastResult;

  double get fraction => total == 0 ? 0 : (done / total).clamp(0, 1);
}

/// Progress of a running A/B comparison.
@immutable
final class AbProgress {
  const AbProgress({required this.done, required this.total, this.side, this.phase = LabJobPhase.running});

  /// Measurements finished, of [total] (reps × 2).
  final int done;
  final int total;

  /// The side being measured now.
  final Winner? side;
  final LabJobPhase phase;

  double get fraction => total == 0 ? 0 : (done / total).clamp(0, 1);
}
