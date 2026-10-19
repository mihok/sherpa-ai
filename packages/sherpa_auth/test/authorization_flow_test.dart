import 'dart:math';

import 'package:sherpa_auth/sherpa_auth.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

const resource = 'https://mcp.example.com';

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

  AuthorizationSpec spec({
    List<String> scopes = const ['files:read', 'offline_access'],
    bool allowMissingPkce = false,
    AuthorizationServerMetadata? server,
    String res = resource,
    bool ephemeral = false,
  }) =>
      AuthorizationSpec(
        server: server ?? meta,
        resource: res,
        scopes: scopes,
        allowMissingPkce: allowMissingPkce,
        ephemeral: ephemeral,
        serverKey: 'https://mcp.example.com',
      );

  group('PKCE (RFC 7636)', () {
    test('36: the App. B vector and verifier constraints', () {
      expect(Pkce.challengeFor('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'), 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
      final p = Pkce.generate(Random.secure());
      expect(p.verifier.length, greaterThanOrEqualTo(43));
      expect(p.verifier.length, lessThanOrEqualTo(128));
      expect(RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(p.verifier), isTrue);
      expect(p.challenge, Pkce.challengeFor(p.verifier));
      expect(p.challenge.contains('='), isFalse);
      expect(() => Pkce.fromVerifier('a' * 42), throwsArgumentError);
      expect(() => Pkce.fromVerifier('a' * 129), throwsArgumentError);
      expect(() => Pkce.fromVerifier('${'a' * 42}+'), throwsArgumentError);
      expect(Pkce.fromVerifier('a' * 128).verifier.length, 128);
      expect(p.toString(), isNot(contains(p.verifier)));
    });
  });

  group('authorization request', () {
    test('37: the URL carries every required parameter; resource is verbatim', () async {
      final prepared = await h.client.prepareAuthorization(spec());
      final q = prepared.url.queryParameters;
      final pending = prepared.pending;
      expect(prepared.url.replace(query: '').toString().replaceAll('?', ''), '${as.issuer}/authorize');
      expect(q['response_type'], 'code');
      expect(q['client_id'], pending.clientId);
      expect(q['redirect_uri'], 'io.github.mihok.sherpa:/oauth/callback');
      expect(q['code_challenge'], Pkce.challengeFor(pending.codeVerifier));
      expect(q['code_challenge_method'], 'S256');
      expect(q['state'], pending.state);
      expect(q['state']!.length, greaterThanOrEqualTo(43)); // 256 bits
      expect(q['scope'], 'files:read offline_access');
      expect(q['resource'], 'https://mcp.example.com');
      expect(q['prompt'], 'consent');
      expect(q.containsKey('nonce'), isFalse);
      expect(pending.issuer, as.issuer);
      expect(pending.issParameterSupported, isTrue);
      expect(pending.tokenEndpoint.toString(), '${as.issuer}/token');
    });

    test('without PRM the resource is the canonical server URI and is still sent', () async {
      final res = canonicalResourceUri(Uri.parse('HTTPS://MCP.Example.com:443/#frag'));
      expect(res, 'https://mcp.example.com');
      expect(canonicalResourceUri(Uri.parse('https://mcp.example.com:8443/server/mcp')), 'https://mcp.example.com:8443/server/mcp');
      final prepared = await h.client.prepareAuthorization(spec(res: res));
      expect(prepared.url.queryParameters['resource'], 'https://mcp.example.com');
    });

    test('the authorization endpoint query is retained and protocol params cannot be overridden', () async {
      as.editMetadata = (m) => {...m, 'authorization_endpoint': '${as.issuer}/authorize?tenant=blue'};
      final m = await h.discover(as);
      final prepared = await h.client.prepareAuthorization(AuthorizationSpec(
        server: m,
        resource: resource,
        extraParameters: const {'orgIds': 'o1', 'state': 'attacker', 'redirect_uri': 'evil.app:/x'},
      ));
      final q = prepared.url.queryParameters;
      expect(q['tenant'], 'blue');
      expect(q['orgIds'], 'o1');
      expect(q['state'], prepared.pending.state);
      expect(q['redirect_uri'], 'io.github.mihok.sherpa:/oauth/callback');
    });

    test('38: scope selection: challenge > PRM scopes_supported > omitted; offline_access only when listed', () {
      expect(selectScopes(challenged: ['a'], resourceScopesSupported: ['b', 'c'], serverScopesSupported: ['offline_access']), ['a', 'offline_access']);
      expect(selectScopes(resourceScopesSupported: ['b', 'c']), ['b', 'c']);
      expect(selectScopes(resourceScopesSupported: ['b'], serverScopesSupported: ['b']), ['b']);
      expect(selectScopes(), isEmpty);
      expect(selectScopes(serverScopesSupported: ['offline_access']), isEmpty, reason: 'never offline_access alone');
      expect(selectScopes(challenged: ['a', 'offline_access'], serverScopesSupported: ['offline_access']), ['a', 'offline_access']);
      expect(selectScopes(challenged: ['a'], serverScopesSupported: ['offline_access'], requestOfflineAccess: false), ['a']);
      expect(unionScopes([['a', 'b'], ['b', 'c'], ['a', 'd']]), ['a', 'b', 'c', 'd']);
      expect(splitScopes('  a  b\ta  '), ['a', 'b']);
    });

    test('38b: prompt=consent only with offline_access; scope omitted when empty; nonce only with openid', () async {
      final noOffline = await h.client.prepareAuthorization(spec(scopes: ['files:read']));
      expect(noOffline.url.queryParameters.containsKey('prompt'), isFalse);
      final none = await h.client.prepareAuthorization(spec(scopes: const []));
      expect(none.url.queryParameters.containsKey('scope'), isFalse);
      final oidc = await h.client.prepareAuthorization(spec(scopes: ['openid', 'profile']));
      expect(oidc.url.queryParameters['nonce'], isNotNull);
      expect(oidc.pending.nonce, oidc.url.queryParameters['nonce']);
    });

    test('the pending flow is persisted before the browser opens', () async {
      var persisted = false;
      h.browser.onAuthorize = (url) async {
        final pending = await h.store.readPending(url.queryParameters['state']!);
        persisted = pending != null && pending.issuer == as.issuer && pending.resource == resource;
        return as.approve(url);
      };
      await h.client.authorize(spec(ephemeral: true));
      expect(persisted, isTrue);
      expect(h.browser.schemes.single, 'io.github.mihok.sherpa');
      expect(h.browser.ephemeral.single, isTrue);
    });

    test('PKCE not advertised → refused before the browser; the override proceeds and still uses S256', () async {
      as.editMetadata = (m) => {...m}..remove('code_challenge_methods_supported');
      final m = await h.discover(as);
      await expectLater(h.client.authorize(spec(server: m)),
          throwsA(isA<PkceNotSupportedException>().having((e) => e.overridable, 'overridable', isTrue)));
      expect(h.browser.opened, isEmpty);
      expect(await h.store.listPending(), isEmpty);

      final tokens = await h.client.authorize(spec(server: m, allowMissingPkce: true));
      expect(tokens.accessToken, isNotEmpty);
      expect(h.browser.opened.single.queryParameters['code_challenge_method'], 'S256');
      expect(h.logs.all, contains('user override'));
    });

    test('61: javascript:, data: and non-https authorization endpoints never reach the browser', () async {
      for (final bad in ['javascript:alert(1)', 'data:text/html,<script>x</script>', 'http://as.example/authorize']) {
        final m = AuthorizationServerMetadata(
          issuer: as.issuer,
          authorizationEndpoint: Uri.parse(bad),
          tokenEndpoint: meta.tokenEndpoint,
          codeChallengeMethodsSupported: const ['S256'],
        );
        final strict = Harness(as: as, policy: const AuthNetworkPolicy());
        addTearDown(strict.close);
        await expectLater(strict.client.authorize(spec(server: m)), throwsA(isA<AuthPolicyException>()), reason: bad);
        expect(strict.browser.opened, isEmpty, reason: bad);
      }
    });

    test('interactive authorization is refused from the background', () async {
      final bg = Harness(as: as, canInteract: () => false);
      addTearDown(bg.close);
      await expectLater(bg.client.authorize(spec()), throwsA(isA<InteractiveAuthNotAllowedException>()));
      expect(bg.browser.opened, isEmpty);
      expect(await bg.store.listPending(), isEmpty);
    });

    test('a cancelled or failing browser deletes the pending flow', () async {
      h.browser.onAuthorize = (_) async => throw AuthCancelledException();
      await expectLater(h.client.authorize(spec()), throwsA(isA<AuthCancelledException>()));
      expect(await h.store.listPending(), isEmpty);
      h.browser.onAuthorize = (_) async => throw StateError('PlatformException(secret stuff)');
      await expectLater(h.client.authorize(spec()),
          throwsA(isA<BrowserUnavailableException>().having((e) => e.toString(), 'text', isNot(contains('secret stuff')))));
      expect(await h.store.listPending(), isEmpty);
    });
  });

  group('callback validation', () {
    test('the resource parameter is on both the authorize and the token request', () async {
      final tokens = await h.client.authorize(spec());
      expect(as.authorizeRequests.single['resource'], resource);
      final form = as.tokenRequests.single.form;
      expect(form['resource'], resource);
      expect(form['grant_type'], 'authorization_code');
      expect(form['code_verifier']!.length, greaterThanOrEqualTo(43));
      expect(form['redirect_uri'], 'io.github.mihok.sherpa:/oauth/callback');
      expect(form['client_id'], tokens.clientId);
      expect(as.tokenRequests.single.authorization, isNull, reason: 'public client: no Basic auth');
      expect(tokens.resource, resource);
      expect(tokens.issuer, as.issuer);
      expect(await h.store.readTokens(as.issuer, resource), isNotNull);
    });

    test('39: state is unique; unknown, expired and reused states are dropped', () async {
      final a = await h.client.prepareAuthorization(spec());
      final b = await h.client.prepareAuthorization(spec());
      expect(a.pending.state, isNot(b.pending.state));

      final forged = Uri.parse('io.github.mihok.sherpa:/oauth/callback?code=x&state=forged&iss=${Uri.encodeQueryComponent(as.issuer)}');
      await expectLater(h.client.completeAuthorization(forged),
          throwsA(isA<CallbackRejectedException>().having((e) => e.reason, 'reason', CallbackRejection.unknownState)));

      final cb = as.approve(a.url);
      await h.client.completeAuthorization(cb);
      await expectLater(h.client.completeAuthorization(cb),
          throwsA(isA<CallbackRejectedException>().having((e) => e.reason, 'reason', CallbackRejection.unknownState)));
      expect(as.tokenRequests.length, 1, reason: 'a replayed callback never reaches the token endpoint');

      final cbB = as.approve(b.url);
      h.clock.advance(const Duration(minutes: 11));
      await expectLater(h.client.completeAuthorization(cbB),
          throwsA(isA<CallbackRejectedException>().having((e) => e.reason, 'reason', CallbackRejection.expired)));
      expect(await h.store.listPending(), isEmpty);

      final noState = Uri.parse('io.github.mihok.sherpa:/oauth/callback?code=x');
      await expectLater(h.client.completeAuthorization(noState),
          throwsA(isA<CallbackRejectedException>().having((e) => e.reason, 'reason', CallbackRejection.missingState)));
    });

    test('pending flows expire and are purged', () async {
      await h.client.prepareAuthorization(spec());
      await h.client.prepareAuthorization(spec());
      h.clock.advance(const Duration(minutes: 5));
      expect(await h.client.purgeExpiredPending(), 0);
      h.clock.advance(const Duration(minutes: 6));
      expect(await h.client.purgeExpiredPending(), 2);
      expect(await h.store.listPending(), isEmpty);
    });

    test('a pending flow survives process death', () async {
      final store = SecretAuthStateStore(InMemorySecretStore());
      final first = Harness(as: as, store: store);
      final prepared = await first.client.prepareAuthorization(spec());
      final callback = as.approve(prepared.url);
      first.close(); // the app is killed while the browser is open

      final second = Harness(as: as, store: store, clock: first.clock);
      addTearDown(second.close);
      final pending = await second.client.pendingFor(callback);
      expect(pending!.serverKey, 'https://mcp.example.com');
      final tokens = await second.client.completeAuthorization(callback);
      expect(tokens.resource, resource);
      expect(await second.client.accessTokenFor(resource), tokens.accessToken);
    });

    test('40: the RFC 9207 iss table', () {
      IssCheck check(String? iss, bool supported) =>
          checkAuthorizationResponseIssuer(iss: iss, expectedIssuer: 'https://as.example/t1', issParameterSupported: supported);
      expect(check('https://as.example/t1', true), IssCheck.ok);
      expect(check('https://as.example/t2', true), IssCheck.mismatch);
      expect(check(null, true), IssCheck.missing);
      expect(check('https://as.example/t1', false), IssCheck.ok);
      expect(check('https://evil.example', false), IssCheck.mismatch);
      expect(check(null, false), IssCheck.ok);
      // Exact comparison: no normalisation of any kind.
      for (final v in ['https://AS.example/t1', 'HTTPS://as.example/t1', 'https://as.example:443/t1', 'https://as.example/t1/', 'https://as.example%2Ft1', 'https://as.example/%74%31']) {
        expect(check(v, true), IssCheck.mismatch, reason: v);
      }
    });

    test('40b: iss rows end to end', () async {
      // Row 1 mismatch (case and trailing slash variants).
      for (final bad in [as.issuer.toUpperCase(), '${as.issuer}/', Uri.encodeComponent(as.issuer)]) {
        as.issOverride = bad;
        await expectLater(h.client.authorize(spec()),
            throwsA(isA<CallbackRejectedException>().having((e) => e.reason, 'reason', CallbackRejection.issuerMismatch)),
            reason: bad);
      }
      as.issOverride = null;
      // Row 2: advertised but missing.
      as.includeIss = false;
      await expectLater(h.client.authorize(spec()),
          throwsA(isA<CallbackRejectedException>().having((e) => e.reason, 'reason', CallbackRejection.issuerMissing)));
      expect(as.tokenRequests, isEmpty, reason: 'the code is never redeemed');
      // Row 4: not advertised, absent → proceed.
      as.issSupported = false;
      meta = await h.discover(as);
      expect((await h.client.authorize(spec())).accessToken, isNotEmpty);
      // Row 3: not advertised, present and wrong → reject.
      as.includeIss = true;
      as.issOverride = 'https://evil.example';
      await expectLater(h.client.authorize(spec()),
          throwsA(isA<CallbackRejectedException>().having((e) => e.isSecurityViolation, 'security', isTrue)));
    });

    test('41: on an iss mismatch the error response is not surfaced', () async {
      as.issOverride = 'https://evil.example';
      h.browser.onAuthorize = (url) async => as.approve(url, error: 'access_denied');
      Object? thrown;
      try {
        await h.client.authorize(spec());
      } on Object catch (e) {
        thrown = e;
      }
      expect(thrown, isA<CallbackRejectedException>().having((e) => e.reason, 'reason', CallbackRejection.issuerMismatch));
      expect(thrown.toString(), isNot(contains('access_denied')));
      expect(thrown.toString(), isNot(contains('SECRET-DESCRIPTION')));
      expect(h.logs.all, isNot(contains('SECRET-DESCRIPTION')));
    });

    test('an error response with a valid iss maps to a code, never the description', () async {
      h.browser.onAuthorize = (url) async => as.approve(url, error: 'access_denied');
      await expectLater(
          h.client.authorize(spec()),
          throwsA(isA<AuthorizationDeniedException>()
              .having((e) => e.userDenied, 'userDenied', isTrue)
              .having((e) => e.toString(), 'text', isNot(contains('SECRET-DESCRIPTION')))));
      h.browser.onAuthorize = (url) async => as.approve(url, error: '<script>alert(1)</script>');
      await expectLater(h.client.authorize(spec()),
          throwsA(isA<AuthorizationDeniedException>().having((e) => e.code, 'code', AuthorizationErrorCode.other)));
    });

    test('42: a callback to a different redirect is rejected', () async {
      for (final wrong in ['io.github.mihok.sherpa:/oauth/other', 'evil.app:/oauth/callback', 'https://evil.example/oauth/callback']) {
        h.browser.onAuthorize = (url) async {
          final cb = as.approve(url);
          return Uri.parse(wrong).replace(query: cb.query);
        };
        await expectLater(h.client.authorize(spec()),
            throwsA(isA<CallbackRejectedException>().having((e) => e.reason, 'reason', CallbackRejection.redirectMismatch)),
            reason: wrong);
      }
      expect(as.tokenRequests, isEmpty);
    });

    test('duplicate response parameters are rejected (RFC 6749 §3.1)', () async {
      h.browser.onAuthorize = (url) async {
        final cb = as.approve(url);
        return Uri.parse('${cb.toString()}&code=second');
      };
      await expectLater(h.client.authorize(spec()),
          throwsA(isA<CallbackRejectedException>().having((e) => e.reason, 'reason', CallbackRejection.duplicateParameter)));
    });

    test('a browser returning another flow\'s callback is rejected', () async {
      final other = await h.client.prepareAuthorization(spec());
      h.browser.onAuthorize = (_) async => as.approve(other.url);
      await expectLater(h.client.authorize(spec()),
          throwsA(isA<CallbackRejectedException>().having((e) => e.reason, 'reason', CallbackRejection.stateMismatch)));
    });

    test('43: the code is redeemed at the recorded token endpoint even if discovery changed', () async {
      final decoy = await FakeHttp.start();
      addTearDown(decoy.close);
      final prepared = await h.client.prepareAuthorization(spec());
      as.editMetadata = (m) => {...m, 'token_endpoint': '${decoy.origin}/token'};
      expect((await h.discover(as)).tokenEndpoint.toString(), '${decoy.origin}/token');
      await h.client.completeAuthorization(as.approve(prepared.url));
      expect(as.tokenRequests.length, 1);
      expect(decoy.requests, isEmpty);
    });

    test('a callback without code or error is rejected', () async {
      final prepared = await h.client.prepareAuthorization(spec());
      final cb = Uri.parse('io.github.mihok.sherpa:/oauth/callback').replace(queryParameters: {
        'state': prepared.pending.state,
        'iss': as.issuer,
      });
      await expectLater(h.client.completeAuthorization(cb),
          throwsA(isA<CallbackRejectedException>().having((e) => e.reason, 'reason', CallbackRejection.missingCode)));
    });
  });
}
