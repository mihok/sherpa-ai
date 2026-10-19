/// The eval report: metrics, cases and gate checks, written as JSON (for
/// gates and dashboards) and as a short markdown summary (for humans and
/// CI job summaries).
library;

import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Which direction of change is an improvement.
enum Better {
  higher,
  lower,

  /// Any change is a regression (exact invariants, e.g. a count of 0).
  equal,

  /// Informational: never gated against a baseline.
  none,
}

/// One measured number.
@immutable
final class Metric {
  const Metric(
    this.name,
    this.value, {
    this.better = Better.none,
    this.unit = '',
    this.description,
    this.min,
    this.max,
    this.group,
  });

  factory Metric.fromJson(String name, Map<String, Object?> j) => Metric(
        name,
        (j['value']! as num).toDouble(),
        better: Better.values.byName((j['better'] as String?) ?? 'none'),
        unit: (j['unit'] as String?) ?? '',
        description: j['description'] as String?,
        min: (j['min'] as num?)?.toDouble(),
        max: (j['max'] as num?)?.toDouble(),
        group: j['group'] as String?,
      );

  /// A ratio in [0, 1] computed from counts; 0 when [total] is 0 (with
  /// [whenEmpty] to override).
  factory Metric.ratio(
    String name,
    int count,
    int total, {
    Better better = Better.none,
    String? description,
    double? min,
    double? max,
    double whenEmpty = 0,
    String? group,
  }) =>
      Metric(name, total == 0 ? whenEmpty : count / total,
          better: better, unit: 'ratio', description: description, min: min, max: max, group: group);

  final String name;
  final double value;
  final Better better;
  final String unit;
  final String? description;

  /// Absolute gate: the run fails when [value] is below [min] or above [max].
  final double? min;
  final double? max;

  /// Breakdown key (e.g. a parser path); null for headline metrics.
  final String? group;

  /// The key metrics are stored under (`group/name` for breakdowns).
  String get key => group == null ? name : '$group/$name';

  bool get hasAbsoluteGate => min != null || max != null;

  bool get passesAbsolute => (min == null || value >= min! - 1e-12) && (max == null || value <= max! + 1e-12);

  Map<String, Object?> toJson() => {
        'value': _round(value),
        'better': better.name,
        if (unit.isNotEmpty) 'unit': unit,
        if (description != null) 'description': description,
        if (min != null) 'min': min,
        if (max != null) 'max': max,
        if (group != null) 'group': group,
      };

  String format() {
    if (unit == 'ratio') return '${(value * 100).toStringAsFixed(1)}%';
    final v = value == value.roundToDouble() && value.abs() < 1e12 ? value.toInt().toString() : value.toStringAsFixed(3);
    return unit.isEmpty || unit == 'count' ? v : '$v $unit';
  }
}

num _round(double v) => v == v.roundToDouble() && v.abs() < 1e15 ? v.toInt() : double.parse(v.toStringAsFixed(6));

/// One scenario or corpus case.
@immutable
final class CaseResult {
  const CaseResult({
    required this.id,
    required this.pass,
    this.group,
    this.detail,
    this.knownIssue,
    this.data = const {},
  });

  factory CaseResult.fromJson(Map<String, Object?> j) => CaseResult(
        id: j['id']! as String,
        pass: j['pass']! as bool,
        group: j['group'] as String?,
        detail: j['detail'] as String?,
        knownIssue: j['knownIssue'] as String?,
        data: (j['data'] as Map?)?.cast<String, Object?>() ?? const {},
      );

  final String id;
  final bool pass;
  final String? group;

  /// Why it failed (or what it observed).
  final String? detail;

  /// Set for a documented, accepted failure: it does not fail the gate, and
  /// passing anyway is reported (so the entry can be removed).
  final String? knownIssue;
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => {
        'id': id,
        'pass': pass,
        if (group != null) 'group': group,
        if (detail != null) 'detail': detail,
        if (knownIssue != null) 'knownIssue': knownIssue,
        if (data.isNotEmpty) 'data': data,
      };
}

/// How failing cases affect the gate.
enum CasePolicy {
  /// Every case must pass (deterministic harness invariants).
  all,

  /// A case may fail only if it also failed in the committed baseline
  /// (corpora that document current gaps).
  baseline,

  /// Report only (real models).
  none,
}

/// One gate check.
@immutable
final class GateCheck {
  const GateCheck(this.name, {required this.pass, this.detail, this.warning = false});

  factory GateCheck.fromJson(Map<String, Object?> j) => GateCheck(
        j['name']! as String,
        pass: j['pass']! as bool,
        detail: j['detail'] as String?,
        warning: (j['warning'] as bool?) ?? false,
      );

  final String name;
  final bool pass;
  final String? detail;

  /// Reported but never fails the run.
  final bool warning;

  Map<String, Object?> toJson() => {
        'name': name,
        'pass': pass,
        if (detail != null) 'detail': detail,
        if (warning) 'warning': true,
      };
}

/// What a suite run produced.
final class SuiteReport {
  SuiteReport({
    required this.suite,
    required this.title,
    required this.model,
    this.casePolicy = CasePolicy.all,
    List<Metric>? metrics,
    List<CaseResult>? cases,
    List<String>? notes,
    Map<String, Object?>? extra,
  })  : metrics = metrics ?? [],
        cases = cases ?? [],
        notes = notes ?? [],
        extra = extra ?? {};

  factory SuiteReport.fromJson(Map<String, Object?> j) => SuiteReport(
        suite: j['suite']! as String,
        title: (j['title'] as String?) ?? '',
        model: (j['model'] as String?) ?? 'unknown',
        casePolicy: CasePolicy.values.byName((j['casePolicy'] as String?) ?? 'all'),
        metrics: [
          for (final e in ((j['metrics'] as Map?) ?? const {}).entries)
            Metric.fromJson(_metricName(e.key as String), (e.value as Map).cast<String, Object?>()),
        ],
        cases: [for (final c in (j['cases'] as List?) ?? const []) CaseResult.fromJson((c as Map).cast<String, Object?>())],
        notes: [...((j['notes'] as List?) ?? const []).cast<String>()],
        extra: (j['extra'] as Map?)?.cast<String, Object?>(),
      )
        ..gates.addAll([
          for (final g in (j['gates'] as List?) ?? const []) GateCheck.fromJson((g as Map).cast<String, Object?>()),
        ])
        ..durationMs = (j['durationMs'] as num?)?.toInt() ?? 0;

  static String _metricName(String key) => key.contains('/') ? key.substring(key.lastIndexOf('/') + 1) : key;

  static const String schema = 'sherpa.eval.report/1';

  final String suite;
  final String title;

  /// `scripted`, `local:<file>` or `remote:<id>`.
  final String model;
  final CasePolicy casePolicy;
  final List<Metric> metrics;
  final List<CaseResult> cases;
  final List<String> notes;

  /// Suite-specific structured detail (tables, probe results).
  final Map<String, Object?> extra;
  final List<GateCheck> gates = [];
  int durationMs = 0;

  Metric? metric(String key) {
    for (final m in metrics) {
      if (m.key == key) return m;
    }
    return null;
  }

  /// Every non-warning gate passed.
  bool get passed => gates.every((g) => g.pass || g.warning);

  Iterable<CaseResult> get failures => cases.where((c) => !c.pass);

  Map<String, Object?> toJson() => {
        'schema': schema,
        'suite': suite,
        'title': title,
        'model': model,
        'casePolicy': casePolicy.name,
        'passed': passed,
        'durationMs': durationMs,
        'host': {
          'os': Platform.operatingSystem,
          'cpus': Platform.numberOfProcessors,
          'dart': Platform.version.split(' ').first,
        },
        'metrics': {for (final m in metrics) m.key: m.toJson()},
        'gates': [for (final g in gates) g.toJson()],
        'cases': [for (final c in cases) c.toJson()],
        if (notes.isNotEmpty) 'notes': notes,
        if (extra.isNotEmpty) 'extra': extra,
      };

  /// The short human summary.
  String toMarkdown({int maxFailures = 25}) {
    final b = StringBuffer()
      ..writeln('## $suite — $title')
      ..writeln()
      ..writeln('Model: `$model` · ${cases.length} cases · ${(durationMs / 1000).toStringAsFixed(1)} s · '
          '**${passed ? 'PASS' : 'FAIL'}**')
      ..writeln();
    final headline = metrics.where((m) => m.group == null).toList();
    if (headline.isNotEmpty) {
      b
        ..writeln('| metric | value | gate |')
        ..writeln('|---|---:|---|');
      for (final m in headline) {
        final gate = [
          if (m.min != null) '≥ ${_fmtBound(m, m.min!)}',
          if (m.max != null) '≤ ${_fmtBound(m, m.max!)}',
        ].join(', ');
        b.writeln('| ${m.name} | ${m.format()} | $gate |');
      }
      b.writeln();
    }
    final groups = <String, List<Metric>>{};
    for (final m in metrics.where((m) => m.group != null)) {
      (groups[m.group!] ??= []).add(m);
    }
    if (groups.isNotEmpty) {
      final names = <String>{for (final ms in groups.values) for (final m in ms) m.name}.toList();
      b
        ..writeln('| group | ${names.join(' | ')} |')
        ..writeln('|---|${names.map((_) => '---:').join('|')}|');
      for (final e in groups.entries) {
        final byName = {for (final m in e.value) m.name: m};
        b.writeln('| ${e.key} | ${names.map((n) => byName[n]?.format() ?? '').join(' | ')} |');
      }
      b.writeln();
    }
    final failedGates = gates.where((g) => !g.pass && !g.warning).toList();
    final warnings = gates.where((g) => g.warning && !g.pass).toList();
    if (failedGates.isNotEmpty) {
      b.writeln('**Failed gates**');
      for (final g in failedGates.take(maxFailures)) {
        b.writeln('- ${g.name}${g.detail == null ? '' : ': ${g.detail}'}');
      }
      if (failedGates.length > maxFailures) b.writeln('- … ${failedGates.length - maxFailures} more');
      b.writeln();
    }
    if (warnings.isNotEmpty) {
      b.writeln('**Warnings**');
      for (final g in warnings.take(maxFailures)) {
        b.writeln('- ${g.name}${g.detail == null ? '' : ': ${g.detail}'}');
      }
      b.writeln();
    }
    final known = cases.where((c) => c.knownIssue != null && !c.pass).toList();
    if (known.isNotEmpty) {
      b.writeln('**Known issues (accepted failures)**');
      for (final c in known.take(maxFailures)) {
        b.writeln('- `${c.id}`: ${c.knownIssue}');
      }
      if (known.length > maxFailures) b.writeln('- … ${known.length - maxFailures} more');
      b.writeln();
    }
    if (notes.isNotEmpty) {
      b.writeln('**Notes**');
      for (final n in notes) {
        b.writeln('- $n');
      }
      b.writeln();
    }
    return b.toString();
  }

  static String _fmtBound(Metric m, double v) =>
      m.unit == 'ratio' ? '${(v * 100).toStringAsFixed(1)}%' : (v == v.roundToDouble() ? '${v.toInt()}' : '$v');

  /// Writes `<dir>/<suite>.json` and `<dir>/<suite>.md`; returns the JSON
  /// file. [name] overrides the file stem (e.g. `L3.local`).
  File write(String dir, {String? name}) {
    final stem = name ?? suite;
    Directory(dir).createSync(recursive: true);
    final json = File(p.join(dir, '$stem.json'))
      ..writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(toJson())}\n');
    File(p.join(dir, '$stem.md')).writeAsStringSync(toMarkdown());
    return json;
  }
}
