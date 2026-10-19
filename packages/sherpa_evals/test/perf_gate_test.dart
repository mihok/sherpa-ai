// Runs the real `tools/perf_gate.dart` as a subprocess against the
// committed `bench/baselines/linux-ci` baselines and synthetic results.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sherpa_evals/src/bench/scenarios.dart';
import 'package:sherpa_evals/src/data.dart';
import 'package:test/test.dart';

final String _root = repoRoot();
final String _gate = p.join(_root, 'tools', 'perf_gate.dart');
final String _baselines = p.join(_root, 'bench', 'baselines', 'linux-ci');

Map<String, Object?> _json(File f) => (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>();

List<File> _baselineFiles() =>
    Directory(_baselines).listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()..sort((a, b) => a.path.compareTo(b.path));

/// A result file whose medians equal the baseline values (times [scale]
/// for [metric] of [scenario]), with [samples] runs.
void _writeResults(
  Directory dir, {
  String? scenario,
  String? metric,
  double scale = 1,
  int samples = 5,
  Set<String> skip = const {},
}) {
  for (final f in _baselineFiles()) {
    final b = _json(f);
    final id = b['scenario']! as String;
    if (skip.contains(id)) continue;
    final metrics = (b['metrics']! as Map).cast<String, Object?>();
    final out = <String, Object?>{
      'schema': 'sherpa.bench.result/1',
      'scenario': id,
      'device_class': 'linux-ci',
      'samples': samples,
      'metrics': {
        for (final e in metrics.entries)
          e.key: () {
            final v = ((e.value! as Map)['baseline']! as num).toDouble() * (id == scenario && e.key == metric ? scale : 1);
            // Noisy runs around the value; the gate takes the median.
            return {'median': v, 'runs': [v * 0.9, v, v * 1.1, v, v * 0.95].take(samples).toList()};
          }(),
      },
    };
    File(p.join(dir.path, '$id.json')).writeAsStringSync(jsonEncode(out));
  }
}

Future<ProcessResult> _run(List<String> args) =>
    Process.run(Platform.resolvedExecutable, ['run', _gate, ...args], workingDirectory: _root);

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('perf_gate_test'));
  tearDown(() async => tmp.delete(recursive: true));

  test('every host scenario has a linux-ci baseline and vice versa', () {
    final scenarios = {for (final s in allBenchScenarios()) s.id};
    final baselines = {for (final f in _baselineFiles()) _json(f)['scenario']! as String};
    expect(baselines, scenarios);
    for (final f in _baselineFiles()) {
      final b = _json(f);
      expect(b['device_class'], 'linux-ci');
      expect(b['min_samples'], greaterThanOrEqualTo(3));
      for (final m in (b['metrics']! as Map).values.cast<Map<String, Object?>>()) {
        expect(m['baseline'], isA<num>());
        expect(m['max_regression_pct'], isA<num>());
        expect(m.containsKey(m['better'] == 'higher' ? 'abs_min' : 'abs_max'), isTrue);
      }
    }
  });

  test('passes against the committed baselines', () async {
    _writeResults(tmp);
    final r = await _run(['--results', tmp.path, '--baselines', _baselines]);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    expect(r.stdout, contains('**PASS**'));
  });

  test('fails on an injected latency regression beyond the margin', () async {
    // markdown p90: +150% allowed; 3x is a regression.
    _writeResults(tmp, scenario: 'markdown_stream', metric: 'p90_us_per_token', scale: 3);
    final summary = p.join(tmp.path, 'summary.md');
    final json = p.join(tmp.path, 'gate.json');
    final r = await _run(['--results', tmp.path, '--baselines', _baselines, '--summary', summary, '--json', json]);
    expect(r.exitCode, 1, reason: '${r.stdout}');
    expect(r.stdout, matches(RegExp(r'markdown_stream \| p90_us_per_token .*\*\*FAIL\*\*')));
    expect(File(summary).readAsStringSync(), contains('**FAIL**'));
    final verdict = _json(File(json));
    expect(verdict['passed'], isFalse);
  });

  test('a regression within the margin passes (noise tolerance)', () async {
    _writeResults(tmp, scenario: 'markdown_stream', metric: 'p90_us_per_token', scale: 2);
    final r = await _run(['--results', tmp.path, '--baselines', _baselines]);
    expect(r.exitCode, 0, reason: '${r.stdout}');
  });

  test('fails when a higher-is-better metric drops below its floor', () async {
    _writeResults(tmp, scenario: 'sse_decode', metric: 'events_per_s', scale: 0.3);
    final r = await _run(['--results', tmp.path, '--baselines', _baselines]);
    expect(r.exitCode, 1);
    expect(r.stdout, matches(RegExp(r'sse_decode \| events_per_s .*\*\*FAIL\*\*')));
  });

  test('the absolute cap applies even inside the relative margin', () async {
    final b = Directory(p.join(tmp.path, 'b'))..createSync();
    final res = Directory(p.join(tmp.path, 'r'))..createSync();
    File(p.join(b.path, 'x.json')).writeAsStringSync(jsonEncode({
      'scenario': 'x',
      'min_samples': 1,
      'metrics': {
        'ms': {'baseline': 10, 'max_regression_pct': 100, 'abs_max': 15},
      },
    }));
    File(p.join(res.path, 'x.json')).writeAsStringSync(jsonEncode({
      'scenario': 'x',
      'samples': 1,
      'metrics': {
        'ms': {'median': 16},
      },
    }));
    final r = await _run(['--results', res.path, '--baselines', b.path]);
    expect(r.exitCode, 1, reason: 'min(15, 10 × 2) = 15 < 16');
  });

  test('a run below min_samples is invalid', () async {
    _writeResults(tmp, samples: 2);
    final r = await _run(['--results', tmp.path, '--baselines', _baselines]);
    expect(r.exitCode, 1);
    expect(r.stdout, contains('INVALID'));
  });

  test('a missing result fails, unless the baseline is optional', () async {
    _writeResults(tmp, skip: {'engine_qwen3_0_6b'});
    final r = await _run(['--results', tmp.path, '--baselines', _baselines]);
    expect(r.exitCode, 0, reason: 'the engine baseline is optional: ${r.stdout}');
    expect(r.stdout, contains('SKIP'));
    File(p.join(tmp.path, 'sse_decode.json')).deleteSync();
    final r2 = await _run(['--results', tmp.path, '--baselines', _baselines]);
    expect(r2.exitCode, 1);
    expect(r2.stdout, contains('MISSING'));
  });

  test('--rebaseline writes new baselines and keeps the margins', () async {
    _writeResults(tmp, scenario: 'handoff', metric: 'build_ms', scale: 2);
    final out = Directory(p.join(tmp.path, 'new'));
    final r = await _run(['--rebaseline', '--results', tmp.path, '--baselines', _baselines, '--out', out.path]);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    final old = _json(File(p.join(_baselines, 'handoff.json')));
    final now = _json(File(p.join(out.path, 'handoff.json')));
    final oldBuild = ((old['metrics']! as Map)['build_ms']! as Map).cast<String, Object?>();
    final newBuild = ((now['metrics']! as Map)['build_ms']! as Map).cast<String, Object?>();
    expect(newBuild['baseline'], closeTo((oldBuild['baseline']! as num) * 2, 0.1));
    expect(newBuild['max_regression_pct'], oldBuild['max_regression_pct']);
    expect(newBuild['abs_max'], oldBuild['abs_max']);
    // The committed baselines are untouched.
    expect(_json(File(p.join(_baselines, 'handoff.json'))), old);
  });
}
