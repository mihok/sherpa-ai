/// Runs official reference MCP servers under Node for conformance tests.
///
/// Packages are installed OUTSIDE the repo (default
/// `/tmp/claude-0/mcp-test-servers`, override with
/// `SHERPA_MCP_TEST_SERVERS`); node comes from `SHERPA_MCP_NODE`, `PATH`
/// or `/opt/node22/bin/node`. Tests skip cleanly when either is missing.
/// Server code is only ever executed here, in tests, never in the app.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

String get serversRoot =>
    Platform.environment['SHERPA_MCP_TEST_SERVERS'] ?? '/tmp/claude-0/mcp-test-servers';

String? findNode() {
  final explicit = Platform.environment['SHERPA_MCP_NODE'];
  if (explicit != null && File(explicit).existsSync()) return explicit;
  for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
    if (dir.isNotEmpty && File('$dir/node').existsSync()) return '$dir/node';
  }
  const fallback = '/opt/node22/bin/node';
  return File(fallback).existsSync() ? fallback : null;
}

/// Why the tests needing [paths] (relative to [serversRoot]) cannot run, or null.
String? skipUnless(List<String> paths) {
  if (findNode() == null) return 'node is not available';
  for (final p in paths) {
    if (!File('$serversRoot/$p').existsSync()) return 'missing $serversRoot/$p (run packages/sherpa_mcp/tool/install_test_servers.sh)';
  }
  return null;
}

Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

/// One running server process.
final class NodeServer {
  NodeServer._(this._process, this.port);

  final Process _process;
  final int port;
  final List<String> output = [];

  Uri url(String path) => Uri.parse('http://127.0.0.1:$port$path');

  /// Starts `node <script> <args>` in [cwd] with `PORT`, waiting for [ready].
  static Future<NodeServer> start({
    required String cwd,
    required String script,
    List<String> args = const [],
    Map<String, String> env = const {},
    required RegExp ready,
  }) async {
    final port = await freePort();
    final process = await Process.start(
      findNode()!,
      [script, ...args],
      workingDirectory: cwd,
      environment: {'PORT': '$port', ...env},
    );
    final server = NodeServer._(process, port);
    final up = Completer<void>();
    void onLine(String line) {
      server.output.add(line);
      if (!up.isCompleted && ready.hasMatch(line)) up.complete();
    }

    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine);
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine);
    unawaited(process.exitCode.then((code) {
      if (!up.isCompleted) up.completeError(StateError('server exited ($code): ${server.output.join('\n')}'));
    }));
    await up.future.timeout(const Duration(seconds: 30));
    return server;
  }

  Future<void> stop() async {
    _process.kill();
    await _process.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
      _process.kill(ProcessSignal.sigkill);
      return -1;
    });
  }
}
