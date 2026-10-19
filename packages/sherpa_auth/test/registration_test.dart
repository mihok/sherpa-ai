import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:sherpa_auth/sherpa_auth.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  late FakeAuthServer as;
  Harness? harness;
  Harness h0() => harness!;

  setUp(() async {
    as = await FakeAuthServer.start();
  });

  tearDown(() async {
    harness?.close();
    harness = null;
    await as.close();
  });

  Future<ClientRegistration> resolve({
    OAuthClientIdentity id = identity,
    List<PreRegisteredClient> pre = const [],
    List<String> scopes = const ['files:read'],
  }) async {
    harness?.close();
    final h = harness = Harness(as: as, id: id);
    final m = await h.discover(as);
    return h.client.registrar.resolve(m, http: h.transport, preRegistered: pre, scopes: scopes);
  }

  const withCimd = OAuthClientIdentity(
    clientName: 'Sherpa',
    redirectUri: 'io.github.mihok.sherpa:/oauth/callback',
    httpsRedirectUri: 'https://sherpa.example/oauth/callback',
    metadataDocumentUrl: cimdUrl,
  );

  test('28: a pre-registered client for the issuer wins over CIMD and DCR', () async {
    as.cimdSupported = true;
    final reg = await resolve(id: withCimd, pre: [PreRegisteredClient(issuer: as.issuer, clientId: 'my-app')]);
    expect(reg.kind, RegistrationKind.preRegistered);
    expect(reg.clientId, 'my-app');
    expect(as.registerRequests, isEmpty);
    expect((await h0().store.readRegistration(as.issuer))!.clientId, 'my-app');
  });

  test('29: CIMD is used only when the flag is literally true', () async {
    as.cimdSupported = true;
    final reg = await resolve(id: withCimd);
    expect(reg.kind, RegistrationKind.metadataDocument);
    expect(reg.clientId, cimdUrl);
    expect(reg.redirectUri, 'https://sherpa.example/oauth/callback');
    expect(as.registerRequests, isEmpty);

    as.cimdSupported = false;
    as.editMetadata = (m) => {...m, 'client_id_metadata_document_supported': 'true'};
    final reg2 = await resolve(id: withCimd);
    expect(reg2.kind, RegistrationKind.dynamic);
  });

  test('CIMD is skipped when Sherpa has no metadata document URL', () async {
    as.cimdSupported = true;
    final reg = await resolve();
    expect(reg.kind, RegistrationKind.dynamic);
  });

  test('30: the CIMD client_id must be https with a path and no fragment, query, userinfo or dot segments', () {
    OAuthClientIdentity.checkMetadataDocumentUrl(cimdUrl);
    for (final bad in [
      'http://sherpa.example/client.json',
      'https://sherpa.example',
      'https://sherpa.example/',
      'https://sherpa.example/client.json#x',
      'https://sherpa.example/client.json?v=1',
      'https://user@sherpa.example/client.json',
      'https://sherpa.example/a/../client.json',
      'https://sherpa.example/./client.json',
    ]) {
      expect(() => OAuthClientIdentity.checkMetadataDocumentUrl(bad), throwsArgumentError, reason: bad);
    }
  });

  test('redirect URIs: reverse-DNS private-use schemes, https, loopback http only', () {
    for (final ok in ['io.github.mihok.sherpa:/oauth/callback', 'https://sherpa.example/cb', 'http://127.0.0.1:8080/cb']) {
      OAuthClientIdentity.checkRedirectUri(ok);
    }
    for (final bad in ['sherpa:/cb', 'http://sherpa.example/cb', 'javascript:alert(1)', 'io.github.x:/cb#f', 'data:/x']) {
      expect(() => OAuthClientIdentity.checkRedirectUri(bad), throwsArgumentError, reason: bad);
    }
  });

  test('31: the DCR body carries application_type, refresh_token grant, auth method none and the scope', () async {
    final reg = await resolve(scopes: ['files:read', 'offline_access']);
    expect(reg.kind, RegistrationKind.dynamic);
    final body = as.registerRequests.single.json;
    expect(body['application_type'], 'native');
    expect(body['grant_types'], ['authorization_code', 'refresh_token']);
    expect(body['response_types'], ['code']);
    expect(body['token_endpoint_auth_method'], 'none');
    expect(body['redirect_uris'], ['io.github.mihok.sherpa:/oauth/callback']);
    expect(body['scope'], 'files:read offline_access');
    expect(body['client_name'], 'Sherpa');
    expect(as.registerRequests.single.headers['content-type'], startsWith('application/json'));
  });

  test('32: the DCR ladder moves on after a rejection, stops after 3, and the outcome is cached', () async {
    final seen = <(String?, String?)>[];
    as.registerHook = (body) {
      seen.add((body['application_type'] as String?, (body['redirect_uris'] as List).first as String?));
      if (seen.length < 3) return json({'error': 'invalid_redirect_uri'}, status: 400);
      return null;
    };
    final reg = await resolve(id: withCimd);
    expect(seen, [
      ('native', 'https://sherpa.example/oauth/callback'),
      ('web', 'https://sherpa.example/oauth/callback'),
      ('native', 'io.github.mihok.sherpa:/oauth/callback'),
    ]);
    expect(reg.redirectUri, 'io.github.mihok.sherpa:/oauth/callback');
    expect(reg.applicationType, 'native');

    // Cached per issuer: no second registration.
    final again = await h0().client.registrar.resolve(await h0().discover(as), http: h0().transport);
    expect(again.clientId, reg.clientId);
    expect(as.registerRequests.length, 3);
  });

  test('32b: every rung rejected → RegistrationRejectedException with the last code', () async {
    as.registerHook = (_) => json({'error': 'invalid_client_metadata', 'error_description': 'nope'}, status: 400);
    await expectLater(resolve(id: withCimd),
        throwsA(isA<RegistrationRejectedException>().having((e) => e.errorCode, 'code', 'invalid_client_metadata')));
    expect(as.registerRequests.length, 3);
  });

  test('a 401 from DCR (initial access token required) stops the ladder', () async {
    as.registerHook = (_) => json({'error': 'invalid_token'}, status: 401);
    await expectLater(resolve(id: withCimd), throwsA(isA<RegistrationRejectedException>()));
    expect(as.registerRequests.length, 1);
  });

  test('a substituted redirect URI counts as a rejection', () async {
    var n = 0;
    as.registerHook = (body) {
      n++;
      if (n == 1) return json({...body, 'client_id': 'c1', 'redirect_uris': ['https://elsewhere.example/cb']}, status: 201);
      return null;
    };
    final reg = await resolve(id: withCimd);
    expect(reg.clientId, isNot('c1'));
    expect(n, 2);
  });

  test('DCR server errors are retryable and stop the ladder', () async {
    as.registerHook = (_) => Response.internalServerError();
    await expectLater(resolve(), throwsA(isA<AuthServerException>()));
    expect(as.registerRequests.length, 1);
  });

  test('concurrent resolutions share one registration request', () async {
    final h = harness = Harness(as: as);
    final m = await h.discover(as);
    final regs = await Future.wait([for (var i = 0; i < 5; i++) h.client.registrar.resolve(m, http: h.transport)]);
    expect(regs.map((r) => r.clientId).toSet().length, 1);
    expect(as.registerRequests.length, 1);
  });

  test('33: the DCR result is stored keyed by issuer; another issuer cannot read it', () async {
    final reg = await resolve();
    expect((await h0().store.readRegistration(as.issuer))!.clientId, reg.clientId);
    expect(await h0().store.readRegistration('${as.http.origin}/tenant2'), isNull);
    expect(await h0().store.readRegistration('${as.issuer}/'), isNull);
  });

  test('34: pre-registered credentials for another issuer are surfaced, not used', () async {
    await expectLater(
        resolve(pre: [const PreRegisteredClient(issuer: 'https://old-as.example', clientId: 'old')]),
        throwsA(isA<AuthorizationServerMismatchException>()
            .having((e) => e.configuredIssuers, 'configured', ['https://old-as.example'])));
    expect(as.registerRequests, isEmpty);
  });

  test('35: no CIMD and no registration endpoint → ClientIdRequiredException with the redirect to register', () async {
    as.dcrSupported = false;
    await expectLater(
        resolve(),
        throwsA(isA<ClientIdRequiredException>()
            .having((e) => e.redirectUri, 'redirect', 'io.github.mihok.sherpa:/oauth/callback')
            .having((e) => e.issuer, 'issuer', as.issuer)));
  });

  test('an expired DCR client secret triggers a new registration', () async {
    as.registerHook = (body) => json({...body, 'client_id': 'c-${as.registerRequests.length}', 'client_secret': 'S3CRET-VALUE', 'client_secret_expires_at': 1}, status: 201);
    final reg = await resolve();
    expect(reg.clientSecret, 'S3CRET-VALUE');
    expect(reg.secretExpired(h0().clock.now()), isTrue);
    await h0().client.registrar.resolve(await h0().discover(as), http: h0().transport);
    expect(as.registerRequests.length, 2);
  });

  group('token endpoint auth method selection (R02 §5.5)', () {
    ClientRegistration reg({String? secret, String method = 'none'}) => ClientRegistration(
        kind: RegistrationKind.dynamic, issuer: 'i', clientId: 'c', redirectUri: 'x.y:/z', clientSecret: secret, tokenEndpointAuthMethod: method);

    test('public clients always use none', () {
      expect(selectTokenEndpointAuthMethod(reg(), null), 'none');
      expect(selectTokenEndpointAuthMethod(reg(), ['client_secret_basic', 'client_secret_post']), 'none');
      expect(selectTokenEndpointAuthMethod(reg(method: 'client_secret_basic'), ['client_secret_basic']), 'none');
    });

    test('confidential clients: own method if supported, then basic > post > none', () {
      expect(selectTokenEndpointAuthMethod(reg(secret: 's', method: 'client_secret_post'), ['client_secret_post']), 'client_secret_post');
      expect(selectTokenEndpointAuthMethod(reg(secret: 's', method: 'client_secret_post'), []), 'client_secret_post');
      expect(selectTokenEndpointAuthMethod(reg(secret: 's', method: 'none'), ['client_secret_basic', 'none']), 'none');
      expect(selectTokenEndpointAuthMethod(reg(secret: 's', method: 'private_key_jwt'), ['client_secret_basic']), 'client_secret_basic');
      expect(selectTokenEndpointAuthMethod(reg(secret: 's', method: 'private_key_jwt'), ['client_secret_post']), 'client_secret_post');
      expect(selectTokenEndpointAuthMethod(reg(secret: 's', method: 'private_key_jwt'), ['none']), 'none');
      expect(selectTokenEndpointAuthMethod(reg(secret: 's', method: 'private_key_jwt'), null), 'client_secret_basic');
    });
  });

  group('SecretAuthStateStore', () {
    test('keys are hashed (no issuer, URL or state in key names) and values round-trip', () async {
      final secrets = InMemorySecretStore();
      final store = SecretAuthStateStore(secrets);
      final reg = ClientRegistration(
          kind: RegistrationKind.dynamic, issuer: as.issuer, clientId: 'cid', redirectUri: 'a.b:/c', clientSecret: 'S3CRET-VALUE');
      await store.writeRegistration(reg);
      final tokens = TokenSet(
        issuer: as.issuer,
        resource: 'https://mcp.example.com/mcp',
        clientId: 'cid',
        accessToken: 'ACCESS-VALUE-1',
        refreshToken: 'REFRESH-VALUE-1',
        tokenEndpoint: Uri.parse('${as.issuer}/token'),
        obtainedAt: DateTime.utc(2026),
        expiresAt: DateTime.utc(2026, 1, 1, 1),
        requestedScopes: const ['a', 'b'],
      );
      await store.writeTokens(tokens);
      final pending = PendingAuthorization(
        state: 'STATE-VALUE-123',
        codeVerifier: 'v' * 43,
        issuer: as.issuer,
        issParameterSupported: true,
        authorizationEndpoint: Uri.parse('${as.issuer}/authorize'),
        tokenEndpoint: Uri.parse('${as.issuer}/token'),
        clientId: 'cid',
        registrationKind: RegistrationKind.dynamic,
        redirectUri: 'a.b:/c',
        resource: 'https://mcp.example.com/mcp',
        scopes: const ['a'],
        purpose: AuthPurpose.initial,
        createdAt: DateTime.utc(2026),
        expiresAt: DateTime.utc(2026, 1, 1, 0, 10),
      );
      await store.writePending(pending);
      await store.writeBinding(ServerBinding(
          serverKey: 'https://mcp.example.com/mcp', resource: 'https://mcp.example.com/mcp', issuer: as.issuer, updatedAt: DateTime.utc(2026)));

      final keys = await secrets.keys();
      expect(keys, hasLength(4));
      for (final k in keys) {
        expect(k, startsWith('oauth/'));
        expect(k, isNot(contains('127.0.0.1')));
        expect(k, isNot(contains('STATE-VALUE')));
        expect(k, isNot(contains('mcp.example.com')));
      }
      expect(keys, contains('oauth/${SecretAuthStateStore.hash(as.issuer)}/client'));

      expect((await store.readRegistration(as.issuer))!.clientSecret, 'S3CRET-VALUE');
      expect((await store.readTokens(as.issuer, tokens.resource))!.toJson(), tokens.toJson());
      expect((await store.readPending('STATE-VALUE-123'))!.toJson(), pending.toJson());
      expect(await store.listTokens(resource: tokens.resource), hasLength(1));
      expect(await store.listTokens(resource: 'https://other.example'), isEmpty);
      expect(await store.listPending(), hasLength(1));
      expect((await store.readBinding('https://mcp.example.com/mcp'))!.issuer, as.issuer);

      // Corrupt values read as absent rather than crashing.
      await secrets.write('oauth/${SecretAuthStateStore.hash(as.issuer)}/client', '{not json');
      expect(await store.readRegistration(as.issuer), isNull);
      await secrets.write('oauth/${SecretAuthStateStore.hash(as.issuer)}/client', jsonEncode({'kind': 'gone'}));
      expect(await store.readRegistration(as.issuer), isNull);

      await store.deleteTokens(as.issuer, tokens.resource);
      await store.deletePending('STATE-VALUE-123');
      expect(await store.listTokens(), isEmpty);
      expect(await store.listPending(), isEmpty);
    });
  });
}
