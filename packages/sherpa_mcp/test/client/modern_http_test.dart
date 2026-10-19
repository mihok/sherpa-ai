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

  setUp(() async => server = await FakeMcpServer.start());
  tearDown(() async {
    await conn?.close();
    conn = null;
    await server.close();
  });

  Future<McpConnection> connect({
    InputRequestHandler? handler,
    McpClientCapabilities caps = const McpClientCapabilities(),
    McpLogLevel? logLevel,
    McpLimits limits = const McpLimits(),
  }) async =>
      conn = await McpConnection.connect(
        serverConfig(server.url),
        options: options(handler: handler, capabilities: caps, logLevel: logLevel, limits: limits),
      );

  group('discovery and envelope', () {
    test('probes server/discover first and settles on 2026-07-28', () async {
      final c = await connect();
      expect(c.era, McpEra.modern);
      expect(c.transportKind, McpTransportKind.modernHttp);
      expect(c.protocolVersion, '2026-07-28');
      expect(c.serverInfo?.name, 'fake');
      expect(c.instructions, 'Use the echo tool.');
      expect(c.verdict?.transport, McpTransportKind.modernHttp);
      expect(c.verdictChanged, isTrue);
      expect(server.requests.first.rpcMethod, 'server/discover');
      expect(server.rpc('initialize'), isEmpty);
    });

    test('every POST carries the required headers and _meta envelope', () async {
      final c = await connect(handler: ScriptedHandler());
      await c.listTools();
      for (final r in server.requests) {
        expect(r.method, 'POST');
        expect(r.headers['accept'], 'application/json, text/event-stream');
        expect(r.headers['content-type'], 'application/json');
        expect(r.headers['mcp-protocol-version'], '2026-07-28');
        expect(r.headers['mcp-method'], r.rpcMethod);
        expect(r.headers.containsKey('mcp-session-id'), isFalse);
        final meta = r.meta!;
        expect(meta[McpMetaKeys.protocolVersion], '2026-07-28');
        expect(meta[McpMetaKeys.clientInfo], {'name': 'sherpa', 'version': '0.1.0', 'title': 'Sherpa'});
        // Elicitation (both modes) only; no sampling, no roots by default.
        expect(meta[McpMetaKeys.clientCapabilities], {
          'elicitation': {'form': <String, Object?>{}, 'url': <String, Object?>{}},
        });
        expect(meta.containsKey(McpMetaKeys.logLevel), isFalse);
      }
    });

    test('declares MCP Apps, sampling (+tools) and tasks only when enabled', () async {
      final c = await connect(
        handler: ScriptedHandler(),
        caps: const McpClientCapabilities(sampling: true, samplingTools: true, mcpApps: true, tasks: true),
      );
      await c.listTools();
      final caps = server.rpc('tools/list').single.meta![McpMetaKeys.clientCapabilities]! as Map;
      expect(caps['sampling'], {'tools': <String, Object?>{}});
      expect(caps.containsKey('roots'), isFalse);
      expect(caps['extensions'], {
        'io.modelcontextprotocol/ui': {
          'mimeTypes': ['text/html;profile=mcp-app'],
        },
        'io.modelcontextprotocol/tasks': <String, Object?>{},
      });
    });

    test('without an input handler no input capability is declared', () async {
      await (await connect()).listTools();
      expect(server.rpc('tools/list').single.meta![McpMetaKeys.clientCapabilities], <String, Object?>{});
    });

    test('discover() refreshes per ttlMs', () async {
      server.ttlMs = 0;
      final c = await connect();
      await c.discover();
      expect(server.rpc('server/discover'), hasLength(2));
    });
  });

  group('tools', () {
    test('lists every page, caches by ttlMs and refreshes on demand', () async {
      server
        ..pageSize = 1
        ..tools = [
          for (final n in ['a', 'b', 'c'])
            {
              'name': n,
              'inputSchema': {'type': 'object'},
            },
        ];
      final c = await connect();
      final tools = await c.listTools();
      expect([for (final t in tools) t.name], ['a', 'b', 'c']);
      expect([for (final r in server.rpc('tools/list')) r.params!['cursor']], [null, '1', '2']);
      await c.listTools();
      expect(server.rpc('tools/list'), hasLength(3), reason: 'served from cache');
      await c.listTools(refresh: true);
      expect(server.rpc('tools/list'), hasLength(6));
    });

    test('ttlMs 0 means always re-fetch', () async {
      server.ttlMs = 0;
      final c = await connect();
      await c.listTools();
      await c.listTools();
      expect(server.rpc('tools/list'), hasLength(2));
    });

    test('an invalid cursor restarts pagination once', () async {
      server
        ..pageSize = 1
        ..tools = [
          for (final n in ['a', 'b'])
            {
              'name': n,
              'inputSchema': {'type': 'object'},
            },
        ];
      var failed = false;
      server.intercept = (r) {
        if (r.rpcMethod == 'tools/list' && r.params?['cursor'] == '1' && !failed) {
          failed = true;
          return Response.ok(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': r.id,
              'error': {'code': -32602, 'message': 'invalid cursor'},
            }),
            headers: {'content-type': 'application/json'},
          );
        }
        return null;
      };
      final tools = await (await connect()).listTools();
      expect([for (final t in tools) t.name], ['a', 'b']);
      expect(server.rpc('tools/list'), hasLength(4));
    });

    test('exposes annotations, outputSchema, icons and MCP Apps metadata', () async {
      server.tools = [
        {
          'name': 'chart',
          'title': 'Chart',
          'inputSchema': {'type': 'object', 'additionalProperties': false},
          'outputSchema': {'type': 'array'},
          'annotations': {'readOnlyHint': true, 'openWorldHint': false, 'destructiveHint': 'yes'},
          'icons': [
            {'src': 'https://x.test/i.png', 'mimeType': 'image/png', 'sizes': ['48x48']},
            {'src': 'javascript:alert(1)'},
          ],
          '_meta': {
            'ui': {
              'resourceUri': 'ui://charts/main',
              'visibility': ['app'],
            },
          },
        },
        {
          'name': 'legacyui',
          'inputSchema': {'type': 'object'},
          '_meta': {'ui/resourceUri': 'ui://old'},
        },
        {
          'name': 'badui',
          'inputSchema': {'type': 'object'},
          '_meta': {
            'ui': {'resourceUri': 'https://evil.test'},
          },
        },
      ];
      final tools = await (await connect()).listTools();
      final chart = tools.first;
      expect(chart.displayName, 'Chart');
      expect(chart.annotations.isReadOnly, isTrue);
      expect(chart.annotations.isOpenWorld, isFalse);
      expect(chart.annotations.destructiveHint, isNull, reason: 'wrong-typed hint dropped');
      expect(chart.outputSchema, {'type': 'array'});
      expect([for (final i in chart.icons) i.isAllowedScheme], [true, false]);
      expect(chart.uiResourceUri, 'ui://charts/main');
      expect(chart.modelVisible, isFalse);
      expect(chart.appCallable, isTrue);
      expect(tools[1].uiResourceUri, 'ui://old');
      expect(tools[2].uiResourceUri, isNull);
      expect(chart.raw['annotations'], containsPair('destructiveHint', 'yes'), reason: 'raw kept for hash pinning');
      final def = chart.toDefinition(modelName: 'srv__chart', serverId: 'srv');
      expect(def.wireName, 'chart');
      expect(def.modelVisible, isFalse);
      expect(def.uiResourceUri, 'ui://charts/main');
    });

    test('drops tools with invalid x-mcp-header, malformed schemas and duplicates', () async {
      server.tools = [
        {
          'name': 'ok',
          'inputSchema': {'type': 'object'},
        },
        {
          'name': 'bad-header',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'n': {'type': 'number', 'x-mcp-header': 'N'},
            },
          },
        },
        {'name': 'no-schema'},
        {
          'name': 'array-root',
          'inputSchema': {'type': 'array'},
        },
        {
          'name': 'ok',
          'inputSchema': {'type': 'object'},
        },
      ];
      final c = await connect();
      final diags = <McpDiagnostic>[];
      final sub = c.changes.listen((e) {
        if (e is McpDiagnostic) diags.add(e);
      });
      final tools = await c.listTools();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect([for (final t in tools) t.name], ['ok']);
      expect([for (final r in c.rejectedTools) r.name], ['bad-header', 'no-schema', 'array-root', 'ok']);
      expect(c.rejectedTools.first.reason, contains('integer or boolean'));
      expect(diags, hasLength(4));
      await c.listTools(); // cache hit
      expect(c.rejectedTools, hasLength(4), reason: 'a cache hit keeps the last fetch\'s rejections');
      await expectLater(c.callTool('bad-header'), throwsA(isA<McpProtocolException>()));
    });

    test('callTool mirrors Mcp-Name and Mcp-Param-* exactly (strict server accepts)', () async {
      server.tools = [
        {
          'name': 'weather',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'region': {'type': 'string', 'x-mcp-header': 'Region'},
              'greeting': {'type': 'string', 'x-mcp-header': 'Greeting'},
              'days': {'type': 'integer', 'x-mcp-header': 'Days'},
            },
          },
        },
      ];
      server.toolImpls['weather'] = (c) => {
            'content': [
              {'type': 'text', 'text': 'sunny in ${c.arguments['region']}'},
            ],
            'structuredContent': {'temp': 21},
          };
      final c = await connect();
      final r = await c.callTool('weather', arguments: {'region': 'us-west1', 'greeting': 'Hello, 世界', 'days': 3.0});
      expect((r.content.single as McpTextContent).text, 'sunny in us-west1');
      expect(r.structuredContent, {'temp': 21});
      expect(r.isError, isFalse);
      final call = server.rpc('tools/call').single;
      expect(call.headers['mcp-name'], 'weather');
      expect(call.headers['mcp-param-region'], 'us-west1');
      expect(call.headers['mcp-param-greeting'], '=?base64?SGVsbG8sIOS4lueVjA==?=');
      expect(call.headers['mcp-param-days'], '3');
    });

    test('-32020 header mismatch re-fetches tools/list and retries once', () async {
      server.tools = [
        {
          'name': 'weather',
          'inputSchema': {'type': 'object'},
        },
      ];
      server.toolImpls['weather'] = (c) => {'content': <Object?>[]};
      final c = await connect();
      await c.listTools();
      // The server's definition changes behind the client's (fresh) cache.
      server.tools = [
        {
          'name': 'weather',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'region': {'type': 'string', 'x-mcp-header': 'Region'},
            },
          },
        },
      ];
      await c.callTool('weather', arguments: {'region': 'eu'});
      final calls = server.rpc('tools/call');
      expect(calls, hasLength(2));
      expect(calls.first.headers.containsKey('mcp-param-region'), isFalse);
      expect(calls.last.headers['mcp-param-region'], 'eu');
      expect(calls.first.id, isNot(calls.last.id));
    });

    test('content blocks of every kind, isError and result _meta', () async {
      server.toolImpls['echo'] = (c) => {
            'isError': true,
            'content': [
              {'type': 'text', 'text': 't', 'annotations': {'audience': ['user'], 'priority': 0.5}},
              {'type': 'image', 'data': base64.encode([1, 2]), 'mimeType': 'image/png'},
              {'type': 'audio', 'data': 'not base64!', 'mimeType': 'audio/wav'},
              {'type': 'resource_link', 'uri': 'file:///x', 'name': 'x', 'size': 3},
              {
                'type': 'resource',
                'resource': {'uri': 'file:///y', 'text': 'why'},
              },
              {'type': 'hologram', 'beam': 1},
            ],
            '_meta': {
              'ui': {'resourceUri': 'ui://r'},
            },
          };
      final r = await (await connect()).callTool('echo', arguments: {'text': 'x'});
      expect(r.isError, isTrue);
      expect(r.uiResourceUri, 'ui://r');
      expect([for (final b in r.content) b.type], ['text', 'image', 'audio', 'resource_link', 'resource', 'hologram']);
      expect(r.content.first.annotations!.forUserOnly, isTrue);
      expect((r.content[1] as McpImageContent).bytes, [1, 2]);
      final parts = r.toToolResult().content;
      expect(parts[1], isA<ImagePart>());
      expect(parts[2], const TextPart('[audio with invalid data]'));
      expect(parts[3], isA<ResourceLinkPart>());
      expect((parts[4] as EmbeddedResourcePart).text, 'why');
      expect(parts[5], const TextPart('[unsupported content: hologram]'));
    });

    test('progress notifications reach the callback; logs only with a level', () async {
      server.toolImpls['echo'] = (c) async {
        c
          ..progress(1, total: 2, message: 'half')
          ..log('info', 'working');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        c.progress(2, total: 2);
        return {'content': <Object?>[]};
      };
      var c = await connect();
      final logs = <McpLogMessage>[];
      var sub = c.logs.listen(logs.add);
      final progress = <ToolProgress>[];
      await c.callTool('echo', onProgress: progress.add);
      expect([for (final p in progress) p.fraction], [0.5, 1.0]);
      expect(progress.first.message, 'half');
      expect(server.rpc('tools/call').single.meta!['progressToken'], isNotNull);
      expect(logs, isEmpty, reason: 'no logLevel → server must not log');
      await sub.cancel();
      await c.close();

      c = await connect(logLevel: McpLogLevel.info);
      sub = c.logs.listen(logs.add);
      await c.callTool('echo');
      await eventually(() => logs.isNotEmpty);
      await sub.cancel();
      expect(logs.single.level, McpLogLevel.info);
      expect(logs.single.data, 'working');
      expect(logs.single.requestId, isNotNull);
      expect(server.rpc('tools/call').last.meta![McpMetaKeys.logLevel], 'info');
    });

    test('meta: advisory idempotency key; reserved keys refused', () async {
      final c = await connect();
      await c.callTool('echo', arguments: {'text': 'x'}, idempotencyKey: 'run1:call1', meta: {'com.acme/trace': 't'});
      final meta = server.rpc('tools/call').single.meta!;
      expect(meta['ai.sherpa/idempotencyKey'], 'run1:call1');
      expect(meta['com.acme/trace'], 't');
      for (final k in ['io.modelcontextprotocol/protocolVersion', 'progressToken', 'ai.sherpa/idempotencyKey']) {
        expect(() => c.callTool('echo', meta: {k: 1}), throwsArgumentError, reason: k);
      }
    });

    test('an unknown resultType is invalid', () async {
      server.toolImpls['echo'] = (c) => {'resultType': 'mystery'};
      final c = await connect();
      await expectLater(c.callTool('echo'), throwsA(isA<McpProtocolException>()));
    });

    test('unknown tool → McpRpcException -32602', () async {
      final c = await connect();
      await expectLater(
          c.callTool('nope'), throwsA(isA<McpRpcException>().having((e) => e.isInvalidParams, 'invalid params', true)));
    });
  });

  group('multi round-trip requests', () {
    test('elicitation round: new id, original params, inputResponses, exact requestState echo', () async {
      const state = 'opaque+/=state with spaces';
      server.toolImpls['echo'] = (c) {
        if (c.inputResponses == null) {
          return {
            'resultType': 'input_required',
            'inputRequests': {
              'login': {
                'method': 'elicitation/create',
                'params': {
                  'mode': 'form',
                  'message': 'GitHub username?',
                  'requestedSchema': {
                    'type': 'object',
                    'properties': {
                      'name': {'type': 'string'},
                    },
                    'required': ['name'],
                  },
                },
              },
            },
            'requestState': state,
          };
        }
        expect(c.requestState, state);
        final answer = c.inputResponses!['login']! as Map;
        return {
          'content': [
            {'type': 'text', 'text': 'hi ${(answer['content']! as Map)['name']}'},
          ],
        };
      };
      final handler = ScriptedHandler(onElicit: (r, ctx) => const McpElicitResult.accept({'name': 'octocat'}));
      final c = await connect(handler: handler);
      final r = await c.callTool('echo', arguments: {'text': 'x'});
      expect((r.content.single as McpTextContent).text, 'hi octocat');
      final calls = server.rpc('tools/call');
      expect(calls, hasLength(2));
      expect(calls[0].id, isNot(calls[1].id));
      expect(calls[1].params!['arguments'], {'text': 'x'});
      expect(calls[1].params!['inputResponses'], {
        'login': {
          'action': 'accept',
          'content': {'name': 'octocat'},
        },
      });
      expect(calls[1].params!['requestState'], state);
      expect(calls[0].params!.containsKey('requestState'), isFalse);
      final ctx = handler.contexts.single;
      expect(ctx.serverId, 'srv');
      expect(ctx.era, McpEra.modern);
      expect(ctx.originMethod, 'tools/call');
      expect(ctx.originName, 'echo');
      expect(handler.elicitations.single.mode, McpElicitMode.form);
    });

    test('URL elicitation and sampling both go to the one handler', () async {
      server.toolImpls['echo'] = (c) {
        if (c.inputResponses == null) {
          return {
            'resultType': 'input_required',
            'inputRequests': {
              'auth': {
                'method': 'elicitation/create',
                'params': {'mode': 'url', 'message': 'Sign in', 'url': 'https://auth.example.com/x'},
              },
              'ask': {
                'method': 'sampling/createMessage',
                'params': {
                  'messages': [
                    {
                      'role': 'user',
                      'content': {'type': 'text', 'text': 'Capital of France?'},
                    },
                  ],
                  'maxTokens': 50,
                },
              },
            },
          };
        }
        return {
          'content': [
            {'type': 'text', 'text': jsonEncode(c.inputResponses)},
          ],
        };
      };
      final handler = ScriptedHandler(
        onElicit: (r, _) => const McpElicitResult.accept(),
        onSample: (r, _) => const McpSamplingResult(
          content: [McpTextContent('Paris.')],
          model: 'local-qwen',
          stopReason: 'endTurn',
        ),
      );
      final c = await connect(handler: handler, caps: const McpClientCapabilities(sampling: true));
      final r = await c.callTool('echo');
      final responses = jsonDecode((r.content.single as McpTextContent).text) as Map;
      expect(responses['auth'], {'action': 'accept'});
      expect(responses['ask'], {
        'role': 'assistant',
        'content': {'type': 'text', 'text': 'Paris.'},
        'model': 'local-qwen',
        'stopReason': 'endTurn',
      });
      expect(handler.elicitations.single.url, Uri.parse('https://auth.example.com/x'));
      expect(handler.samplings.single.maxTokens, 50);
    });

    test('declined sampling ends the call without a retry', () async {
      server.toolImpls['echo'] = (c) => {
            'resultType': 'input_required',
            'inputRequests': {
              'ask': {
                'method': 'sampling/createMessage',
                'params': {'messages': <Object?>[], 'maxTokens': 5},
              },
            },
          };
      final c = await connect(handler: ScriptedHandler(), caps: const McpClientCapabilities(sampling: true));
      await expectLater(c.callTool('echo'), throwsA(isA<McpInputDeclinedException>()));
      expect(server.rpc('tools/call'), hasLength(1));
    });

    test('an input request for an undeclared capability is a protocol violation', () async {
      server.toolImpls['echo'] = (c) => {
            'resultType': 'input_required',
            'inputRequests': {
              'roots': {'method': 'roots/list'},
            },
          };
      final c = await connect(handler: ScriptedHandler());
      await expectLater(c.callTool('echo'), throwsA(isA<McpProtocolException>()));
      expect(server.rpc('tools/call'), hasLength(1));
    });

    test('URL elicitation with a non-http(s) URL is refused', () async {
      server.toolImpls['echo'] = (c) => {
            'resultType': 'input_required',
            'inputRequests': {
              'x': {
                'method': 'elicitation/create',
                'params': {'mode': 'url', 'message': 'm', 'url': 'javascript:alert(1)'},
              },
            },
          };
      final handler = ScriptedHandler();
      final c = await connect(handler: handler);
      await expectLater(c.callTool('echo'), throwsA(isA<McpProtocolException>()));
      expect(handler.elicitations, isEmpty);
    });

    test('requestState-only (load shedding) retries with the echoed state', () async {
      server.toolImpls['echo'] = (c) => c.requestState == null
          ? {'resultType': 'input_required', 'requestState': 'eyJwIjo1MH0='}
          : {
              'content': [
                {'type': 'text', 'text': 'done ${c.requestState}'},
              ],
            };
      final r = await (await connect()).callTool('echo');
      expect((r.content.single as McpTextContent).text, 'done eyJwIjo1MH0=');
      expect(server.rpc('tools/call').last.params!.containsKey('inputResponses'), isFalse);
    });

    test('rounds are bounded', () async {
      server.toolImpls['echo'] = (c) => {'resultType': 'input_required', 'requestState': 'again'};
      final c = await connect(limits: const McpLimits(maxInputRounds: 3));
      await expectLater(c.callTool('echo'), throwsA(isA<McpLimitExceededException>()));
      expect(server.rpc('tools/call'), hasLength(4));
    });

    test('input_required on a non-MRTR method is invalid', () async {
      server.intercept = (r) => r.rpcMethod == 'tools/list'
          ? Response.ok(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': r.id,
                'result': {'resultType': 'input_required', 'requestState': 'x'},
              }),
              headers: {'content-type': 'application/json'})
          : null;
      final c = await connect();
      await expectLater(c.listTools(), throwsA(isA<McpProtocolException>()));
    });
  });

  group('cancellation and timeouts', () {
    test('cancel closes the response stream; no notifications/cancelled on HTTP', () async {
      final started = Completer<void>();
      server.toolImpls['echo'] = (c) {
        started.complete();
        hang();
      };
      final c = await connect();
      final token = CancellationToken();
      final call = c.callTool('echo', cancel: token);
      await started.future;
      token.cancel('user pressed stop');
      await expectLater(call, throwsA(isA<CancelledException>()));
      await eventually(() => server.toolStreamDisconnects == 1);
      expect(server.requests.where((r) => r.rpcMethod == 'notifications/cancelled'), isEmpty);
    });

    test('idle timeout cancels by closing the stream and throws McpTimeoutException', () async {
      server.toolImpls['echo'] = (c) => hang();
      final c = await connect();
      await expectLater(
        c.callTool('echo', timeout: const Duration(milliseconds: 150)),
        throwsA(isA<McpTimeoutException>()),
      );
      await eventually(() => server.toolStreamDisconnects == 1);
    });

    test('progress resets the idle timeout; the hard cap still applies', () async {
      server.toolImpls['echo'] = (c) async {
        for (var i = 1; i <= 6; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 60));
          c.progress(i);
        }
        return {'content': <Object?>[]};
      };
      final c = await connect();
      await c.callTool('echo', timeout: const Duration(milliseconds: 150), onProgress: (_) {});
      await expectLater(
        c.callTool('echo',
            timeout: const Duration(milliseconds: 150),
            maxTimeout: const Duration(milliseconds: 200),
            onProgress: (_) {}),
        throwsA(isA<McpTimeoutException>()),
      );
    });

    test('a broken stream fails tools/call (not retried) but re-issues safe requests', () async {
      var brokeList = false;
      server.intercept = (r) {
        if (r.rpcMethod == 'tools/call' || (r.rpcMethod == 'tools/list' && !brokeList)) {
          if (r.rpcMethod == 'tools/list') brokeList = true;
          return Response.ok(Stream.value(utf8.encode(': keep-alive\n\n')),
              headers: {'content-type': 'text/event-stream'}, context: {'shelf.io.buffer_output': false});
        }
        return null;
      };
      final c = await connect();
      await expectLater(c.listTools(), completes);
      expect(server.rpc('tools/list'), hasLength(2));
      final ids = {for (final r in server.rpc('tools/list')) r.id};
      expect(ids, hasLength(2), reason: 're-issued with a new id');
      await expectLater(
        c.callTool('echo'),
        throwsA(isA<McpTransportException>().having((e) => e.streamInterrupted, 'streamInterrupted', true)),
      );
      expect(server.rpc('tools/call'), hasLength(1));
    });
  });

  group('resources, prompts, completion', () {
    test('read is cached by ttlMs; not found maps to isResourceNotFound', () async {
      final c = await connect();
      expect((await c.listResources()).single.uri, 'file:///a.txt');
      final r = await c.readResource('file:///a.txt');
      expect((r.contents.single as McpTextResourceContents).text, 'hello');
      await c.readResource('file:///a.txt');
      expect(server.rpc('resources/read'), hasLength(1));
      expect(server.rpc('resources/read').single.headers['mcp-name'], 'file:///a.txt');
      await expectLater(
        c.readResource('file:///missing'),
        throwsA(isA<McpRpcException>().having((e) => e.isResourceNotFound, 'not found', true)),
      );
    });

    test('prompts and completion', () async {
      final c = await connect();
      final prompts = await c.listPrompts();
      expect(prompts.single.arguments.single.required, isTrue);
      final p = await c.getPrompt('greet', arguments: {'who': 'Ada'});
      expect((p.messages.single.content as McpTextContent).text, 'Hello Ada');
      final done = await c.complete(const McpPromptRef('greet'), argument: 'who', value: 'b');
      expect(done.values, ['bob']);
      expect(done.total, 3);
      final req = server.rpc('completion/complete').single.params!;
      expect(req['ref'], {'type': 'ref/prompt', 'name': 'greet'});
      expect(req['argument'], {'name': 'who', 'value': 'b'});
    });

    test('complete() skips the round trip without the completions capability', () async {
      server.capabilities = {'tools': <String, Object?>{}};
      final c = await connect();
      expect((await c.complete(const McpPromptRef('greet'), argument: 'who', value: 'a')).values, isEmpty);
      expect(server.rpc('completion/complete'), isEmpty);
    });
  });

  group('subscriptions/listen', () {
    test('ack, list_changed invalidates the cache, resource subscription re-filters', () async {
      final c = await connect();
      final events = <McpChange>[];
      final sub = c.changes.listen(events.add);
      final ack = await c.listen();
      expect(ack.toolsListChanged, isTrue);
      expect(ack.resourceSubscriptions, isEmpty);
      final listen = server.rpc('subscriptions/listen').single;
      expect(listen.params!['notifications'], {
        'toolsListChanged': true,
        'promptsListChanged': true,
        'resourcesListChanged': true,
      });

      await c.listTools();
      server.pushModern('notifications/tools/list_changed');
      await eventually(() => events.whereType<McpToolsListChanged>().isNotEmpty);
      await c.listTools();
      expect(server.rpc('tools/list'), hasLength(2), reason: 'cache invalidated');

      final s = await c.subscribeResource('file:///a.txt');
      await eventually(() => server.openListenStreams == 1);
      final second = server.rpc('subscriptions/listen').last;
      expect((second.params!['notifications']! as Map)['resourceSubscriptions'], ['file:///a.txt']);
      expect(second.id, isNot(listen.id));
      await c.readResource('file:///a.txt');
      server.pushModern('notifications/resources/updated', uri: 'file:///a.txt');
      await eventually(() => events.whereType<McpResourceUpdated>().isNotEmpty);
      await c.readResource('file:///a.txt');
      expect(server.rpc('resources/read'), hasLength(2), reason: 'updated invalidates the read cache');

      await s.cancel();
      await c.stopListening();
      await eventually(() => server.openListenStreams == 0);
      await sub.cancel();
      expect(events.whereType<McpListenStateChanged>().last.active, isFalse);
    });

    test('a dropped listen stream reconnects and resyncs', () async {
      final c = await connect();
      final events = <McpChange>[];
      final sub = c.changes.listen(events.add);
      await c.listen();
      await server.dropListenStreams();
      await eventually(() => events.whereType<McpToolsListChanged>().any((e) => e.resync),
          timeout: const Duration(seconds: 10));
      expect(server.rpc('subscriptions/listen'), hasLength(2));
      expect(c.isListening, isTrue);
      await sub.cancel();
    });
  });

  group('tasks extension', () {
    test('CreateTaskResult → onTaskCreated, poll tasks/get, tasks/update for input, result', () async {
      server.toolImpls['echo'] = (c) => server.createTask();
      final c = await connect(
        handler: ScriptedHandler(onElicit: (r, _) => const McpElicitResult.accept({'ok': true})),
        caps: const McpClientCapabilities(tasks: true),
      );
      McpTaskHandle? handle;
      final statuses = <McpTaskStatus>[];
      final sub = c.changes.listen((e) {
        if (e is McpTaskStatusChanged) statuses.add(e.task.status);
      });
      final future = c.callTool('echo', onTaskCreated: (h) => handle = h);
      await eventually(() => handle != null);
      final task = server.tasks[handle!.taskId]!;
      expect(McpTaskHandle.fromJson(handle!.toJson()).taskId, task.id);
      await eventually(() => task.polls >= 1);
      task
        ..status = 'input_required'
        ..inputRequests = {
          'confirm': {
            'method': 'elicitation/create',
            'params': {
              'message': 'OK?',
              'requestedSchema': {
                'type': 'object',
                'properties': {
                  'ok': {'type': 'boolean'},
                },
              },
            },
          },
        };
      await eventually(() => task.receivedInput != null);
      expect(task.receivedInput, {
        'confirm': {
          'action': 'accept',
          'content': {'ok': true},
        },
      });
      task
        ..status = 'completed'
        ..result = {
          'content': [
            {'type': 'text', 'text': 'finished'},
          ],
        };
      final r = await future;
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect((r.content.single as McpTextContent).text, 'finished');
      expect(r.taskId, task.id);
      expect(statuses, containsAllInOrder([McpTaskStatus.working, McpTaskStatus.inputRequired, McpTaskStatus.completed]));
      expect(server.rpc('tasks/get').first.headers['mcp-name'], task.id);
    });

    test('cancelling sends tasks/cancel; resumeToolTask picks a task up again', () async {
      server.toolImpls['echo'] = (c) => server.createTask();
      final c = await connect(caps: const McpClientCapabilities(tasks: true));
      McpTaskHandle? handle;
      final token = CancellationToken();
      final future = c.callTool('echo', cancel: token, onTaskCreated: (h) => handle = h);
      await eventually(() => handle != null);
      token.cancel();
      await expectLater(future, throwsA(isA<CancelledException>()));
      await eventually(() => server.tasks[handle!.taskId]!.cancelled);

      // A second task, resumed from its persisted handle.
      final c2 = await connect(caps: const McpClientCapabilities(tasks: true));
      McpTaskHandle? h2;
      unawaited(c2.callTool('echo', onTaskCreated: (h) => h2 = h, cancel: CancellationToken()..cancel()).catchError(
            (Object _) => McpCallToolResult(content: const [], raw: const {}),
          ));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(h2, isNull, reason: 'pre-cancelled calls never start');
      final created = server.createTask();
      final persisted = McpTaskHandle(
        serverId: 'srv',
        taskId: created['taskId']! as String,
        method: 'tools/call',
        name: 'echo',
        createdAt: DateTime.utc(2026),
      ).toJson();
      final resumed = c2.resumeToolTask(McpTaskHandle.fromJson(persisted));
      server.tasks[created['taskId']]!
        ..status = 'completed'
        ..result = {
          'content': [
            {'type': 'text', 'text': 'resumed'},
          ],
        };
      expect(((await resumed).content.single as McpTextContent).text, 'resumed');
      await c2.close();
    });

    test('a task result without the extension declared is invalid', () async {
      server.toolImpls['echo'] = (c) => server.createTask();
      final c = await connect();
      await expectLater(c.callTool('echo'), throwsA(isA<McpProtocolException>()));
    });
  });
}
