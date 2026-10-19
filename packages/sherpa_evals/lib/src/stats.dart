/// Small statistics helpers shared by suites and benchmarks.
library;

import 'dart:math' as math;

/// Median of [xs] (mean of the middle two for even lengths); NaN if empty.
double median(Iterable<num> xs) {
  final s = [for (final x in xs) x.toDouble()]..sort();
  if (s.isEmpty) return double.nan;
  final mid = s.length ~/ 2;
  return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

/// Linear-interpolated percentile ([q] in 0..1) of [xs]; NaN if empty.
double percentile(Iterable<num> xs, double q) {
  final s = [for (final x in xs) x.toDouble()]..sort();
  if (s.isEmpty) return double.nan;
  if (s.length == 1) return s.single;
  final pos = (s.length - 1) * q.clamp(0, 1);
  final lo = pos.floor();
  final hi = pos.ceil();
  return s[lo] + (s[hi] - s[lo]) * (pos - lo);
}

double mean(Iterable<num> xs) {
  var n = 0;
  var sum = 0.0;
  for (final x in xs) {
    n++;
    sum += x;
  }
  return n == 0 ? double.nan : sum / n;
}

/// pass@1 over tasks: the mean per-task success rate across trials.
double passAt1(List<List<bool>> trialsPerTask) =>
    trialsPerTask.isEmpty ? 0 : mean([for (final t in trialsPerTask) t.isEmpty ? 0 : t.where((x) => x).length / t.length]);

/// pass^k (τ-bench): the share of tasks for which ALL k trials succeed.
/// With fewer than k recorded trials the unbiased estimator
/// C(c, k) / C(n, k) is used (c successes out of n trials), as τ-bench does.
double passHatK(List<List<bool>> trialsPerTask, int k) {
  if (trialsPerTask.isEmpty) return 0;
  return mean([
    for (final t in trialsPerTask) _choose(t.where((x) => x).length, k) / math.max(1, _choose(t.length, k)),
  ]);
}

double _choose(int n, int k) {
  if (k < 0 || k > n) return 0;
  var r = 1.0;
  for (var i = 1; i <= k; i++) {
    r = r * (n - k + i) / i;
  }
  return r;
}
