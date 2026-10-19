import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../common/key_value_store.dart';
import '../engine/engine_host.dart';
import '../engine/engine_types.dart';

/// What a tuning result is valid for. A profile measured under another OS,
/// app or engine version (a new llama.cpp can change kernels and thread
/// scaling) or on another device is not reused: the key changes and the
/// sweep runs again.
@immutable
final class AutotuneEnvironment {
  const AutotuneEnvironment({
    required this.deviceId,
    required this.osVersion,
    required this.appVersion,
    required this.engineVersion,
    required this.performanceCores,
  });

  /// Stable device model identifier (e.g. "Pixel 9 Pro", "iPhone17,1").
  final String deviceId;
  final String osVersion;
  final String appVersion;

  /// `se_version_string()` (includes the llama.cpp commit).
  final String engineVersion;

  /// From `se_system_info_json().cpu.performance_cores`.
  final int performanceCores;

  String key(String modelKey) => [deviceId, osVersion, appVersion, engineVersion, modelKey].join('|');
}

/// One point of the sweep.
@immutable
final class TuningCandidate {
  const TuningCandidate({
    required this.nThreads,
    this.nBatch = 512,
    this.nUbatch = 256,
    this.typeK = KvType.f16,
    this.typeV = KvType.f16,
    this.flashAttention = FlashAttention.auto,
  });

  factory TuningCandidate.fromJson(JsonMap j) => TuningCandidate(
        nThreads: j.optInt('nThreads') ?? 0,
        nBatch: j.optInt('nBatch') ?? 512,
        nUbatch: j.optInt('nUbatch') ?? 256,
        typeK: KvType.byLabel(j.opt<String>('typeK') ?? 'f16'),
        typeV: KvType.byLabel(j.opt<String>('typeV') ?? 'f16'),
        flashAttention: FlashAttention.values.byName(j.opt<String>('flashAttention') ?? 'auto'),
      );

  final int nThreads;
  final int nBatch;
  final int nUbatch;
  final KvType typeK;
  final KvType typeV;
  final FlashAttention flashAttention;

  TuningCandidate copyWith({int? nThreads, int? nBatch, int? nUbatch, KvType? typeK, KvType? typeV, FlashAttention? flashAttention}) =>
      TuningCandidate(
        nThreads: nThreads ?? this.nThreads,
        nBatch: nBatch ?? this.nBatch,
        nUbatch: nUbatch ?? this.nUbatch,
        typeK: typeK ?? this.typeK,
        typeV: typeV ?? this.typeV,
        flashAttention: flashAttention ?? this.flashAttention,
      );

  BenchConfig bench({required int nPrompt, required int nGen, required int nReps}) => BenchConfig(
        nThreads: nThreads,
        nThreadsBatch: nThreads,
        nBatch: nBatch,
        nUbatch: nUbatch,
        nPrompt: nPrompt,
        nGen: nGen,
        nReps: nReps,
        typeK: typeK,
        typeV: typeV,
        flashAttention: flashAttention,
      );

  /// Applies this candidate to a session config (context and seed stay).
  SessionConfig applyTo(SessionConfig c) => c.copyWith(
        nThreads: nThreads,
        nThreadsBatch: nThreads,
        nBatch: nBatch,
        nUbatch: nUbatch,
        typeK: typeK,
        typeV: typeV,
        flashAttention: flashAttention,
      );

  JsonMap toJson() => {
        'nThreads': nThreads,
        'nBatch': nBatch,
        'nUbatch': nUbatch,
        'typeK': typeK.label,
        'typeV': typeV.label,
        'flashAttention': flashAttention.name,
      };

  @override
  bool operator ==(Object other) =>
      other is TuningCandidate &&
      other.nThreads == nThreads &&
      other.nBatch == nBatch &&
      other.nUbatch == nUbatch &&
      other.typeK == typeK &&
      other.typeV == typeV &&
      other.flashAttention == flashAttention;

  @override
  int get hashCode => Object.hash(nThreads, nBatch, nUbatch, typeK, typeV, flashAttention);

  @override
  String toString() => 't$nThreads b$nBatch/$nUbatch ${typeK.label}/${typeV.label} fa:${flashAttention.name}';
}

@immutable
final class TuningSample {
  const TuningSample(this.candidate, this.promptTokensPerSec, this.genTokensPerSec);

  final TuningCandidate candidate;
  final double promptTokensPerSec;
  final double genTokensPerSec;
}

/// The turn shape the trade-off is optimized for. POLICY: an agent step on
/// a phone is ~500 new prompt tokens (user message or tool result over a
/// cached prefix) and ~150 generated tokens.
@immutable
final class AutotuneWorkload {
  const AutotuneWorkload({this.promptTokens = 512, this.genTokens = 150});

  final int promptTokens;
  final int genTokens;

  /// Seconds for one such turn; lower is better. Combines prefill and
  /// decode speed in the units the user feels.
  double seconds(TuningSample s) {
    if (s.promptTokensPerSec <= 0 || s.genTokensPerSec <= 0) return double.infinity;
    return promptTokens / s.promptTokensPerSec + genTokens / s.genTokensPerSec;
  }
}

/// The sweep grid. Stages run as coordinate descent (threads, then batch
/// sizes, then KV type × flash attention) so a device with 8 performance
/// cores needs ~14 short benches instead of the 96-point full grid.
@immutable
final class AutotuneSweep {
  const AutotuneSweep({
    required this.threads,
    this.batchSizes = const [128, 256, 512],
    this.kvVariants = const [
      (KvType.f16, FlashAttention.off),
      (KvType.f16, FlashAttention.on),
      (KvType.q8_0, FlashAttention.on),
    ],
    this.nPrompt = 128,
    this.nGen = 32,
    this.nReps = 2,
  });

  /// Threads 1..performance cores (capped at 8: ggml's barriers stop scaling
  /// and efficiency cores slow the whole team down).
  factory AutotuneSweep.forCores(int performanceCores) =>
      AutotuneSweep(threads: [for (var t = 1; t <= performanceCores.clamp(1, 8); t++) t]);

  final List<int> threads;

  /// `n_batch` values; `n_ubatch` = min(n_batch, 512).
  final List<int> batchSizes;

  /// K = V type with a flash-attention mode. A quantized V cache requires
  /// flash attention, and KV below q8_0 is never tuned in (R11 §9.6.2: it
  /// hurts tool calling).
  final List<(KvType, FlashAttention)> kvVariants;
  final int nPrompt;
  final int nGen;
  final int nReps;
}

enum AutotuneSource { measured, defaults, override }

/// The chosen configuration for one (device, OS, app, engine, model).
@immutable
final class AutotuneProfile {
  const AutotuneProfile({
    required this.candidate,
    required this.source,
    required this.environmentKey,
    this.promptTokensPerSec = 0,
    this.genTokensPerSec = 0,
    this.samples = const [],
    this.measuredAt,
  });

  factory AutotuneProfile.fromJson(JsonMap j) => AutotuneProfile(
        candidate: TuningCandidate.fromJson(j.obj('candidate')),
        source: AutotuneSource.values.byName(j.opt<String>('source') ?? 'measured'),
        environmentKey: j.opt<String>('environmentKey') ?? '',
        promptTokensPerSec: j.optDouble('ppTps') ?? 0,
        genTokensPerSec: j.optDouble('tgTps') ?? 0,
        samples: [
          for (final s in j.opt<List<Object?>>('samples') ?? const <Object?>[])
            if (s is Map)
              TuningSample(
                TuningCandidate.fromJson(s.cast<String, Object?>().obj('candidate')),
                (s['pp'] as num?)?.toDouble() ?? 0,
                (s['tg'] as num?)?.toDouble() ?? 0,
              ),
        ],
        measuredAt: j.opt<String>('measuredAt') == null ? null : DateTime.parse(j.req<String>('measuredAt')),
      );

  final TuningCandidate candidate;
  final AutotuneSource source;
  final String environmentKey;
  final double promptTokensPerSec;
  final double genTokensPerSec;
  final List<TuningSample> samples;
  final DateTime? measuredAt;

  JsonMap toJson() => compact({
        'candidate': candidate.toJson(),
        'source': source.name,
        'environmentKey': environmentKey,
        'ppTps': promptTokensPerSec,
        'tgTps': genTokensPerSec,
        'samples': [
          for (final s in samples) {'candidate': s.candidate.toJson(), 'pp': s.promptTokensPerSec, 'tg': s.genTokensPerSec},
        ],
        'measuredAt': measuredAt?.toUtc().toIso8601String(),
      });
}

/// Power-user overrides, applied on top of the measured profile.
@immutable
final class AutotuneOverrides {
  const AutotuneOverrides({this.nThreads, this.nBatch, this.nUbatch, this.typeK, this.typeV, this.flashAttention});

  factory AutotuneOverrides.fromJson(JsonMap j) => AutotuneOverrides(
        nThreads: j.optInt('nThreads'),
        nBatch: j.optInt('nBatch'),
        nUbatch: j.optInt('nUbatch'),
        typeK: j.opt<String>('typeK') == null ? null : KvType.byLabel(j.req<String>('typeK')),
        typeV: j.opt<String>('typeV') == null ? null : KvType.byLabel(j.req<String>('typeV')),
        flashAttention:
            j.opt<String>('flashAttention') == null ? null : FlashAttention.values.byName(j.req<String>('flashAttention')),
      );

  final int? nThreads;
  final int? nBatch;
  final int? nUbatch;
  final KvType? typeK;
  final KvType? typeV;
  final FlashAttention? flashAttention;

  bool get isEmpty =>
      nThreads == null && nBatch == null && nUbatch == null && typeK == null && typeV == null && flashAttention == null;

  TuningCandidate apply(TuningCandidate c) => c.copyWith(
        nThreads: nThreads,
        nBatch: nBatch,
        nUbatch: nUbatch,
        typeK: typeK,
        typeV: typeV,
        flashAttention: flashAttention,
      );

  JsonMap toJson() => compact({
        'nThreads': nThreads,
        'nBatch': nBatch,
        'nUbatch': nUbatch,
        'typeK': typeK?.label,
        'typeV': typeV?.label,
        'flashAttention': flashAttention?.name,
      });
}

/// First-use performance tuning with `se_bench`.
///
/// Runs once per [AutotuneEnvironment.key] (device, OS, app, engine,
/// model): the sweep benches the loaded model over thread counts (1..the
/// performance cores), `n_batch`/`n_ubatch`, and KV type × flash attention,
/// keeps only candidates that fit the memory budget, and picks the one that
/// minimizes [AutotuneWorkload.seconds]. The profile is persisted in the
/// [KeyValueStore]; a changed environment re-tunes. Power-user overrides
/// win over measurements. Benching under thermal throttling would measure
/// the throttle, so callers skip tuning when the device is hot.
///
/// Run it as background work (the scheduler's `background` priority): it
/// occupies the cores for tens of seconds on a phone.
final class Autotuner {
  Autotuner({
    required EngineHost host,
    required KeyValueStore store,
    required AutotuneEnvironment environment,
    AutotuneSweep? sweep,
    this.workload = const AutotuneWorkload(),
    Clock clock = const SystemClock(),
  })  : _host = host,
        _store = store,
        env = environment,
        sweep = sweep ?? AutotuneSweep.forCores(environment.performanceCores),
        _clock = clock;

  final EngineHost _host;
  final KeyValueStore _store;
  final AutotuneEnvironment env;
  final AutotuneSweep sweep;
  final AutotuneWorkload workload;
  final Clock _clock;

  static String _profileKey(String modelKey) => 'sherpa.autotune.profile.$modelKey';
  static String _overridesKey(String modelKey) => 'sherpa.autotune.overrides.$modelKey';

  /// The default when nothing was measured: all performance cores (the
  /// engine's own default), R04 §21.4's phone batch sizes, q8_0 KV.
  TuningCandidate get defaults => TuningCandidate(
        nThreads: env.performanceCores.clamp(1, 8),
        nBatch: 512,
        nUbatch: 256,
        typeK: KvType.q8_0,
        typeV: KvType.q8_0,
        flashAttention: FlashAttention.auto,
      );

  /// The stored profile for [modelKey] in this environment, with overrides
  /// applied; null when it must be (re)measured.
  Future<AutotuneProfile?> cached(String modelKey) async {
    final j = await _store.read(_profileKey(modelKey));
    final overrides = await this.overrides(modelKey);
    if (j == null) return null;
    final p = AutotuneProfile.fromJson(j);
    if (p.environmentKey != env.key(modelKey)) return null;
    return _withOverrides(p, overrides);
  }

  Future<AutotuneOverrides> overrides(String modelKey) async {
    final j = await _store.read(_overridesKey(modelKey));
    return j == null ? const AutotuneOverrides() : AutotuneOverrides.fromJson(j);
  }

  Future<void> setOverrides(String modelKey, AutotuneOverrides o) =>
      o.isEmpty ? _store.delete(_overridesKey(modelKey)) : _store.write(_overridesKey(modelKey), o.toJson());

  AutotuneProfile _withOverrides(AutotuneProfile p, AutotuneOverrides o) => o.isEmpty
      ? p
      : AutotuneProfile(
          candidate: o.apply(p.candidate),
          source: AutotuneSource.override,
          environmentKey: p.environmentKey,
          promptTokensPerSec: p.promptTokensPerSec,
          genTokensPerSec: p.genTokensPerSec,
          samples: p.samples,
          measuredAt: p.measuredAt,
        );

  /// Returns the profile for [modelKey], running the sweep on [model] when
  /// none is stored for this environment (or [force]). [fits] rejects
  /// candidates over the memory budget (e.g. an f16 KV cache that only fits
  /// at a shorter context).
  Future<AutotuneProfile> profileFor({
    required ModelRef model,
    required String modelKey,
    Future<bool> Function(TuningCandidate candidate)? fits,
    bool force = false,
    CancellationToken? cancel,
    void Function(TuningCandidate candidate, BenchResult result)? onSample,
  }) async {
    if (!force) {
      final c = await cached(modelKey);
      if (c != null) return c;
    }
    final samples = <TuningSample>[];
    Future<TuningSample?> measure(TuningCandidate c) async {
      cancel?.throwIfCancelled();
      for (final s in samples) {
        if (s.candidate == c) return s;
      }
      if (fits != null && !await fits(c)) return null;
      try {
        final r = await _host.bench(model, c.bench(nPrompt: sweep.nPrompt, nGen: sweep.nGen, nReps: sweep.nReps),
            cancel: cancel);
        onSample?.call(c, r);
        final s = TuningSample(c, r.promptTokensPerSec, r.genTokensPerSec);
        samples.add(s);
        return s;
      } on EngineException {
        cancel?.throwIfCancelled();
        return null; // an unsupported combination (e.g. FA off with quantized V)
      }
    }

    var best = defaults.copyWith(typeK: KvType.f16, typeV: KvType.f16);
    // Stage 1: threads (decode speed is mostly thread-bound).
    best = await _stage(best, [for (final t in sweep.threads) best.copyWith(nThreads: t)], measure) ?? best;
    // Stage 2: batch sizes (prefill speed and compute-buffer size).
    best = await _stage(best, [
          for (final b in sweep.batchSizes) best.copyWith(nBatch: b, nUbatch: b < 512 ? b : 512),
        ], measure) ??
        best;
    // Stage 3: KV type × flash attention.
    best = await _stage(best, [
          for (final (kv, fa) in sweep.kvVariants) best.copyWith(typeK: kv, typeV: kv, flashAttention: fa),
        ], measure) ??
        best;

    final chosen = select(samples, workload: workload) ?? best;
    final sample = samples.where((s) => s.candidate == chosen).firstOrNull;
    final profile = AutotuneProfile(
      candidate: chosen,
      source: samples.isEmpty ? AutotuneSource.defaults : AutotuneSource.measured,
      environmentKey: env.key(modelKey),
      promptTokensPerSec: sample?.promptTokensPerSec ?? 0,
      genTokensPerSec: sample?.genTokensPerSec ?? 0,
      samples: samples,
      measuredAt: _clock.now(),
    );
    if (samples.isNotEmpty) await _store.write(_profileKey(modelKey), profile.toJson());
    return _withOverrides(profile, await overrides(modelKey));
  }

  Future<TuningCandidate?> _stage(
    TuningCandidate current,
    List<TuningCandidate> candidates,
    Future<TuningSample?> Function(TuningCandidate) measure,
  ) async {
    final stage = <TuningSample>[];
    for (final c in candidates) {
      final s = await measure(c);
      if (s != null) stage.add(s);
    }
    return select(stage, workload: workload);
  }

  /// The best candidate of [samples] for [workload]: the shortest turn time
  /// among candidates [allowed] by the memory budget; ties (within 3 %, the
  /// noise of a short bench) go to fewer threads, then to the smaller KV
  /// cache — less heat and memory for the same speed.
  static TuningCandidate? select(
    List<TuningSample> samples, {
    AutotuneWorkload workload = const AutotuneWorkload(),
    bool Function(TuningCandidate candidate)? allowed,
  }) {
    final ok = [for (final s in samples) if (allowed == null || allowed(s.candidate)) s];
    if (ok.isEmpty) return null;
    final fastest = ok.map(workload.seconds).reduce((a, b) => a < b ? a : b);
    if (!fastest.isFinite) return null;
    final near = [for (final s in ok) if (workload.seconds(s) <= fastest * 1.03) s];
    near.sort((a, b) {
      final t = a.candidate.nThreads.compareTo(b.candidate.nThreads);
      if (t != 0) return t;
      final kv = a.candidate.typeK.precisionRank.compareTo(b.candidate.typeK.precisionRank);
      if (kv != 0) return kv;
      return workload.seconds(a).compareTo(workload.seconds(b));
    });
    return near.first.candidate;
  }
}
