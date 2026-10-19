import 'dart:convert';
import 'dart:io';

import 'package:sherpa_evals/src/bench/bench.dart';
import 'package:sherpa_evals/src/bench/scenarios.dart';
import 'package:test/test.dart';

void main() {
  for (final s in allBenchScenarios().where((s) => s is! EngineBench)) {
    test('${s.id} runs and writes a gateable result', () async {
      final tmp = await Directory.systemTemp.createTemp('bench_test');
      addTearDown(() => tmp.delete(recursive: true));
      final r = await runScenario(s, samples: 1);
      expect(r.skipped, isNull);
      expect(r.samples, 1);
      final j = (jsonDecode(r.write(tmp.path).readAsStringSync()) as Map).cast<String, Object?>();
      expect(j['scenario'], s.id);
      final metrics = (j['metrics']! as Map).cast<String, Object?>();
      expect(metrics, isNotEmpty);
      for (final m in metrics.values.cast<Map<String, Object?>>()) {
        expect(m['median'], isA<num>());
        expect((m['median']! as num).isFinite, isTrue);
        expect(m['runs'], hasLength(1));
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  }

  test('the engine scenario skips cleanly without engine or model', () {
    final e = EngineBench();
    expect(e.skipReason == null || e.skipReason!.isNotEmpty, isTrue);
  });
}
