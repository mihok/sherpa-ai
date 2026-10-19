/// Runs Sherpa's eval suites. See `--help` and the package README.
library;

import 'dart:io';

import 'package:sherpa_evals/src/cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await runEvalCli(args);
  // The engine host's isolates and MCP transports must not keep the VM up.
  await stdout.flush();
  exit(exitCode);
}
