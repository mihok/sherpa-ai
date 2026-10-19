import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;

/// Five-number summary of a small sample (one metric over N reps).
///
/// Quartiles use linear interpolation between order statistics (the
/// "type 7" definition spreadsheets use), so 3 to 10 reps give stable,
/// explainable numbers without a stats dependency.
@immutable
final class Summary {
  const Summary({required this.n, required this.min, required this.q1, required this.median, required this.q3, required this.max});

  factory Summary.of(Iterable<double> values) {
    final v = [for (final x in values) if (x.isFinite) x]..sort();
    if (v.isEmpty) return const Summary(n: 0, min: 0, q1: 0, median: 0, q3: 0, max: 0);
    return Summary(
      n: v.length,
      min: v.first,
      q1: quantile(v, 0.25),
      median: quantile(v, 0.5),
      q3: quantile(v, 0.75),
      max: v.last,
    );
  }

  final int n;
  final double min;
  final double q1;
  final double median;
  final double q3;
  final double max;

  /// Interquartile range: the middle half of the runs.
  double get iqr => q3 - q1;

  /// IQR relative to the median ("±4 %" spread), 0 when the median is 0.
  double get relativeSpread => median == 0 ? 0 : iqr / median.abs();

  /// The middle halves of the two samples share at least one value.
  bool overlaps(Summary other) => q1 <= other.q3 && other.q1 <= q3;

  /// [p] in 0..1 of an ascending list.
  static double quantile(List<double> sorted, double p) {
    if (sorted.length == 1) return sorted.single;
    final h = (sorted.length - 1) * p;
    final lo = h.floor();
    final hi = math.min(lo + 1, sorted.length - 1);
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (h - lo);
  }
}

/// Which side of an A/B comparison is better on one metric.
enum Winner { a, b, none }

/// The minimum reps per side before a winner can be called: with fewer the
/// quartiles are just the samples themselves.
const int kMinRepsForVerdict = 3;

/// One metric compared between A and B.
///
/// The rule is deliberately simple and conservative: a side wins only when
/// the middle halves of the runs (the IQRs) do not overlap, so a winner is
/// one that was better in at least three quarters of the pairs, not one
/// lucky median. Fewer than [kMinRepsForVerdict] reps per side never call
/// a winner.
@immutable
final class MetricComparison {
  const MetricComparison({required this.a, required this.b, required this.higherIsBetter});

  final Summary a;
  final Summary b;
  final bool higherIsBetter;

  bool get enoughReps => a.n >= kMinRepsForVerdict && b.n >= kMinRepsForVerdict;

  Winner get winner {
    if (!enoughReps || a.overlaps(b)) return Winner.none;
    final aBetter = higherIsBetter ? a.median > b.median : a.median < b.median;
    return aBetter ? Winner.a : Winner.b;
  }

  /// How much better the winner's median is, as a fraction of the loser's
  /// (0.18 = 18 % faster or 18 % less time). 0 without a winner.
  double get advantage {
    final w = winner;
    if (w == Winner.none) return 0;
    final (best, other) = w == Winner.a ? (a.median, b.median) : (b.median, a.median);
    if (other == 0) return 0;
    return higherIsBetter ? best / other - 1 : 1 - best / other;
  }
}
