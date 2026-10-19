import 'dart:async';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:sherpa_net/sherpa_net.dart' show Backoff;
import 'package:test/test.dart';

import '../support/fake_mcp_server.dart';
import '../support/helpers.dart' as http_helpers;
import 'harness.dart';

void main() {
  late Harness h;
  tearDown(() async => h.close());

  test('connects lazily on first use and reports health', () async {
    h = Harness()..add('a', [tool('ping', annotations: readOnly)]);
    expect(h.connects, 0);
    expect(h.manager.health('a').status, McpServerStatus.idle);
    final tools = await h.manager.listTools('a');
    expect([for (final t in tools) t.name], ['ping']);
    expect(h.connects, 1);
    final health = h.manager.health('a');
    expect(health.status, McpServerStatus.connected);
    expect(health.era, McpEra.modern);
    expect(health.latency, isNotNull);
    expect(health.serverName, 'a');
    final checked = await h.manager.checkHealth('a');
    expect(checked.isConnected, isTrue);
    expect(h.manager.logs('a').map((e) => e.message), contains(startsWith('connected (modern')));
  });

  test('reconnects with backoff after the connection is lost, then tells the router to re-list', () async {
    h = Harness()..add('a', [tool('ping', annotations: readOnly)]);
    await h.manager.listTools('a');
    final events = <McpServerEvent>[];
    final sub = h.manager.events.listen(events.add);
    await h.dropConnections('a');
    await until(() => events.whereType<McpServerStatusChanged>().any((e) => e.health.status == McpServerStatus.offline));
    await until(() => h.manager.health('a').isConnected);
    expect(h.connects, 2);
    await until(() => events.whereType<McpServerToolsChanged>().any((e) => e.reason == 'reconnected'));
    expect(h.manager.health('a').reconnectAttempts, 0, reason: 'reset after success');
    expect(h.manager.logs('a').map((e) => e.message), contains(startsWith('connection lost')));
    await sub.cancel();
  });

  test('offline fail-fast: while a reconnect is pending, calls fail at once with a model-facing message', () async {
    h = Harness(backoff: Backoff(base: const Duration(seconds: 30), max: const Duration(seconds: 30)))
      ..add('a', [tool('ping')], name: 'Alpha');
    h.down.add('a');
    final first = h.manager.callTool('a', 'ping');
    await expectLater(first, throwsA(isA<McpServerUnavailableException>()
        .having((e) => e.status, 'status', McpServerStatus.offline)
        .having((e) => e.modelMessage, 'modelMessage', contains('"Alpha" tool server is offline'))));
    expect(h.connects, 1);
    final health = h.manager.health('a');
    expect(health.status, McpServerStatus.offline);
    expect(health.nextRetryAt, isNotNull);
    expect(health.lastError, contains('connection refused'));
    final sw = Stopwatch()..start();
    await expectLater(h.manager.callTool('a', 'ping'), throwsA(isA<McpServerUnavailableException>()));
    expect(h.connects, 1, reason: 'no new attempt while the backoff timer runs');
    expect(sw.elapsedMilliseconds, lessThan(200));
    // The UI's retry button / network-back path reconnects at once.
    h.down.clear();
    await h.manager.reconnect('a');
    expect((await h.manager.callTool('a', 'ping')).isError, isFalse);
  });

  test('gives up after maxReconnectAttempts and tries again on next use', () async {
    h = Harness(maxReconnectAttempts: 2)..add('a', [tool('ping')]);
    h.down.add('a');
    await expectLater(h.manager.listTools('a'), throwsA(isA<McpServerUnavailableException>()));
    await until(() => h.connects == 3); // first + 2 reconnects
    await until(() => h.manager.health('a').nextRetryAt == null);
    expect(h.manager.logs('a').map((e) => e.message), contains(startsWith('giving up')));
    h.down.clear();
    expect(await h.manager.listTools('a'), hasLength(1));
    expect(h.connects, 4);
  });

  test('a lost connection mid-call: idempotent tools are retried once after reconnect, others report unknown outcome',
      () async {
    h = Harness(backoff: Backoff(base: const Duration(seconds: 30), max: const Duration(seconds: 30)));
    var runs = 0;
    Future<DartToolResult> drop(JsonMap args, DartToolContext ctx) async {
      runs++;
      if (runs == 1) {
        unawaited(h.dropConnections('a'));
        await ctx.cancel.whenCancelled; // never answers on this session
      }
      return DartToolResult.text('ran $runs');
    }

    h.add('a', [tool('read', handler: drop), tool('write', handler: drop)]);
    final r = await h.manager.callTool('a', 'read', retryOnReconnect: true, idempotencyKey: 's:c1');
    expect((r.content.single as McpTextContent).text, 'ran 2');
    expect(h.connects, 2);

    runs = 0;
    await expectLater(
      h.manager.callTool('a', 'write'),
      throwsA(isA<McpCallInterruptedException>()
          .having((e) => e.modelMessage, 'modelMessage', contains('unknown whether it took effect'))),
    );
    expect(runs, 1, reason: 'never re-sent');
  });

  test('a stopped run does not wait for a slow lazy connect', () async {
    h = Harness()..add('a', [tool('ping')]);
    h.slow['a'] = const Duration(seconds: 2);
    final token = CancellationToken();
    final sw = Stopwatch()..start();
    final call = h.manager.callTool('a', 'ping', cancel: token);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    token.cancel('stopped');
    await expectLater(call, throwsA(isA<CancelledException>()));
    expect(sw.elapsedMilliseconds, lessThan(1000));
  });

  test('needsAuth: no reconnect loop, the app is told, calls fail fast until reconnect()', () async {
    h = Harness()..add('a', [tool('ping')], name: 'Alpha');
    h.needAuth.add('a');
    await expectLater(h.manager.connection('a'),
        throwsA(isA<McpServerUnavailableException>().having((e) => e.status, 'status', McpServerStatus.needsAuth)));
    expect(h.authRequired, ['a']);
    expect(h.manager.health('a').status, McpServerStatus.needsAuth);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(h.connects, 1, reason: 'auth failures are not retried automatically');
    await expectLater(
        h.manager.callTool('a', 'ping'),
        throwsA(isA<McpServerUnavailableException>()
            .having((e) => e.modelMessage, 'modelMessage', contains('needs the user to sign in again'))));
    h.needAuth.clear();
    await h.manager.reconnect('a');
    expect(h.manager.health('a').isConnected, isTrue);
  });

  test('non-transient failure (no in-process server registered) is an error, not a retry loop', () async {
    h = Harness();
    h.manager.addServer(McpServerConfig(
      id: 'ghost',
      name: 'Ghost',
      url: Uri.parse('sherpa-inprocess://ghost'),
      transport: McpTransportPreference.inProcess,
    ));
    await expectLater(h.manager.listTools('ghost'), throwsA(isA<McpServerUnavailableException>()));
    expect(h.manager.health('ghost').status, McpServerStatus.error);
    expect(h.manager.health('ghost').nextRetryAt, isNull);
  });

  test('enable/disable closes the connection and fails fast; trust changes go to the callback', () async {
    h = Harness()..add('a', [tool('ping')], trusted: false);
    await h.manager.listTools('a');
    final conn = h.manager.connectedOrNull('a')!;
    await h.manager.setEnabled('a', false);
    expect(conn.isClosed, isTrue);
    expect(h.manager.health('a').status, McpServerStatus.disabled);
    expect(h.configChanges.last.enabled, isFalse);
    await expectLater(h.manager.callTool('a', 'ping'),
        throwsA(isA<McpServerUnavailableException>().having((e) => e.status, 'status', McpServerStatus.disabled)));
    await h.manager.setEnabled('a', true);
    expect(h.manager.health('a').status, McpServerStatus.idle);
    expect(await h.manager.listTools('a'), hasLength(1));

    h.manager.setTrusted('a', true);
    expect(h.trustChanges, ['a=true']);
    expect(h.manager.config('a')!.trusted, isTrue);
    expect(h.manager.trustedServerIds, {'a'});
    h.manager.setTrusted('a', false);
    expect(h.trustChanges, ['a=true', 'a=false']);
  });

  test('network unavailable: remote servers fail fast without dialling; in-process ones keep working', () async {
    h = Harness()..add('local', [tool('ping')]);
    h.manager.addServer(McpServerConfig(id: 'remote', name: 'Remote', url: Uri.parse('https://remote.example/mcp')));
    h.manager.setNetworkAvailable(false);
    await expectLater(h.manager.connection('remote'),
        throwsA(isA<McpServerUnavailableException>().having((e) => e.reason, 'reason', 'the device is offline')));
    expect(h.connects, 0);
    expect(await h.manager.listTools('local'), hasLength(1));
  });

  test('server logs land in a redacted ring buffer (debug console)', () async {
    h = Harness(
      options: const McpClientOptions(
        logLevel: McpLogLevel.debug,
        timeouts: McpTimeouts(inProcessProbe: Duration(milliseconds: 500)),
      ),
      logCapacity: 8,
    );
    h.add('a', [
      tool('noisy', handler: (args, ctx) async {
        ctx.log(McpLogLevel.info, {'token': 'abc123', 'msg': 'auth with Bearer abcdefghijklmnop'}, logger: 'auth');
        for (var i = 0; i < 10; i++) {
          ctx.log(McpLogLevel.debug, 'line $i');
        }
        return DartToolResult.text('ok');
      }),
    ]);
    await h.manager.callTool('a', 'noisy');
    final first = (await h.manager.callTool('a', 'noisy')).content;
    expect(first, isNotEmpty);
    await until(() => h.manager.logs('a').any((e) => e.message == 'line 9'));
    final logs = h.manager.logs('a');
    expect(logs.length, 8);
    h.manager.clearLogs('a');
    h.manager.addServer(McpServerConfig(
      id: 'b',
      name: 'B',
      url: Uri.parse('sherpa-inprocess://b'),
      transport: McpTransportPreference.inProcess,
    ));
    h.servers['b'] = DartMcpServer(info: const McpImplementation(name: 'b', version: '1'), tools: [
      tool('secret', handler: (args, ctx) async {
        ctx.log(McpLogLevel.info, {'token': 'abc123', 'msg': 'auth with Bearer abcdefghijklmnop'}, logger: 'auth');
        return DartToolResult.text('ok');
      }),
    ]);
    await h.manager.callTool('b', 'secret');
    await until(() => h.manager.logs('b').any((e) => e.source == McpLogSource.server));
    final line = h.manager.logs('b').firstWhere((e) => e.source == McpLogSource.server);
    expect(line.level, 'info');
    expect(line.message, startsWith('[auth] '));
    expect(line.message, isNot(contains('abc123')));
    expect(line.message, isNot(contains('abcdefghijklmnop')));
  });

  test('listen() / stopListening() follow the app lifecycle; list_changed reaches the event stream', () async {
    h = Harness()..add('a', [tool('one')]);
    await h.manager.listTools('a');
    final events = <McpServerEvent>[];
    final sub = h.manager.events.listen(events.add);
    await h.manager.listen();
    expect(h.manager.connectedOrNull('a')!.isListening, isTrue);
    await until(() => events.whereType<McpServerToolsChanged>().any((e) => e.reason == 'resumed'));
    h.servers['a']!.setTools([tool('one'), tool('two')]);
    await until(() => events.whereType<McpServerToolsChanged>().any((e) => e.reason == 'list_changed'));
    await h.manager.stopListening();
    expect(h.manager.connectedOrNull('a')!.isListening, isFalse);
    await sub.cancel();
  });

  test('dispose closes connections and makes the manager unusable', () async {
    h = Harness()..add('a', [tool('one')]);
    await h.manager.listTools('a');
    final c = h.manager.connectedOrNull('a')!;
    await h.manager.dispose();
    expect(c.isClosed, isTrue);
    expect(() => h.manager.connection('a'), throwsStateError);
  });

  group('over HTTP', () {
    late FakeMcpServer server;
    late McpServerManager manager;
    setUp(() async => server = await FakeMcpServer.start());
    tearDown(() async {
      await manager.dispose();
      await server.close();
      h = Harness(); // keep the outer tearDown happy
    });

    test('persists the era verdict through the callbacks', () async {
      final verdicts = <EraVerdict>[];
      final configs = <McpServerConfig>[];
      manager = McpServerManager(
        servers: [http_helpers.serverConfig(server.url, id: 'web')],
        options: http_helpers.options(),
        onVerdictChanged: (_, v) => verdicts.add(v),
        onConfigChanged: configs.add,
      );
      final tools = await manager.listTools('web');
      expect(tools, isNotEmpty);
      expect(verdicts.single.transport, McpTransportKind.modernHttp);
      expect(configs.last.cachedVerdict, verdicts.single);
      expect(manager.config('web')!.cachedVerdict, verdicts.single);
      final health = await manager.checkHealth('web');
      expect(health.isConnected, isTrue);
      expect(health.protocolVersion, '2026-07-28');
    });
  });
}
