/// `dart run sherpa_evals:eval`: runs suites, writes reports, applies gates.
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'data.dart';
import 'gate.dart';
import 'report.dart';
import 'runtime/models.dart';
import 'suites/registry.dart';
import 'suites/suite.dart';

ArgParser evalArgParser() => ArgParser()
  ..addOption('suite', abbr: 's', defaultsTo: 'all', help: 'L0..L4, a comma list, or all')
  ..addOption('model', abbr: 'm', defaultsTo: 'scripted', help: 'scripted | local:<gguf> | remote:<provider json>')
  ..addOption('out', defaultsTo: 'build/evals', help: 'report directory')
  ..addOption('baselines', help: 'baseline directory (default: the package\'s baselines/)')
  ..addFlag('update-baseline', negatable: false, help: 'write the current results as the new baselines')
  ..addFlag('gate', defaultsTo: true, help: 'exit non-zero when a gate fails')
  ..addOption('trials', help: 'trials per task (L3 pass^k)')
  ..addOption('limit', help: 'run at most N cases/tasks per suite (real-model subsets)')
  ..addOption('only', help: 'only cases whose id contains this (comma list: any)')
  ..addOption('context', help: 'local model context window (default 4096)')
  ..addOption('threads', help: 'local engine threads (default \$SHERPA_TEST_THREADS or 2)')
  ..addFlag('help', abbr: 'h', negatable: false);

/// Runs the CLI; returns the process exit code.
Future<int> runEvalCli(List<String> argv, {IOSink? out}) async {
  // stdout is not ours to close.
  // ignore: close_sinks
  final o = out ?? stdout;
  final parser = evalArgParser();
  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n\n${parser.usage}');
    return 2;
  }
  if (args.flag('help')) {
    o.writeln('Usage: dart run sherpa_evals:eval [options]\n\n${parser.usage}');
    return 0;
  }
  final ModelSpec model;
  try {
    model = ModelSpec.parse(args.option('model')!);
  } on Object catch (e) {
    stderr.writeln('$e');
    return 2;
  }
  final List<EvalSuite> suites;
  try {
    suites = selectSuites(args.option('suite')!);
  } on ArgumentError catch (e) {
    stderr.writeln(e.message);
    return 2;
  }
  final baselineDir = args.option('baselines') ?? p.join(evalsPackageRoot(), 'baselines');
  final outDir = args.option('out')!;
  ModelRuntime? runtime;
  if (!model.isScripted) {
    o.writeln('loading ${model.label} …');
    runtime = await openRuntime(
      model,
      context: int.tryParse(args.option('context') ?? ''),
      threads: int.tryParse(args.option('threads') ?? ''),
    );
  }
  final ctx = EvalContext(
    model: model,
    runtime: runtime,
    trials: int.tryParse(args.option('trials') ?? ''),
    limit: int.tryParse(args.option('limit') ?? ''),
    only: args.option('only'),
    log: o.writeln,
  );
  final reports = <SuiteReport>[];
  try {
    for (final s in suites) {
      if (!s.supports(model)) {
        o.writeln('${s.id}: skipped for ${model.label}');
        continue;
      }
      o.writeln('${s.id}: ${s.title} (${model.label}) …');
      final sw = Stopwatch()..start();
      final report = await s.run(ctx);
      report.durationMs = sw.elapsedMilliseconds;
      final baselineFile = File(p.join(baselineDir, '${report.suite}.${model.kind}.json'));
      final baseline = EvalBaseline.load(baselineFile);
      evaluateGates(report, baseline: model.isScripted || baseline != null ? baseline : null);
      if (args.flag('update-baseline')) {
        EvalBaseline.fromReport(report, previous: baseline).save(baselineFile);
        o.writeln('  baseline written: ${baselineFile.path}');
      }
      // Real-model reports sit next to the scripted ones (L3.local.json).
      final file = report.write(outDir, name: model.isScripted ? null : '${report.suite}.${model.kind}');
      reports.add(report);
      o.writeln('  ${report.passed ? 'PASS' : 'FAIL'} in ${(report.durationMs / 1000).toStringAsFixed(1)} s → ${file.path}');
      for (final m in report.metrics.where((m) => m.group == null)) {
        o.writeln('    ${m.name}: ${m.format()}');
      }
      for (final g in report.gates.where((g) => !g.pass && !g.warning).take(10)) {
        o.writeln('    ✗ ${g.name}${g.detail == null ? '' : ': ${g.detail}'}');
      }
    }
  } finally {
    await runtime?.dispose();
  }
  if (reports.isNotEmpty) {
    Directory(outDir).createSync(recursive: true);
    File(p.join(outDir, model.isScripted ? 'summary.md' : 'summary.${model.kind}.md'))
        .writeAsStringSync([for (final r in reports) r.toMarkdown()].join('\n'));
  }
  final failed = reports.where((r) => !r.passed).map((r) => r.suite).toList();
  if (failed.isNotEmpty) o.writeln('gates failed: ${failed.join(', ')}');
  return failed.isNotEmpty && args.flag('gate') ? 1 : 0;
}
