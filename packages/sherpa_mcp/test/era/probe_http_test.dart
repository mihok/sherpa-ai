import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:test/test.dart';

import '../support/fake_mcp_server.dart';
import '../support/helpers.dart';

Response _rpc(Object? id, int code, String message, {int status = 200, Object? data}) => Response(
      status,
      body: jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message, 'data': ?data},
      }),
      headers: {'content-type': 'application/json'},
    );

final class _Auth implements McpAuthHook {
  _Auth(this.decisions);

  final List<AuthRetry> decisions;
  var token = 'old';
  final List<int> challenges = [];

  @override
  Future<Map<String, String>> headersFor(Uri serverUrl) async => {'authorization': 'Bearer $token'};

  @override
  Future<AuthRetry> onAuthChallenge(Uri serverUrl, int status, Map<String, String> responseHeaders) async {
    challenges.add(status);
    final d = decisions.removeAt(0);
    if (d == AuthRetry.retry) token = 'new';
    return d;
  }
}

void main() {
  late FakeMcpServer server;
  McpConnection? conn;

  setUp(() async => server = await FakeMcpServer.start());
  tearDown(() async {
    await conn?.close();
    conn = null;
    await server.close();
  });

  Future<McpConnection> connect({McpServerConfig? config, McpClientOptions? opts}) async =>
      conn = await McpConnection.connect(config ?? serverConfig(server.url), options: opts ?? options());

  test('a legacy server answering 200 + -32601 (no header checks) → legacy', () async {
    server.intercept = (r) => r.rpcMethod == 'server/discover' ? _rpc(r.id, -32601, 'Method not found') : null;
    final c = await connect();
    expect(c.era, McpEra.legacy);
  });

  test('TS v1 stateless 400 -32000 "Unsupported protocol version" → legacy', () async {
    server.intercept = (r) => r.rpcMethod == 'server/discover'
        ? _rpc(r.id, -32000, 'Bad Request: Unsupported protocol version: 2026-07-28 (supported versions: 2025-11-25)',
            status: 400)
        : null;
    expect((await connect()).era, McpEra.legacy);
  });

  test('-32022 with a mutual version → one corrective retry, stays modern', () async {
    var first = true;
    server.intercept = (r) {
      if (r.rpcMethod == 'server/discover' && first) {
        first = false;
        return _rpc(r.id, -32022, 'Unsupported protocol version', status: 400, data: {
          'supported': ['2026-07-28', '2025-11-25'],
          'requested': '2026-07-28',
        });
      }
      return null;
    };
    final c = await connect();
    expect(c.era, McpEra.modern);
    expect(server.rpc('server/discover'), hasLength(2));
    expect(server.rpc('initialize'), isEmpty);
  });

  test('-32022 with only other modern versions → hard error, no fallback', () async {
    server.intercept = (r) => r.rpcMethod == 'server/discover'
        ? _rpc(r.id, -32022, 'Unsupported protocol version', status: 400, data: {
            'supported': ['2027-02-01'],
          })
        : null;
    await expectLater(connect(), throwsA(isA<McpUnsupportedVersionException>()));
    expect(server.rpc('initialize'), isEmpty);
  });

  test('5xx on the probe → error, no verdict, no initialize', () async {
    server.intercept = (r) => r.rpcMethod == 'server/discover' ? Response.internalServerError() : null;
    await expectLater(connect(), throwsA(isA<McpEraNegotiationException>()));
    expect(server.rpc('initialize'), isEmpty);
  });

  test('a 2xx non-JSON-RPC reply is unusable → error', () async {
    server.intercept =
        (r) => r.rpcMethod == 'server/discover' ? Response.ok('<html>', headers: {'content-type': 'text/html'}) : null;
    await expectLater(connect(), throwsA(isA<McpEraNegotiationException>()));
  });

  test('a modern-only server answers initialize with -32022: no HTTP+SSE fallback', () async {
    server
      ..legacy = false
      ..modernOverride = (400, {'jsonrpc': '2.0', 'id': 'x', 'error': {'code': -32000, 'message': 'x'}});
    // Probe says "legacy" (-32000), initialize says modern-only (-32022 400).
    await expectLater(connect(), throwsA(isA<McpEraNegotiationException>()));
    expect(server.requests.where((r) => r.method == 'GET'), isEmpty);
  });

  group('auth is not an era verdict', () {
    test('401 → hook retries with a new token → probe succeeds', () async {
      server.intercept = (r) =>
          r.headers['authorization'] == 'Bearer old' ? Response(401, headers: {'www-authenticate': 'Bearer'}) : null;
      final auth = _Auth([AuthRetry.retry]);
      final c = await connect(opts: options(auth: auth));
      expect(c.era, McpEra.modern);
      expect(auth.challenges, [401]);
      expect(server.requests.last.headers['authorization'], 'Bearer new');
    });

    test('needsUserConsent → McpAuthRequiredException for the app to run OAuth', () async {
      server.intercept = (r) => Response(401, headers: {'www-authenticate': 'Bearer resource_metadata="x"'});
      await expectLater(
        connect(opts: options(auth: _Auth([AuthRetry.needsUserConsent]))),
        throwsA(isA<McpAuthRequiredException>()
            .having((e) => e.needsUserConsent, 'consent', true)
            .having((e) => e.wwwAuthenticate, 'challenge', contains('resource_metadata'))),
      );
    });

    test('403 after a retry fails without looping', () async {
      server.intercept = (r) => Response.forbidden('no');
      final auth = _Auth([AuthRetry.retry, AuthRetry.retry]);
      await expectLater(connect(opts: options(auth: auth)),
          throwsA(isA<McpAuthRequiredException>().having((e) => e.needsUserConsent, 'consent', false)));
      expect(auth.challenges, [403]);
    });

    test('the bearer token goes on every request, including GET and DELETE', () async {
      server.modern = false;
      final c = await connect(opts: options(auth: _Auth([])));
      await c.listen();
      await c.close();
      conn = null;
      expect(server.requests, isNotEmpty);
      for (final r in server.requests) {
        expect(r.headers['authorization'], 'Bearer old', reason: '$r');
      }
      expect(server.requests.map((r) => r.method).toSet(), {'POST', 'GET', 'DELETE'});
    });
  });

  group('cached verdicts', () {
    test('a cached legacy verdict skips the modern probe', () async {
      server.modern = false;
      final first = await connect();
      final verdict = first.verdict!;
      expect(EraVerdict.fromJson(jsonDecode(jsonEncode(verdict.toJson())) as Map<String, Object?>), verdict);
      await first.close();
      server.requests.clear();
      final second = await connect(config: serverConfig(server.url, verdict: verdict));
      expect(second.era, McpEra.legacy);
      expect(server.rpc('server/discover'), isEmpty);
      expect(second.verdictChanged, isFalse);
      expect(second.probeLog.first, startsWith('cached verdict'));
    });

    test('a contradicted cached verdict re-probes once and reports the new one', () async {
      server.modern = false;
      final legacyVerdict = (await connect()).verdict!;
      await conn!.close();
      // The server upgraded to modern-only.
      server
        ..modern = true
        ..legacy = false;
      final c = await connect(config: serverConfig(server.url, verdict: legacyVerdict));
      expect(c.era, McpEra.modern);
      expect(c.verdictChanged, isTrue);
      expect(c.probeLog.first, contains('failed'));
    });

    test('a verdict for another endpoint is ignored', () async {
      final other = EraVerdict(
        transport: McpTransportKind.legacySse,
        protocolVersion: '2024-11-05',
        endpoint: 'http://127.0.0.1:1/elsewhere',
        decidedAt: DateTime.utc(2026),
      );
      expect((await connect(config: serverConfig(server.url, verdict: other))).era, McpEra.modern);
    });

    test('the process-wide EraVerdictCache is filled and used', () async {
      final cache = EraVerdictCache();
      server.modern = false;
      await connect(opts: options(cache: cache));
      expect(cache.lookup(server.url)?.transport, McpTransportKind.legacyStreamableHttp);
      await conn!.close();
      server.requests.clear();
      await connect(opts: options(cache: cache));
      expect(server.rpc('server/discover'), isEmpty);
    });

    test('network errors with a cached verdict do not trigger a re-probe', () async {
      final verdict = (await connect()).verdict!;
      await conn!.close();
      conn = null;
      final url = server.url;
      await server.close();
      await expectLater(
        McpConnection.connect(serverConfig(url, verdict: verdict), options: options()),
        throwsA(isA<McpTransportException>()),
      );
      server = await FakeMcpServer.start();
    });
  });

  test('forced transport preferences do not probe other eras', () async {
    server.modern = false;
    final c = await connect(config: serverConfig(server.url, transport: McpTransportPreference.legacyStreamableHttp));
    expect(c.era, McpEra.legacy);
    expect(server.rpc('server/discover'), isEmpty);
    await c.close();
    await expectLater(
      connect(config: serverConfig(server.url, transport: McpTransportPreference.modernHttp)),
      throwsA(isA<McpEraNegotiationException>()),
    );
    expect(server.rpc('initialize'), hasLength(1), reason: 'no fallback when pinned to modern');
  });
}
