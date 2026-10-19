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

  group('min_abs_tolerance (absolute floor on the allowed change)', () {
    late Directory b;
    late Directory res;
    setUp(() {
      b = Directory(p.join(tmp.path, 'b'))..createSync();
      res = Directory(p.join(tmp.path, 'r'))..createSync();
    });

    Future<int> gate(Map<String, Object?> spec, num value) async {
      File(p.join(b.path, 'x.json')).writeAsStringSync(jsonEncode({
        'scenario': 'x',
        'min_samples': 1,
        'metrics': {'m': spec},
      }));
      File(p.join(res.path, 'x.json')).writeAsStringSync(jsonEncode({
        'scenario': 'x',
        'samples': 1,
        'metrics': {
          'm': {'median': value},
        },
      }));
      return (await _run(['--results', res.path, '--baselines', b.path])).exitCode;
    }

    test('a zero baseline is no longer a zero-tolerance gate', () async {
      const zero = {'baseline': 0, 'max_regression_pct': 50};
      expect(await gate(zero, 0), 0);
      expect(await gate(zero, 1), 1, reason: 'without a floor one missed frame fails a 0 baseline');
      const floored = {'baseline': 0, 'max_regression_pct': 50, 'min_abs_tolerance': 3};
      expect(await gate(floored, 3), 0);
      expect(await gate(floored, 4), 1);
    });

    test('the floor never tightens a larger relative margin, and the absolute cap still wins', () async {
      expect(await gate({'baseline': 100, 'max_regression_pct': 10, 'min_abs_tolerance': 3}, 110), 0);
      expect(await gate({'baseline': 100, 'max_regression_pct': 10, 'min_abs_tolerance': 3}, 111), 1);
      expect(await gate({'baseline': 2, 'max_regression_pct': 10, 'min_abs_tolerance': 3}, 5), 0, reason: '2 + max(0.2, 3)');
      expect(await gate({'baseline': 0, 'min_abs_tolerance': 5, 'abs_max': 2}, 3), 1, reason: 'min(abs_max 2, 0 + 5)');
      expect(await gate({'baseline': 10, 'better': 'higher', 'max_regression_pct': 10, 'min_abs_tolerance': 4}, 6), 0);
      expect(await gate({'baseline': 10, 'better': 'higher', 'max_regression_pct': 10, 'min_abs_tolerance': 4}, 5.9), 1);
    });

    test('--rebaseline keeps the floor and gives a zero count no zero cap', () async {
      File(p.join(b.path, 'x.json')).writeAsStringSync(jsonEncode({
        'scenario': 'x',
        'min_samples': 1,
        'metrics': {
          'missed': {'baseline': 4, 'unit': 'count', 'max_regression_pct': 50, 'min_abs_tolerance': 3},
        },
      }));
      File(p.join(res.path, 'x.json')).writeAsStringSync(jsonEncode({
        'scenario': 'x',
        'samples': 1,
        'metrics': {
          'missed': {'median': 0, 'unit': 'count'},
          // New in this result: the converter's suggested floor is taken.
          'gc': {'median': 0, 'unit': 'count', 'min_abs_tolerance': 5},
        },
      }));
      final out = p.join(tmp.path, 'new');
      final r = await _run(['--rebaseline', '--results', res.path, '--baselines', b.path, '--out', out]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      final m = (_json(File(p.join(out, 'x.json')))['metrics']! as Map).cast<String, Object?>();
      expect(m['missed'], {'baseline': 0.0, 'unit': 'count', 'max_regression_pct': 50, 'min_abs_tolerance': 3});
      expect(m['gc'], {'baseline': 0.0, 'unit': 'count', 'max_regression_pct': 150, 'min_abs_tolerance': 5});
      // The rebaselined zero passes two missed frames and fails four.
      final rb = Directory(out);
      for (final (v, code) in [(2, 0), (4, 1)]) {
        File(p.join(res.path, 'x.json')).writeAsStringSync(jsonEncode({
          'scenario': 'x',
          'samples': 1,
          'metrics': {
            'missed': {'median': v},
            'gc': {'median': 0},
          },
        }));
        expect((await _run(['--results', res.path, '--baselines', rb.path])).exitCode, code, reason: 'missed=$v');
      }
    });
  });

  group('frame bench', () {
    final converter = p.join(_root, 'bench', 'app', 'timeline_to_result.dart');
    final countKeys = [
      'missed_frame_build_budget_count',
      'missed_frame_rasterizer_budget_count',
      'new_gen_gc_count',
      'old_gen_gc_count',
    ];

    test('timeline_to_result gates the missed-frame and GC counts with a floor', () async {
      final summaries = <String>[];
      for (final (i, missed) in [3, 1, 2].indexed) {
        final f = File(p.join(tmp.path, 'run$i.json'))
          ..writeAsStringSync(jsonEncode({
            'frame_count': 600,
            'average_frame_build_time_millis': 4.1,
            '90th_percentile_frame_build_time_millis': 7.5,
            '99th_percentile_frame_build_time_millis': 12.0,
            '90th_percentile_frame_rasterizer_time_millis': 6.0,
            '99th_percentile_frame_rasterizer_time_millis': 11.0,
            'worst_frame_build_time_millis': 40.0,
            'worst_frame_rasterizer_time_millis': 30.0,
            'missed_frame_build_budget_count': missed,
            'missed_frame_rasterizer_budget_count': 0,
            'new_gen_gc_count': 12,
            'old_gen_gc_count': 0,
            '90th_percentile_vsync_transitions_missed': 0,
            '99th_percentile_vsync_transitions_missed': 1,
          }));
        summaries.add(f.path);
      }
      final out = p.join(tmp.path, 'out');
      final r = await Process.run(Platform.resolvedExecutable,
          [converter, '--scenario', 'chat_stream_long_reply', '--device-class', 'android-mid-adreno650-gles', '--out', out, ...summaries],
          workingDirectory: _root);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      final result = _json(File(p.join(out, 'chat_stream_long_reply.json')));
      final metrics = (result['metrics']! as Map).cast<String, Object?>();
      final info = (result['info']! as Map).cast<String, Object?>();
      for (final k in countKeys) {
        expect(metrics[k], isA<Map<String, Object?>>().having((m) => m['min_abs_tolerance'], 'floor', isA<num>()), reason: k);
        expect(info.containsKey(k), isFalse, reason: '$k is gated, not info');
      }
      expect((metrics['missed_frame_build_budget_count']! as Map)['median'], 2);
      expect(info.keys, containsAll(['worst_frame_build_time_millis', '99th_percentile_vsync_transitions_missed']));

      // Against the device baselines once measured (placeholder flag off):
      // the counts are gated, within their floor.
      final measured = Directory(p.join(tmp.path, 'measured'))..createSync();
      final baseline = _json(File(p.join(_root, 'bench', 'baselines', 'android-mid-adreno650-gles', 'chat_stream_long_reply.json')))
        ..remove('placeholder')
        ..['min_samples'] = 3
        ..['min_frames'] = 540;
      // As a rebaseline would have measured it: 10 young-generation GCs.
      ((baseline['metrics']! as Map)['new_gen_gc_count']! as Map)['baseline'] = 10;
      File(p.join(measured.path, 'chat_stream_long_reply.json')).writeAsStringSync(jsonEncode(baseline));
      final ok = await _run(['--results', out, '--baselines', measured.path]);
      expect(ok.exitCode, 0, reason: '${ok.stdout}');
      expect(ok.stdout, contains('missed_frame_build_budget_count'));
      // Five missed frames against a 0 baseline with a floor of 3: a regression.
      final worse = _json(File(p.join(out, 'chat_stream_long_reply.json')));
      ((worse['metrics']! as Map)['missed_frame_build_budget_count']! as Map)
        ..['median'] = 5
        ..remove('runs');
      File(p.join(out, 'chat_stream_long_reply.json')).writeAsStringSync(jsonEncode(worse));
      final bad = await _run(['--results', out, '--baselines', measured.path]);
      expect(bad.exitCode, 1);
      expect(bad.stdout, matches(RegExp(r'missed_frame_build_budget_count .*\*\*FAIL\*\*')));
    });

    test('every device baseline gates the counts with an absolute floor', () {
      final files = Directory(p.join(_root, 'bench', 'baselines'))
          .listSync()
          .whereType<Directory>()
          .where((d) => !d.path.endsWith('linux-ci'))
          .expand((d) => d.listSync().whereType<File>().where((f) => f.path.endsWith('.json')))
          .toList();
      expect(files, isNotEmpty);
      for (final f in files) {
        final metrics = (_json(f)['metrics']! as Map).cast<String, Object?>();
        for (final k in countKeys) {
          final m = (metrics[k] as Map?)?.cast<String, Object?>();
          expect(m, isNotNull, reason: '${f.path}: $k');
          expect(m!['min_abs_tolerance'], isA<num>().having((n) => n, 'floor', greaterThan(0)), reason: '${f.path}: $k');
        }
      }
    });
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
