import 'package:http/http.dart' as http;
import 'package:sherpa_auth/sherpa_auth.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  late FakeAuthServer as;
  late FakeMcpServer rs;
  late Harness h;
  late McpAuthorizer authz;
  late McpServerAuthConfig server;

  McpServerAuthConfig configFor(FakeMcpServer s, {bool allowMissingPkce = false, List<PreRegisteredClient> pre = const []}) =>
      McpServerAuthConfig(
        serverUrl: s.url,
        networkScope: NetworkScope.loopback,
        allowHttp: true,
        allowMissingPkceSupport: allowMissingPkce,
        preRegisteredClients: pre,
      );

  setUp(() async {
    as = await FakeAuthServer.start();
    rs = await FakeMcpServer.start(as);
    h = Harness(as: as);
    server = configFor(rs);
    authz = McpAuthorizer(oauth: h.client, serverConfig: (k) => k == server.serverKey ? server : null);
  });

  tearDown(() async {
    h.close();
    await rs.close();
    await as.close();
  });

  Future<http.Response> post(String op, String? token, {FakeMcpServer? to}) =>
      h.httpClient.post((to ?? rs).url, headers: {'x-op': op, 'authorization': ?(token == null ? null : 'Bearer $token')}, body: '{}');

  Future<McpAuthOutcome> react(http.Response r, {String? used, bool retried = false, String? op, McpServerAuthConfig? cfg}) =>
      authz.onResponse(cfg ?? server, statusCode: r.statusCode, headers: r.headers, usedAccessToken: used, retried: retried, operation: op);

  /// The first sign-in, as the UI would drive it.
  Future<String> signIn() async {
    final r = await post('read', null);
    expect(r.statusCode, 401);
    final o = await react(r) as McpNeedsUserConsent;
    final done = await authz.authorize(o.request) as McpAuthorized;
    return done.accessToken;
  }

  test('401 → consent → authorize → retry succeeds', () async {
    final r = await post('read', await authz.tokenFor(server));
    expect(r.statusCode, 401);
    final o = await react(r);
    expect(o, isA<McpNeedsUserConsent>());
    expect(h.browser.opened, isEmpty, reason: 'onResponse never opens a browser');
    final c = (o as McpNeedsUserConsent).request;
    expect(c.purpose, AuthPurpose.initial);
    expect(c.scopes, ['files:read', 'offline_access']);
    expect(c.issuer, as.issuer);
    expect(c.authorizationServerHost, '127.0.0.1');
    expect(c.resource, rs.resource);
    expect(c.resourceName, 'Example Files');
    expect(c.pkceOverrideInEffect, isFalse);

    final done = await authz.authorize(c);
    expect(done, isA<McpAuthorized>());
    final token = (done as McpAuthorized).accessToken;
    expect(done.authorizationHeader, 'Bearer $token');
    expect(done.toString(), isNot(contains(token)));
    expect((await post('read', token)).statusCode, 200);
    expect(await authz.tokenFor(server), token);
    expect(as.authorizeRequests.single['resource'], rs.resource);
    expect(as.tokenRequests.single.form['resource'], rs.resource);
  });

  test('63: Authorization is never sent to metadata URLs or AS endpoints', () async {
    await signIn();
    for (final r in [...rs.http.requests.where((r) => r.method == 'GET'), ...as.http.requests]) {
      expect(r.authorization, isNull, reason: r.toString());
    }
  });

  group('step-up (A26 L379-405)', () {
    test('52: 403 insufficient_scope → union scopes, interactive (no refresh), one retry', () async {
      final t0 = await signIn();
      final r = await post('write', t0);
      expect(r.statusCode, 403);
      final o = await react(r, used: t0, op: 'tools/call:write') as McpNeedsUserConsent;
      expect(o.request.purpose, AuthPurpose.stepUp);
      expect(o.request.scopes, ['files:read', 'offline_access', 'files:write']);
      expect(as.refreshRequests, isEmpty, reason: 'a refresh cannot widen scope');
      final done = await authz.authorize(o.request) as McpAuthorized;
      expect(as.authorizeRequests.last['scope'], 'files:read offline_access files:write');
      expect((await post('write', done.accessToken)).statusCode, 200);
    });

    test('53: the same 403 after step-up stops with "permission not granted"', () async {
      as.grantScopes = (requested) => requested.where((s) => s != 'files:write').toList();
      final t0 = await signIn();
      final o = await react(await post('write', t0), used: t0, op: 'w') as McpNeedsUserConsent;
      final done = await authz.authorize(o.request) as McpAuthorized;
      final again = await post('write', done.accessToken);
      expect(again.statusCode, 403);
      final last = await react(again, used: done.accessToken, op: 'w');
      expect(last, isA<McpAuthFailed>().having((f) => f.reason, 'reason', McpAuthFailure.insufficientScope));
      expect(h.browser.opened.length, 2);
    });

    test('a 403 naming scopes the token already has is not retried', () async {
      final t0 = await signIn();
      final fake = http.Response('', 403, headers: {'www-authenticate': 'Bearer error="insufficient_scope", scope="files:read"'});
      expect(await react(fake, used: t0), isA<McpAuthFailed>().having((f) => f.reason, 'reason', McpAuthFailure.insufficientScope));
    });

    test('54: a 403 without insufficient_scope is not an auth signal', () async {
      for (final headers in [
        const <String, String>{},
        {'www-authenticate': 'Bearer error="invalid_token"'},
        {'www-authenticate': 'Basic realm="x"'},
      ]) {
        final o = await react(http.Response('forbidden', 403, headers: headers));
        expect(o, isA<McpAuthFailed>().having((f) => f.reason, 'reason', McpAuthFailure.notAnAuthChallenge));
      }
      expect(h.browser.opened, isEmpty);
      expect(rs.http.requests, isEmpty, reason: 'no discovery either');
    });

    test('56: a declined step-up becomes a tool error without a browser', () async {
      final t0 = await signIn();
      final o = await react(await post('write', t0), used: t0, op: 'w') as McpNeedsUserConsent;
      authz.decline(o.request);
      final again = await react(await post('write', t0), used: t0, op: 'w');
      expect(again, isA<McpAuthFailed>().having((f) => f.reason, 'reason', McpAuthFailure.stepUpDeclined));
      expect(h.browser.opened.length, 1);
      // The denial is remembered only for a while.
      h.clock.advance(const Duration(minutes: 11));
      expect(await react(await post('write', t0), used: t0, op: 'w'), isA<McpNeedsUserConsent>());
    });
  });

  test('55: 401 → authorize → 401 again on the retry trips the circuit breaker', () async {
    final token = await signIn();
    rs.revoked.add(token);
    final r = await post('read', token);
    expect(r.statusCode, 401);
    final o = await react(r, used: token, retried: true);
    expect(o, isA<McpAuthFailed>().having((f) => f.reason, 'reason', McpAuthFailure.unauthorizedAfterAuthorization));
    expect(as.refreshRequests, isEmpty);
  });

  test('55b: a token minted moments ago being rejected trips the breaker without a `retried` flag', () async {
    final token = await signIn();
    rs.revoked.add(token);
    final o = await react(await post('read', token));
    expect(o, isA<McpAuthFailed>().having((f) => f.reason, 'reason', McpAuthFailure.unauthorizedAfterAuthorization));
    expect(as.refreshRequests, isEmpty);
  });

  test('a transport that cannot report the token used still gets a refresh (seam with no usedAccessToken)', () async {
    await signIn();
    h.clock.advance(const Duration(minutes: 5));
    final sent = await authz.tokenFor(server);
    rs.revoked.add(sent!);
    final o = await authz.onResponse(server, statusCode: 401, headers: (await post('read', sent)).headers);
    expect(o, isA<McpAuthorized>());
    expect((o as McpAuthorized).accessToken, isNot(sent));
    expect(as.refreshRequests, hasLength(1));
    expect(await authz.tokenFor(server), o.accessToken);
    // The retry with the new token fails too → breaker, no second refresh.
    rs.revoked.add(o.accessToken);
    final again = await authz.onResponse(server, statusCode: 401, headers: (await post('read', o.accessToken)).headers);
    expect(again, isA<McpAuthFailed>().having((f) => f.reason, 'reason', McpAuthFailure.unauthorizedAfterAuthorization));
    expect(as.refreshRequests, hasLength(1));
  });

  test('48 (MCP): ten concurrent 401s share exactly one refresh', () async {
    final token = await signIn();
    h.clock.advance(const Duration(minutes: 5));
    rs.revoked.add(token);
    as.tokenDelay = const Duration(milliseconds: 50);
    final responses = await Future.wait([for (var i = 0; i < 10; i++) post('read', token)]);
    expect(responses.map((r) => r.statusCode).toSet(), {401});
    final outcomes = await Future.wait([for (final r in responses) react(r, used: token)]);
    expect(as.refreshRequests.length, 1);
    final tokens = {for (final o in outcomes) (o as McpAuthorized).accessToken};
    expect(tokens, hasLength(1));
    expect((await post('read', tokens.single)).statusCode, 200);
    // A straggler holding the old token reuses the new one without a request.
    final late = await react(responses.first, used: token);
    expect((late as McpAuthorized).accessToken, tokens.single);
    expect(as.refreshRequests.length, 1);
  });

  test('49 (MCP): offline during refresh → failed(network), tokens kept, no consent, no browser', () async {
    final token = await signIn();
    h.clock.advance(const Duration(minutes: 5));
    rs.revoked.add(token);
    final r = await post('read', token);
    await as.close();
    final o = await react(r, used: token);
    expect(o, isA<McpAuthFailed>().having((f) => f.reason, 'reason', McpAuthFailure.network).having((f) => f.retryable, 'retryable', isTrue));
    expect(h.browser.opened.length, 1);
    final b = (await h.store.readBinding(server.serverKey))!;
    expect(await h.store.readTokens(b.issuer, b.resource), isNotNull);
    as = await FakeAuthServer.start();
  });

  test('invalid_grant on the reactive refresh → consent to re-authorize', () async {
    final token = await signIn();
    h.clock.advance(const Duration(minutes: 5));
    rs.revoked.add(token);
    as.tokenHook = (f) => f['grant_type'] == 'refresh_token' ? json({'error': 'invalid_grant'}, status: 400) : null;
    final o = await react(await post('read', token), used: token);
    expect(o, isA<McpNeedsUserConsent>().having((c) => c.request.purpose, 'purpose', AuthPurpose.reauthorize));
    expect(h.browser.opened.length, 1);
  });

  test('18: a changed resource_metadata re-discovers; an AS change drops the old grant', () async {
    final token = await signIn();
    final as2 = await FakeAuthServer.start(tenantPath: '/tenant2');
    addTearDown(as2.close);
    h.browser.onAuthorize = (url) async => as2.approve(url);
    rs.http.route('GET /.well-known/oauth-protected-resource/v2', (r, _) => json({...rs.prm, 'authorization_servers': [as2.issuer]}));
    rs.headerMetadataUrl = '${rs.http.origin}/.well-known/oauth-protected-resource/v2';
    rs.revoked.add(token);
    final o = await react(await post('read', token), used: token);
    expect(o, isA<McpNeedsUserConsent>());
    expect((o as McpNeedsUserConsent).request.issuer, as2.issuer);
    expect(await h.store.readTokens(as.issuer, rs.resource), isNull, reason: 'old AS grant dropped');
    expect(as.refreshRequests, isEmpty, reason: 'the old refresh token is never sent anywhere');
    final b = (await h.store.readBinding(server.serverKey))!;
    expect(b.issuer, as2.issuer);
    expect(b.resourceMetadataUrl, rs.headerMetadataUrl);
    final done = await authz.authorize(o.request);
    expect(done, isA<McpAuthorized>());
    expect(as2.tokenRequests, hasLength(1));
  });

  test('AS selection: the first authorization server that validates and supports PKCE wins', () async {
    final noPkce = await FakeAuthServer.start(tenantPath: '/nopkce');
    addTearDown(noPkce.close);
    noPkce.editMetadata = (m) => {...m}..remove('code_challenge_methods_supported');
    rs.authorizationServers = [noPkce.issuer, as.issuer];
    final o = await react(await post('read', null)) as McpNeedsUserConsent;
    expect(o.request.issuer, as.issuer);

    rs.authorizationServers = [noPkce.issuer];
    final fresh = McpAuthorizer(oauth: h.client);
    final failed = await fresh.onResponse(server, statusCode: 401, headers: (await post('read', null)).headers);
    expect(failed, isA<McpAuthFailed>().having((f) => f.reason, 'reason', McpAuthFailure.pkceUnsupported));
    expect(((failed as McpAuthFailed).cause! as PkceNotSupportedException).overridable, isTrue);
  });

  test('the per-server PKCE override proceeds and is flagged on the consent', () async {
    as.editMetadata = (m) => {...m}..remove('code_challenge_methods_supported');
    server = configFor(rs, allowMissingPkce: true);
    final o = await react(await post('read', null)) as McpNeedsUserConsent;
    expect(o.request.pkceOverrideInEffect, isTrue);
    expect(await authz.authorize(o.request), isA<McpAuthorized>());
  });

  test('pre-registered credentials for another AS are surfaced', () async {
    server = configFor(rs, pre: const [PreRegisteredClient(issuer: 'https://other-as.example', clientId: 'x')]);
    final o = await react(await post('read', null));
    expect(o, isA<McpAuthFailed>().having((f) => f.reason, 'reason', McpAuthFailure.authorizationServerMismatch));
  });

  test('62: a token for server A is never offered for server B on the same AS', () async {
    final rsB = await FakeMcpServer.start(as, path: '/other');
    addTearDown(rsB.close);
    final serverB = configFor(rsB);
    final tokenA = await signIn();
    expect(await authz.tokenFor(serverB), isNull);
    expect((await post('read', tokenA, to: rsB)).statusCode, 401, reason: 'audience-bound');
    final o = await react(await post('read', null, to: rsB), cfg: serverB) as McpNeedsUserConsent;
    expect(o.request.resource, rsB.resource);
    final tokenB = (await authz.authorize(o.request) as McpAuthorized).accessToken;
    expect(tokenB, isNot(tokenA));
    expect(await authz.tokenFor(server), tokenA);
    expect(await authz.tokenFor(serverB), tokenB);
  });

  test('64: sign-out wipes tokens, pending flows and the binding; the shared registration stays', () async {
    await signIn();
    await h.client.prepareAuthorization(AuthorizationSpec(
      server: await h.discover(as),
      resource: rs.resource,
      serverKey: server.serverKey,
    ));
    expect(await h.store.listPending(), hasLength(1));
    await authz.signOut(server);
    expect(await authz.tokenFor(server), isNull);
    expect(await h.store.listTokens(), isEmpty);
    expect(await h.store.listPending(), isEmpty);
    expect(await h.store.readBinding(server.serverKey), isNull);
    expect(await h.store.readRegistration(as.issuer), isNotNull);
    expect(as.http.to('/tenant1/revoke'), hasLength(1));
  });

  test('a flow resumed after process death completes through completeFromCallback', () async {
    final store = SecretAuthStateStore(InMemorySecretStore());
    final first = Harness(as: as, store: store);
    final firstAuthz = McpAuthorizer(oauth: first.client);
    final o = await firstAuthz.onResponse(server, statusCode: 401, headers: (await post('read', null)).headers) as McpNeedsUserConsent;
    // The flow is recorded and the user approves in the browser, but the OS
    // kills the app before the callback is handled.
    final prepared = await first.client.prepareAuthorization(AuthorizationSpec(
      server: o.request.authorizationServer,
      resource: o.request.resource,
      scopes: o.request.scopes,
      serverKey: server.serverKey,
      policy: server.networkPolicy(),
    ));
    final callback = as.approve(prepared.url);
    first.close();

    final second = Harness(as: as, store: store, clock: first.clock);
    addTearDown(second.close);
    final secondAuthz = McpAuthorizer(oauth: second.client, serverConfig: (k) => k == server.serverKey ? server : null);
    final done = await secondAuthz.completeFromCallback(callback);
    expect(done, isA<McpAuthorized>());
    expect(await secondAuthz.tokenFor(server), (done as McpAuthorized).accessToken);
  });

  test('from the background the consent is reported but authorize refuses', () async {
    final bg = Harness(as: as, canInteract: () => false);
    addTearDown(bg.close);
    final bgAuthz = McpAuthorizer(oauth: bg.client);
    final o = await bgAuthz.onResponse(server, statusCode: 401, headers: (await post('read', null)).headers);
    expect(o, isA<McpNeedsUserConsent>());
    final r = await bgAuthz.authorize((o as McpNeedsUserConsent).request);
    expect(r, isA<McpAuthFailed>().having((f) => f.reason, 'reason', McpAuthFailure.interactionNotAllowed));
    expect(bg.browser.opened, isEmpty);
  });

  test('an explicit "Sign in" builds consent without a 401', () async {
    final o = await authz.consentFor(server);
    expect(o, isA<McpNeedsUserConsent>());
    expect((o as McpNeedsUserConsent).request.scopes, ['files:read', 'files:write', 'offline_access']);
  });

  test('a user cancelling the browser is reported as cancelled', () async {
    final o = await react(await post('read', null)) as McpNeedsUserConsent;
    h.browser.onAuthorize = (_) async => throw AuthCancelledException();
    expect(await authz.authorize(o.request), isA<McpAuthFailed>().having((f) => f.reason, 'reason', McpAuthFailure.cancelled));
  });

  test('non-auth statuses are not auth signals', () async {
    expect(await react(http.Response('', 500)), isA<McpAuthFailed>().having((f) => f.reason, 'reason', McpAuthFailure.notAnAuthChallenge));
  });

  test('a server whose PRM names another origin is refused', () async {
    rs.editPrm = (m) => {...m, 'resource': 'https://victim.example/mcp'};
    final o = await react(await post('read', null));
    expect(o, isA<McpAuthFailed>().having((f) => f.reason, 'reason', McpAuthFailure.discovery));
    expect(((o as McpAuthFailed).cause! as DiscoveryException).failure, DiscoveryFailure.resourceMismatch);
  });

  test('a public server with publicOnly scope cannot reach loopback metadata', () async {
    final strict = McpServerAuthConfig(serverUrl: rs.url, allowHttp: true);
    final o = await authz.onResponse(strict, statusCode: 401, headers: (await post('read', null)).headers);
    expect(o, isA<McpAuthFailed>().having((f) => f.reason, 'reason', McpAuthFailure.policyBlocked));
    expect(rs.http.requests.where((r) => r.method == 'GET'), isEmpty);
  });

  test('the step-up response header also refreshes stale metadata', () async {
    final t0 = await signIn();
    rs.http.route('GET /.well-known/oauth-protected-resource/moved', (r, _) => json(rs.prm));
    final fake = http.Response('', 403, headers: {
      'www-authenticate': 'Bearer error="insufficient_scope", scope="files:write", '
          'resource_metadata="${rs.http.origin}/.well-known/oauth-protected-resource/moved"',
    });
    final o = await react(fake, used: t0, op: 'w');
    expect(o, isA<McpNeedsUserConsent>());
    expect(rs.http.paths, contains('/.well-known/oauth-protected-resource/moved'));
  });
}
