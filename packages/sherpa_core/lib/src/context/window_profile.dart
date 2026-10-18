import 'package:meta/meta.dart';

import '../common/json.dart';
import '../provider/model_provider.dart';
import 'budget.dart';
import 'token_estimator.dart';

/// Size class of a model window, from the R11 §9.2 table.
enum WindowTier { tiny, small, medium, large, huge, custom }

/// Escalation-ladder parameters for one window size (R11 §9.2).
///
/// Why window-scaled: a fixed 80% compaction trigger is fine on a 200K
/// window but on a 4–8K on-device window the summarization call itself would
/// not fit, and keeping the last 4 user turns verbatim can be the whole
/// window. The table lowers the triggers and the kept tail as W shrinks.
@immutable
final class WindowProfile {
  const WindowProfile({
    required this.thresholds,
    required this.keepRecentUserTurns,
    required this.keptTailFraction,
    this.modelCompaction = true,
    this.tier = WindowTier.custom,
  });

  /// Looks up the §9.2 row for the (memory-adjusted) window [limit] and
  /// applies the compact-trigger formula.
  ///
  /// | Window | prune | compact | handoff | keep | kept tail |
  /// |---|---|---|---|---|---|
  /// | ≤ 4K | 0.50 | 0.70, deterministic summary only | 0.85 | 1 | 40% W |
  /// | ≤ 8K | 0.55 | ≤ 0.70 (formula) | 0.90 | 2 | 35% W |
  /// | ≤ 16K | 0.60 | ≤ 0.78 (formula) | 0.92 | 2 | 30% W |
  /// | < 128K | 0.60 | ≤ 0.80 (formula) | 0.92 | 3 | 30% W |
  /// | ≥ 128K | 0.50, ≤ 100K abs | 0.85, ≤ 150K abs | 0.95 | 4 | 30% W |
  ///
  /// The ≤ 4K compact ratio is Sherpa's choice (the digest leaves it open):
  /// halfway between prune and handoff, since the extractive summary needs no
  /// summarizer call and so no formula headroom.
  factory WindowProfile.forWindow({
    required int limit,
    required int usableInput,
    int safetyMargin = 0,
    int maxSummaryTokens = defaultMaxSummaryTokens,
    int summarizerPromptTokens = defaultSummarizerPromptTokens,
  }) {
    final w = usableInput <= 0 ? 1 : usableInput;
    final formula = compactTrigger(
      limit: limit,
      usableInput: w,
      safetyMargin: safetyMargin,
      maxSummaryTokens: maxSummaryTokens,
      summarizerPromptTokens: summarizerPromptTokens,
    );
    final (tier, prune, compact, handoff, keep, tail) = switch (limit) {
      <= 4096 => (WindowTier.tiny, 0.50, 0.70, 0.85, 1, 0.40),
      <= 8192 => (WindowTier.small, 0.55, _min(0.70, formula), 0.90, 2, 0.35),
      <= 16384 => (WindowTier.medium, 0.60, _min(0.78, formula), 0.92, 2, 0.30),
      < 131072 => (WindowTier.large, 0.60, _min(0.80, formula), 0.92, 3, 0.30),
      _ => (
          WindowTier.huge,
          _min(0.50, 100000 / w),
          _min(_min(0.85, 150000 / w), formula),
          0.95,
          4,
          0.30,
        ),
    };
    return WindowProfile(
      tier: tier,
      thresholds: ordered(prune: prune, compact: compact, handoff: handoff),
      keepRecentUserTurns: keep,
      keptTailFraction: tail,
      modelCompaction: tier != WindowTier.tiny,
    );
  }

  factory WindowProfile.fromJson(JsonMap j) => WindowProfile(
        thresholds: ContextThresholds.fromJson(j.obj('thresholds')),
        keepRecentUserTurns: j.optInt('keepRecentUserTurns') ?? 2,
        keptTailFraction: j.optDouble('keptTailFraction') ?? 0.30,
        modelCompaction: j.opt<bool>('modelCompaction') ?? true,
        tier: WindowTier.values.firstWhere((t) => t.name == j.opt<String>('tier'), orElse: () => WindowTier.custom),
      );

  static const int defaultMaxSummaryTokens = 1024;
  static const int defaultSummarizerPromptTokens = 500;

  final ContextThresholds thresholds;

  /// K: the kept tail starts at the oldest of the last K real user turns.
  final int keepRecentUserTurns;

  /// Cap on the kept tail as a fraction of W; K shrinks until it fits.
  final double keptTailFraction;

  /// False for ≤ 4K windows: no LLM summarizer, the deterministic summary
  /// is used and a handoff is recommended right after (R11 §9.2).
  final bool modelCompaction;
  final WindowTier tier;

  /// `compactAt ≤ (limit − summarizerPromptTokens − maxSummaryTokens −
  /// margin) / W`, clamped to [0.5, 0.85]: the summarization request (the
  /// context up to the cut + the prompt + the summary it writes) must itself
  /// fit the window (R11 §9.2).
  static double compactTrigger({
    required int limit,
    required int usableInput,
    int safetyMargin = 0,
    int maxSummaryTokens = defaultMaxSummaryTokens,
    int summarizerPromptTokens = defaultSummarizerPromptTokens,
  }) {
    if (usableInput <= 0) return 0.5;
    final raw = (limit - summarizerPromptTokens - maxSummaryTokens - safetyMargin) / usableInput;
    return raw.isNaN ? 0.5 : raw.clamp(0.5, 0.85).toDouble();
  }

  /// Estimate margin (R11 §9.2): none for exact counters; [calibrated]
  /// (0.10) once a heuristic counter has ≥ 3 calibrations and dense-script
  /// share is ≤ 25%; [uncalibrated] (0.20) otherwise. Counters other than
  /// [HeuristicTokenCounter] report no calibrations, so they get 0.20.
  static double safetyFraction(
    TokenCounter counter, {
    required double denseShare,
    double calibrated = 0.10,
    double uncalibrated = 0.20,
  }) {
    if (counter.isExact) return 0;
    final calibrations = counter is HeuristicTokenCounter ? counter.calibrationCount : 0;
    return calibrations >= 3 && denseShare <= 0.25 ? calibrated : uncalibrated;
  }

  /// Builds thresholds that satisfy `prune < compact < handoff ≤ 1`, pulling
  /// prune below compact when the formula forces compaction early.
  static ContextThresholds ordered({required double prune, required double compact, required double handoff}) {
    final h = handoff.clamp(0.05, 1.0).toDouble();
    final c = compact.clamp(0.03, h - 0.01).toDouble();
    final p = prune.clamp(0.01, c - 0.02).toDouble();
    return ContextThresholds(prune: p, compact: c, handoff: h);
  }

  /// Thermal pressure: prune [shift] earlier so the device does less
  /// prefill work per step (compaction and handoff are unchanged).
  WindowProfile pruneEarlier(double shift) => shift <= 0
      ? this
      : WindowProfile(
          thresholds: ordered(
            prune: (thresholds.prune - shift).clamp(0.2, 1.0).toDouble(),
            compact: thresholds.compact,
            handoff: thresholds.handoff,
          ),
          keepRecentUserTurns: keepRecentUserTurns,
          keptTailFraction: keptTailFraction,
          modelCompaction: modelCompaction,
          tier: tier,
        );

  JsonMap toJson() => {
        'thresholds': thresholds.toJson(),
        'keepRecentUserTurns': keepRecentUserTurns,
        'keptTailFraction': keptTailFraction,
        'modelCompaction': modelCompaction,
        'tier': tier.name,
      };

  static double _min(double a, double b) => a < b ? a : b;
}
