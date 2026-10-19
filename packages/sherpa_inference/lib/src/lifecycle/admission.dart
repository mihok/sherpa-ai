import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart';

import '../engine/engine_types.dart';

const int _mib = 1024 * 1024;

/// How admission control sizes a session.
@immutable
final class AdmissionPolicy {
  const AdmissionPolicy({
    this.safetyMarginBytes = 128 * _mib,
    this.fitFraction,
    this.moderatePressureFactor = 0.8,
    this.contextStep = 256,
  });

  /// Subtracted from the budget for allocator slack, the Dart heap growing
  /// during a turn and transient spikes. POLICY; tune with kill forensics.
  final int safetyMarginBytes;

  /// Share of the available memory the model may take. Null = per platform
  /// (`FitConstants`: iOS 0.6 per R06 §5's budget rule, Android/other 0.75).
  final double? fitFraction;

  /// Budget multiplier while the OS reports moderate pressure.
  final double moderatePressureFactor;

  /// llama.cpp pads n_ctx to multiples of 256 (R04 §0.8).
  final int contextStep;
}

/// What admission is asked to fit.
@immutable
final class AdmissionRequest {
  const AdmissionRequest({
    required this.base,
    required this.preferredContext,
    required this.minContext,
    required this.kvLadder,
    this.trainContext,
  });

  /// Everything but n_ctx and the KV types (threads, batches, seed...).
  final SessionConfig base;
  final int preferredContext;
  final int minContext;

  /// KV types to try, best first. For tool-calling sessions it never goes
  /// below q8_0 (R11 §9.6.2).
  final List<KvType> kvLadder;

  /// The model's training context (caps the preferred one), when known.
  final int? trainContext;
}

/// The memory available to a model load.
@immutable
final class MemoryBudget {
  const MemoryBudget({
    required this.totalBytes,
    this.anonymousCapBytes,
    required this.source,
    this.availableBytes,
    this.fraction = 1,
  });

  /// Computes the budget from the latest memory sample and the device.
  factory MemoryBudget.from(MemoryState state, {DeviceProfile? device, AdmissionPolicy policy = const AdmissionPolicy()}) {
    final platform = device?.platform ?? DevicePlatform.other;
    final fraction = policy.fitFraction ??
        switch (platform) {
          DevicePlatform.ios => FitConstants.iosFitFraction,
          DevicePlatform.android => FitConstants.androidFitFraction,
          DevicePlatform.other => FitConstants.otherFitFraction,
        };
    var available = state.availableBytes ?? device?.availableRamBytes;
    var source = state.availableBytes != null ? state.source : 'device profile';
    if (available == null && device != null) {
      final f = platform == DevicePlatform.android
          ? FitConstants.androidAssumedAvailableFraction
          : FitConstants.otherAssumedAvailableFraction;
      available = math.max(0, (device.totalRamBytes * f).round() - FitConstants.appOverheadBytes);
      source = 'estimated from total RAM';
    }
    if (available == null) return const MemoryBudget(totalBytes: null, source: 'unknown');
    var budget = (available * fraction).round() - policy.safetyMarginBytes;
    if (state.pressure == MemoryPressure.moderate) budget = (budget * policy.moderatePressureFactor).round();
    if (state.pressure == MemoryPressure.critical) budget = 0;
    int? cap;
    if (platform == DevicePlatform.android && device != null) {
      final limiter = (device.osMajor ?? 0) >= FitConstants.androidLimiterSinceApiRelease;
      final c = device.perProcessCapBytes ??
          (limiter ? (device.totalRamBytes * FitConstants.androidLimiterForegroundFraction).round() : null);
      if (c != null) cap = (c * fraction).round();
    }
    return MemoryBudget(
      totalBytes: math.max(0, budget),
      anonymousCapBytes: cap,
      source: source,
      availableBytes: available,
      fraction: fraction,
    );
  }

  /// Budget for weights + KV + compute (null = unknown → admit as asked).
  final int? totalBytes;

  /// Per-process cap on anonymous memory (Android 17 limiter), if any.
  final int? anonymousCapBytes;
  final String source;
  final int? availableBytes;
  final double fraction;

  bool get isKnown => totalBytes != null;

  bool admits(MemoryEstimate e) =>
      (totalBytes == null || e.totalBytes <= totalBytes!) &&
      (anonymousCapBytes == null || e.anonymousBytes <= anonymousCapBytes!);
}

/// The result of admission: a config that fits, or a refusal with reasons.
@immutable
final class AdmissionPlan {
  const AdmissionPlan({
    required this.config,
    required this.estimate,
    required this.budget,
    required this.notes,
    this.refusal,
  });

  final SessionConfig? config;
  final MemoryEstimate? estimate;
  final MemoryBudget budget;

  /// Human-readable decisions ("context reduced to 4096 to fit").
  final List<String> notes;

  /// Set when nothing fits; ready to show.
  final String? refusal;

  bool get admitted => config != null && refusal == null;
}

typedef Estimator = Future<MemoryEstimate> Function(SessionConfig config);

/// Picks the largest context, then the best KV type, that fits [budget]:
///
/// 1. the preferred context with each KV type of the ladder (keeping a long
///    context is worth a cheaper KV type down to the ladder's floor);
/// 2. otherwise, per KV type, the largest context that fits, solved from
///    the dry run's linear KV term (`kv_bytes_per_token`) and verified with
///    a second dry run;
/// 3. otherwise refuse, naming the smallest demand and the budget.
///
/// Every number comes from `se_estimate_memory` (no-alloc dry run; within
/// 0.2 % of real allocations on the host, native/llama/README.md), never
/// from file size heuristics.
Future<AdmissionPlan> planAdmission(AdmissionRequest req, MemoryBudget budget, Estimator estimator,
    {AdmissionPolicy policy = const AdmissionPolicy()}) async {
  final notes = <String>[];
  final memo = <(int, KvType), MemoryEstimate>{};
  Future<MemoryEstimate> estimate(SessionConfig c) async =>
      memo[(c.nCtx, c.typeK)] ??= await estimator(c);
  var maxCtx = req.preferredContext;
  if (req.trainContext != null && req.trainContext! > 0 && maxCtx > req.trainContext!) {
    maxCtx = req.trainContext!;
    notes.add('context capped at the model\'s training length ${req.trainContext}');
  }
  final minCtx = math.min(req.minContext, maxCtx);
  SessionConfig cfg(int ctx, KvType kv) => req.base.copyWith(nCtx: ctx, typeK: kv, typeV: kv);

  MemoryEstimate? smallest;
  // 1. Keep the preferred context, lowering KV precision along the ladder.
  for (final kv in req.kvLadder) {
    final e = await estimate(cfg(maxCtx, kv));
    smallest = e;
    if (budget.admits(e)) {
      if (kv != req.kvLadder.first) notes.add('KV cache ${kv.label} to keep a $maxCtx-token context');
      return AdmissionPlan(config: cfg(maxCtx, kv), estimate: e, budget: budget, notes: notes);
    }
    if (!budget.isKnown) break;
  }
  // 2. Shrink the context: per KV type find the largest context that fits,
  //    then take the largest context overall (ties: the better KV type,
  //    which comes first in the ladder).
  final step = policy.contextStep;
  final limit = budget.totalBytes ?? (1 << 62);
  (int, KvType, MemoryEstimate)? best;
  for (final kv in req.kvLadder) {
    final probe = await estimate(cfg(maxCtx, kv));
    final perToken = probe.kvBytesPerToken;
    if (perToken <= 0) continue;
    final capLimit = budget.anonymousCapBytes == null ? null : budget.anonymousCapBytes! + probe.modelMappedBytes;
    final room = (capLimit == null ? limit : math.min(limit, capLimit)) - probe.fixedBytes;
    var ctx = math.min(room <= 0 ? 0 : (room ~/ perToken) ~/ step * step, maxCtx);
    // The linear model is exact for KV; a few re-checks absorb compute-
    // buffer drift without unbounded dry runs.
    for (var tries = 0; tries < 4 && ctx >= minCtx && (best == null || ctx > best.$1); tries++) {
      final e = await estimate(cfg(ctx, kv));
      if (smallest == null || e.totalBytes < smallest.totalBytes) smallest = e;
      if (budget.admits(e)) {
        best = (ctx, kv, e);
        break;
      }
      ctx -= step; // compute buffers move a little with n_ctx; step down and re-check
    }
    if (best == null) {
      final atMin = await estimate(cfg(minCtx, kv));
      if (smallest == null || atMin.totalBytes < smallest.totalBytes) smallest = atMin;
    }
  }
  if (best != null) {
    final (ctx, kv, e) = best;
    notes.add('context reduced to $ctx tokens (KV ${kv.label}) to fit ${_mb(limit)} of memory');
    return AdmissionPlan(config: cfg(ctx, kv), estimate: e, budget: budget, notes: notes);
  }
  final need = smallest == null ? 'more memory' : '${_mb(smallest.totalBytes)} at a ${smallest.nCtx}-token context';
  final have = budget.totalBytes == null ? 'an unknown amount' : _mb(budget.totalBytes!);
  return AdmissionPlan(
    config: null,
    estimate: smallest,
    budget: budget,
    notes: notes,
    refusal: 'Not enough memory to load this model: it needs $need, and about $have is available '
        '(${budget.source}). Close other apps or pick a smaller model.',
  );
}

String _mb(int bytes) => '${(bytes / _mib).round()} MB';
