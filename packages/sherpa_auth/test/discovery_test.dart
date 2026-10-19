import 'package:shelf/shelf.dart';
import 'package:sherpa_auth/sherpa_auth.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  late Harness h;
  late FakeHttp rs;

  setUp(() async {
    h = Harness();
    rs = await FakeHttp.start();
  });

  tearDown(() async {
    h.close();
    await rs.close();
  });

  JsonMapLike prmFor(String resource, {List<String>? as}) => {
        'resource': resource,
        'authorization_servers': as ?? ['https://auth.example.com/tenant1'],
        'scopes_supported': ['files:read'],
      };

  Future<ProtectedResourceMetadata> discoverPrm(Uri server, {Uri? header, ResourceMatchPolicy match = ResourceMatchPolicy.sameOriginPathPrefix}) =>
      discoverProtectedResource(serverUrl: server, http: h.transport, resourceMetadataUrl: header, matchPolicy: match, logger: h.logs.call);

  group('PRM discovery (RFC 9728, ASD26 L37-47)', () {
    test('10: the header URL is used verbatim and nothing else is probed', () async {
      final server = rs.root.replace(path: '/mcp');
      rs.route('GET /custom/prm', (r, _) => json(prmFor('${rs.origin}/mcp')));
      final prm = await discoverPrm(server, header: rs.root.replace(path: '/custom/prm'));
      expect(prm.resource, '${rs.origin}/mcp');
      expect(prm.match, ResourceMatch.exact);
      expect(rs.paths, ['/custom/prm']);
    });

    test('a header URL that answers 404 falls back to the well-known URLs', () async {
      rs.route('GET /.well-known/oauth-protected-resource/mcp', (r, _) => json(prmFor('${rs.origin}/mcp')));
      final prm = await discoverPrm(rs.root.replace(path: '/mcp'), header: rs.root.replace(path: '/stale'));
      expect(prm.resource, '${rs.origin}/mcp');
      expect(rs.paths, ['/stale', '/.well-known/oauth-protected-resource/mcp']);
    });

    test('11: no header → path-aware, then root on 404', () async {
      rs.route('GET /.well-known/oauth-protected-resource', (r, _) => json(prmFor(rs.origin)));
      final prm = await discoverPrm(rs.root.replace(path: '/mcp'));
      expect(rs.paths, ['/.well-known/oauth-protected-resource/mcp', '/.well-known/oauth-protected-resource']);
      expect(prm.match, ResourceMatch.pathPrefix);
      expect(h.logs.all, contains('same-origin path-prefix rule'));
    });

    test('12: a server at the root gets a single root probe', () async {
      expect(protectedResourceMetadataUrls(Uri.parse('https://h.example/')), [Uri.parse('https://h.example/.well-known/oauth-protected-resource')]);
      expect(protectedResourceMetadataUrls(Uri.parse('https://h.example')), [Uri.parse('https://h.example/.well-known/oauth-protected-resource')]);
      rs.route('GET /.well-known/oauth-protected-resource', (r, _) => json(prmFor(rs.origin)));
      await discoverPrm(rs.root.replace(path: '/'));
      expect(rs.paths, ['/.well-known/oauth-protected-resource']);
    });

    test('13: a trailing slash is stripped and the query is kept after the path', () {
      expect(protectedResourceMetadataUrls(Uri.parse('https://h.example/mcp/')).first,
          Uri.parse('https://h.example/.well-known/oauth-protected-resource/mcp'));
      expect(protectedResourceMetadataUrls(Uri.parse('https://h.example/mcp?tenant=1#frag')).first,
          Uri.parse('https://h.example/.well-known/oauth-protected-resource/mcp?tenant=1'));
      expect(protectedResourceMetadataUrls(Uri.parse('https://h.example/public/mcp')),
          [Uri.parse('https://h.example/.well-known/oauth-protected-resource/public/mcp'), Uri.parse('https://h.example/.well-known/oauth-protected-resource')]);
    });

    test('14: 500 on the path probe is an error (no fallback); 502 falls back', () async {
      rs.route('GET /.well-known/oauth-protected-resource/mcp', (r, _) => Response.internalServerError());
      rs.route('GET /.well-known/oauth-protected-resource', (r, _) => json(prmFor(rs.origin)));
      await expectLater(discoverPrm(rs.root.replace(path: '/mcp')), throwsA(isA<AuthServerException>()));
      expect(rs.paths, ['/.well-known/oauth-protected-resource/mcp']);

      rs.requests.clear();
      rs.route('GET /.well-known/oauth-protected-resource/mcp', (r, _) => Response(502));
      final prm = await discoverPrm(rs.root.replace(path: '/mcp'));
      expect(prm.resource, rs.origin);
      expect(rs.paths.length, 2);
    });

    test('15: a 200 HTML catch-all falls back to the next candidate', () async {
      rs.route('GET /.well-known/oauth-protected-resource/mcp',
          (r, _) => Response.ok('<!doctype html><html>app</html>', headers: {'content-type': 'text/html'}));
      rs.route('GET /.well-known/oauth-protected-resource', (r, _) => json(prmFor(rs.origin)));
      expect((await discoverPrm(rs.root.replace(path: '/mcp'))).resource, rs.origin);
    });

    test('a schema-invalid PRM falls back, and is reported when nothing else works', () async {
      rs.route('GET /.well-known/oauth-protected-resource/mcp', (r, _) => json({'resource': 42}));
      await expectLater(
          discoverPrm(rs.root.replace(path: '/mcp')),
          throwsA(isA<DiscoveryException>().having((e) => e.failure, 'failure', DiscoveryFailure.resourceMetadataInvalid)));
      expect(rs.paths.length, 2);
    });

    test('nothing anywhere → resourceMetadataNotFound', () async {
      await expectLater(
          discoverPrm(rs.root.replace(path: '/mcp')),
          throwsA(isA<DiscoveryException>().having((e) => e.failure, 'failure', DiscoveryFailure.resourceMetadataNotFound)));
    });

    group('16: resource match policy', () {
      final server = Uri.parse('https://ex.com/api/mcp');

      test('identical → exact; same-origin segment prefix → relaxed; others rejected', () {
        const p = ResourceMatchPolicy.sameOriginPathPrefix;
        expect(matchResource('https://ex.com/api/mcp', server, p), ResourceMatch.exact);
        expect(matchResource('https://ex.com/api', server, p), ResourceMatch.pathPrefix);
        expect(matchResource('https://ex.com', server, p), ResourceMatch.pathPrefix);
        expect(matchResource('https://ex.com/', server, p), ResourceMatch.pathPrefix);
        expect(matchResource('https://ex.com/ap', server, p), isNull);
        expect(matchResource('https://ex.com/api/mcp/sub', server, p), isNull);
        expect(matchResource('https://ex.com/api123', Uri.parse('https://ex.com/api123/x'), p), ResourceMatch.pathPrefix);
        expect(matchResource('https://ex.com/api', Uri.parse('https://ex.com/api123'), p), isNull);
        expect(matchResource('https://evil.com/api/mcp', server, p), isNull);
        expect(matchResource('http://ex.com/api/mcp', server, p), isNull);
        expect(matchResource('https://ex.com:8443/api/mcp', server, p), isNull);
        expect(matchResource('https://ex.com/api?x=1', server, p), isNull);
      });

      test('the exact policy rejects the relaxation', () {
        const p = ResourceMatchPolicy.exact;
        expect(matchResource('https://ex.com/api/mcp', server, p), ResourceMatch.exact);
        expect(matchResource('https://ex.com', server, p), isNull);
      });

      test('a cross-origin resource is rejected end to end, even if well-formed', () async {
        rs.route('GET /.well-known/oauth-protected-resource/mcp', (r, _) => json(prmFor('https://victim.example/mcp')));
        rs.route('GET /.well-known/oauth-protected-resource', (r, _) => json(prmFor('https://victim.example')));
        await expectLater(
            discoverPrm(rs.root.replace(path: '/mcp')),
            throwsA(isA<DiscoveryException>().having((e) => e.failure, 'failure', DiscoveryFailure.resourceMismatch)));
      });

      test('the PRM resource string is kept verbatim (no trailing slash added)', () async {
        rs.route('GET /.well-known/oauth-protected-resource', (r, _) => json(prmFor(rs.origin)));
        final prm = await discoverPrm(rs.root.replace(path: '/mcp'));
        expect(prm.resource, rs.origin);
        expect(prm.resource.endsWith('/'), isFalse);
      });
    });

    test('17: empty or missing authorization_servers is an error', () async {
      rs.route('GET /.well-known/oauth-protected-resource/mcp', (r, _) => json({'resource': '${rs.origin}/mcp', 'authorization_servers': <String>[]}));
      await expectLater(
          discoverPrm(rs.root.replace(path: '/mcp')),
          throwsA(isA<DiscoveryException>().having((e) => e.failure, 'failure', DiscoveryFailure.noAuthorizationServers)));
      rs.route('GET /.well-known/oauth-protected-resource/mcp', (r, _) => json({'resource': '${rs.origin}/mcp'}));
      await expectLater(discoverPrm(rs.root.replace(path: '/mcp')), throwsA(isA<DiscoveryException>()));
    });

    test('no Authorization header or cookies are sent on metadata fetches', () async {
      rs.route('GET /.well-known/oauth-protected-resource/mcp', (r, _) => json(prmFor('${rs.origin}/mcp')));
      await discoverPrm(rs.root.replace(path: '/mcp'));
      for (final r in rs.requests) {
        expect(r.authorization, isNull);
        expect(r.headers['cookie'], isNull);
        expect(r.headers['accept'], 'application/json');
      }
    });
  });

  group('AS discovery (RFC 8414 + OIDC, ASD26 L75-94)', () {
    test('19: a path issuer yields exactly three URLs in spec order; pathless yields two', () async {
      expect(authorizationServerMetadataUrls('https://auth.example.com/tenant1'), [
        Uri.parse('https://auth.example.com/.well-known/oauth-authorization-server/tenant1'),
        Uri.parse('https://auth.example.com/.well-known/openid-configuration/tenant1'),
        Uri.parse('https://auth.example.com/tenant1/.well-known/openid-configuration'),
      ]);
      expect(authorizationServerMetadataUrls('https://auth.example.com'), [
        Uri.parse('https://auth.example.com/.well-known/oauth-authorization-server'),
        Uri.parse('https://auth.example.com/.well-known/openid-configuration'),
      ]);
      // And the client really probes in that order.
      final as = await FakeAuthServer.start();
      addTearDown(as.close);
      as.metadataPaths = {'/tenant1/.well-known/openid-configuration'};
      final m = await h.discover(as);
      expect(m.issuer, as.issuer);
      expect(as.http.paths, [
        '/.well-known/oauth-authorization-server/tenant1',
        '/.well-known/openid-configuration/tenant1',
        '/tenant1/.well-known/openid-configuration',
      ]);
    });

    test('20: `https://as/` is pathless; `https://as/t1/` inserts /t1', () {
      expect(authorizationServerMetadataUrls('https://as.example/').length, 2);
      expect(authorizationServerMetadataUrls('https://as.example/t1/').first,
          Uri.parse('https://as.example/.well-known/oauth-authorization-server/t1'));
      expect(() => authorizationServerMetadataUrls('https://as.example/?q=1'), throwsA(isA<DiscoveryException>()));
      expect(() => authorizationServerMetadataUrls('https://as.example/#f'), throwsA(isA<DiscoveryException>()));
    });

    test('21: falls back on 4xx and 502; 503 is an error', () async {
      final as = await FakeAuthServer.start();
      addTearDown(as.close);
      as.metadataPaths = {'/.well-known/openid-configuration/tenant1'};
      as.http.route('GET /.well-known/oauth-authorization-server/tenant1', (r, _) => Response(502));
      expect((await h.discover(as)).issuer, as.issuer);
      as.http.route('GET /.well-known/oauth-authorization-server/tenant1', (r, _) => Response(503));
      await expectLater(h.discover(as), throwsA(isA<AuthServerException>().having((e) => e.retryable, 'retryable', isTrue)));
    });

    test('22: an issuer mismatch is not used; all mismatching → IssuerMismatchException (attacker example)', () async {
      final as = await FakeAuthServer.start();
      addTearDown(as.close);
      as.metadataPaths = {
        '/.well-known/oauth-authorization-server/tenant1',
        '/.well-known/openid-configuration/tenant1',
      };
      var first = true;
      as.editMetadata = (m) {
        if (first) {
          first = false;
          return {...m, 'issuer': 'https://honest.example'};
        }
        return m;
      };
      final m = await h.discover(as);
      expect(m.issuer, as.issuer);
      expect(as.http.paths.length, 2);
      expect(h.logs.all, contains('claims issuer'));

      as.editMetadata = (m) => {...m, 'issuer': 'https://honest.example'};
      await expectLater(
          h.discover(as),
          throwsA(isA<IssuerMismatchException>()
              .having((e) => e.expected, 'expected', as.issuer)
              .having((e) => e.actual, 'actual', 'https://honest.example')));
    });

    test('issuer comparison is exact: case, default port and encoding all matter', () {
      expect(issuerMatches('https://as.example/t1', 'https://as.example/t1'), isTrue);
      expect(issuerMatches('https://as.example/t1', 'https://AS.example/t1'), isFalse);
      expect(issuerMatches('https://as.example/t1', 'https://as.example:443/t1'), isFalse);
      expect(issuerMatches('https://as.example/~t1', 'https://as.example/%7Et1'), isFalse);
    });

    test('23: the trailing-slash tolerance works in one direction only', () {
      expect(issuerMatches('https://as.example/t1/', 'https://as.example/t1'), isTrue);
      expect(issuerMatches('https://as.example/t1', 'https://as.example/t1/'), isFalse);
      expect(issuerMatches('https://as.example/', 'https://as.example'), isTrue);
    });

    test('the validated document issuer becomes the recorded issuer', () async {
      final as = await FakeAuthServer.start(tenantPath: '');
      addTearDown(as.close);
      final m = await discoverAuthorizationServer('${as.issuer}/', http: h.transport);
      expect(m.issuer, as.issuer);
    });

    test('24: PKCE absent → refuse; ["plain"] → refuse; ["S256"] → ok; override only for absent', () {
      AuthorizationServerMetadata meta(Object? methods) => AuthorizationServerMetadata.fromJson({
            'issuer': 'https://as.example',
            'authorization_endpoint': 'https://as.example/authorize',
            'token_endpoint': 'https://as.example/token',
            'response_types_supported': ['code'],
            'code_challenge_methods_supported': ?methods,
          });
      expect(() => meta(null).checkPkce(),
          throwsA(isA<PkceNotSupportedException>().having((e) => e.overridable, 'overridable', isTrue)));
      expect(() => meta(['plain']).checkPkce(),
          throwsA(isA<PkceNotSupportedException>().having((e) => e.overridable, 'overridable', isFalse)));
      expect(() => meta(<String>[]).checkPkce(allowMissing: true), throwsA(isA<PkceNotSupportedException>()));
      expect(() => meta(['plain']).checkPkce(allowMissing: true), throwsA(isA<PkceNotSupportedException>()));
      meta(['S256']).checkPkce();
      meta(['plain', 'S256']).checkPkce();
      meta(null).checkPkce(allowMissing: true);
    });

    test('25: response_types_supported without "code" (or missing) is invalid', () async {
      final as = await FakeAuthServer.start();
      addTearDown(as.close);
      as.editMetadata = (m) => {...m, 'response_types_supported': ['token']};
      await expectLater(
          h.discover(as),
          throwsA(isA<DiscoveryException>().having((e) => e.failure, 'failure', DiscoveryFailure.authorizationServerInvalid)));
      as.editMetadata = (m) => {...m}..remove('response_types_supported');
      await expectLater(h.discover(as), throwsA(isA<DiscoveryException>()));
    });

    test('26: an http token endpoint (non-loopback) is refused; javascript: endpoints invalidate the document', () {
      final m = AuthorizationServerMetadata.fromJson({
        'issuer': 'https://as.example',
        'authorization_endpoint': 'https://as.example/authorize',
        'token_endpoint': 'http://as.example/token',
        'response_types_supported': ['code'],
        'code_challenge_methods_supported': ['S256'],
      });
      expect(() => m.checkEndpoints(const AuthNetworkPolicy()), throwsA(isA<AuthPolicyException>()));
      for (final bad in ['javascript:alert(1)', 'data:text/html,hi', 'file:///etc/passwd', 'vbscript:x', '/relative']) {
        expect(
            () => AuthorizationServerMetadata.fromJson({
                  'issuer': 'https://as.example',
                  'authorization_endpoint': bad,
                  'token_endpoint': 'https://as.example/token',
                  'response_types_supported': ['code'],
                }),
            throwsA(isA<Object>()),
            reason: bad);
      }
    });

    test('27: an OIDC document without jwks_uri etc. is accepted', () {
      final m = AuthorizationServerMetadata.fromJson({
        'issuer': 'https://as.example',
        'authorization_endpoint': 'https://as.example/authorize',
        'token_endpoint': 'https://as.example/token',
        'response_types_supported': ['code'],
        'code_challenge_methods_supported': ['S256'],
      });
      expect(m.tokenEndpoint.path, '/token');
    });

    test('boolean capabilities count only as literal true', () {
      JsonMapLike base(Object v) => {
            'issuer': 'https://as.example',
            'authorization_endpoint': 'https://as.example/authorize',
            'token_endpoint': 'https://as.example/token',
            'response_types_supported': ['code'],
            'client_id_metadata_document_supported': v,
            'authorization_response_iss_parameter_supported': v,
          };
      final yes = AuthorizationServerMetadata.fromJson(base(true));
      expect(yes.clientIdMetadataDocumentSupported, isTrue);
      expect(yes.authorizationResponseIssParameterSupported, isTrue);
      final str = AuthorizationServerMetadata.fromJson(base('true'));
      expect(str.clientIdMetadataDocumentSupported, isFalse);
      expect(str.authorizationResponseIssParameterSupported, isFalse);
    });

    test('metadata round-trips through JSON', () async {
      final as = await FakeAuthServer.start();
      addTearDown(as.close);
      final m = await h.discover(as);
      final again = AuthorizationServerMetadata.fromJson(m.toJson());
      expect(again.toJson(), m.toJson());
      expect(m.metadataUrl!.path, '/.well-known/oauth-authorization-server/tenant1');
    });
  });
}

typedef JsonMapLike = Map<String, Object?>;
