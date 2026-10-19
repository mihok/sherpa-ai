/// Sherpa's evaluation harness and host benchmarks (see the README).
///
/// The CLIs are `bin/eval.dart` and `bin/bench.dart`; this library exposes
/// what other harnesses (a device test, a dashboard) need: the report and
/// gate types, the suites, the device-runnable L2 runner and the
/// benchmark scenarios.
library;

export 'src/bench/bench.dart';
export 'src/bench/scenarios.dart' show allBenchScenarios;
export 'src/cli.dart' show evalArgParser, runEvalCli;
export 'src/gate.dart';
export 'src/report.dart';
export 'src/suites/l2_ast.dart';
export 'src/suites/l2_bfcl.dart' show bfclTools, l2Categories, observeBfcl, runBfcl;
export 'src/suites/registry.dart';
export 'src/suites/suite.dart';
