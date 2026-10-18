import 'package:meta/meta.dart';

import '../common/json.dart';

/// Escalation thresholds as a fraction of the usable window.
@immutable
final class ContextThresholds {
  const ContextThresholds({this.prune = 0.60, this.compact = 0.80, this.handoff = 0.92})
      : assert(prune < compact && compact < handoff && handoff <= 1.0);

  factory ContextThresholds.fromJson(JsonMap j) => ContextThresholds(
        prune: j.optDouble('prune') ?? 0.60,
        compact: j.optDouble('compact') ?? 0.80,
        handoff: j.optDouble('handoff') ?? 0.92,
      );

  final double prune;
  final double compact;
  final double handoff;

  JsonMap toJson() => {'prune': prune, 'compact': compact, 'handoff': handoff};
}

enum ContextLevel { healthy, pruning, compacting, handoff, overflow }

/// The token budget for one model call:
/// `system + tools + pinned + history + outputReserve <= limit - margin`.
@immutable
final class ContextBudget {
  const ContextBudget({
    required this.limit,
    required this.outputReserve,
    required this.safetyMargin,
    required this.systemTokens,
    required this.toolTokens,
    required this.pinnedTokens,
    required this.historyTokens,
    required this.exact,
  });

  /// The model's (possibly memory-reduced) context window.
  final int limit;
  final int outputReserve;

  /// Extra headroom when counts are estimated rather than exact.
  final int safetyMargin;
  final int systemTokens;
  final int toolTokens;
  final int pinnedTokens;
  final int historyTokens;
  final bool exact;

  int get inputTokens => systemTokens + toolTokens + pinnedTokens + historyTokens;

  /// Tokens available for input once output and margin are reserved.
  int get usableInput => (limit - outputReserve - safetyMargin).clamp(0, limit);

  int get remaining => usableInput - inputTokens;

  /// Fraction of [usableInput] consumed. > 1.0 means the call cannot fit.
  double get ratio => usableInput == 0 ? double.infinity : inputTokens / usableInput;

  bool get fits => remaining >= 0;

  ContextLevel levelFor(ContextThresholds t) {
    final r = ratio;
    if (r > 1.0) return ContextLevel.overflow;
    if (r >= t.handoff) return ContextLevel.handoff;
    if (r >= t.compact) return ContextLevel.compacting;
    if (r >= t.prune) return ContextLevel.pruning;
    return ContextLevel.healthy;
  }

  JsonMap toJson() => {
        'limit': limit,
        'outputReserve': outputReserve,
        'safetyMargin': safetyMargin,
        'system': systemTokens,
        'tools': toolTokens,
        'pinned': pinnedTokens,
        'history': historyTokens,
        'exact': exact,
      };
}
