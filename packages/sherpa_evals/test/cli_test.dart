// The whole scripted run, as CI invokes it: every suite passes its gates
// against the committed baselines.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sherpa_evals/src/cli.dart';
import 'package:sherpa_evals/src/suites/registry.dart';
import 'package:test/test.dart';

void main() {
  test('--suite all --model scripted passes every gate', () async {
    final tmp = await Directory.systemTemp.createTemp('evals_cli');
    addTearDown(() => tmp.delete(recursive: true));
    final log = File(p.join(tmp.path, 'log.txt')).openWrite();
    final code = await runEvalCli(['--suite', 'all', '--model', 'scripted', '--out', tmp.path], out: log);
    await log.close();
    final text = File(p.join(tmp.path, 'log.txt')).readAsStringSync();
    expect(code, 0, reason: text);
    for (final s in allSuites) {
      final report = (jsonDecode(File(p.join(tmp.path, '${s.id}.json')).readAsStringSync()) as Map).cast<String, Object?>();
      expect(report['passed'], isTrue, reason: s.id);
      expect(File(p.join(tmp.path, '${s.id}.md')).existsSync(), isTrue);
    }
    expect(File(p.join(tmp.path, 'summary.md')).readAsStringSync(), contains('## L4'));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('suite selection and usage errors', () async {
    expect([for (final s in allSuites) s.id], ['L0', 'L1', 'L2', 'L3', 'L4']);
    expect(selectSuites('l3,L4').map((s) => s.id), ['L3', 'L4']);
    expect(() => selectSuites('L5'), throwsArgumentError, reason: 'L5 is deferred');
    expect(await runEvalCli(['--model', 'nonsense'], out: IOSink(StreamController<List<int>>().sink)), 2);
  });
}
