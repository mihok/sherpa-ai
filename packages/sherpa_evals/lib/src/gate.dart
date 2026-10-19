/// Eval gates: absolute bounds a suite declares on its metrics, case
/// policies, and "no regressions versus a committed baseline".
library;

import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

import 'report.dart';

/// A committed snapshot of a suite's metrics and per-case verdicts.
@immutable
final class EvalBaseline {
  const EvalBaseline({
    required this.suite,
    required this.model,
    required this.metrics,
    required this.cases,
    this.tolerance = const {},
  });

  factory EvalBaseline.fromJson(Map<String, Object?> j) => EvalBaseline(
        suite: j['suite']! as String,
        model: (j['model'] as String?) ?? 'scripted',
        metrics: {
          for (final e in ((j['metrics'] as Map?) ?? const {}).entries) e.key as String: (e.value as num).toDouble(),
        },
        cases: {for (final e in ((j['cases'] as Map?) ?? const {}).entries) e.key as String: e.value as bool},
        tolerance: {
          for (final e in ((j['tolerance'] as Map?) ?? const {}).entries) e.key as String: (e.value as num).toDouble(),
        },
      );

  /// The baseline a report would produce, keeping [previous] tolerances.
  factory EvalBaseline.fromReport(SuiteReport r, {EvalBaseline? previous}) => EvalBaseline(
        suite: r.suite,
        model: r.model,
        metrics: {
          for (final m in r.metrics)
            if (m.better != Better.none) m.key: m.value,
        },
        cases: {for (final c in r.cases) c.id: c.pass},
        tolerance: previous?.tolerance ?? const {},
      );

  static EvalBaseline? load(File f) {
    if (!f.existsSync()) return null;
    return EvalBaseline.fromJson((jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>());
  }

  final String suite;
  final String model;
  final Map<String, double> metrics;
  final Map<String, bool> cases;

  /// Allowed drift per metric key (default 0: scripted runs are exact).
  final Map<String, double> tolerance;

  Map<String, Object?> toJson() => {
        'suite': suite,
        'model': model,
        'metrics': {for (final e in metrics.entries) e.key: _round(e.value)},
        if (tolerance.isNotEmpty) 'tolerance': tolerance,
        'cases': Map.fromEntries(cases.entries.toList()..sort((a, b) => a.key.compareTo(b.key))),
      };

  void save(File f) {
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(toJson())}\n');
  }
}

num _round(double v) => v == v.roundToDouble() ? v.toInt() : double.parse(v.toStringAsFixed(6));

/// Half a unit of the 6th decimal [_round] keeps, plus float slack.
const double _precision = 5e-7 + 1e-12;

/// Computes [SuiteReport.gates] (replacing any already there):
///
/// 1. every metric with an absolute bound (`min`/`max`) must meet it;
/// 2. cases, per [SuiteReport.casePolicy]: [CasePolicy.all] — every case
///    passes; [CasePolicy.baseline] — no case that passed in [baseline]
///    fails now; [CasePolicy.none] — report only. A case with a
///    `knownIssue` never fails the gate; one that passes anyway is a
///    warning (remove the entry);
/// 3. with a [baseline], no metric with a direction regresses beyond its
///    tolerance (`higher`: not lower; `lower`: not higher; `equal`: same).
///
/// New cases and metrics (absent from the baseline) are accepted and
/// reported as warnings so the baseline gets refreshed.
List<GateCheck> evaluateGates(SuiteReport r, {EvalBaseline? baseline}) {
  final out = <GateCheck>[];
  for (final m in r.metrics.where((m) => m.hasAbsoluteGate)) {
    out.add(GateCheck(
      'metric ${m.key} ${[if (m.min != null) '≥ ${m.min}', if (m.max != null) '≤ ${m.max}'].join(' and ')}',
      pass: m.passesAbsolute,
      detail: 'value ${m.format()}',
    ));
  }
  for (final c in r.cases) {
    if (c.knownIssue != null) {
      if (c.pass) {
        out.add(GateCheck('case ${c.id}', pass: false, warning: true,
            detail: 'passes but is listed as a known issue (${c.knownIssue}); remove the entry'));
      }
      continue;
    }
    if (c.pass) continue;
    switch (r.casePolicy) {
      case CasePolicy.all:
        out.add(GateCheck('case ${c.id}', pass: false, detail: c.detail));
      case CasePolicy.baseline:
        final before = baseline?.cases[c.id];
        if (before == null) {
          out.add(GateCheck('case ${c.id}', pass: false, warning: baseline != null,
              detail: 'new failing case${baseline == null ? ' (no baseline)' : ''}: ${c.detail ?? ''}'));
        } else if (before) {
          out.add(GateCheck('case ${c.id}', pass: false, detail: 'regressed (passed in the baseline): ${c.detail ?? ''}'));
        }
      case CasePolicy.none:
        break;
    }
  }
  if (baseline != null && r.casePolicy != CasePolicy.none) {
    for (final m in r.metrics) {
      if (m.better == Better.none) continue;
      final before = baseline.metrics[m.key];
      if (before == null) {
        out.add(GateCheck('baseline ${m.key}', pass: false, warning: true, detail: 'not in the baseline (new metric)'));
        continue;
      }
      // Baselines store 6 decimals (see [_round]): compare at that precision.
      final tol = (baseline.tolerance[m.key] ?? 0) + _precision;
      final ok = switch (m.better) {
        Better.higher => m.value >= before - tol,
        Better.lower => m.value <= before + tol,
        Better.equal => (m.value - before).abs() <= tol,
        Better.none => true,
      };
      if (!ok) {
        out.add(GateCheck('baseline ${m.key}', pass: false,
            detail: '${m.format()} vs baseline ${Metric(m.name, before, unit: m.unit).format()} (${m.better.name} is better)'));
      }
    }
    final ids = {for (final c in r.cases) c.id};
    final removed = baseline.cases.keys.where((id) => !ids.contains(id)).length;
    if (removed > 0) {
      out.add(GateCheck('baseline cases', pass: false, warning: true, detail: '$removed baseline case(s) no longer run'));
    }
  }
  if (out.every((g) => g.pass || g.warning)) out.insert(0, const GateCheck('all gates', pass: true));
  r.gates
    ..clear()
    ..addAll(out);
  return out;
}
