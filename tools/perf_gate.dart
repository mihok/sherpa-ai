/// Performance gate (docs/research/12-mobile-ux-ci.md §3.8).
///
///     dart run tools/perf_gate.dart [--results build/bench] [--baselines bench/baselines/linux-ci]
///                                   [--summary out.md] [--json out.json]
///     dart run tools/perf_gate.dart --rebaseline [--out dir]
///
/// Reads every baseline `<baselines>/<scenario>.json`:
///
///     {"scenario": "markdown_stream", "device_class": "linux-ci", "min_samples": 5,
///      "metrics": {"p90_us_per_token": {"baseline": 41.2, "max_regression_pct": 150, "abs_max": 400},
///                  "tokens_per_s": {"baseline": 61000, "better": "higher", "max_regression_pct": 60, "abs_min": 5000},
///                  "missed_frame_build_budget_count": {"baseline": 0, "max_regression_pct": 50, "min_abs_tolerance": 3}}}
///
/// and the matching result `<results>/<scenario>.json` written by
/// `dart run sherpa_evals:bench`, which holds `samples` and, per metric,
/// `median` and `runs` (the gate uses the median of the runs).
///
/// * A lower-is-better metric (the default) fails when its median exceeds
///   `min(abs_max, baseline + max(baseline × max_regression_pct/100, min_abs_tolerance))`;
///   a higher-is-better one (`"better": "higher"`) fails when it drops below
///   `max(abs_min, baseline − max(baseline × max_regression_pct/100, min_abs_tolerance))`.
///   `min_abs_tolerance` is an absolute floor on the allowed change, in the
///   metric's unit: without it a relative bound is zero for a zero baseline,
///   so "0 missed frames" would become a zero-tolerance gate. A missing
///   bound is ignored.
/// * A run with fewer than `min_samples` samples is INVALID (fails), and so
///   is a frame-timing run whose `frame_count` is below `min_frames`.
/// * A missing or skipped result fails unless the baseline is
///   `"optional": true` (benchmarks that need hardware, e.g. the engine).
/// * Results without a baseline are reported, not gated.
///
/// `--rebaseline` writes the current medians as new baselines (into
/// `--out`, default the baselines directory), keeping each metric's
/// margins; it still refuses invalid runs (`--min-samples N` sets the
/// requirement for scenarios that have no baseline yet, default 5). In CI it runs only for PRs
/// labelled `perf-rebaseline`, and uploads the new files for review.
///
/// Exit codes: 0 pass, 1 regression or invalid run, 2 usage error.
library;

import 'dart:convert';
import 'dart:io';

/// One gated metric's verdict.
final class MetricVerdict {
  MetricVerdict(this.name, this.value, this.baseline, this.limit, this.higher, this.pass, {this.note});

  final String name;
  final double? value;
  final double baseline;
  final double? limit;
  final bool higher;
  final bool pass;
  final String? note;
}

/// One scenario's verdict.
final class ScenarioVerdict {
  ScenarioVerdict(this.scenario, this.status, {this.detail, List<MetricVerdict>? metrics}) : metrics = metrics ?? [];

  final String scenario;

  /// PASS, FAIL, INVALID, SKIP, MISSING or NEW.
  final String status;
  final String? detail;
  final List<MetricVerdict> metrics;

  bool get failed => status == 'FAIL' || status == 'INVALID' || status == 'MISSING';
}

Map<String, Object?> _readJson(File f) => (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>();

double? _num(Object? v) => v is num ? v.toDouble() : null;

double _median(List<double> xs) {
  final s = [...xs]..sort();
  if (s.isEmpty) return double.nan;
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

/// The median of a result metric: recomputed from `runs` when present.
double? resultValue(Object? metric) {
  if (metric is num) return metric.toDouble();
  if (metric is! Map) return null;
  final runs = metric['runs'];
  if (runs is List && runs.isNotEmpty) {
    return _median([
      for (final r in runs)
        if (r is num) r.toDouble(),
    ]);
  }
  return _num(metric['median']) ?? _num(metric['value']);
}

/// The threshold a metric must stay within (null: no bound).
double? limitFor(Map<String, Object?> spec) {
  final base = _num(spec['baseline'])!;
  final pct = _num(spec['max_regression_pct']);
  final floor = _num(spec['min_abs_tolerance']);
  final higher = spec['better'] == 'higher';
  // The allowed change: the relative margin, but never less than the floor.
  final relTol = pct == null ? null : (base * pct / 100).abs();
  final tol = relTol == null ? floor : (floor == null || relTol > floor ? relTol : floor);
  if (higher) {
    final rel = tol == null ? null : base - tol;
    final abs = _num(spec['abs_min']);
    if (rel == null) return abs;
    return abs == null ? rel : (rel > abs ? rel : abs);
  }
  final rel = tol == null ? null : base + tol;
  final abs = _num(spec['abs_max']);
  if (rel == null) return abs;
  return abs == null ? rel : (rel < abs ? rel : abs);
}

/// Gates one [baseline] against its [result] (null when the file is missing).
ScenarioVerdict gateScenario(Map<String, Object?> baseline, Map<String, Object?>? result) {
  final id = baseline['scenario']! as String;
  final optional = baseline['optional'] == true;
  if (result == null) {
    return ScenarioVerdict(id, optional ? 'SKIP' : 'MISSING', detail: 'no result file');
  }
  if (result['skipped'] != null) {
    return ScenarioVerdict(id, optional ? 'SKIP' : 'MISSING', detail: 'skipped: ${result['skipped']}');
  }
  final minSamples = (_num(baseline['min_samples']) ?? 1).toInt();
  final samples = (_num(result['samples']) ?? 0).toInt();
  if (samples < minSamples) {
    return ScenarioVerdict(id, 'INVALID', detail: '$samples samples < min_samples $minSamples');
  }
  final metrics = ((result['metrics'] as Map?) ?? const {}).cast<String, Object?>();
  final minFrames = _num(baseline['min_frames']);
  if (minFrames != null) {
    final frames = resultValue(metrics['frame_count']);
    if (frames == null || frames < minFrames) {
      return ScenarioVerdict(
        id,
        'INVALID',
        detail: 'frame_count ${frames?.toStringAsFixed(0)} < min_frames ${minFrames.toStringAsFixed(0)}',
      );
    }
  }
  final out = <MetricVerdict>[];
  for (final e in ((baseline['metrics'] as Map?) ?? const {}).cast<String, Object?>().entries) {
    final spec = (e.value! as Map).cast<String, Object?>();
    final higher = spec['better'] == 'higher';
    final base = _num(spec['baseline'])!;
    final value = resultValue(metrics[e.key]);
    final limit = limitFor(spec);
    if (value == null || value.isNaN) {
      out.add(MetricVerdict(e.key, null, base, limit, higher, false, note: 'missing from the result'));
      continue;
    }
    final pass = limit == null || (higher ? value >= limit : value <= limit);
    out.add(MetricVerdict(e.key, value, base, limit, higher, pass));
  }
  return ScenarioVerdict(id, out.every((m) => m.pass) ? 'PASS' : 'FAIL', metrics: out);
}

String _fmt(double? v) {
  if (v == null) return '—';
  if (v.abs() >= 1000) return v.toStringAsFixed(0);
  if (v.abs() >= 10) return v.toStringAsFixed(1);
  return v.toStringAsFixed(3);
}

String markdown(List<ScenarioVerdict> vs, {required String baselines}) {
  final b = StringBuffer()
    ..writeln('## Perf gate (`$baselines`)')
    ..writeln()
    ..writeln('| scenario | metric | median | baseline | limit | status |')
    ..writeln('|---|---|---:|---:|---:|---|');
  for (final v in vs) {
    if (v.metrics.isEmpty) {
      b.writeln('| ${v.scenario} | | | | | **${v.status}** ${v.detail ?? ''} |');
      continue;
    }
    for (final m in v.metrics) {
      final dir = m.higher ? '≥' : '≤';
      final change = m.value == null || m.baseline == 0
          ? ''
          : ' (${((m.value! / m.baseline - 1) * 100).toStringAsFixed(0)}%)';
      b.writeln(
        '| ${v.scenario} | ${m.name} | ${_fmt(m.value)}$change | ${_fmt(m.baseline)} | '
        '${m.limit == null ? '' : '$dir ${_fmt(m.limit)}'} | ${m.pass ? 'pass' : '**FAIL**'}${m.note == null ? '' : ' ${m.note}'} |',
      );
    }
  }
  final failed = vs.where((v) => v.failed).length;
  b
    ..writeln()
    ..writeln(failed == 0 ? '**PASS**' : '**FAIL**: $failed scenario(s)');
  return b.toString();
}

Map<String, Object?> _rebaselined(Map<String, Object?>? old, Map<String, Object?> result, {required int minSamples}) {
  final metrics = ((result['metrics'] as Map?) ?? const {}).cast<String, Object?>();
  final oldMetrics = ((old?['metrics'] as Map?) ?? const {}).cast<String, Object?>();
  double round(double v) =>
      v.abs() >= 100 ? double.parse(v.toStringAsFixed(1)) : double.parse(v.toStringAsPrecision(4));
  return {
    'scenario': result['scenario'],
    'device_class': result['device_class'] ?? old?['device_class'],
    if (old?['description'] != null || result['description'] != null)
      'description': old?['description'] ?? result['description'],
    'min_samples': old?['min_samples'] ?? minSamples,
    // Frame-timing runs (R12): fewer frames than this make a run invalid.
    if (old?['min_frames'] != null || metrics.containsKey('frame_count'))
      'min_frames': old?['min_frames'] ?? (resultValue(metrics['frame_count'])! * 0.9).floor(),
    if (old?['optional'] == true) 'optional': true,
    if (old?['note'] != null) 'note': old!['note'],
    'measured': {
      'samples': result['samples'],
      'host': result['host'],
      'at': DateTime.now().toUtc().toIso8601String().substring(0, 10),
    },
    'metrics': {
      for (final e in metrics.entries)
        if (e.key != 'frame_count')
          e.key: () {
            final prev = (oldMetrics[e.key] as Map?)?.cast<String, Object?>();
            final value = resultValue(e.value)!;
            final higher = ((e.value as Map?)?['better'] ?? prev?['better']) == 'higher';
            // The floor is kept from the old baseline, else taken from the
            // result's suggestion (timeline_to_result.dart sets one for counts).
            final floor = prev?['min_abs_tolerance'] ?? (e.value as Map?)?['min_abs_tolerance'];
            // A ×10 cap of a zero baseline would be a zero-tolerance gate again.
            final Object? cap;
            if (higher) {
              cap = prev?['abs_min'] ?? round(value / 10);
            } else {
              cap = prev?['abs_max'] ?? (value == 0 ? null : round(value * 10));
            }
            return {
              'baseline': round(value),
              if (higher) 'better': 'higher',
              if ((e.value as Map?)?['unit'] case final String u when u.isNotEmpty) 'unit': u,
              'max_regression_pct': prev?['max_regression_pct'] ?? (higher ? 60 : 150),
              'min_abs_tolerance': ?floor,
              if (higher) 'abs_min': cap else 'abs_max': ?cap,
            };
          }(),
    },
  };
}

Future<int> runPerfGate(List<String> argv, {IOSink? out}) async {
  // stdout is not ours to close.
  // ignore: close_sinks
  final o = out ?? stdout;
  String? opt(String name) {
    final i = argv.indexOf('--$name');
    if (i < 0) return null;
    if (i + 1 >= argv.length) throw FormatException('--$name needs a value');
    return argv[i + 1];
  }

  final String results;
  final String baselines;
  final String? summary;
  final String? jsonOut;
  final String? rebaseOut;
  final int newMinSamples;
  try {
    for (final a in argv) {
      if (a.startsWith('--') &&
          !const {'--results', '--baselines', '--summary', '--json', '--out', '--min-samples', '--rebaseline', '--help'}.contains(a)) {
        throw FormatException('unknown option $a');
      }
    }
    results = opt('results') ?? 'build/bench';
    baselines = opt('baselines') ?? 'bench/baselines/linux-ci';
    summary = opt('summary');
    jsonOut = opt('json');
    rebaseOut = opt('out');
    newMinSamples = int.parse(opt('min-samples') ?? '5');
  } on FormatException catch (e) {
    stderr.writeln(
      '${e.message}\nusage: dart run tools/perf_gate.dart [--results dir] [--baselines dir] '
      '[--summary file.md] [--json file.json] [--rebaseline [--out dir]]',
    );
    return 2;
  }
  if (argv.contains('--help')) {
    o.writeln(
      'usage: dart run tools/perf_gate.dart [--results dir] [--baselines dir] [--summary file.md] '
      '[--json file.json] [--rebaseline [--out dir]]',
    );
    return 0;
  }
  final bdir = Directory(baselines);
  final rdir = Directory(results);
  final baselineFiles = bdir.existsSync()
      ? (bdir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];
  final resultFiles = rdir.existsSync()
      ? (rdir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];
  Map<String, Object?>? resultFor(String scenario) {
    final f = File('${rdir.path}/$scenario.json');
    return f.existsSync() ? _readJson(f) : null;
  }

  if (argv.contains('--rebaseline')) {
    if (resultFiles.isEmpty) {
      stderr.writeln('no results in ${rdir.path}');
      return 1;
    }
    final target = Directory(rebaseOut ?? baselines)..createSync(recursive: true);
    var invalid = 0;
    for (final f in resultFiles) {
      final r = _readJson(f);
      final id = r['scenario'] as String?;
      if (id == null) continue;
      final oldFile = File('${bdir.path}/$id.json');
      final old = oldFile.existsSync() ? _readJson(oldFile) : null;
      if (r['skipped'] != null) {
        o.writeln('$id: skipped (${r['skipped']}); baseline kept');
        if (old != null && target.path != bdir.path) {
          File('${target.path}/$id.json').writeAsStringSync(oldFile.readAsStringSync());
        }
        continue;
      }
      final minSamples = (_num(old?['min_samples']) ?? newMinSamples).toInt();
      if ((_num(r['samples']) ?? 0) < minSamples) {
        stderr.writeln('$id: INVALID (${r['samples']} samples < $minSamples); not rebaselined');
        invalid++;
        continue;
      }
      File('${target.path}/$id.json')
          .writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(_rebaselined(old, r, minSamples: newMinSamples))}\n');
      o.writeln('$id: rebaselined → ${target.path}/$id.json');
    }
    return invalid == 0 ? 0 : 1;
  }

  if (baselineFiles.isEmpty) {
    stderr.writeln('no baselines in ${bdir.path}');
    return 1;
  }
  final verdicts = <ScenarioVerdict>[];
  final gated = <String>{};
  for (final f in baselineFiles) {
    final b = _readJson(f);
    final id = b['scenario']! as String;
    gated.add(id);
    verdicts.add(gateScenario(b, resultFor(id)));
  }
  for (final f in resultFiles) {
    final id = _readJson(f)['scenario'];
    if (id is String && !gated.contains(id)) {
      verdicts.add(ScenarioVerdict(id, 'NEW', detail: 'no baseline (not gated)'));
    }
  }
  final md = markdown(verdicts, baselines: bdir.path);
  o.writeln(md);
  if (summary != null) File(summary).writeAsStringSync(md, mode: FileMode.append);
  if (jsonOut != null) {
    File(jsonOut).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({
        'schema': 'sherpa.perf.gate/1',
        'passed': !verdicts.any((v) => v.failed),
        'scenarios': [
          for (final v in verdicts) {
              'scenario': v.scenario,
              'status': v.status,
              if (v.detail != null) 'detail': v.detail,
              'metrics': [
                for (final m in v.metrics) {'name': m.name, 'value': m.value, 'baseline': m.baseline, 'limit': m.limit, 'pass': m.pass},
              ],
            },
        ],
      })}\n',
    );
  }
  return verdicts.any((v) => v.failed) ? 1 : 0;
}

Future<void> main(List<String> argv) async {
  exitCode = await runPerfGate(argv);
}
