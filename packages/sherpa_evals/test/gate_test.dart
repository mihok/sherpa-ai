import 'package:sherpa_evals/src/gate.dart';
import 'package:sherpa_evals/src/report.dart';
import 'package:sherpa_evals/src/stats.dart';
import 'package:test/test.dart';

SuiteReport _report({CasePolicy policy = CasePolicy.all, List<Metric>? metrics, List<CaseResult>? cases}) =>
    SuiteReport(suite: 'LX', title: 't', model: 'scripted', casePolicy: policy, metrics: metrics, cases: cases);

void main() {
  group('stats', () {
    test('median and percentile', () {
      expect(median([3, 1, 2]), 2);
      expect(median([4, 1, 2, 3]), 2.5);
      expect(median(<num>[]).isNaN, isTrue);
      expect(percentile([1, 2, 3, 4, 5], 0.9), closeTo(4.6, 1e-9));
      expect(percentile([7], 0.99), 7);
    });

    test('pass@1 and pass^k (τ-bench estimator)', () {
      final trials = [
        [true, true, true, true],
        [true, false, true, true],
        [false, false, false, false],
      ];
      expect(passAt1(trials), closeTo((1 + 0.75 + 0) / 3, 1e-9));
      expect(passHatK(trials, 4), closeTo(1 / 3, 1e-9));
      // 3 of 4 successes: C(3,2)/C(4,2) = 3/6.
      expect(passHatK([trials[1]], 2), closeTo(0.5, 1e-9));
    });
  });

  group('evaluateGates', () {
    test('absolute bounds fail the run', () {
      final r = _report(metrics: [const Metric('dups', 1, max: 0), const Metric('rate', 1, min: 1)]);
      evaluateGates(r);
      expect(r.passed, isFalse);
      expect(r.gates.where((g) => !g.pass).single.name, contains('dups'));
    });

    test('CasePolicy.all: any failing case fails; a known issue does not', () {
      final r = _report(cases: [
        const CaseResult(id: 'a', pass: true),
        const CaseResult(id: 'b', pass: false, knownIssue: 'documented'),
      ]);
      evaluateGates(r);
      expect(r.passed, isTrue);
      final r2 = _report(cases: [const CaseResult(id: 'c', pass: false)]);
      evaluateGates(r2);
      expect(r2.passed, isFalse);
    });

    test('a known issue that passes is a warning, not a failure', () {
      final r = _report(cases: [const CaseResult(id: 'b', pass: true, knownIssue: 'documented')]);
      evaluateGates(r);
      expect(r.passed, isTrue);
      expect(r.gates.any((g) => g.warning && g.name == 'case b'), isTrue);
    });

    test('CasePolicy.baseline: only regressions against the baseline fail', () {
      const baseline = EvalBaseline(suite: 'LX', model: 'scripted', metrics: {}, cases: {'old_gap': false, 'was_ok': true});
      final r = _report(policy: CasePolicy.baseline, cases: [
        const CaseResult(id: 'old_gap', pass: false),
        const CaseResult(id: 'was_ok', pass: true),
      ]);
      evaluateGates(r, baseline: baseline);
      expect(r.passed, isTrue);
      final r2 = _report(policy: CasePolicy.baseline, cases: [
        const CaseResult(id: 'old_gap', pass: false),
        const CaseResult(id: 'was_ok', pass: false),
      ]);
      evaluateGates(r2, baseline: baseline);
      expect(r2.passed, isFalse);
    });

    test('directional metrics may not regress beyond tolerance', () {
      const baseline = EvalBaseline(
        suite: 'LX',
        model: 'scripted',
        metrics: {'acc': 0.9, 'cost': 10},
        cases: {},
        tolerance: {'cost': 1},
      );
      final ok = _report(metrics: [const Metric('acc', 0.95, better: Better.higher), const Metric('cost', 11, better: Better.lower)]);
      evaluateGates(ok, baseline: baseline);
      expect(ok.passed, isTrue);
      final bad = _report(metrics: [const Metric('acc', 0.85, better: Better.higher), const Metric('cost', 12, better: Better.lower)]);
      evaluateGates(bad, baseline: baseline);
      expect(bad.gates.where((g) => !g.pass && !g.warning).map((g) => g.name), containsAll(['baseline acc', 'baseline cost']));
    });

    test('a value equal to its 6-decimal baseline is not a regression', () {
      final r = _report(metrics: [Metric('rate', 99 / 107, better: Better.higher), Metric('cost', 2 / 3, better: Better.lower)]);
      final b = EvalBaseline.fromJson(EvalBaseline.fromReport(r).toJson());
      evaluateGates(r, baseline: b);
      expect(r.passed, isTrue, reason: '${r.gates.map((g) => '${g.name}: ${g.detail}')}');
      final worse = _report(metrics: [Metric('rate', 98 / 107, better: Better.higher), Metric('cost', 2 / 3, better: Better.lower)]);
      evaluateGates(worse, baseline: b);
      expect(worse.passed, isFalse);
    });

    test('baselines round-trip and keep tolerances', () {
      final r = _report(metrics: [const Metric('acc', 0.5, better: Better.higher), const Metric('info', 3)], cases: [
        const CaseResult(id: 'x', pass: true),
      ]);
      const prev = EvalBaseline(suite: 'LX', model: 'scripted', metrics: {}, cases: {}, tolerance: {'acc': 0.1});
      final b = EvalBaseline.fromReport(r, previous: prev);
      final back = EvalBaseline.fromJson(b.toJson());
      expect(back.metrics, {'acc': 0.5});
      expect(back.tolerance, {'acc': 0.1});
      expect(back.cases, {'x': true});
    });
  });
}
