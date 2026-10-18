import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../gguf/ggml_types.dart';
import '../naming/name_types.dart';
import '../naming/quant_types.dart';
import 'device_profile.dart';
import 'fit_constants.dart';
import 'model_architecture.dart';

/// Runtime configuration the estimate assumes. Defaults are R04 §21's phone
/// defaults: q8_0 K/V (forces flash attention), `n_ubatch` 256,
/// `n_outputs_max` = 1, unified KV, `swa_full` off.
@immutable
final class FitOptions {
  const FitOptions({
    this.contextLength = 4096,
    this.typeK = KvCacheType.q8_0,
    this.typeV = KvCacheType.q8_0,
    this.nUbatch = 256,
    this.outputs = 1,
    this.sequences = 1,
    this.kvUnified = true,
    this.swaFull = false,
    this.flashAttention = true,
    this.runtimeOverheadBytes,
    this.appOverheadBytes,
    this.weightRepackFraction = 0,
    this.fitFraction,
    this.tightFraction = FitConstants.tightFraction,
    this.unsupportedQuants = const {},
    this.allowTernary = false,
  });

  final int contextLength;
  final KvCacheType typeK;
  final KvCacheType typeV;
  final int nUbatch;

  /// `n_outputs_max`; `n_draft + 1` with speculative decoding.
  final int outputs;
  final int sequences;
  final bool kvUnified;
  final bool swaFull;

  /// Off adds one layer's f32 attention scores. A quantized V cache forces
  /// it on (R04 §0.6).
  final bool flashAttention;

  /// Overrides the per-platform runtime overhead constant.
  final int? runtimeOverheadBytes;

  /// Overrides the app baseline used when availability is estimated.
  final int? appOverheadBytes;

  /// Share of weight bytes duplicated into anonymous memory by CPU repacking
  /// (`use_extra_bufts`, KleidiAI). R04 saw ~1.0 on an x86 host (AMX); the
  /// on-device effect is UNVERIFIED, so it is 0 until the perf lab measures it.
  final double weightRepackFraction;

  /// Overrides the platform's "fits" share of the budget.
  final double? fitFraction;
  final double tightFraction;

  /// Quant ids the bundled runtime cannot load (`{'Q1_0', 'NVFP4'}` on an
  /// older engine build, R08 §16 risk 7).
  final Set<String> unsupportedQuants;
  final bool allowTernary;

  bool get effectiveFlashAttention => flashAttention || typeV.isQuantized;

  FitOptions copyWith({int? contextLength, KvCacheType? typeK, KvCacheType? typeV, int? nUbatch, int? outputs}) =>
      FitOptions(
        contextLength: contextLength ?? this.contextLength,
        typeK: typeK ?? this.typeK,
        typeV: typeV ?? this.typeV,
        nUbatch: nUbatch ?? this.nUbatch,
        outputs: outputs ?? this.outputs,
        sequences: sequences,
        kvUnified: kvUnified,
        swaFull: swaFull,
        flashAttention: flashAttention,
        runtimeOverheadBytes: runtimeOverheadBytes,
        appOverheadBytes: appOverheadBytes,
        weightRepackFraction: weightRepackFraction,
        fitFraction: fitFraction,
        tightFraction: tightFraction,
        unsupportedQuants: unsupportedQuants,
        allowTernary: allowTernary,
      );
}

/// The model side of a fit question: real bytes of the files that will be
/// loaded (sum of all shards + projector + draft) and the header shape.
@immutable
final class ModelFootprintInput {
  const ModelFootprintInput({
    required this.architecture,
    required this.weightBytes,
    this.mmprojBytes = 0,
    this.draftBytes = 0,
    this.quant,
    this.label,
  });

  final ModelArchitecture architecture;

  /// Σ shard file sizes from `tree`/`paths-info` — never name-implied bpw
  /// (R08 §15.3).
  final int weightBytes;
  final int mmprojBytes;
  final int draftBytes;

  /// The file type (`general.file_type` when peeked, else the name's).
  final QuantType? quant;
  final String? label;
}

enum FitVerdict {
  fits,
  tight,
  wontFit;

  bool isWorseThan(FitVerdict other) => index > other.index;
}

enum FitSeverity { info, warning, blocking }

enum FitReasonCode {
  exceedsAvailableMemory,
  nearAvailableMemory,
  exceedsProcessLimit,
  nearProcessLimit,
  budgetEstimated,
  contextClamped,
  removedQuant,
  runtimeUnsupportedQuant,
  gpuBackendUnsupportedQuant,
  thermal,
  lowPower,
  slowCpu,
  mixtureOfExperts,
  approximation,
}

@immutable
final class FitReason {
  const FitReason(this.code, this.severity, this.message);

  final FitReasonCode code;
  final FitSeverity severity;

  /// Ready-to-show sentence.
  final String message;

  @override
  String toString() => '${severity.name}: $message';
}

/// Estimated peak memory, by component.
@immutable
final class MemoryBreakdown {
  const MemoryBreakdown({
    required this.weightsBytes,
    required this.mmprojBytes,
    required this.draftBytes,
    required this.kvBytes,
    required this.computeBytes,
    required this.runtimeOverheadBytes,
    required this.repackBytes,
    required this.appOverheadBytes,
  });

  /// mmap'ed weights that must stay resident for usable decode speed.
  final int weightsBytes;
  final int mmprojBytes;
  final int draftBytes;
  final int kvBytes;
  final int computeBytes;
  final int runtimeOverheadBytes;

  /// Anonymous copies made by CPU weight repacking.
  final int repackBytes;

  /// App baseline, counted only when availability was estimated.
  final int appOverheadBytes;

  int get totalBytes =>
      weightsBytes + mmprojBytes + draftBytes + kvBytes + computeBytes + runtimeOverheadBytes + repackBytes + appOverheadBytes;

  JsonMap toJson() => {
        'weightsBytes': weightsBytes,
        'mmprojBytes': mmprojBytes,
        'draftBytes': draftBytes,
        'kvBytes': kvBytes,
        'computeBytes': computeBytes,
        'runtimeOverheadBytes': runtimeOverheadBytes,
        'repackBytes': repackBytes,
        'appOverheadBytes': appOverheadBytes,
        'totalBytes': totalBytes,
      };
}

@immutable
final class FitResult {
  const FitResult({
    required this.verdict,
    required this.reasons,
    required this.breakdown,
    required this.kv,
    required this.contextLength,
    required this.budgetBytes,
    required this.demandBytes,
    required this.budgetEstimated,
    this.processCapBytes,
    this.processDemandBytes,
    this.recommendedMaxContext,
  });

  final FitVerdict verdict;
  final List<FitReason> reasons;
  final MemoryBreakdown breakdown;
  final KvEstimate kv;

  /// The context actually assessed (requested, clamped to the model's).
  final int contextLength;

  /// Memory available for the model (physical / jetsam budget).
  final int budgetBytes;
  final int demandBytes;
  final bool budgetEstimated;

  /// Per-process ceiling and the share of the demand it applies to
  /// (Android 17 limiter: anonymous memory only).
  final int? processCapBytes;
  final int? processDemandBytes;

  /// Largest context (multiple of 256, ≤ the model's) that still Fits;
  /// null when even 256 tokens do not.
  final int? recommendedMaxContext;

  double get budgetShare => budgetBytes <= 0 ? double.infinity : demandBytes / budgetBytes;

  bool get fits => verdict == FitVerdict.fits;
}

final class _Budget {
  _Budget({
    required this.available,
    required this.estimated,
    required this.fitFraction,
    required this.cap,
    required this.weightsCountTowardCap,
    required this.appOverhead,
    required this.runtimeOverhead,
    required this.capLabel,
  });

  final int available;
  final bool estimated;
  final double fitFraction;
  final int? cap;
  final bool weightsCountTowardCap;
  final int appOverhead;
  final int runtimeOverhead;
  final String capLabel;
}

_Budget _budget(DeviceProfile d, FitOptions o) {
  final app = o.appOverheadBytes ?? FitConstants.appOverheadBytes;
  switch (d.platform) {
    case DevicePlatform.ios:
      // os_proc_available_memory() is already "limit − footprint" (R06 §5).
      final cap = d.perProcessCapBytes ?? _iosCap(d);
      final measured = d.availableRamBytes;
      return _Budget(
        available: measured ?? math.max(0, cap - app),
        estimated: measured == null,
        fitFraction: o.fitFraction ?? FitConstants.iosFitFraction,
        cap: null,
        weightsCountTowardCap: FitConstants.iosWeightsCountTowardCap,
        appOverhead: measured == null ? app : 0,
        runtimeOverhead: o.runtimeOverheadBytes ?? FitConstants.iosRuntimeOverheadBytes,
        capLabel: 'iOS memory limit',
      );
    case DevicePlatform.android:
      final measured = d.availableRamBytes;
      final separate = d.separateInferenceProcess ?? true;
      final limiterApplies = (d.osMajor ?? 0) >= FitConstants.androidLimiterSinceApiRelease;
      int? cap = d.perProcessCapBytes ??
          (limiterApplies ? (d.totalRamBytes * FitConstants.androidLimiterForegroundFraction).round() : null);
      if (cap != null && !separate) cap = math.max(0, cap - app);
      return _Budget(
        available: measured ?? math.max(0, (d.totalRamBytes * FitConstants.androidAssumedAvailableFraction).round() - app),
        estimated: measured == null,
        fitFraction: o.fitFraction ?? FitConstants.androidFitFraction,
        cap: cap,
        weightsCountTowardCap: false,
        appOverhead: measured == null ? app : 0,
        runtimeOverhead: o.runtimeOverheadBytes ?? FitConstants.androidRuntimeOverheadBytes,
        capLabel: 'Android memory limiter',
      );
    case DevicePlatform.other:
      final measured = d.availableRamBytes;
      return _Budget(
        available: measured ?? math.max(0, (d.totalRamBytes * FitConstants.otherAssumedAvailableFraction).round() - app),
        estimated: measured == null,
        fitFraction: o.fitFraction ?? FitConstants.otherFitFraction,
        cap: d.perProcessCapBytes,
        weightsCountTowardCap: true,
        appOverhead: measured == null ? app : 0,
        runtimeOverhead: o.runtimeOverheadBytes ?? FitConstants.otherRuntimeOverheadBytes,
        capLabel: 'process memory limit',
      );
  }
}

int _iosCap(DeviceProfile d) {
  const gb = 1024 * 1024 * 1024;
  final t = d.totalRamBytes;
  if (t <= 4.5 * gb) return FitConstants.ios4GbCap;
  if (t <= 6.5 * gb) return FitConstants.ios6GbCap;
  if (d.increasedMemoryLimit) return FitConstants.iosEntitledCap;
  return math.min(FitConstants.iosEntitledCap, (t * FitConstants.iosUnentitledFraction).round());
}

FitVerdict _classify(int demand, int budget, double fit, double tight) {
  if (budget <= 0) return FitVerdict.wontFit;
  if (demand <= budget * fit) return FitVerdict.fits;
  if (demand <= budget * tight) return FitVerdict.tight;
  return FitVerdict.wontFit;
}

final class _Eval {
  _Eval(this.verdict, this.breakdown, this.kv, this.demand, this.capDemand, this.physicalVerdict, this.capVerdict);

  final FitVerdict verdict;
  final MemoryBreakdown breakdown;
  final KvEstimate kv;
  final int demand;
  final int? capDemand;
  final FitVerdict physicalVerdict;
  final FitVerdict? capVerdict;
}

_Eval _evaluate(DeviceProfile d, ModelFootprintInput m, FitOptions o, _Budget b, int ctx) {
  final a = m.architecture;
  final kv = estimateKvCache(a,
      contextLength: ctx,
      typeK: o.typeK,
      typeV: o.typeV,
      sequences: o.sequences,
      unified: o.kvUnified,
      swaFull: o.swaFull,
      nUbatch: o.nUbatch);
  final compute = estimateComputeBytes(a,
      nUbatch: o.nUbatch, outputs: o.outputs, contextCells: kv.contextCells, flashAttention: o.effectiveFlashAttention);
  final repack = (m.weightBytes * o.weightRepackFraction).round();
  final breakdown = MemoryBreakdown(
    weightsBytes: m.weightBytes,
    mmprojBytes: m.mmprojBytes,
    draftBytes: m.draftBytes,
    kvBytes: kv.bytes,
    computeBytes: compute,
    runtimeOverheadBytes: b.runtimeOverhead,
    repackBytes: repack,
    appOverheadBytes: b.appOverhead,
  );
  final demand = breakdown.totalBytes;
  final physical = _classify(demand, b.available, b.fitFraction, o.tightFraction);
  int? capDemand;
  FitVerdict? capVerdict;
  final cap = b.cap;
  if (cap != null) {
    capDemand = b.weightsCountTowardCap
        ? demand
        : kv.bytes + compute + b.runtimeOverhead + repack + (FitConstants.mmprojIsAnonymous ? m.mmprojBytes : 0);
    capVerdict = _classify(capDemand, cap, b.fitFraction, o.tightFraction);
  }
  final verdict = capVerdict != null && capVerdict.isWorseThan(physical) ? capVerdict : physical;
  return _Eval(verdict, breakdown, kv, demand, capDemand, physical, capVerdict);
}

String _gb(int bytes) {
  final g = bytes / (1024 * 1024 * 1024);
  if (g >= 1) return '${g.toStringAsFixed(g >= 10 ? 0 : 1)} GB';
  return '${(bytes / (1024 * 1024)).round()} MB';
}

/// Will this model run on this device at this context?
///
/// A pure function of its inputs. The breakdown is weights (resident mmap)
/// + projector + draft + KV at the padded context (SWA-aware) + compute
/// buffers + runtime overhead (+ the app baseline when availability is
/// estimated). Two limits are checked: physical memory available to the
/// app, and the per-process ceiling where one applies (iOS jetsam counts
/// everything; the Android 17 limiter counts anonymous memory only).
FitResult assessFit(
  DeviceProfile device,
  ModelFootprintInput model, {
  FitOptions options = const FitOptions(),
  bool computeMaxContext = true,
}) {
  final a = model.architecture;
  final b = _budget(device, options);
  final reasons = <FitReason>[];
  final train = a.trainContextLength;
  var ctx = math.max(1, options.contextLength);
  if (train != null && train > 0 && ctx > train) {
    reasons.add(FitReason(FitReasonCode.contextClamped, FitSeverity.info,
        'The model was trained for $train tokens; context capped at $train.'));
    ctx = train;
  }
  final e = _evaluate(device, model, options, b, ctx);
  var verdict = e.verdict;

  final q = model.quant;
  if (q != null && q.isRemoved) {
    verdict = FitVerdict.wontFit;
    reasons.add(FitReason(FitReasonCode.removedQuant, FitSeverity.blocking,
        '${q.id} was removed from GGUF; the bundled llama.cpp cannot load it.'));
  } else if (q != null && options.unsupportedQuants.contains(q.id)) {
    verdict = FitVerdict.wontFit;
    reasons.add(FitReason(FitReasonCode.runtimeUnsupportedQuant, FitSeverity.blocking,
        '${q.id} needs a newer llama.cpp than the one bundled.'));
  }

  final demand = _gb(e.demand);
  switch (e.physicalVerdict) {
    case FitVerdict.wontFit:
      reasons.add(FitReason(FitReasonCode.exceedsAvailableMemory, FitSeverity.blocking,
          'Needs about $demand; only about ${_gb(b.available)} is available.'));
    case FitVerdict.tight:
      reasons.add(FitReason(FitReasonCode.nearAvailableMemory, FitSeverity.warning,
          'Needs about $demand of the ~${_gb(b.available)} available; other apps may be closed or the model killed.'));
    case FitVerdict.fits:
      break;
  }
  if (e.capVerdict != null && b.cap != null) {
    final what = b.weightsCountTowardCap ? 'memory' : 'KV cache and buffers';
    switch (e.capVerdict!) {
      case FitVerdict.wontFit:
        reasons.add(FitReason(FitReasonCode.exceedsProcessLimit, FitSeverity.blocking,
            'The ${b.capLabel} allows about ${_gb(b.cap!)}; $what need ${_gb(e.capDemand!)}.'));
      case FitVerdict.tight:
        reasons.add(FitReason(FitReasonCode.nearProcessLimit, FitSeverity.warning,
            '$what use ${_gb(e.capDemand!)} of the ~${_gb(b.cap!)} ${b.capLabel}.'));
      case FitVerdict.fits:
        break;
    }
  }
  if (b.estimated) {
    reasons.add(const FitReason(FitReasonCode.budgetEstimated, FitSeverity.info,
        'Available memory was estimated from total RAM, not measured.'));
  }
  if (device.platform == DevicePlatform.android &&
      device.accelerators.contains(Accelerator.openclAdreno) &&
      q != null &&
      !FitConstants.openclTensorTypes.contains(q.mainTensorType)) {
    reasons.add(FitReason(FitReasonCode.gpuBackendUnsupportedQuant, FitSeverity.info,
        'The GPU (OpenCL) backend has no ${q.mainTensorType} kernels; this file runs on the CPU.'));
  }
  if (device.thermal == ThermalLevel.serious || device.thermal == ThermalLevel.critical) {
    reasons.add(const FitReason(FitReasonCode.thermal, FitSeverity.warning,
        'The device is hot; generation will be throttled until it cools down.'));
  }
  if (device.lowPowerMode) {
    reasons.add(const FitReason(FitReasonCode.lowPower, FitSeverity.info, 'Low-power mode slows generation.'));
  }
  if (device.cpuClass == CpuClass.low && !a.isMoe && model.weightBytes > 1536 * 1024 * 1024) {
    reasons.add(const FitReason(FitReasonCode.slowCpu, FitSeverity.warning,
        'This CPU reads weights slowly; expect slow generation with a model this size.'));
  }
  if (a.isMoe) {
    reasons.add(FitReason(FitReasonCode.mixtureOfExperts, FitSeverity.info,
        'Mixture of experts: all ${a.expertCount} experts must be in memory, '
        'though only ${a.expertUsedCount ?? '?'} run per token (speed follows the active count).'));
  }
  for (final n in a.notes) {
    reasons.add(FitReason(FitReasonCode.approximation, FitSeverity.info, 'Estimate: $n.'));
  }

  int? maxCtx;
  if (computeMaxContext) maxCtx = _maxContext(device, model, options, b, train);

  return FitResult(
    verdict: verdict,
    reasons: List.unmodifiable(reasons),
    breakdown: e.breakdown,
    kv: e.kv,
    contextLength: ctx,
    budgetBytes: b.available,
    demandBytes: e.demand,
    budgetEstimated: b.estimated,
    processCapBytes: b.cap,
    processDemandBytes: e.capDemand,
    recommendedMaxContext: maxCtx,
  );
}

/// Binary search over multiples of 256: memory is monotone in context, so
/// the largest Fits context is well defined.
int? _maxContext(DeviceProfile d, ModelFootprintInput m, FitOptions o, _Budget b, int? train) {
  const step = FitConstants.contextPadding;
  final upper = math.max(step, (train != null && train > 0 ? train : 131072) ~/ step * step);
  bool ok(int ctx) => _evaluate(d, m, o, b, ctx).verdict == FitVerdict.fits;
  if (!ok(step)) return null;
  if (ok(upper)) return upper;
  var lo = 1; // in steps: lo fits, hi does not
  var hi = upper ~/ step;
  while (hi - lo > 1) {
    final mid = (lo + hi) ~/ 2;
    if (ok(mid * step)) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return lo * step;
}

// ---------------------------------------------------------------------------
// Quant recommendation
// ---------------------------------------------------------------------------

/// One downloadable variant of a model (all shards + optional sidecars).
@immutable
final class QuantCandidate {
  const QuantCandidate({
    required this.id,
    required this.weightBytes,
    this.quant,
    this.mmprojBytes = 0,
    this.draftBytes = 0,
    this.parameterCount,
    this.blockedReason,
  });

  final String id;
  final int weightBytes;
  final QuantLabel? quant;
  final int mmprojBytes;
  final int draftBytes;

  /// Exact parameter count when known (GGUF tensor table, `safetensors.total`).
  final int? parameterCount;

  /// Set by the planner for files that must never be offered.
  final String? blockedReason;
}

@immutable
final class RankedQuant {
  const RankedQuant({required this.candidate, required this.fit, this.effectiveBpw, required this.qualityBpw, this.excludedReason});

  final QuantCandidate candidate;
  final FitResult fit;

  /// File bytes × 8 / parameters — the measured truth (R08 §0.20).
  final double? effectiveBpw;

  /// What ranking used: [effectiveBpw], else the name-implied bpw.
  final double qualityBpw;
  final String? excludedReason;

  bool get eligible => excludedReason == null;
}

@immutable
final class QuantRecommendation {
  const QuantRecommendation({required this.ranked, this.best, this.fallback, required this.summary});

  /// Highest-quality eligible variant that Fits (quantized preferred).
  final RankedQuant? best;

  /// When nothing Fits: the highest-quality eligible variant that is Tight.
  final RankedQuant? fallback;

  /// Every candidate, best quality first, with its fit and exclusion.
  final List<RankedQuant> ranked;
  final String summary;
}

/// Effective bits per weight of a file: the number that matters for memory.
double? effectiveBitsPerWeight(int fileBytes, int? parameterCount) =>
    parameterCount == null || parameterCount <= 0 ? null : fileBytes * 8 / parameterCount;

/// Picks the largest-quality variant that Fits with headroom.
///
/// Quality is ranked by measured effective bpw (bytes × 8 / params) when the
/// parameter count is known — names lie for small models (gemma-3-270m
/// Q2_K is 7.07 bpw) — else by the label's bpw. Removed, runtime-unsupported
/// and ternary types are never recommended. Unquantized files are chosen
/// only when no quantized file fits ([FitConstants.preferQuantizedOverFloat]).
QuantRecommendation recommendQuant(
  DeviceProfile device,
  ModelArchitecture architecture,
  List<QuantCandidate> candidates, {
  FitOptions options = const FitOptions(),
}) {
  final ranked = <RankedQuant>[];
  for (final c in candidates) {
    final type = c.quant?.ggufType;
    final fit = assessFit(
      device,
      ModelFootprintInput(
        architecture: architecture,
        weightBytes: c.weightBytes,
        mmprojBytes: c.mmprojBytes,
        draftBytes: c.draftBytes,
        quant: type,
        label: c.id,
      ),
      options: options,
      computeMaxContext: false,
    );
    final eff = effectiveBitsPerWeight(c.weightBytes, c.parameterCount ?? architecture.parameterCount);
    final quality = eff ?? c.quant?.bpw ?? type?.typicalFileBpw ?? c.quant?.bits?.toDouble() ?? 0;
    String? excluded = c.blockedReason;
    if (excluded == null && (c.quant?.isRemoved ?? false)) excluded = '${c.quant!.label} was removed from GGUF';
    if (excluded == null && type != null && options.unsupportedQuants.contains(type.id)) {
      excluded = '${type.id} is not supported by the bundled runtime';
    }
    if (excluded == null && type?.status == QuantStatus.ternary && !options.allowTernary) {
      excluded = 'ternary quants only suit ternary-trained models';
    }
    ranked.add(RankedQuant(candidate: c, fit: fit, effectiveBpw: eff, qualityBpw: quality, excludedReason: excluded));
  }
  int byQuality(RankedQuant x, RankedQuant y) {
    final q = y.qualityBpw.compareTo(x.qualityBpw);
    if (q != 0) return q;
    final xi = x.candidate.quant?.imatrix ?? false ? 1 : 0;
    final yi = y.candidate.quant?.imatrix ?? false ? 1 : 0;
    if (xi != yi) return yi - xi;
    return x.candidate.weightBytes.compareTo(y.candidate.weightBytes);
  }

  ranked.sort(byQuality);
  bool isFloat(RankedQuant r) => r.candidate.quant?.ggufType?.isFloat ?? (r.candidate.quant?.bits ?? 0) >= 16;
  final eligible = ranked.where((r) => r.eligible).toList();
  final fitting = eligible.where((r) => r.fit.verdict == FitVerdict.fits).toList();
  RankedQuant? best;
  if (fitting.isNotEmpty) {
    best = FitConstants.preferQuantizedOverFloat
        ? fitting.firstWhere((r) => !isFloat(r), orElse: () => fitting.first)
        : fitting.first;
  }
  RankedQuant? fallback;
  if (best == null) {
    final tight = eligible.where((r) => r.fit.verdict == FitVerdict.tight).toList();
    if (tight.isNotEmpty) fallback = tight.firstWhere((r) => !isFloat(r), orElse: () => tight.first);
  }
  final summary = best != null
      ? '${best.candidate.id} is the best quality that fits this device with headroom.'
      : fallback != null
          ? 'Nothing fits with headroom; ${fallback.candidate.id} might load but is tight.'
          : eligible.isEmpty
              ? 'No loadable variant in this repository.'
              : 'No variant of this model fits this device.';
  return QuantRecommendation(ranked: List.unmodifiable(ranked), best: best, fallback: fallback, summary: summary);
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

enum StorageVerdict { ok, tight, insufficient, unknown }

@immutable
final class StorageCheck {
  const StorageCheck({
    required this.verdict,
    required this.requiredBytes,
    required this.marginBytes,
    this.freeBytes,
    required this.message,
  });

  final StorageVerdict verdict;

  /// Bytes still to write (download remainder + temporary copies).
  final int requiredBytes;
  final int marginBytes;
  final int? freeBytes;
  final String message;
}

/// Is there room for a download? [tempBytes] covers transient copies (the
/// planner reports the largest byte-split part, which is joined after
/// verification); [alreadyHaveBytes] is what resumable `.part` files hold.
StorageCheck assessStorage({
  required int downloadBytes,
  required int? freeBytes,
  int tempBytes = 0,
  int alreadyHaveBytes = 0,
}) {
  final need = math.max(0, downloadBytes - alreadyHaveBytes) + tempBytes;
  final margin = math.max(FitConstants.storageMarginFloorBytes, (downloadBytes * FitConstants.storageMarginFraction).round());
  if (freeBytes == null) {
    return StorageCheck(
        verdict: StorageVerdict.unknown, requiredBytes: need, marginBytes: margin, message: 'Free space unknown.');
  }
  if (freeBytes >= need + margin) {
    return StorageCheck(
        verdict: StorageVerdict.ok, requiredBytes: need, marginBytes: margin, freeBytes: freeBytes,
        message: 'Needs ${_gb(need)}; ${_gb(freeBytes)} free.');
  }
  if (freeBytes >= need) {
    return StorageCheck(
        verdict: StorageVerdict.tight, requiredBytes: need, marginBytes: margin, freeBytes: freeBytes,
        message: 'Needs ${_gb(need)}; only ${_gb(freeBytes - need)} would be left afterwards.');
  }
  return StorageCheck(
      verdict: StorageVerdict.insufficient, requiredBytes: need, marginBytes: margin, freeBytes: freeBytes,
      message: 'Needs ${_gb(need)} but only ${_gb(freeBytes)} is free.');
}
