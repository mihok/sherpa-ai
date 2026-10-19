import 'package:sherpa_auth/sherpa_auth.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  late FakeAuthServer hub;
  late Harness h;
  late HuggingFaceOAuth hf;

  setUp(() async {
    // HF layout: issuer = origin, endpoints under /oauth, no `iss` support.
    hub = await FakeAuthServer.start(tenantPath: '', endpointPath: '/oauth');
    hub
      ..issSupported = false
      ..includeIss = false;
    h = Harness(as: hub);
    hf = HuggingFaceOAuth(oauth: h.client, clientId: 'hf-public-app', hubUri: hub.http.root);
  });

  tearDown(() async {
    h.close();
    await hub.close();
  });

  test('the static metadata matches the live HF document and passes the MCP-grade checks', () {
    final m = HuggingFaceOAuth.staticMetadata(HuggingFaceOAuth.defaultHub);
    expect(m.issuer, 'https://huggingface.co');
    expect(m.authorizationEndpoint.toString(), 'https://huggingface.co/oauth/authorize');
    expect(m.tokenEndpoint.toString(), 'https://huggingface.co/oauth/token');
    expect(m.deviceAuthorizationEndpoint.toString(), 'https://huggingface.co/oauth/device');
    expect(m.codeChallengeMethodsSupported, ['S256']);
    m.checkPkce();
    m.checkEndpoints(const AuthNetworkPolicy());
    expect(HuggingFaceOAuth.defaultScopes, ['openid', 'profile', 'gated-repos', 'inference-api']);
  });

  test('sign-in: PKCE S256, exact redirect, HF scopes, nonce, and no resource parameter', () async {
    final tokens = await hf.signIn(orgId: 'org-123');
    final q = h.browser.opened.single.queryParameters;
    expect(q['client_id'], 'hf-public-app');
    expect(q['redirect_uri'], 'io.github.mihok.sherpa:/oauth/callback');
    expect(q['scope'], 'openid profile gated-repos inference-api');
    expect(q['code_challenge_method'], 'S256');
    expect(q['state'], isNotEmpty);
    expect(q['nonce'], isNotEmpty);
    expect(q['orgIds'], 'org-123');
    expect(q.containsKey('resource'), isFalse);
    expect(q.containsKey('prompt'), isFalse, reason: 'no offline_access without scopes_supported');

    final form = hub.tokenRequests.single.form;
    expect(form['code_verifier']!.length, greaterThanOrEqualTo(43));
    expect(form['client_id'], 'hf-public-app');
    expect(form.containsKey('resource'), isFalse);
    expect(hub.tokenRequests.single.authorization, isNull, reason: 'public app despite the advertised auth methods');

    expect(tokens.resource, hub.http.origin);
    expect(await hf.accessToken(), tokens.accessToken);
  });

  test('refresh (if HF issues refresh tokens) omits resource too', () async {
    final t0 = await hf.signIn();
    h.clock.advance(const Duration(hours: 9));
    final next = await hf.accessToken();
    expect(next, isNot(t0.accessToken));
    expect(hub.refreshRequests.single.form.containsKey('resource'), isFalse);
  });

  test('without a refresh token the user signs in again after expiry', () async {
    hub.issueRefreshTokens = false;
    await hf.signIn();
    h.clock.advance(const Duration(hours: 9));
    expect(await hf.accessToken(), isNull);
  });

  test('sign-out removes the grant', () async {
    await hf.signIn();
    await hf.signOut();
    expect(await hf.accessToken(), isNull);
    expect(await hf.tokens(), isNull);
  });

  test('refreshMetadata finds the OIDC document and checks the issuer', () async {
    hub.metadataPaths = {'/.well-known/openid-configuration'};
    final m = await hf.refreshMetadata();
    expect(m.issuer, hub.http.origin);
    expect(hub.http.paths, ['/.well-known/oauth-authorization-server', '/.well-known/openid-configuration']);
  });

  group('device flow (RFC 8628)', () {
    test('pending → slow_down → success', () async {
      hub.deviceOutcome = 'slow_down_then_success';
      final d = await hf.startDeviceSignIn();
      expect(d.userCode, 'WDJB-MJHT');
      expect(d.verificationUri.path, '/oauth/device/verify');
      expect(d.verificationUriComplete!.queryParameters['user_code'], 'WDJB-MJHT');
      expect(d.toString(), isNot(contains(d.deviceCode)));
      expect(hub.http.to('/oauth/device').single.form['scope'], 'openid profile gated-repos inference-api');
      final tokens = await hf.completeDeviceSignIn(d);
      expect(tokens.accessToken, isNotEmpty);
      final polls = hub.tokenRequests.where((r) => r.form['grant_type'] == 'urn:ietf:params:oauth:grant-type:device_code');
      expect(polls.length, 2);
      expect(await hf.accessToken(), tokens.accessToken);
    });

    test('denied and expired codes end the poll', () async {
      hub.deviceOutcome = 'denied';
      await expectLater(hf.completeDeviceSignIn(await hf.startDeviceSignIn()),
          throwsA(isA<AuthorizationDeniedException>().having((e) => e.code, 'code', AuthorizationErrorCode.accessDenied)));
      hub.deviceOutcome = 'expired';
      await expectLater(hf.completeDeviceSignIn(await hf.startDeviceSignIn()),
          throwsA(isA<AuthorizationDeniedException>().having((e) => e.code, 'code', AuthorizationErrorCode.expiredToken)));
    });

    test('the poll stops when the code expires locally or is cancelled', () async {
      final d = await hf.startDeviceSignIn();
      h.clock.advance(const Duration(minutes: 16));
      await expectLater(hf.completeDeviceSignIn(d), throwsA(isA<AuthorizationDeniedException>()));
      final cancel = CancellationToken()..cancel('user closed the sheet');
      await expectLater(hf.completeDeviceSignIn(await hf.startDeviceSignIn(), cancel: cancel), throwsA(isA<CancelledException>()));
    });
  });

  test('an invalid HF redirect URI is rejected at construction', () {
    expect(() => HuggingFaceOAuth(oauth: h.client, clientId: 'x', redirectUri: 'nodots:/cb'), throwsArgumentError);
  });
}
