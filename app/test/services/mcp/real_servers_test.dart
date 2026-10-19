/// The app's MCP wiring against the official reference servers under Node,
/// the ones sherpa_mcp's conformance tests use: server-everything 1.0.0
/// (Streamable HTTP, 2025-11-25 sessions) and the 2026-07-28 test server on
/// `@modelcontextprotocol/server@2.3.1`.
///
/// Install them with `packages/sherpa_mcp/tool/install_test_servers.sh`;
/// without them (or without node) these tests skip.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sherpa/services/mcp/input/elicitation_form.dart';
import 'package:sherpa/services/mcp/input/host_settings.dart';
import 'package:sherpa/services/mcp/input/input_queue.dart';
import 'package:sherpa/services/mcp/mcp_records.dart';
import 'package:sherpa/services/mcp/mcp_runtime.dart';
import 'package:sherpa/services/mcp/server_probe.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';

import 'support/mcp_fakes.dart';

String get _root => Platform.environment['SHERPA_MCP_TEST_SERVERS'] ?? '/tmp/claude-0/mcp-test-servers';

String? _node() {
  for (final dir in [...(Platform.environment['PATH'] ?? '').split(':'), '/opt/node22/bin']) {
    if (dir.isNotEmpty && File('$dir/node').existsSync()) return '$dir/node';
  }
  return null;
}

String? _skip(String path) {
  if (_node() == null) return 'node is not available';
  return File('$_root/$path').existsSync() ? null : 'missing $_root/$path (run packages/sherpa_mcp/tool/install_test_servers.sh)';
}

final class _Node {
  _Node(this.process, this.port);

  final Process process;
  final int port;

  static Future<_Node> start(String cwd, String script, List<String> args, RegExp ready, {Map<String, String> env = const {}}) async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    final p = await Process.start(_node()!, [script, ...args], workingDirectory: cwd, environment: {'PORT': '$port', ...env});
    final up = Completer<void>();
    final out = <String>[];
    void line(String l) {
      out.add(l);
      if (!up.isCompleted && ready.hasMatch(l)) up.complete();
    }

    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(line);
    p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(line);
    unawaited(p.exitCode.then((c) {
      if (!up.isCompleted) up.completeError(StateError('server exited ($c): ${out.join('\n')}'));
    }));
    await up.future.timeout(const Duration(seconds: 30));
    return _Node(p, port);
  }

  Uri url(String path) => Uri.parse('http://127.0.0.1:$port$path');

  Future<void> stop() async {
    process.kill();
    await process.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return -1;
    });
  }
}

void main() {
  // flutter_test answers every dart:io HTTP request with 400; these tests
  // talk to real local servers.
  setUpAll(() => HttpOverrides.global = null);

  Future<void> addReviewAndCall(Uri url, {required McpEra era, required String tool, required JsonMap args, required String want}) async {
    final client = http.Client();
    addTearDown(client.close);
    final check = await McpUrlValidator().check(url.toString());
    expect(check.isValid, isTrue, reason: check.error);
    expect(check.local, isTrue, reason: 'a loopback http server is a "server on my network"');
    final report = await ConnectingMcpProber(client: client).probe(
      McpServerConfig(id: 'probe', name: 'probe', url: check.url!, allowLocalNetwork: true),
    );
    expect(report.error, isNull);
    expect(report.era, era);
    expect(report.toolCount, greaterThan(0));

    final rt = await McpRuntime.create(
      records: InMemoryMcpRecords(),
      secrets: InMemorySecretStore(),
      httpClient: client,
      browser: FakeBrowser(),
      deviceFacts: fakeDevice,
      notes: InMemoryNoteStorage(),
      canInteract: () => true,
    );
    addTearDown(rt.dispose);
    final c = await rt.addServer(url: check.url!, name: 'Reference', allowLocalNetwork: true, verdict: report.verdict);
    await rt.refresh();
    expect(rt.manager.health(c.id).status, McpServerStatus.connected);
    expect(rt.manager.health(c.id).era, era);
    final entry = rt.toolsOf(c.id).firstWhere((e) => e.tool.name == tool);
    expect(entry.quarantined, isTrue, reason: 'an untrusted server waits for review');
    expect(await rt.approveTool(entry.key), isTrue);
    final r = await rt.router.execute(ToolCall(id: 'c1', name: entry.modelName, arguments: args), toolCtx('s'));
    expect(r.isError, isFalse);
    expect((r.content.single as TextPart).text, contains(want));
    expect(rt.manager.logs(c.id).map((l) => l.message).join('\n'), contains('connected'));
  }

  /// A runtime with [url] added, its [tools] approved (and sampling asked
  /// for when [sampling]).
  Future<(McpRuntime, String)> runtimeWith(Uri url, List<String> tools, {bool sampling = false}) async {
    final client = http.Client();
    addTearDown(client.close);
    final rt = await McpRuntime.create(
      records: InMemoryMcpRecords(),
      secrets: InMemorySecretStore(),
      httpClient: client,
      browser: FakeBrowser(),
      deviceFacts: fakeDevice,
      notes: InMemoryNoteStorage(),
      canInteract: () => true,
    );
    addTearDown(rt.dispose);
    final c = await rt.addServer(url: url, name: 'Reference', allowLocalNetwork: true);
    if (sampling) await rt.updateHostSettings(c.id, const McpServerHostSettings(sampling: McpSamplingMode.ask));
    await rt.refresh();
    for (final t in tools) {
      final entry = rt.toolsOf(c.id).firstWhere((e) => e.tool.name == t);
      await rt.approveTool(entry.key);
    }
    return (rt, c.id);
  }

  Future<McpPendingInput> nextInput(McpRuntime rt) async {
    await eventually(() => rt.inputQueue.pending.isNotEmpty, timeout: const Duration(seconds: 20));
    return rt.inputQueue.pending.first;
  }

  test(
    "server-everything's elicitation form (2025-11-25 server → client request) through Sherpa's input queue",
    skip: _skip('everything/node_modules/@modelcontextprotocol/server-everything/dist/index.js'),
    () async {
      final srv = await _Node.start(
        '$_root/everything',
        'node_modules/@modelcontextprotocol/server-everything/dist/index.js',
        ['streamableHttp'],
        RegExp('listening on port'),
      );
      addTearDown(srv.stop);
      final (rt, id) = await runtimeWith(srv.url('/mcp'), ['trigger-elicitation-request']);
      final name = rt.toolsOf(id).firstWhere((e) => e.tool.name == 'trigger-elicitation-request').modelName;
      final call = rt.router.execute(ToolCall(id: 'c1', name: name, arguments: const {}), toolCtx('chat-real'));
      final p = await nextInput(rt) as PendingFormElicitation;
      expect(p.context.era, McpEra.legacy);
      expect(p.sessionId, 'chat-real', reason: "the legacy request inherits the call's origin");
      // Every field of the reference schema is one Sherpa renders.
      expect(p.form.unsupported, isEmpty);
      expect(p.form.asksForSecret, isFalse);
      expect({for (final f in p.form.fields) f.kind}, containsAll(ElicitationFieldKind.values));
      final values = {...p.form.initialValues(), 'name': 'Ada Lovelace', 'check': true};
      expect(p.accept(values), isTrue);
      final r = await call;
      final text = r.content.whereType<TextPart>().map((t) => t.text).join('\n');
      expect(text, contains('Name: Ada Lovelace'));
      expect(text, contains('Favorite Integer: 42'), reason: 'defaults were pre-filled');
      expect(rt.inputRecords(id).single.outcome, McpInputOutcome.accepted);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'the 2026-07-28 test server: MRTR elicitation and sampling through the input queue',
    skip: _skip('modern/node_modules/@modelcontextprotocol/server/package.json'),
    () async {
      final target = File('$_root/modern/modern_server.mjs');
      File('../packages/sherpa_mcp/test/integration/servers/modern_server.mjs').copySync(target.path);
      final srv = await _Node.start('$_root/modern', 'modern_server.mjs', const [], RegExp(r'^listening \d+'), env: {'LEGACY': 'reject'});
      addTearDown(srv.stop);
      final (rt, id) = await runtimeWith(srv.url('/mcp'), ['confirm', 'ask-model'], sampling: true);
      String model(String wire) => rt.toolsOf(id).firstWhere((e) => e.tool.name == wire).modelName;

      final confirm = rt.router.execute(ToolCall(id: 'c1', name: model('confirm'), arguments: const {'action': 'deploy'}), toolCtx('s'));
      final form = await nextInput(rt) as PendingFormElicitation;
      expect(form.context.era, McpEra.modern);
      expect(form.request.message, 'Really deploy?');
      form.accept({'confirm': true});
      expect((await confirm).content.whereType<TextPart>().single.text, contains('confirmed deploy'));

      final ask = rt.router.execute(ToolCall(id: 'c2', name: model('ask-model'), arguments: const {'question': 'Capital of France?'}), toolCtx('s'));
      final sampling = await nextInput(rt) as PendingSampling;
      expect(sampling.stage, SamplingStage.approval, reason: 'ask: the user approves first');
      expect(sampling.limits.maxTokens, 64);
      sampling.approve();
      sampling.setDraft(const SamplingDraft(text: 'Paris', model: 'sherpa-test', modelLabel: 'Test'));
      sampling.send();
      expect((await ask).content.whereType<TextPart>().single.text, 'model sherpa-test said: Paris');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'server-everything (Streamable HTTP, 2025-11-25): probe, add, review, call',
    skip: _skip('everything/node_modules/@modelcontextprotocol/server-everything/dist/index.js'),
    () async {
      final srv = await _Node.start(
        '$_root/everything',
        'node_modules/@modelcontextprotocol/server-everything/dist/index.js',
        ['streamableHttp'],
        RegExp('listening on port'),
      );
      addTearDown(srv.stop);
      await addReviewAndCall(srv.url('/mcp'), era: McpEra.legacy, tool: 'echo', args: {'message': 'hi'}, want: 'hi');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'the 2026-07-28 test server (stateless): probe, add, review, call',
    skip: _skip('modern/node_modules/@modelcontextprotocol/server/package.json'),
    () async {
      final target = File('$_root/modern/modern_server.mjs');
      File('../packages/sherpa_mcp/test/integration/servers/modern_server.mjs').copySync(target.path);
      final srv = await _Node.start('$_root/modern', 'modern_server.mjs', const [], RegExp(r'^listening \d+'), env: {'LEGACY': 'reject'});
      addTearDown(srv.stop);
      await addReviewAndCall(srv.url('/mcp'), era: McpEra.modern, tool: 'echo', args: {'message': 'hi'}, want: 'Echo: hi');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
