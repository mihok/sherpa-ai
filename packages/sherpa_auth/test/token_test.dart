import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:sherpa_auth/sherpa_auth.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

const resource = 'https://mcp.example.com/mcp';

void main() {
  late FakeAuthServer as;
  late Harness h;
  late AuthorizationServerMetadata meta;

  setUp(() async {
    as = await FakeAuthServer.start();
    h = Harness(as: as);
    meta = await h.discover(as);
  });

  tearDown(() async {
    h.close();
    await as.close();
  });

  Future<TokenSet> signIn({List<String> scopes = const ['files:read', 'offline_access'], ClientRegistration? client}) =>
      h.client.authorize(AuthorizationSpec(server: meta, resource: resource, scopes: scopes, client: client));

  test('44: form encoding and client_id for public clients', () async {
    await signIn(scopes: ['files:read', 'a b+c&d=e']);
    final r = as.tokenRequests.single;
    expect(r.headers['content-type'], startsWith('application/x-www-form-urlencoded'));
    expect(r.body, contains('redirect_uri=io.github.mihok.sherpa%3A%2Foauth%2Fcallback'));
    expect(r.body, contains('resource=https%3A%2F%2Fmcp.example.com%2Fmcp'));
    expect(r.form['client_id'], isNotEmpty);
    expect(r.form.containsKey('client_secret'), isFalse);
    expect(as.authorizeRequests.single['scope'], 'files:read a b+c&d=e');
  });

  test('44b: client_secret_basic uses RFC 6749 §2.3.1 form-encoding before base64', () async {
    const id = 'my app:1';
    const secret = 'p@ss:w/rd+%';
    as.secrets[id] = secret;
    final client = ClientRegistration(
      kind: RegistrationKind.preRegistered,
      issuer: as.issuer,
      clientId: id,
      clientSecret: secret,
      redirectUri: identity.redirectUri,
      tokenEndpointAuthMethod: 'client_secret_basic',
    );
    await signIn(client: client);
    final auth = as.tokenRequests.single.authorization!;
    expect(auth, startsWith('Basic '));
    final decoded = utf8.decode(base64.decode(auth.substring(6)));
    expect(decoded, '${Uri.encodeQueryComponent(id)}:${Uri.encodeQueryComponent(secret)}');
    expect(as.tokenRequests.single.form.containsKey('client_id'), isFalse);
  });

  test('44c: client_secret_post sends id and secret in the body', () async {
    as.secrets['post-client'] = 'POST-SECRET-1';
    await signIn(
        client: ClientRegistration(
      kind: RegistrationKind.preRegistered,
      issuer: as.issuer,
      clientId: 'post-client',
      clientSecret: 'POST-SECRET-1',
      redirectUri: identity.redirectUri,
      tokenEndpointAuthMethod: 'client_secret_post',
    ));
    final f = as.tokenRequests.single.form;
    expect(f['client_id'], 'post-client');
    expect(f['client_secret'], 'POST-SECRET-1');
    expect(as.tokenRequests.single.authorization, isNull);
  });

  test('45: a missing scope means granted = requested; bearer is case-insensitive; other types are rejected', () async {
    as.includeScopeInResponse = false;
    as.tokenType = 'bearer';
    final t = await signIn(scopes: ['files:read']);
    expect(t.grantedScopes, isNull);
    expect(t.effectiveScopes, ['files:read']);
    expect(t.tokenType, 'Bearer');

    as.tokenType = 'mac';
    await expectLater(signIn(), throwsA(isA<AuthProtocolException>()));
    as.tokenType = 'DPoP';
    await expectLater(signIn(), throwsA(isA<AuthProtocolException>()));
  });

  group('46: token endpoint error mapping', () {
    Future<Object?> failWith(Response Function() response) async {
      as.tokenHook = (_) => response();
      try {
        await signIn();
      } on Object catch (e) {
        return e;
      }
      return null;
    }

    test('invalid_grant', () async {
      final e = await failWith(() => json({'error': 'invalid_grant', 'error_description': 'code expired'}, status: 400));
      expect(e, isA<TokenEndpointException>().having((e) => e.isInvalidGrant, 'grant', isTrue).having((e) => e.description, 'desc', 'code expired'));
    });

    test('invalid_client on 400 and on 401 (with and without a body)', () async {
      expect(await failWith(() => json({'error': 'invalid_client'}, status: 400)), isA<InvalidClientException>());
      expect(await failWith(() => json({'error': 'invalid_client'}, status: 401)), isA<InvalidClientException>());
      expect(await failWith(() => Response(401, body: 'nope')), isA<InvalidClientException>());
    });

    test('invalid_target', () async {
      expect(await failWith(() => json({'error': 'invalid_target'}, status: 400)),
          isA<TokenEndpointException>().having((e) => e.error, 'error', 'invalid_target'));
    });

    test('a 200 carrying an error is an error', () async {
      expect(await failWith(() => json({'error': 'invalid_scope'})),
          isA<TokenEndpointException>().having((e) => e.error, 'error', 'invalid_scope'));
    });

    test('non-JSON 5xx and server_error are retryable server errors', () async {
      expect(await failWith(() => Response(503, body: '<html>down</html>')),
          isA<AuthServerException>().having((e) => e.retryable, 'retryable', isTrue));
      expect(await failWith(() => json({'error': 'temporarily_unavailable'}, status: 400)), isA<AuthServerException>());
    });

    test('non-JSON 200, unknown statuses and malformed error codes', () async {
      expect(await failWith(() => Response.ok('<html>')), isA<AuthProtocolException>());
      expect(await failWith(() => Response(418)), isA<AuthProtocolException>());
      expect(await failWith(() => json({'error': 'bad"code\\'}, status: 400)),
          isA<TokenEndpointException>().having((e) => e.error, 'error', 'invalid_error_code'));
      expect(await failWith(() => json({'token_type': 'Bearer'})), isA<AuthProtocolException>());
    });

    test('a token endpoint redirect is not followed', () async {
      final other = await FakeHttp.start();
      addTearDown(other.close);
      expect(await failWith(() => Response(307, headers: {'location': '${other.origin}/token'})), isA<AuthProtocolException>());
      expect(other.requests, isEmpty);
    });
  });

  group('refresh', () {
    test('47: refresh sends resource; a rotated refresh token replaces the old one; none returned keeps it', () async {
      final t0 = await signIn();
      h.clock.advance(const Duration(hours: 2));
      final t1 = (await h.client.refresh(as.issuer, resource));
      final req = as.refreshRequests.single.form;
      expect(req['resource'], resource);
      expect(req['refresh_token'], t0.refreshToken);
      expect(req.containsKey('scope'), isFalse, reason: 'refresh can never widen scope');
      expect(t1.refreshToken, isNot(t0.refreshToken));
      expect((await h.store.readTokens(as.issuer, resource))!.refreshToken, t1.refreshToken);

      as.rotateRefreshTokens = false;
      final t2 = await h.client.refresh(as.issuer, resource);
      expect(t2.refreshToken, t1.refreshToken);
      expect(t2.accessToken, isNot(t1.accessToken));
    });

    test('48: concurrent callers share a single refresh request', () async {
      await signIn();
      h.clock.advance(const Duration(hours: 2));
      as.tokenDelay = const Duration(milliseconds: 100);
      final tokens = await Future.wait([for (var i = 0; i < 10; i++) h.client.accessTokenFor(resource)]);
      expect(as.refreshRequests.length, 1);
      expect(tokens.toSet().length, 1);
      expect(tokens.first, isNotNull);
    });

    test('a later caller holding the replaced access token does not refresh again', () async {
      final t0 = await signIn();
      await h.client.refresh(as.issuer, resource, ifAccessTokenIs: t0.accessToken);
      final again = await h.client.refresh(as.issuer, resource, ifAccessTokenIs: t0.accessToken);
      expect(as.refreshRequests.length, 1);
      expect(again.accessToken, isNot(t0.accessToken));
    });

    test('49: a network error during refresh keeps the tokens and never opens a browser', () async {
      final t0 = await signIn();
      final opened = h.browser.opened.length;
      h.clock.advance(const Duration(hours: 2));
      await as.close();
      await expectLater(h.client.accessTokenFor(resource),
          throwsA(isA<AuthNetworkException>().having((e) => e.retryable, 'retryable', isTrue)));
      expect(h.browser.opened.length, opened);
      expect((await h.store.readTokens(as.issuer, resource))!.refreshToken, t0.refreshToken);
      as = await FakeAuthServer.start(); // for tearDown
    });

    test('a 5xx during refresh keeps the tokens', () async {
      final t0 = await signIn();
      h.clock.advance(const Duration(hours: 2));
      as.tokenHook = (_) => Response(502);
      await expectLater(h.client.accessTokenFor(resource), throwsA(isA<AuthServerException>()));
      expect((await h.store.readTokens(as.issuer, resource))!.refreshToken, t0.refreshToken);
    });

    test('50: invalid_grant deletes the tokens → sign-in required', () async {
      await signIn();
      h.clock.advance(const Duration(hours: 2));
      as.tokenHook = (_) => json({'error': 'invalid_grant'}, status: 400);
      expect(await h.client.accessTokenFor(resource), isNull);
      expect(await h.store.readTokens(as.issuer, resource), isNull);
      await expectLater(h.client.refresh(as.issuer, resource),
          throwsA(isA<SignInRequiredException>().having((e) => e.reason, 'reason', SignInReason.notSignedIn)));
      expect(h.browser.opened.length, 1, reason: 'only the original sign-in');
    });

    test('51: proactive refresh at expires_at - skew via the fake clock', () async {
      final t0 = await signIn();
      h.clock.advance(const Duration(minutes: 58));
      expect(await h.client.accessTokenFor(resource), t0.accessToken);
      expect(as.refreshRequests, isEmpty);
      h.clock.advance(const Duration(minutes: 1, seconds: 1));
      final next = await h.client.accessTokenFor(resource);
      expect(next, isNot(t0.accessToken));
      expect(as.refreshRequests.length, 1);
    });

    test('expired without a refresh token → null, no request', () async {
      as.issueRefreshTokens = false;
      final t = await signIn();
      expect(t.canRefresh, isFalse);
      h.clock.advance(const Duration(hours: 2));
      expect(await h.client.accessTokenFor(resource), isNull);
      expect(as.refreshRequests, isEmpty);
    });

    test('tokens without expires_in stay usable until a 401', () async {
      as.expiresIn = null;
      final t = await signIn();
      h.clock.advance(const Duration(days: 30));
      expect(await h.client.accessTokenFor(resource), t.accessToken);
    });

    test('reuse detection: presenting a rotated-out refresh token revokes the grant', () async {
      final t0 = await signIn();
      await h.client.refresh(as.issuer, resource);
      final current = (await h.store.readTokens(as.issuer, resource))!;
      // A stale copy (e.g. restored backup or a second process) reuses t0.
      await h.store.writeTokens(t0);
      h.clock.advance(const Duration(hours: 2));
      expect(await h.client.accessTokenFor(resource), isNull);
      expect(await h.store.readTokens(as.issuer, resource), isNull);
      // The AS revoked the whole grant, including the newest refresh token.
      expect(as.refreshTokens[current.refreshToken]!.revoked, isTrue);
    });

    test('invalid_client on refresh drops a DCR registration once, then becomes fatal', () async {
      final t0 = await signIn();
      final firstClient = t0.clientId;
      as.rejectedClients.add(firstClient);
      await expectLater(h.client.refresh(as.issuer, resource),
          throwsA(isA<InvalidClientException>().having((e) => e.recovered, 'recovered', isTrue).having((e) => e.requiresSignIn, 'signIn', isTrue)));
      expect(await h.store.readRegistration(as.issuer), isNull);
      expect(await h.store.readTokens(as.issuer, resource), isNull);

      // The next user-initiated sign-in registers afresh.
      final t1 = await signIn();
      expect(t1.clientId, isNot(firstClient));
      expect(as.registerRequests.length, 2);

      as.rejectedClients.add(t1.clientId);
      await expectLater(h.client.refresh(as.issuer, resource),
          throwsA(isA<InvalidClientException>().having((e) => e.recovered, 'recovered', isFalse)));
      expect(await h.store.readRegistration(as.issuer), isNotNull, reason: 'dropped only once');
    });

    test('invalid_client for a grant whose client was replaced leaves the current registration alone', () async {
      final t0 = await signIn();
      final replacement = ClientRegistration(
          kind: RegistrationKind.dynamic, issuer: as.issuer, clientId: 'newer-client', redirectUri: identity.redirectUri);
      await h.store.writeRegistration(replacement);
      as.rejectedClients.add(t0.clientId);
      await expectLater(h.client.refresh(as.issuer, resource),
          throwsA(isA<InvalidClientException>().having((e) => e.recovered, 'recovered', isTrue)));
      expect(as.refreshRequests.single.form['client_id'], t0.clientId, reason: 'the grant is refreshed by its own client');
      expect((await h.store.readRegistration(as.issuer))!.clientId, 'newer-client');
      expect(await h.store.readTokens(as.issuer, resource), isNull);
    });

    test('onInsufficientScope: union of requested, granted and challenged; null when already covered', () async {
      as.grantScopes = (r) => [...r.where((s) => s != 'offline_access'), 'extra:granted'];
      await signIn(scopes: ['files:read', 'offline_access']);
      final write = BearerChallenge.parse('Bearer error="insufficient_scope", scope="files:write"')!;
      expect(await h.client.onInsufficientScope(write, resource: resource),
          ['files:read', 'offline_access', 'extra:granted', 'files:write']);
      final covered = BearerChallenge.parse('Bearer error="insufficient_scope", scope="files:read"')!;
      expect(await h.client.onInsufficientScope(covered, resource: resource), isNull);
      expect(await h.client.onInsufficientScope(write, resource: 'https://never-signed-in.example'), ['files:write']);
    });

    test('invalid_client never drops a pre-registered client', () async {
      final client = ClientRegistration(
          kind: RegistrationKind.preRegistered, issuer: as.issuer, clientId: 'pre', redirectUri: identity.redirectUri);
      await signIn(client: client);
      as.rejectedClients.add('pre');
      await expectLater(h.client.refresh(as.issuer, resource),
          throwsA(isA<InvalidClientException>().having((e) => e.recovered, 'recovered', isFalse)));
      expect((await h.store.readRegistration(as.issuer))!.clientId, 'pre');
    });

    test('sign-out revokes the refresh token (RFC 7009) and wipes the grant', () async {
      final t = await signIn();
      await h.client.signOut(resource);
      final revoke = as.http.to('/tenant1/revoke').single.form;
      expect(revoke['token'], t.refreshToken);
      expect(revoke['token_type_hint'], 'refresh_token');
      expect(await h.store.readTokens(as.issuer, resource), isNull);
      expect(await h.store.readRegistration(as.issuer), isNotNull, reason: 'registration is per issuer and may be shared');
    });
  });
}
