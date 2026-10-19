import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sherpa/features/models/state/hub_account.dart';
import 'package:sherpa/features/models/state/models_providers.dart';
import 'package:sherpa/routing/routes.dart';
import 'package:sherpa/services/downloads/record_store.dart';
import 'package:sherpa/services/mcp/auth/oauth_platform.dart';
import 'package:sherpa_auth/sherpa_auth.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:sherpa_net/sherpa_net.dart';

import 'support/mcp_rig.dart';

void main() {
  group('MCP sign-in', () {
    Future<(McpRig, FakeAuthWorld, String)> protectedRig(WidgetTester tester) async {
      final world = FakeAuthWorld(issuer: 'https://login.example.net');
      final remote = FakeRemoteServers()
        ..add(toolsUrl, name: 'Docs', tools: [fakeTool('read', annotations: readOnlyHints)])
        ..requireBearer[toolsUrl] = world.issued.contains
        ..resourceMetadata[toolsUrl] = world.prmUrl;
      final browser = FakeBrowser(world.approve);
      final rig = await McpRig.create(tester, remote: remote, httpClient: world.client(), browser: browser);
      final c = await rig.addRemote(tester, name: 'Docs');
      return (rig, world, c.id);
    }

    testWidgets('the consent sheet names the server, where you sign in and the scopes; continuing signs in', (tester) async {
      final (rig, world, id) = await protectedRig(tester);
      await rig.pump(tester, location: Routes.tools);
      expect(find.text('Sign in to use this server.'), findsOneWidget);
      expect(rig.browser.opened, isEmpty, reason: 'nothing opens before the user taps');

      await rig.tap(tester, find.text('Sign in'));
      expect(find.text('Sign in to Docs'), findsOneWidget);
      expect(find.text('Docs · tools.example.com'), findsOneWidget);
      expect(find.text('https://login.example.net'), findsOneWidget);
      expect(find.text('tools:read'), findsOneWidget);
      expect(find.textContaining('a different site from the server'), findsOneWidget);
      expect(find.textContaining("this phone's secure storage"), findsOneWidget);
      expect(rig.browser.opened, isEmpty);

      await rig.tap(tester, find.text('Continue to sign in'));
      expect(rig.browser.opened.single.host, 'login.example.net');
      expect(world.issued, hasLength(1));
      expect(rig.runtime.manager.health(id).status, McpServerStatus.connected);
      expect(find.text('Signed in to Docs'), findsOneWidget);
    });

    testWidgets('"Not now" opens nothing and keeps the server waiting', (tester) async {
      final (rig, _, id) = await protectedRig(tester);
      await rig.pump(tester, location: Routes.toolServer(id));
      await rig.tap(tester, find.text('Sign in'));
      await rig.tap(tester, find.text('Not now'));
      expect(rig.browser.opened, isEmpty);
      expect(rig.runtime.manager.health(id).status, McpServerStatus.needsAuth);
      expect(rig.runtime.oauth.stateOf(id).declined, isTrue);
    });
  });

  group('Sign in with Hugging Face', () {
    const clientId = 'hf-test-client';

    (HubAccount, InMemorySecretStore, FakeBrowser) hfAccount({bool configured = true}) {
      final secrets = InMemorySecretStore();
      final codes = <String>{};
      final client = MockClient((r) async {
        if (r.method == 'POST' && r.url.path == '/oauth/token') {
          final form = Uri.splitQueryString(r.body);
          if (!codes.remove(form['code']) || form['client_id'] != clientId || form['code_verifier'] == null) {
            return http.Response('{"error":"invalid_grant"}', 400, headers: {'content-type': 'application/json'});
          }
          return http.Response(
            jsonEncode({'access_token': 'hf_oauth_token', 'token_type': 'Bearer', 'expires_in': 28800, 'scope': 'openid profile gated-repos inference-api'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (r.url.path == '/api/whoami-v2') {
          if (r.headers['authorization'] != 'Bearer hf_oauth_token') return http.Response('{"error":"bad"}', 401);
          return http.Response(
            jsonEncode({'name': 'sherpa-tester', 'fullname': 'Sherpa Tester', 'orgs': <Object?>[], 'auth': {'type': 'oauth'}}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('not found', 404);
      });
      final browser = FakeBrowser((url) {
        final q = url.queryParameters;
        final code = 'code-${codes.length + 1}';
        codes.add(code);
        return Uri.parse(q['redirect_uri']!).replace(queryParameters: {'code': code, 'state': q['state']!});
      });
      final oauth = HuggingFaceOAuth(
        oauth: OAuthClient(
          store: SecretAuthStateStore(secrets),
          browser: browser,
          identity: SherpaOAuth.identity,
          httpClient: client,
          policy: const AuthNetworkPolicy(publicPolicy: UrlPolicy(resolver: fakeResolver)),
        ),
        clientId: clientId,
      );
      final account = HubAccount(
        secrets: secrets,
        store: InMemoryRecordStore(),
        client: client,
        oauth: configured ? oauth : null,
        oauthClientId: configured ? clientId : '',
      );
      return (account, secrets, browser);
    }

    testWidgets('a consent sheet, then the browser; the token lands in secure storage only', (tester) async {
      final (account, secrets, browser) = hfAccount();
      final rig = await McpRig.create(tester);
      rig.extra = [hubAccountProvider.overrideWithValue(account)];
      await rig.pump(tester, location: Routes.huggingFace);
      expect(find.text('Or paste an access token'), findsOneWidget);
      await rig.tap(tester, find.text('Sign in with Hugging Face'));
      expect(find.text('https://huggingface.co'), findsOneWidget);
      expect(find.text('Use Inference Providers on your account (this can spend your credits) (inference-api)'), findsOneWidget);
      expect(browser.opened, isEmpty);

      await rig.tap(tester, find.text('Continue to sign in'));
      expect(browser.opened.single.host, 'huggingface.co');
      expect(browser.opened.single.queryParameters['client_id'], clientId);
      expect(browser.opened.single.queryParameters['redirect_uri'], SherpaOAuth.redirectUri);
      expect(browser.opened.single.queryParameters['code_challenge_method'], 'S256');
      expect(find.textContaining('Signed in with Hugging Face'), findsOneWidget);
      expect(find.textContaining('@sherpa-tester'), findsOneWidget);
      late String? token;
      await tester.runAsync(() async => token = await account.token());
      expect(token, 'hf_oauth_token');
      final keys = await secrets.keys();
      expect(keys, isNot(contains(HubAccount.tokenKey)), reason: 'no pasted token');
      expect(keys.any((k) => k.startsWith('oauth/') && k.contains('/tokens/')), isTrue);
    });

    testWidgets('without an OAuth client id the button is hidden and the screen says why', (tester) async {
      final (account, _, _) = hfAccount(configured: false);
      final rig = await McpRig.create(tester);
      rig.extra = [hubAccountProvider.overrideWithValue(account)];
      await rig.pump(tester, location: Routes.huggingFace);
      expect(find.text('Sign in with Hugging Face'), findsNothing);
      expect(find.text(HubAccount.browserSignInUnavailable), findsOneWidget);
      expect(find.text('Verify and save'), findsOneWidget, reason: 'pasting a token still works');
    });
  });
}
