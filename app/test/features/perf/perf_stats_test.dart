import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/features/perf/state/perf_stats.dart';

void main() {
  group('Summary', () {
    test('median and quartiles interpolate between order statistics', () {
      final s = Summary.of([5, 1, 4, 2, 3]);
      expect(s.n, 5);
      expect(s.min, 1);
      expect(s.q1, 2);
      expect(s.median, 3);
      expect(s.q3, 4);
      expect(s.max, 5);
      expect(s.iqr, 2);

      final even = Summary.of([10, 20, 30, 40]);
      expect(even.median, 25);
      expect(even.q1, 17.5);
      expect(even.q3, 32.5);
    });

    test('one value, no values and non-finite values', () {
      expect(Summary.of([7]).median, 7);
      expect(Summary.of([7]).iqr, 0);
      expect(Summary.of(const []).n, 0);
      expect(Summary.of([1, double.infinity, 3]).n, 2);
    });

    test('overlap is inclusive', () {
      Summary s(double q1, double q3) => Summary(n: 4, min: q1, q1: q1, median: (q1 + q3) / 2, q3: q3, max: q3);
      expect(s(1, 3).overlaps(s(3, 5)), isTrue);
      expect(s(3, 5).overlaps(s(1, 3)), isTrue);
      expect(s(1, 3).overlaps(s(3.1, 5)), isFalse);
      expect(Summary.of([1, 2, 3]).overlaps(Summary.of([4, 5, 6])), isFalse);
    });
  });

  group('MetricComparison', () {
    test('a clear winner when the IQRs do not overlap', () {
      final c = MetricComparison(
        a: Summary.of([10, 10.2, 9.8, 10.1]),
        b: Summary.of([12, 12.3, 11.9, 12.1]),
        higherIsBetter: true,
      );
      expect(c.winner, Winner.b);
      expect(c.advantage, closeTo(12.05 / 10.05 - 1, 1e-9));
    });

    test('lower is better for times', () {
      final c = MetricComparison(a: Summary.of([3, 3.1, 2.9]), b: Summary.of([4, 4.1, 3.9]), higherIsBetter: false);
      expect(c.winner, Winner.a);
      expect(c.advantage, closeTo(0.25, 1e-9));
    });

    test('no winner within noise', () {
      final c = MetricComparison(a: Summary.of([10, 11, 12, 13]), b: Summary.of([11.5, 12.5, 13.5, 14.5]), higherIsBetter: true);
      expect(c.a.overlaps(c.b), isTrue);
      expect(c.winner, Winner.none);
      expect(c.advantage, 0);
    });

    test('no winner with fewer than three runs per side', () {
      final c = MetricComparison(a: Summary.of([10, 10]), b: Summary.of([20, 20]), higherIsBetter: true);
      expect(c.enoughReps, isFalse);
      expect(c.winner, Winner.none);
    });
  });
}
