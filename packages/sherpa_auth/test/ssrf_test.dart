import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:sherpa_auth/sherpa_auth.dart';
import 'package:sherpa_net/sherpa_net.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// Public names resolve to a public address; `internal.example` resolves to
/// a private one (DNS rebinding / split-horizon), `cloud.example` to the
/// metadata address.
Future<List<InternetAddress>> fakeDns(String host) async => switch (host) {
      'internal.example' => [InternetAddress('10.1.2.3')],
      'cloud.example' => [InternetAddress('169.254.169.254')],
      'nx.example' => throw const SocketException('no such host'),
      _ => [InternetAddress('93.184.216.34')],
    };

void main() {
  group('57: SSRF — blocked before any request', () {
    late List<http.BaseRequest> sent;
    late AuthHttp transport;

    setUp(() {
      sent = [];
      final client = MockClient((r) async {
        sent.add(r);
        return http.Response('{}', 200);
      });
      transport = AuthHttp(client: client, policy: AuthNetworkPolicy.forServer(Uri.parse('https://mcp.example.com/mcp'), resolver: fakeDns));
    });

    test('private, loopback, link-local, mapped and non-canonical numeric hosts', () async {
      for (final url in [
        'http://169.254.169.254/latest/meta-data/',
        'https://169.254.169.254/prm',
        'https://10.0.0.1/prm',
        'https://172.16.5.4/prm',
        'https://192.168.1.1/prm',
        'https://100.64.0.1/prm',
        'https://127.0.0.1/prm',
        'https://[::1]/prm',
        'https://[::ffff:127.0.0.1]/prm',
        'https://[::ffff:a9fe:a9fe]/prm',
        'https://[fe80::1]/prm',
        'https://[fc00::1]/prm',
        'https://0177.0.0.1/prm',
        'https://0x7f.0.0.1/prm',
        'https://127.1/prm',
        'https://2130706433/prm',
        'https://0.0.0.0/prm',
        'https://localhost/prm',
        'https://printer.local/prm',
        'https://internal.example/prm',
        'https://cloud.example/prm',
        'https://nx.example/prm',
        'http://mcp.example.com/prm',
        'ftp://mcp.example.com/prm',
        'https://user:pass@mcp.example.com/prm',
      ]) {
        await expectLater(
          discoverProtectedResource(serverUrl: Uri.parse('https://mcp.example.com/mcp'), http: transport, resourceMetadataUrl: Uri.parse(url)),
          throwsA(isA<AuthPolicyException>()),
          reason: url,
        );
      }
      expect(sent, isEmpty);
    });

    test('a challenge pointing at cloud metadata is blocked end to end', () async {
      final challenge = BearerChallenge.parse('Bearer resource_metadata="http://169.254.169.254/latest/meta-data/iam"')!;
      await expectLater(
        discoverProtectedResource(serverUrl: Uri.parse('https://mcp.example.com/mcp'), http: transport, resourceMetadataUrl: challenge.resourceMetadata),
        throwsA(isA<AuthPolicyException>().having((e) => e.toString(), 'text', contains('169.254.169.254'))),
      );
      expect(sent, isEmpty);
    });

    test('authorization_servers entries and their endpoints go through the policy too', () async {
      await expectLater(discoverAuthorizationServer('https://10.0.0.7/tenant', http: transport), throwsA(isA<AuthPolicyException>()));
      await expectLater(discoverAuthorizationServer('https://internal.example', http: transport), throwsA(isA<AuthPolicyException>()));
      expect(sent, isEmpty);
      final m = AuthorizationServerMetadata(
        issuer: 'https://as.example',
        authorizationEndpoint: Uri.parse('https://as.example/authorize'),
        tokenEndpoint: Uri.parse('https://192.168.0.10/token'),
      );
      expect(() => m.checkEndpoints(transport.policy), throwsA(isA<AuthPolicyException>()));
    });
  });

  group('58: user-configured LAN servers', () {
    test('same-host metadata is allowed; other private hosts stay blocked', () async {
      final lan = McpServerAuthConfig(serverUrl: Uri.parse('https://192.168.1.5/mcp'), networkScope: NetworkScope.localNetwork);
      final policy = lan.networkPolicy(resolver: fakeDns);
      await policy.check(Uri.parse('https://192.168.1.5/.well-known/oauth-protected-resource/mcp'));
      await policy.check(Uri.parse('https://192.168.1.5:8443/token'));
      await policy.check(Uri.parse('https://auth.example.com/authorize'));
      for (final blocked in ['https://192.168.1.6/', 'https://10.0.0.1/', 'https://127.0.0.1/', 'https://169.254.169.254/', 'http://192.168.1.5/']) {
        await expectLater(policy.check(Uri.parse(blocked)), throwsA(isA<AuthPolicyException>()), reason: blocked);
      }
    });

    test('an AS on another LAN host needs an explicit per-server trust entry', () async {
      final base = McpServerAuthConfig(serverUrl: Uri.parse('https://192.168.1.5/mcp'), networkScope: NetworkScope.localNetwork);
      await expectLater(base.networkPolicy(resolver: fakeDns).check(Uri.parse('https://192.168.1.6/token')), throwsA(isA<AuthPolicyException>()));
      final trusted = McpServerAuthConfig(
          serverUrl: Uri.parse('https://192.168.1.5/mcp'), networkScope: NetworkScope.localNetwork, extraLocalHosts: const {'192.168.1.6'});
      await trusted.networkPolicy(resolver: fakeDns).check(Uri.parse('https://192.168.1.6/token'));
      await expectLater(trusted.networkPolicy(resolver: fakeDns).check(Uri.parse('https://192.168.1.7/')), throwsA(isA<AuthPolicyException>()));
    });

    test('a LAN server with http allowed may use http on its own host only', () async {
      final lan = McpServerAuthConfig(serverUrl: Uri.parse('http://nas.local:8080/mcp'), networkScope: NetworkScope.localNetwork, allowHttp: true);
      final policy = lan.networkPolicy(resolver: (_) async => [InternetAddress('192.168.1.20')]);
      await policy.check(Uri.parse('http://nas.local:8080/.well-known/oauth-protected-resource/mcp'));
      await expectLater(policy.check(Uri.parse('http://other.local/')), throwsA(isA<AuthPolicyException>()));
    });

    test('the default (public) scope blocks a LAN server', () async {
      final pub = McpServerAuthConfig(serverUrl: Uri.parse('https://192.168.1.5/mcp')).networkPolicy(resolver: fakeDns);
      await expectLater(pub.check(Uri.parse('https://192.168.1.5/.well-known/oauth-protected-resource')), throwsA(isA<AuthPolicyException>()));
    });
  });

  group('59: redirects', () {
    late FakeHttp a;
    late FakeHttp b;
    late http.Client client;
    late AuthHttp transport;

    setUp(() async {
      a = await FakeHttp.start();
      b = await FakeHttp.start();
      client = http.Client();
      transport = AuthHttp(client: client, policy: loopbackPolicy);
    });

    tearDown(() async {
      client.close();
      await a.close();
      await b.close();
    });

    test('a cross-origin 302 is not followed', () async {
      a.route('GET /prm', (r, _) => Response.found('${b.origin}/prm'));
      b.route('GET /prm', (r, _) => json({'resource': 'x'}));
      final resp = await transport.get(a.root.replace(path: '/prm'));
      expect(resp.statusCode, 302);
      expect(b.requests, isEmpty);
    });

    test('same-origin 301s are followed up to 5 hops, not 6', () async {
      for (var i = 0; i < 6; i++) {
        a.route('GET /r$i', (r, _) => Response(301, headers: {'location': '/r${i + 1}'}));
      }
      a.route('GET /r6', (r, _) => json({'ok': true}));
      final five = await transport.get(a.root.replace(path: '/r1'));
      expect(five.statusCode, 200);
      expect(five.url.path, '/r6');
      final six = await transport.get(a.root.replace(path: '/r0'));
      expect(six.statusCode, 301);
    });

    test('POST follows only same-origin 307/308, never 302', () async {
      a.route('POST /token', (r, _) => Response.found('/token2'));
      a.route('POST /token2', (r, _) => json({'ok': true}));
      a.route('POST /token3', (r, _) => Response(307, headers: {'location': '/token2'}));
      expect((await transport.postForm(a.root.replace(path: '/token'), const {'a': 'b'})).statusCode, 302);
      final followed = await transport.postForm(a.root.replace(path: '/token3'), const {'a': 'b'});
      expect(followed.statusCode, 200);
      expect(a.to('/token2').single.form, {'a': 'b'});
    });

    test('a redirect adding userinfo is refused', () async {
      a.route('GET /x', (r, _) => Response.found('http://user:pw@127.0.0.1:${a.root.port}/y'));
      expect((await transport.get(a.root.replace(path: '/x'))).statusCode, 302);
      expect(a.to('/y'), isEmpty);
    });

    test('discovery treats an unfollowed redirect as "not here" and moves on', () async {
      a.route('GET /.well-known/oauth-protected-resource/mcp', (r, _) => Response.found('${b.origin}/evil'));
      a.route('GET /.well-known/oauth-protected-resource', (r, _) => json({'resource': a.origin, 'authorization_servers': ['https://as.example']}));
      final prm = await discoverProtectedResource(serverUrl: a.root.replace(path: '/mcp'), http: transport);
      expect(prm.resource, a.origin);
      expect(b.requests, isEmpty);
    });
  });

  group('60: size and time caps', () {
    late FakeHttp a;
    late http.Client client;

    setUp(() async {
      a = await FakeHttp.start();
      client = http.Client();
    });

    tearDown(() async {
      client.close();
      await a.close();
    });

    test('an oversized metadata document is abandoned and treated as invalid', () async {
      final big = '{"resource":"${a.origin}/mcp","authorization_servers":["https://as.example"],"pad":"${'x' * (70 << 10)}"}';
      a.route('GET /.well-known/oauth-protected-resource/mcp', (r, _) => Response.ok(big, headers: {'content-type': 'application/json'}));
      final transport = AuthHttp(client: client, policy: loopbackPolicy);
      final resp = await transport.get(a.root.replace(path: '/.well-known/oauth-protected-resource/mcp'));
      expect(resp.oversized, isTrue);
      expect(resp.jsonObject(), isNull);
      await expectLater(
          discoverProtectedResource(serverUrl: a.root.replace(path: '/mcp'), http: transport),
          throwsA(isA<DiscoveryException>().having((e) => e.failure, 'failure', DiscoveryFailure.resourceMetadataInvalid)));
    });

    test('a slow server (headers) times out as a network error', () async {
      a.route('GET /slow', (r, _) async {
        await Future<void>.delayed(const Duration(seconds: 3));
        return json({});
      });
      final transport = AuthHttp(client: client, policy: loopbackPolicy, limits: const AuthHttpLimits(timeout: Duration(milliseconds: 300)));
      final sw = Stopwatch()..start();
      await expectLater(transport.get(a.root.replace(path: '/slow')), throwsA(isA<AuthNetworkException>()));
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('a slow-drip body times out too', () async {
      a.route('GET /drip', (r, _) => Response.ok(
            Stream<List<int>>.periodic(const Duration(milliseconds: 100), (_) => [0x20]).take(100),
            headers: {'content-type': 'application/json'},
          ));
      final transport = AuthHttp(client: client, policy: loopbackPolicy, limits: const AuthHttpLimits(timeout: Duration(milliseconds: 400)));
      final sw = Stopwatch()..start();
      await expectLater(transport.get(a.root.replace(path: '/drip')), throwsA(isA<AuthNetworkException>()));
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('a refused connection is a network error, not "not found"', () async {
      final transport = AuthHttp(client: client, policy: loopbackPolicy);
      final dead = a.root;
      await a.close();
      await expectLater(
          discoverProtectedResource(serverUrl: dead.replace(path: '/mcp'), http: transport), throwsA(isA<AuthNetworkException>()));
      a = await FakeHttp.start();
    });
  });

  test('UrlPolicy default is public-only', () => expect(const AuthNetworkPolicy().publicPolicy.scope, NetworkScope.publicOnly));
}
