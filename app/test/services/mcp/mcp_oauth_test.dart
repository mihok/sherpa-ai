import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/services/mcp/auth/mcp_oauth.dart';
import 'package:sherpa/services/mcp/auth/oauth_platform.dart';
import 'package:sherpa/services/mcp/mcp_runtime.dart';
import 'package:sherpa_auth/sherpa_auth.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';

import 'support/mcp_fakes.dart';

void main() {
  const url = 'https://tools.example.com/mcp';

  late FakeAuthWorld world;
  late FakeRemoteServers remote;
  late FakeBrowser browser;
  late InMemorySecretStore secrets;
  late McpRuntime rt;

  setUp(() async {
    world = FakeAuthWorld();
    remote = FakeRemoteServers()..add(url, tools: [fakeTool('read', annotations: readOnlyHints)]);
    browser = FakeBrowser(world.approve);
    secrets = InMemorySecretStore();
    rt = await fakeRuntime(remote: remote, client: world.client(), browser: browser, secrets: secrets);
  });
  tearDown(() => rt.dispose());

  Future<String> addProtected() async {
    remote
      ..requireBearer[url] = world.issued.contains
      ..resourceMetadata[url] = world.prmUrl;
    final c = await rt.addServer(url: Uri.parse(url), name: 'Docs');
    return c.id;
  }

  test('a 401 becomes a pending consent; nothing opens a browser until the user approves', () async {
    final id = await addProtected();
    await rt.refresh();
    expect(rt.manager.health(id).status, McpServerStatus.needsAuth);
    final consent = rt.oauth.stateOf(id).consent;
    expect(consent, isNotNull);
    expect(consent!.purpose, AuthPurpose.initial);
    expect(consent.authorizationServerHost, 'auth.example.com');
    expect(consent.scopes, contains('tools:read'));
    expect(browser.opened, isEmpty, reason: 'interactive auth only from a tap');
    final tools = await rt.router.toolsForTurn(sessionId: 's');
    expect(tools.map((t) => t.name), isNot(contains('docs__read')));
  });

  test('consent → authorize → reconnect: the token is stored in the SecretStore only and sent', () async {
    final id = await addProtected();
    await rt.refresh();
    final consent = (await rt.oauth.prepareConsent(id))!;
    final result = await rt.oauth.authorize(id, consent);
    expect(result, isA<McpSignedIn>());
    expect(browser.opened.single.host, 'auth.example.com');
    expect(browser.opened.single.queryParameters['redirect_uri'], SherpaOAuth.redirectUri);
    expect(browser.opened.single.queryParameters['resource'], url);
    expect(rt.manager.health(id).status, McpServerStatus.connected);
    expect(rt.oauth.stateOf(id).needsConsent, isFalse);
    expect(await rt.oauth.hasCredentials(id), isTrue);
    final keys = await secrets.keys(prefix: 'oauth/');
    expect(keys.any((k) => k.contains('/tokens/')), isTrue);
    expect(rt.toolsOf(id).map((e) => e.modelName), ['docs__read']);
    expect((await rt.oauth.headersFor(Uri.parse(url)))['authorization'], 'Bearer ${world.issued.single}');
  });

  test('a cancelled browser is reported without an error state; sign out wipes the tokens', () async {
    final id = await addProtected();
    await rt.refresh();
    browser.approve = null; // the user closes the sheet
    final consent = (await rt.oauth.prepareConsent(id))!;
    final cancelled = await rt.oauth.authorize(id, consent);
    expect(cancelled, isA<McpSignInFailed>().having((f) => f.cancelled, 'cancelled', isTrue));
    expect(rt.oauth.stateOf(id).failure, isNull);

    browser.approve = world.approve;
    expect(await rt.oauth.authorize(id, consent), isA<McpSignedIn>());
    await rt.signOut(id);
    expect(await rt.oauth.hasCredentials(id), isFalse);
    expect((await secrets.keys(prefix: 'oauth/')).where((k) => k.contains('/tokens/')), isEmpty);
    expect(rt.manager.health(id).status, McpServerStatus.needsAuth);
  });

  test('step-up: a 403 insufficient_scope asks for the union of scopes', () async {
    final id = await addProtected();
    await rt.refresh();
    expect(await rt.oauth.authorize(id, (await rt.oauth.prepareConsent(id))!), isA<McpSignedIn>());
    final retry = await rt.oauth.onAuthChallenge(Uri.parse(url), 403, {
      'www-authenticate': 'Bearer error="insufficient_scope", scope="tools:read tools:write", '
          'resource_metadata="${world.prmUrl}"',
    });
    expect(retry, AuthRetry.needsUserConsent);
    final step = rt.oauth.stateOf(id).consent!;
    expect(step.purpose, AuthPurpose.stepUp);
    expect(step.scopes, containsAll(['tools:read', 'tools:write']));
    rt.oauth.decline(id);
    expect(rt.oauth.stateOf(id).declined, isTrue);
  });

  test('failures are described in plain language', () {
    for (final r in McpAuthFailure.values) {
      expect(McpOAuthService.describeFailure(r, null), isNot(contains('Exception')));
    }
  });
}
