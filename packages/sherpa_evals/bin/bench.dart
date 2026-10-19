/// Runs Sherpa's host benchmarks and writes one result file per scenario
/// (`build/bench/<scenario>.json`) for `tools/perf_gate.dart`.
///
///     dart run sherpa_evals:bench [--scenario a,b] [--samples 5] [--out build/bench]
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:sherpa_evals/src/bench/bench.dart';
import 'package:sherpa_evals/src/bench/scenarios.dart';

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('scenario', abbr: 's', defaultsTo: 'all', help: 'scenario ids (comma list) or all')
    ..addOption('samples', abbr: 'n', defaultsTo: '5', help: 'measured samples per scenario (the gate uses the median)')
    ..addOption('out', defaultsTo: 'build/bench', help: 'result directory')
    ..addOption('device-class', defaultsTo: 'linux-ci', help: 'recorded in the results; picks the baselines')
    ..addFlag('list', negatable: false, help: 'list the scenarios')
    ..addFlag('verbose', abbr: 'v', negatable: false)
    ..addFlag('help', abbr: 'h', negatable: false);
  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n\n${parser.usage}');
    exit(2);
  }
  if (args.flag('help')) {
    stdout.writeln('Usage: dart run sherpa_evals:bench [options]\n\n${parser.usage}');
    exit(0);
  }
  final all = allBenchScenarios();
  if (args.flag('list')) {
    for (final s in all) {
      stdout.writeln('${s.id.padRight(28)} ${s.description}');
    }
    exit(0);
  }
  final want = args.option('scenario')!;
  final ids = want == 'all' ? null : {for (final s in want.split(',')) s.trim()};
  final unknown = ids?.where((id) => !all.any((s) => s.id == id)).toList() ?? const [];
  if (unknown.isNotEmpty) {
    stderr.writeln('unknown scenario(s): ${unknown.join(', ')} (have ${all.map((s) => s.id).join(', ')})');
    exit(2);
  }
  final samples = int.tryParse(args.option('samples')!) ?? 5;
  var failed = 0;
  for (final s in all.where((s) => ids == null || ids.contains(s.id))) {
    final sw = Stopwatch()..start();
    try {
      final r = await runScenario(s, samples: samples, deviceClass: args.option('device-class')!, log: args.flag('verbose') ? stdout.writeln : null);
      final f = r.write(args.option('out')!);
      if (r.skipped != null) {
        stdout.writeln('${s.id}: skipped (${r.skipped})');
      } else {
        final medians = r.toJson()['metrics']! as Map;
        stdout.writeln('${s.id} (${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s, ${r.samples} samples) → ${f.path}');
        for (final e in medians.entries) {
          final m = e.value as Map;
          stdout.writeln('  ${e.key}: ${m['median']} ${m['unit']}');
        }
      }
    } on Object catch (e, st) {
      failed++;
      stderr.writeln('${s.id}: FAILED: $e\n$st');
    }
  }
  await stdout.flush();
  // The engine host's isolates must not keep the VM alive.
  exit(failed == 0 ? 0 : 1);
}
