import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:sherpa_mcp/src/client/cache.dart';
import 'package:test/test.dart';

import 'support/fake_mcp_server.dart';
import 'support/helpers.dart';

final class _RotatingAuth implements McpAuthHook {
  var token = 't1';

  @override
  Future<Map<String, String>> headersFor(Uri serverUrl) async => {'authorization': 'Bearer $token'};

  @override
  Future<AuthRetry> onAuthChallenge(Uri serverUrl, int status, Map<String, String> responseHeaders) async {
    token = 't2';
    return AuthRetry.retry;
  }
}

void main() {
  group('McpServerConfig', () {
    test('JSON round trip including the cached verdict', () {
      final v = EraVerdict(
        transport: McpTransportKind.legacyStreamableHttp,
        protocolVersion: '2025-06-18',
        endpoint: endpointKey(Uri.parse('https://mcp.example.com/mcp')),
        decidedAt: DateTime.utc(2026, 10, 18),
      );
      final c = McpServerConfig(
        id: 'gh',
        name: 'GitHub',
        url: Uri.parse('https://mcp.example.com/mcp'),
        cachedVerdict: v,
        trusted: true,
        headers: {'X-Org': 'acme'},
      );
      final back = McpServerConfig.fromJson(jsonDecode(jsonEncode(c.toJson())) as Map<String, Object?>);
      expect(back.toJson(), c.toJson());
      expect(back.cachedVerdict, v);
      expect(back.cachedVerdict!.appliesTo(Uri.parse('https://MCP.example.com:443/mcp?x=1')), isTrue);
      expect(back.cachedVerdict!.appliesTo(Uri.parse('https://mcp.example.com/other')), isFalse);
      expect(back.trusted, isTrue);
      expect(back.enabled, isTrue);
      expect(back.copyWith(clearCachedVerdict: true).cachedVerdict, isNull);
    });

    test('a corrupt or inconsistent verdict is dropped (costs a re-probe only)', () {
      final c = McpServerConfig.fromJson({
        'id': 'x',
        'name': 'x',
        'url': 'https://x.test/mcp',
        'cachedVerdict': {
          'transport': 'modernHttp',
          'protocolVersion': '2025-11-25',
          'endpoint': 'https://x.test:443/mcp',
          'decidedAt': '2026-01-01T00:00:00Z',
        },
      });
      expect(c.cachedVerdict, isNull);
      expect(() => McpServerConfig.fromJson({'id': 'x', 'name': 'x', 'url': 'https://x', 'transport': 'carrier-pigeon'}),
          throwsA(isA<FormatError>()));
    });

    test('capabilities JSON per era and handler presence', () {
      const caps = McpClientCapabilities(elicitationUrl: false, tasks: true, mcpApps: true);
      expect(caps.toJson(era: McpEra.modern, hasHandler: true), {
        'elicitation': {'form': <String, Object?>{}},
        'extensions': {
          'io.modelcontextprotocol/ui': {
            'mimeTypes': ['text/html;profile=mcp-app'],
          },
          'io.modelcontextprotocol/tasks': <String, Object?>{},
        },
      });
      expect(caps.toJson(era: McpEra.legacy, hasHandler: false), {
        'extensions': {
          'io.modelcontextprotocol/ui': {
            'mimeTypes': ['text/html;profile=mcp-app'],
          },
        },
      });
    });

    test('task handles serialize for resumption', () {
      final h = McpTaskHandle(
        serverId: 's',
        taskId: 't',
        method: 'tools/call',
        name: 'export',
        createdAt: DateTime.utc(2026),
        pollIntervalMs: 500,
      );
      final back = McpTaskHandle.fromJson(jsonDecode(jsonEncode(h.toJson())) as Map<String, Object?>);
      expect(back.toJson(), h.toJson());
    });
  });

  group('ResultCache', () {
    test('fresh while now < fetchedAt + ttl; zero/negative ttl never fresh', () {
      final clock = FakeClock();
      final cache = ResultCache(clock)
        ..put('a', 1, ttl: const Duration(seconds: 10), isPrivate: false)
        ..put('b', 2, ttl: Duration.zero, isPrivate: false)
        ..put('c', 3, ttl: const Duration(seconds: -5), isPrivate: false);
      expect(cache.fresh<int>('a'), 1);
      expect(cache.fresh<int>('b'), isNull);
      expect(cache.entry<int>('b')!.value, 2, reason: 'kept for stale-on-error');
      expect(cache.fresh<int>('c'), isNull);
      clock.advance(const Duration(seconds: 10));
      expect(cache.fresh<int>('a'), isNull);
    });

    test('private entries are dropped with the authorization context', () {
      final cache = ResultCache(FakeClock())
        ..put('pub', 1, ttl: const Duration(hours: 1), isPrivate: false)
        ..put('priv', 2, ttl: const Duration(hours: 1), isPrivate: true)
        ..dropPrivate();
      expect(cache.fresh<int>('pub'), 1);
      expect(cache.fresh<int>('priv'), isNull);
    });
  });

  group('connection caching rules', () {
    late FakeMcpServer server;
    setUp(() async => server = await FakeMcpServer.start());
    tearDown(() => server.close());

    test('a credential change drops cacheScope:private lists', () async {
      server.cacheScope = 'private';
      final auth = _RotatingAuth();
      var challenged = false;
      server.intercept = (r) {
        if (r.rpcMethod == 'resources/list' && !challenged) {
          challenged = true;
          return Response(401);
        }
        return null;
      };
      final c = await McpConnection.connect(serverConfig(server.url), options: options(auth: auth));
      await c.listTools();
      await c.listTools();
      expect(server.rpc('tools/list'), hasLength(1));
      await c.listResources(); // 401 → hook rotates the token → retried
      await c.listTools();
      expect(server.rpc('tools/list'), hasLength(2), reason: 'private entry belonged to the old token');
      expect(server.requests.last.headers['authorization'], 'Bearer t2');
      await c.close();
    });

    test('stale data is served when a re-fetch fails at the transport level', () async {
      server.ttlMs = 0;
      final c = await McpConnection.connect(serverConfig(server.url), options: options());
      final first = await c.listTools();
      server.intercept = (r) => r.rpcMethod == 'tools/list' ? Response(503) : null;
      await expectLater(c.listTools(), throwsA(isA<McpHttpStatusException>()), reason: 'HTTP errors are not masked');
      server.intercept = (r) => r.rpcMethod == 'tools/list'
          ? Response.ok(Stream.value(utf8.encode(':\n\n')), headers: {'content-type': 'text/event-stream'})
          : null;
      expect(await c.listTools(), first, reason: 'broken streams twice → stale list');
      await c.close();
    });

    test('MRTR-produced reads are never cached', () async {
      final c = await McpConnection.connect(serverConfig(server.url),
          options: options(handler: ScriptedHandler(onElicit: (r, _) => const McpElicitResult.accept())));
      server.intercept = (r) {
        if (r.rpcMethod != 'resources/read') return null;
        final responded = r.params!.containsKey('inputResponses');
        return Response.ok(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': r.id,
            'result': responded
                ? {
                    'resultType': 'complete',
                    'contents': [
                      {'uri': 'file:///a.txt', 'text': 'secret'},
                    ],
                    'ttlMs': 600000,
                    'cacheScope': 'public',
                  }
                : {
                    'resultType': 'input_required',
                    'inputRequests': {
                      'ok': {
                        'method': 'elicitation/create',
                        'params': {
                          'message': 'Reveal?',
                          'requestedSchema': {'type': 'object', 'properties': <String, Object?>{}},
                        },
                      },
                    },
                  },
          }),
          headers: {'content-type': 'application/json'},
        );
      };
      await c.readResource('file:///a.txt');
      await c.readResource('file:///a.txt');
      expect(server.rpc('resources/read'), hasLength(4));
      await c.close();
    });
  });
}
