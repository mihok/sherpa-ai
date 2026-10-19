import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:test/test.dart';

import '../support/helpers.dart';
import '../support/in_process_server.dart';

void main() {
  final config = McpServerConfig(
    id: 'local',
    name: 'On-device tools',
    url: Uri.parse('sherpa-inprocess://local'),
    transport: McpTransportPreference.inProcess,
  );

  Future<(McpConnection, InProcessServer)> start(McpEra era, {bool silent = false, InputRequestHandler? handler}) async {
    final (client, channel) = InProcessTransport.pair();
    final server = InProcessServer(channel, era: era, silentOnDiscover: silent);
    final c = await McpConnection.connect(config, options: options(handler: handler), transport: client);
    addTearDown(() async {
      await c.close();
      await server.close();
    });
    return (c, server);
  }

  test('modern server over the in-process channel', () async {
    final (c, s) = await start(McpEra.modern, handler: ScriptedHandler(onElicit: (r, _) => const McpElicitResult.accept()));
    expect(c.era, McpEra.modern);
    expect(c.transportKind, McpTransportKind.inProcess);
    expect(c.verdict, isNull, reason: 'in-process verdicts are not persisted');
    expect([for (final t in await c.listTools()) t.name], ['slow', 'ask']);
    final r = await c.callTool('ask');
    expect((r.content.single as McpTextContent).text, 'accept s1');
    expect(s.methods.where((m) => m == 'initialize'), isEmpty);
  });

  test('modern stdio-style cancellation sends notifications/cancelled', () async {
    final (c, s) = await start(McpEra.modern);
    final token = CancellationToken();
    final call = c.callTool('slow', cancel: token);
    await eventually(() => s.methods.contains('tools/call'));
    token.cancel();
    await expectLater(call, throwsA(isA<CancelledException>()));
    await eventually(() => s.cancelled.isNotEmpty);
    expect(s.cancelled.single, s.received.lastWhere((m) => m['method'] == 'tools/call')['id']);
  });

  test('listen on stdio: subscriptionId demux, server-side teardown, re-listen', () async {
    final (c, s) = await start(McpEra.modern);
    final events = <McpChange>[];
    final sub = c.changes.listen(events.add);
    final ack = await c.listen();
    expect(ack.toolsListChanged, isTrue);
    s.notifyToolsChanged();
    await eventually(() => events.whereType<McpToolsListChanged>().isNotEmpty);
    final firstListen = s.listenId;
    s.endListen();
    await eventually(() => s.listenId != firstListen, timeout: const Duration(seconds: 10));
    await c.stopListening();
    await eventually(() => s.cancelled.contains(s.listenId));
    await sub.cancel();
  });

  test('legacy server answering the probe with an error → initialize on the same channel', () async {
    final handler = ScriptedHandler(onElicit: (r, _) => const McpElicitResult.decline());
    final (c, s) = await start(McpEra.legacy, handler: handler);
    expect(c.era, McpEra.legacy);
    expect(c.protocolVersion, '2025-06-18');
    expect(s.methods.take(3), ['server/discover', 'initialize', 'notifications/initialized']);
    final r = await c.callTool('ask');
    expect((r.content.single as McpTextContent).text, 'decline');
    expect(handler.elicitations, hasLength(1));
  });

  test('a silent legacy server: probe timeout means legacy (stdio rule)', () async {
    final (c, s) = await start(McpEra.legacy, silent: true);
    expect(c.era, McpEra.legacy);
    expect(c.probeLog.first, contains('no answer'));
  });

  test('legacy stdio-style cancellation sends notifications/cancelled too', () async {
    final (c, s) = await start(McpEra.legacy);
    final token = CancellationToken();
    final call = c.callTool('slow', cancel: token);
    await eventually(() => s.methods.contains('tools/call'));
    token.cancel();
    await expectLater(call, throwsA(isA<CancelledException>()));
    await eventually(() => s.cancelled.isNotEmpty);
  });

  test('closing the server channel surfaces McpConnectionLost', () async {
    final (c, s) = await start(McpEra.modern);
    final events = <McpChange>[];
    final sub = c.changes.listen(events.add);
    await s.close();
    await eventually(() => events.whereType<McpConnectionLost>().isNotEmpty);
    await sub.cancel();
  });
}
