import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:sherpa_auth/sherpa_auth.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';

import 'fake_as.dart';

export 'fake_as.dart';
export 'fake_http.dart';
export 'fake_rs.dart';

/// Sherpa's identity in tests: the private-use scheme redirect.
const identity = OAuthClientIdentity(
  clientName: 'Sherpa',
  redirectUri: 'io.github.mihok.sherpa:/oauth/callback',
  clientUri: 'https://sherpa.example',
);

const cimdUrl = 'https://sherpa.example/oauth/mcp-client.json';

/// Loopback + http allowed everywhere: the fake servers are on 127.0.0.1.
const loopbackPolicy = AuthNetworkPolicy(publicPolicy: UrlPolicy(scope: NetworkScope.loopback, allowHttp: true));

/// A browser that "signs in" by asking the fake AS to approve.
final class FakeBrowser implements BrowserLauncher {
  FakeBrowser([this.onAuthorize]);

  Future<Uri> Function(Uri url)? onAuthorize;
  final List<Uri> opened = [];
  final List<String> schemes = [];
  final List<bool> ephemeral = [];

  @override
  Future<Uri> authorize(Uri url, {required String callbackScheme, bool ephemeral = false, Uri? redirectUri}) async {
    opened.add(url);
    schemes.add(callbackScheme);
    this.ephemeral.add(ephemeral);
    final f = onAuthorize;
    if (f == null) throw StateError('browser opened unexpectedly');
    return f(url);
  }
}

/// Collects log lines.
final class LogSink {
  final List<String> lines = [];

  void call(AuthLogLevel level, String message) => lines.add('${level.name}: $message');

  String get all => lines.join('\n');
}

/// Wires an [OAuthClient] to a fake AS.
final class Harness {
  Harness({
    FakeAuthServer? as,
    AuthStateStore? store,
    FakeBrowser? browser,
    FakeClock? clock,
    this.policy = loopbackPolicy,
    OAuthClientIdentity id = identity,
    bool Function()? canInteract,
    AuthHttpLimits limits = const AuthHttpLimits(),
  })  : store = store ?? InMemoryAuthStateStore(),
        browser = browser ?? FakeBrowser(),
        clock = clock ?? FakeClock(DateTime.utc(2026, 10, 18, 12)),
        httpClient = http.Client(),
        logs = LogSink() {
    client = OAuthClient(
      store: this.store,
      browser: this.browser,
      identity: id,
      httpClient: httpClient,
      policy: policy,
      limits: limits,
      clock: this.clock,
      random: Random(42),
      canInteract: canInteract,
      sleep: (_) async {},
      logger: logs.call,
    );
    if (as != null) this.browser.onAuthorize ??= (url) async => as.approve(url);
  }

  final AuthStateStore store;
  final FakeBrowser browser;
  final FakeClock clock;
  final AuthNetworkPolicy policy;
  final http.Client httpClient;
  final LogSink logs;
  late final OAuthClient client;

  AuthHttp get transport => client.httpFor(policy);

  Future<AuthorizationServerMetadata> discover(FakeAuthServer as) =>
      discoverAuthorizationServer(as.issuer, http: transport, logger: logs.call);

  void close() => httpClient.close();
}
