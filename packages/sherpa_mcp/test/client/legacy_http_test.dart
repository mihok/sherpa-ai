import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:test/test.dart';

import '../support/fake_mcp_server.dart';
import '../support/helpers.dart';

void main() {
  late FakeMcpServer server;
  McpConnection? conn;

  setUp(() async {
    server = await FakeMcpServer.start();
    // A TS-v1-style legacy server: the modern probe gets 400 -32000.
    server.modern = false;
  });
  tearDown(() async {
    await conn?.close();
    conn = null;
    await server.close();
  });

  Future<McpConnection> connect({
    InputRequestHandler? handler,
    McpClientCapabilities caps = const McpClientCapabilities(),
    McpLogLevel? logLevel,
  }) async =>
      conn = await McpConnection.connect(
        serverConfig(server.url),
        options: options(handler: handler, capabilities: caps, logLevel: logLevel),
      );

  group('handshake', () {
    test('falls back to initialize, echoes the session id and negotiated version', () async {
      final c = await connect(handler: ScriptedHandler());
      expect(c.era, McpEra.legacy);
      expect(c.transportKind, McpTransportKind.legacyStreamableHttp);
      expect(c.protocolVersion, '2025-11-25');
      expect(c.serverInfo?.name, 'fake-legacy');
      expect(c.instructions, 'legacy instructions');
      expect(c.verdict?.transport, McpTransportKind.legacyStreamableHttp);
      expect(c.probeLog.first, contains('legacy'));
      await c.listTools();
      final methods = [for (final r in server.requests) r.rpcMethod];
      expect(methods, ['server/discover', 'initialize', 'notifications/initialized', 'tools/list']);
      final init = server.rpc('initialize').single;
      expect(init.params!['protocolVersion'], '2025-11-25');
      expect(init.params!['capabilities'], {
        'elicitation': {'form': <String, Object?>{}, 'url': <String, Object?>{}},
      });
      expect(init.params!['clientInfo'], {'name': 'sherpa', 'version': '0.1.0', 'title': 'Sherpa'});
      expect(init.headers.containsKey('mcp-session-id'), isFalse);
      final list = server.rpc('tools/list').single;
      expect(list.headers['mcp-session-id'], startsWith('sess-'));
      expect(list.headers['mcp-protocol-version'], '2025-11-25');
      expect(list.headers.containsKey('mcp-method'), isFalse, reason: 'no 2026 headers on legacy traffic');
      expect(list.meta, isNull, reason: 'no per-request envelope in L');
    });

    test('accepts a counter-offer down to 2025-03-26 and refuses older ones', () async {
      server.legacyVersions = ['2025-06-18'];
      final c = await connect();
      expect(c.protocolVersion, '2025-06-18');
      await c.listTools();
      expect(server.rpc('tools/list').single.headers['mcp-protocol-version'], '2025-06-18');
      await c.close();

      server.legacyVersions = ['2024-11-05'];
      await expectLater(connect(), throwsA(isA<McpUnsupportedVersionException>()));
    });

    test('MCP Apps and sampling go into initialize; the tasks extension does not', () async {
      await connect(
        handler: ScriptedHandler(),
        caps: const McpClientCapabilities(sampling: true, mcpApps: true, tasks: true, roots: true),
      );
      final caps = server.rpc('initialize').single.params!['capabilities']! as Map;
      expect(caps['sampling'], <String, Object?>{});
      expect(caps['roots'], <String, Object?>{});
      expect(caps['extensions'], {
        'io.modelcontextprotocol/ui': {
          'mimeTypes': ['text/html;profile=mcp-app'],
        },
      });
    });

    test('an invalid Mcp-Session-Id is refused', () async {
      server.intercept = (r) async {
        if (r.rpcMethod != 'initialize') return null;
        return Response.ok(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': r.id,
            'result': {'protocolVersion': '2025-11-25', 'capabilities': <String, Object?>{}},
          }),
          headers: {'content-type': 'application/json', 'mcp-session-id': 'bad id'},
        );
      };
      await expectLater(connect(), throwsA(isA<McpProtocolException>()));
    });

    test('close() ends the session with DELETE', () async {
      final c = await connect();
      final sid = server.rpc('notifications/initialized').single.headers['mcp-session-id'];
      await c.close();
      conn = null;
      expect(server.deletedSessions, [sid]);
    });
  });

  group('server → client requests through the same InputRequestHandler', () {
    test('elicitation on the POST stream is answered by POST (202)', () async {
      server.toolImpls['echo'] = (c) async {
        final r = await c.request('elicitation/create', {
          'message': 'Name?',
          'requestedSchema': {
            'type': 'object',
            'properties': {
              'name': {'type': 'string'},
            },
          },
        });
        return {
          'content': [
            {'type': 'text', 'text': 'got ${(r! as Map)['content']}'},
          ],
        };
      };
      final handler = ScriptedHandler(onElicit: (r, ctx) => const McpElicitResult.accept({'name': 'Ada'}));
      final c = await connect(handler: handler);
      final r = await c.callTool('echo');
      expect((r.content.single as McpTextContent).text, 'got {name: Ada}');
      final ctx = handler.contexts.single;
      expect(ctx.era, McpEra.legacy);
      expect(ctx.originMethod, 'tools/call');
      expect(ctx.originName, 'echo');
      final answer = server.requests.where((x) => x.json?['result'] != null).single;
      expect(answer.headers['mcp-session-id'], isNotNull);
      expect(answer.json!['result'], {
        'action': 'accept',
        'content': {'name': 'Ada'},
      });
    });

    test('sampling: approved, declined (-1) and tools-without-capability (-32602)', () async {
      final answers = <Object?>[];
      server.toolImpls['echo'] = (c) async {
        answers
          ..add(await c.request('sampling/createMessage', {
            'messages': [
              {
                'role': 'user',
                'content': {'type': 'text', 'text': 'hi'},
              },
            ],
            'maxTokens': 10,
          }))
          ..add(await c.request('sampling/createMessage', {'messages': <Object?>[], 'maxTokens': 10}))
          ..add(await c.request('sampling/createMessage', {
            'messages': <Object?>[],
            'maxTokens': 10,
            'tools': [
              {'name': 't', 'inputSchema': {'type': 'object'}},
            ],
          }));
        return {'content': <Object?>[]};
      };
      var n = 0;
      final handler = ScriptedHandler(onSample: (r, _) {
        if (n++ == 0) return const McpSamplingResult(content: [McpTextContent('hello')], model: 'm');
        throw const InputRequestDeclined('no thanks');
      });
      await (await connect(handler: handler, caps: const McpClientCapabilities(sampling: true))).callTool('echo');
      expect(answers[0], {
        'role': 'assistant',
        'content': {'type': 'text', 'text': 'hello'},
        'model': 'm',
      });
      expect((answers[1]! as Map)['error'], {'code': -1, 'message': 'no thanks'});
      expect(((answers[2]! as Map)['error']! as Map)['code'], -32602);
      expect(handler.samplings, hasLength(2), reason: 'the tools request never reached the handler');
    });

    test('undeclared roots → -32601; ping → {}', () async {
      final answers = <Object?>[];
      server.toolImpls['echo'] = (c) async {
        answers
          ..add(await c.request('roots/list'))
          ..add(await c.request('ping'));
        return {'content': <Object?>[]};
      };
      await (await connect(handler: ScriptedHandler())).callTool('echo');
      expect(((answers[0]! as Map)['error']! as Map)['code'], -32601);
      expect(answers[1], <String, Object?>{});
    });

    test('roots when enabled: only file:// URIs are returned', () async {
      Object? answer;
      server.toolImpls['echo'] = (c) async {
        answer = await c.request('roots/list');
        return {'content': <Object?>[]};
      };
      final handler = ScriptedHandler(onRoots: (_) => [
            McpRoot(uri: Uri.parse('file:///project'), name: 'project'),
            McpRoot(uri: Uri.parse('https://x.test')),
          ]);
      await (await connect(handler: handler, caps: const McpClientCapabilities(roots: true))).callTool('echo');
      expect(answer, {
        'roots': [
          {'uri': 'file:///project', 'name': 'project'},
        ],
      });
    });

    test('-32042 URL elicitation: present, await completion, retry', () async {
      var calls = 0;
      server.toolImpls['echo'] = (c) {
        if (calls++ == 0) {
          rpcFault(-32042, 'URL elicitation required', {
            'elicitations': [
              {'mode': 'url', 'elicitationId': 'el-1', 'message': 'Authorize', 'url': 'https://auth.test/start'},
            ],
          });
        }
        return {
          'content': [
            {'type': 'text', 'text': 'authorized'},
          ],
        };
      };
      final handler = ScriptedHandler(onElicit: (r, _) {
        // The user finishes in the browser; the server announces it.
        Timer(const Duration(milliseconds: 50),
            () => server.pushLegacy('notifications/elicitation/complete', {'elicitationId': 'el-1'}));
        return const McpElicitResult.accept();
      });
      final c = await connect(handler: handler);
      await c.listen();
      final r = await c.callTool('echo');
      expect((r.content.single as McpTextContent).text, 'authorized');
      expect(handler.elicitations.single.elicitationId, 'el-1');
      expect(server.rpc('tools/call'), hasLength(2));
    });
  });

  group('sessions and streams', () {
    test('404 on an expired session → re-initialize without the old id and resend once', () async {
      final c = await connect();
      await c.listTools();
      final firstSid = server.rpc('tools/list').single.headers['mcp-session-id'];
      server.expireSessions();
      final events = <McpChange>[];
      final sub = c.changes.listen(events.add);
      final r = await c.callTool('echo', arguments: {'text': 'again'});
      await sub.cancel();
      expect((r.content.single as McpTextContent).text, 'again');
      final inits = server.rpc('initialize');
      expect(inits, hasLength(2));
      expect(inits.last.headers.containsKey('mcp-session-id'), isFalse);
      final secondSid = server.rpc('tools/call').last.headers['mcp-session-id'];
      expect(secondSid, isNot(firstSid));
      expect(events.whereType<McpDiagnostic>().any((d) => d.message.contains('re-initialized')), isTrue);
    });

    test('GET stream delivers list_changed; lists are cached until it fires', () async {
      final c = await connect();
      final events = <McpChange>[];
      final sub = c.changes.listen(events.add);
      await c.listTools();
      await c.listTools();
      expect(server.rpc('tools/list'), hasLength(2), reason: 'no feed: legacy lists are not cached');
      final ack = await c.listen();
      expect(ack.toolsListChanged, isTrue);
      final get = server.requests.where((r) => r.method == 'GET').single;
      expect(get.headers['accept'], 'text/event-stream');
      expect(get.headers['mcp-session-id'], isNotNull);
      await c.listTools();
      await c.listTools();
      expect(server.rpc('tools/list'), hasLength(3), reason: 'cached while list_changed can arrive');
      server.pushLegacy('notifications/tools/list_changed');
      await eventually(() => events.whereType<McpToolsListChanged>().isNotEmpty);
      await c.listTools();
      expect(server.rpc('tools/list'), hasLength(4));
      await sub.cancel();
    });

    test('a 405 GET means no change feed', () async {
      server.legacyGetStream = false;
      final c = await connect();
      final ack = await c.listen();
      expect(ack.toolsListChanged, isFalse);
      expect(c.isListening, isFalse);
    });

    test('resources/subscribe, updates over the GET stream, unsubscribe', () async {
      final c = await connect();
      final events = <McpChange>[];
      final sub = c.changes.listen(events.add);
      final s = await c.subscribeResource('file:///a.txt');
      expect(server.legacySubscribed, {'file:///a.txt'});
      expect(c.isListening, isTrue);
      server.pushLegacy('notifications/resources/updated', {'uri': 'file:///a.txt'});
      await eventually(() => events.whereType<McpResourceUpdated>().isNotEmpty);
      await s.cancel();
      expect(server.legacySubscribed, isEmpty);
      await sub.cancel();
    });

    test('logging/setLevel and log notifications on the request stream', () async {
      server.toolImpls['echo'] = (c) {
        c.log('warning', {'msg': 'careful'});
        return {'content': <Object?>[]};
      };
      final c = await connect(logLevel: McpLogLevel.warning);
      expect(server.legacyLogLevels, ['warning']);
      final logs = <McpLogMessage>[];
      final sub = c.logs.listen(logs.add);
      await c.callTool('echo');
      await eventually(() => logs.isNotEmpty);
      await sub.cancel();
      expect(logs.single.level, McpLogLevel.warning);
      expect(logs.single.data, {'msg': 'careful'});
      await c.setLogLevel(null);
      expect(server.legacyLogLevels.last, 'emergency');
    });

    test('cancel POSTs notifications/cancelled with the request id', () async {
      final started = Completer<void>();
      server.toolImpls['echo'] = (c) {
        started.complete();
        hang();
      };
      final c = await connect();
      final token = CancellationToken();
      final call = c.callTool('echo', cancel: token);
      await started.future;
      token.cancel('stop');
      await expectLater(call, throwsA(isA<CancelledException>()));
      await eventually(() => server.rpc('notifications/cancelled').isNotEmpty);
      final n = server.rpc('notifications/cancelled').single;
      expect(n.params!['requestId'], server.rpc('tools/call').single.id);
      expect(n.params!['reason'], 'stop');
    });

    test('a dropped POST stream is resumed with GET + Last-Event-ID after retry', () async {
      server.dropPostStreamsAfterPriming = true;
      final c = await connect();
      final r = await c.callTool('echo', arguments: {'text': 'resumed'});
      expect((r.content.single as McpTextContent).text, 'resumed');
      final resume = server.requests.where((x) => x.method == 'GET').single;
      expect(resume.headers['last-event-id'], endsWith('-0'));
      expect(resume.headers['mcp-session-id'], isNotNull);
    });

    test('legacy resource not found (-32002) maps to isResourceNotFound', () async {
      final c = await connect();
      await expectLater(
        c.readResource('file:///nope'),
        throwsA(isA<McpRpcException>().having((e) => e.isResourceNotFound, 'not found', true)),
      );
    });

    test('tasks are a modern extension', () async {
      final c = await connect();
      await expectLater(c.getTask('t'), throwsA(isA<McpProtocolException>()));
    });
  });

  group('HTTP+SSE (2024-11-05)', () {
    test('POST 404s fall back to GET + endpoint event, then initialize over SSE', () async {
      final c = conn = await McpConnection.connect(serverConfig(server.sseUrl), options: options());
      expect(c.transportKind, McpTransportKind.legacySse);
      expect(c.protocolVersion, '2024-11-05');
      expect(c.verdict?.transport, McpTransportKind.legacySse);
      final tools = await c.listTools();
      expect(tools.single.name, 'echo');
      final r = await c.callTool('echo', arguments: {'text': 'over sse'});
      expect((r.content.single as McpTextContent).text, 'over sse');
      final posts = server.requests.where((x) => x.path == '/messages').toList();
      expect([for (final p in posts) p.rpcMethod], ['initialize', 'notifications/initialized', 'tools/list', 'tools/call']);
      expect(c.probeLog.join('\n'), contains('HTTP 404'));
    });

    test('server → client requests and notifications arrive on the SSE stream', () async {
      server.toolImpls['echo'] = (c) async {
        final r = await c.request('elicitation/create', {
          'message': 'ok?',
          'requestedSchema': {'type': 'object', 'properties': <String, Object?>{}},
        });
        return {
          'content': [
            {'type': 'text', 'text': '${(r! as Map)['action']}'},
          ],
        };
      };
      final c = conn = await McpConnection.connect(serverConfig(server.sseUrl),
          options: options(handler: ScriptedHandler(onElicit: (r, _) => const McpElicitResult.cancel())));
      expect(((await c.callTool('echo')).content.single as McpTextContent).text, 'cancel');
      final events = <McpChange>[];
      final sub = c.changes.listen(events.add);
      server.pushLegacy('notifications/tools/list_changed');
      await eventually(() => events.whereType<McpToolsListChanged>().isNotEmpty);
      await server.dropSse();
      await eventually(() => events.whereType<McpConnectionLost>().isNotEmpty);
      await sub.cancel();
      await expectLater(c.listTools(refresh: true), throwsA(isA<McpConnectionClosedException>()));
    });
  });
}
