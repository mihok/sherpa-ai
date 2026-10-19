import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:sherpa_net/sherpa_net.dart';
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

  test('URL policy: loopback servers are refused unless the user allowed local network', () async {
    const publicOnly = UrlPolicy();
    final config = McpServerConfig(id: 's', name: 's', url: server.url);
    final opts = McpClientOptions(httpClient: options().httpClient);
    expect(config.urlPolicy.scope, publicOnly.scope);
    await expectLater(McpConnection.connect(config, options: opts), throwsA(isA<McpTransportException>()));
    expect(server.requests, isEmpty, reason: 'blocked before any byte was sent');
    // allowLocalNetwork widens the policy (loopback + http).
    expect(config.copyWith(allowLocalNetwork: true).urlPolicy.scope, NetworkScope.loopback);
  });

  test('link-local / metadata addresses stay blocked even with local network allowed', () async {
    final config = McpServerConfig(id: 's', name: 's', url: Uri.parse('http://169.254.169.254/mcp'), allowLocalNetwork: true);
    await expectLater(
      McpConnection.connect(config, options: McpClientOptions(httpClient: options().httpClient)),
      throwsA(isA<McpTransportException>()),
    );
  });

  test('a JSON body over maxMessageBytes fails instead of truncating', () async {
    server.intercept = (r) => r.rpcMethod == 'tools/list'
        ? Response.ok(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': r.id,
              'result': {'tools': <Object?>[], 'pad': 'x' * 5000},
            }),
            headers: {'content-type': 'application/json'})
        : null;
    final c = conn = await McpConnection.connect(serverConfig(server.url),
        options: options(limits: const McpLimits(maxMessageBytes: 2048)));
    await expectLater(c.listTools(), throwsA(isA<McpLimitExceededException>()));
  });

  test('one SSE event over maxMessageBytes fails the request', () async {
    server.toolImpls['echo'] = (c) => {
          'content': [
            {'type': 'text', 'text': 'y' * 10000},
          ],
        };
    final c = conn = await McpConnection.connect(serverConfig(server.url),
        options: options(limits: const McpLimits(maxMessageBytes: 4096)));
    await expectLater(c.callTool('echo'), throwsA(isA<McpLimitExceededException>()));
  });

  test('many small events and keep-alives under the cap are fine', () async {
    server
      ..keepAlive = const Duration(milliseconds: 2)
      ..toolImpls['echo'] = (c) async {
        for (var i = 0; i < 50; i++) {
          c.progress(i);
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        return {'content': <Object?>[]};
      };
    final c = conn = await McpConnection.connect(serverConfig(server.url),
        options: options(limits: const McpLimits(maxMessageBytes: 1024)));
    var n = 0;
    await c.callTool('echo', onProgress: (_) => n++);
    expect(n, 50);
  });

  test('cross-origin redirects are not followed; same-origin 307 is', () async {
    server.intercept = (r) => r.rpcMethod == 'server/discover' && r.path == '/mcp'
        ? Response(302, headers: {'location': 'https://elsewhere.test/mcp'})
        : null;
    await expectLater(
      McpConnection.connect(serverConfig(server.url), options: options()),
      throwsA(isA<McpTransportException>().having((e) => e.statusCode, 'status', 302)),
    );
    server.requests.clear();
    server.intercept = (r) => r.path == '/old' ? Response(307, headers: {'location': '/mcp'}) : null;
    final c = conn = await McpConnection.connect(serverConfig(server.root.replace(path: '/old')), options: options());
    expect(c.era, McpEra.modern);
    expect(server.requests.map((r) => r.path).take(2), ['/old', '/mcp']);
  });

  test('configured non-secret headers are sent; secrets and transport headers are refused', () async {
    final config = McpServerConfig(
      id: 's',
      name: 's',
      url: server.url,
      allowLocalNetwork: true,
      headers: {'X-Tenant': 'acme'},
    );
    conn = await McpConnection.connect(config, options: options());
    expect(server.requests.first.headers['x-tenant'], 'acme');
    for (final bad in ['Authorization', 'X-Api-Key', 'Cookie', 'X-Access-Token', 'Mcp-Session-Id', 'Mcp-Param-A']) {
      expect(() => McpServerConfig(id: 's', name: 's', url: server.url, headers: {bad: 'v'}), throwsArgumentError,
          reason: bad);
    }
  });
}
