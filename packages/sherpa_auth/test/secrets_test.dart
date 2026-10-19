import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sherpa_auth/sherpa_auth.dart';
import 'package:sherpa_net/sherpa_net.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// R02 §13 / test 65: tokens, codes, verifiers, `state` and client secrets
/// never appear in logs, exception text or `toString`.
void main() {
  late FakeAuthServer as;
  late FakeMcpServer rs;
  late Harness h;

  setUp(() async {
    as = await FakeAuthServer.start();
    rs = await FakeMcpServer.start(as);
    h = Harness(as: as);
  });

  tearDown(() async {
    h.close();
    await rs.close();
    await as.close();
  });

  test('65: a full flow with DCR secret, refresh and failures leaks nothing', () async {
    // A confidential DCR registration, so a client secret is in play.
    as.registerHook = (body) {
      as.secrets['dcr-client'] = 'CLIENT-SECRET-VALUE-42';
      return json({...body, 'client_id': 'dcr-client', 'client_secret': 'CLIENT-SECRET-VALUE-42', 'token_endpoint_auth_method': 'client_secret_basic'}, status: 201);
    };
    final callbacks = <Uri>[];
    h.browser.onAuthorize = (url) async {
      final cb = as.approve(url);
      callbacks.add(cb);
      return cb;
    };
    final server = McpServerAuthConfig(serverUrl: rs.url, networkScope: NetworkScope.loopback, allowHttp: true);
    final authz = McpAuthorizer(oauth: h.client);
    final errors = <Object>[];
    final outcomes = <McpAuthOutcome>[];

    final first = await h.httpClient.post(rs.url, body: '{}');
    final consent = await authz.onResponse(server, statusCode: first.statusCode, headers: first.headers) as McpNeedsUserConsent;
    outcomes.add(consent);
    final authorized = await authz.authorize(consent.request) as McpAuthorized;
    outcomes.add(authorized);

    // Refresh (rotation), then a refresh whose error echoes the token back.
    h.clock.advance(const Duration(hours: 2));
    await h.client.accessTokenFor(rs.resource, issuer: as.issuer);
    final current = (await h.store.readTokens(as.issuer, rs.resource))!;
    h.clock.advance(const Duration(hours: 2));
    as.tokenHook = (form) => json({
          'error': 'invalid_request',
          'error_description': 'bad refresh_token ${form['refresh_token']} for client CLIENT-SECRET-VALUE-42',
        }, status: 400);
    try {
      await h.client.refresh(as.issuer, rs.resource);
    } on Object catch (e) {
      errors.add(e);
    }
    // A code exchange whose error echoes the code and verifier.
    as.tokenHook = (form) => json({'error': 'invalid_grant', 'error_description': 'code ${form['code']} / ${form['code_verifier']}'}, status: 400);
    try {
      await h.client.authorize(AuthorizationSpec(server: consent.request.authorizationServer, resource: rs.resource, scopes: const ['files:read']));
    } on Object catch (e) {
      errors.add(e);
    }
    as.tokenHook = null;
    // Callback replays and forgeries.
    for (final cb in callbacks) {
      try {
        await h.client.completeAuthorization(cb);
      } on Object catch (e) {
        errors.add(e);
      }
    }

    final secrets = <String>{
      authorized.accessToken,
      current.accessToken,
      ?current.refreshToken,
      'CLIENT-SECRET-VALUE-42',
      for (final r in as.tokenRequests) ...[?r.form['code'], ?r.form['code_verifier'], ?r.form['refresh_token']],
      for (final q in as.authorizeRequests) ...[?q['state'], ?q['code_challenge'], ?q['nonce']],
      for (final cb in callbacks) ?cb.queryParameters['code'],
      ...as.accessTokens.keys,
      ...as.refreshTokens.keys,
    };
    expect(secrets.length, greaterThan(10));
    expect(errors, hasLength(greaterThanOrEqualTo(3)));

    final texts = <String>[
      h.logs.all,
      for (final e in errors) e.toString(),
      for (final e in errors) if (e is TokenEndpointException) e.description ?? '',
      for (final o in outcomes) o.toString(),
      current.toString(),
      (await h.store.readRegistration(as.issuer)).toString(),
      for (final p in await h.store.listPending()) p.toString(),
    ];
    for (final text in texts) {
      for (final s in secrets) {
        expect(text, isNot(contains(s)), reason: 'leaked a secret in: $text');
      }
    }
    expect(h.logs.lines, isNotEmpty);
    // The echoed description survived in sanitised form.
    final echoed = errors.whereType<TokenEndpointException>().first;
    expect(echoed.description, contains(Redactor.mask));
  });

  test('toString of every secret-bearing value is redacted', () async {
    final prepared = await h.client.prepareAuthorization(
        AuthorizationSpec(server: await h.discover(as), resource: rs.resource, scopes: const ['openid']));
    expect(prepared.toString(), isNot(contains(prepared.pending.state)));
    expect(Uri.decodeFull(prepared.toString()), contains(Redactor.mask));
    expect(prepared.pending.toString(), isNot(contains(prepared.pending.codeVerifier)));
    expect(prepared.pending.toString(), isNot(contains(prepared.pending.state)));
    final reg = (await h.store.readRegistration(as.issuer))!;
    expect(reg.toString(), isNot(contains('secret:')));
    final device = DeviceAuthorization(
      issuer: 'i', resource: 'r', clientId: 'c', tokenEndpoint: _u, deviceCode: 'DEVICE-CODE-SECRET', userCode: 'ABCD-EFGH',
      verificationUri: _u, expiresAt: _t, interval: Duration(seconds: 5));
    expect(device.toString(), isNot(contains('DEVICE-CODE-SECRET')));
    expect(device.toString(), contains('ABCD-EFGH'));
    const resp = TokenResponse(accessToken: 'ACCESS-SECRET-XYZ', refreshToken: 'REFRESH-SECRET-XYZ');
    expect(resp.toString(), isNot(contains('SECRET')));
    expect(const McpAuthorized('ACCESS-SECRET-XYZ').toString(), isNot(contains('SECRET')));
  });

  test('AuthRedact.uri masks state, code, challenge, nonce and device codes', () {
    final u = Uri.parse('https://as.example/authorize?state=S1S1S1S1&code=C1C1C1&code_challenge=CH&nonce=N&device_code=D&client_id=cid');
    final r = AuthRedact.uri(u).toString();
    for (final v in ['S1S1S1S1', 'C1C1C1', '=CH', 'nonce=N&', 'device_code=D']) {
      expect(r, isNot(contains(v)));
    }
    expect(r, contains('client_id=cid'));
  });

  test('network errors carrying secrets are scrubbed', () async {
    final client = MockClient((r) async => throw http.ClientException('socket closed while sending refresh_token=REFRESH-SECRET-777 code_verifier'));
    final transport = AuthHttp(client: client, policy: loopbackPolicy);
    await expectLater(
      transport.postForm(Uri.parse('http://127.0.0.1:9/token'), const {'refresh_token': 'REFRESH-SECRET-777'}, secrets: const ['REFRESH-SECRET-777']),
      throwsA(isA<AuthNetworkException>().having((e) => e.toString(), 'text', isNot(contains('REFRESH-SECRET-777')))),
    );
  });

  test('untrusted server text is sanitised for display', () {
    final s = AuthRedact.untrusted('line1\nline2\u0000 Bearer abcdefghijklmnop ${'x' * 500}');
    expect(s.contains('\n'), isFalse);
    expect(s.contains('\u0000'), isFalse);
    expect(s, isNot(contains('abcdefghijklmnop')));
    expect(s.length, lessThanOrEqualTo(201));
  });
}

final Uri _u = Uri(scheme: 'https', host: 'as.example');
final DateTime _t = DateTime.utc(2026);
