import 'dart:async';
import 'dart:io' show InternetAddress;

import 'package:http/http.dart' as http;
import 'package:sherpa_auth/sherpa_auth.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:sherpa_net/sherpa_net.dart' show NetworkScope;

import 'oauth_platform.dart';

/// Where one server's sign-in stands, for the server list and detail.
final class McpAuthState {
  const McpAuthState({this.consent, this.failure, this.declined = false, this.busy = false});

  /// The authorization the server asked for, waiting for the user's tap.
  final McpConsentRequest? consent;

  /// Why the last attempt failed (plain language), if it did.
  final String? failure;

  /// The user said "Not now" to [consent].
  final bool declined;

  /// An authorization is running (the browser is open).
  final bool busy;

  bool get needsConsent => consent != null;

  McpAuthState copyWith({McpConsentRequest? consent, bool clearConsent = false, String? failure, bool clearFailure = false, bool? declined, bool? busy}) =>
      McpAuthState(
        consent: clearConsent ? null : (consent ?? this.consent),
        failure: clearFailure ? null : (failure ?? this.failure),
        declined: declined ?? this.declined,
        busy: busy ?? this.busy,
      );
}

/// What a sign-in attempt from the consent sheet came to.
sealed class McpSignInResult {
  const McpSignInResult();
}

final class McpSignedIn extends McpSignInResult {
  const McpSignedIn();
}

final class McpSignInFailed extends McpSignInResult {
  const McpSignInFailed(this.message, {this.cancelled = false});

  /// Plain language, safe to show.
  final String message;
  final bool cancelled;
}

/// OAuth for MCP servers: sherpa_auth's [McpAuthorizer] behind sherpa_mcp's
/// [McpAuthHook], with tokens in the [SecretStore] only.
///
/// * [headersFor] attaches the server's bearer token (refreshed ahead of
///   expiry) to every request; [onAuthChallenge] reacts to 401/403: a
///   refreshed or concurrently replaced token is retried once, anything
///   interactive becomes a pending [McpConsentRequest] (initial sign-in,
///   re-authorization, or step-up to more scopes) that the UI shows in the
///   consent sheet. A browser is never opened without the user's tap.
/// * [authorize] runs the approved authorization; [onAuthorized] (wired to
///   `McpServerManager.reconnect`) then brings the server back.
/// * [signOut] revokes (best effort) and wipes the server's tokens.
final class McpOAuthService implements McpAuthHook {
  McpOAuthService({
    required SecretStore secrets,
    required http.Client httpClient,
    required BrowserLauncher browser,
    required McpServerConfig? Function(Uri serverUrl) configForUrl,
    required McpServerConfig? Function(String serverId) configForId,
    Clock clock = const SystemClock(),
    bool Function()? canInteract,
    Future<List<InternetAddress>> Function(String host)? resolver,
    AuthNetworkPolicy policy = const AuthNetworkPolicy(),
    AuthLogger? logger,
  })  : _configForUrl = configForUrl,
        _configForId = configForId {
    oauth = OAuthClient(
      store: SecretAuthStateStore(CachingSecretStore(secrets)),
      browser: browser,
      identity: SherpaOAuth.identity,
      httpClient: httpClient,
      policy: policy,
      clock: clock,
      canInteract: canInteract ?? SherpaOAuth.canInteract,
      logger: logger,
    );
    authorizer = McpAuthorizer(
      oauth: oauth,
      resolver: resolver,
      logger: logger,
      serverConfig: (key) {
        for (final c in _knownConfigs) {
          final a = authConfigOf(c);
          if (a.serverKey == key) return a;
        }
        return null;
      },
    );
  }

  late final OAuthClient oauth;
  late final McpAuthorizer authorizer;
  final McpServerConfig? Function(Uri serverUrl) _configForUrl;
  final McpServerConfig? Function(String serverId) _configForId;
  final List<McpServerConfig> _knownConfigs = [];

  /// Called after a successful authorization (reconnect the server).
  Future<void> Function(String serverId)? onAuthorized;

  final Map<String, McpAuthState> _states = {};
  final StreamController<String> _changes = StreamController.broadcast(sync: true);

  /// Ids of servers whose [stateOf] changed.
  Stream<String> get changes => _changes.stream;

  McpAuthState stateOf(String serverId) => _states[serverId] ?? const McpAuthState();

  void _set(String serverId, McpAuthState s) {
    _states[serverId] = s;
    if (!_changes.isClosed) _changes.add(serverId);
  }

  /// The auth settings sherpa_auth needs for [c]: a LAN / loopback server's
  /// own host may be private and plain http; everything else is public
  /// https only (the AS and metadata hosts included).
  static McpServerAuthConfig authConfigOf(McpServerConfig c) => McpServerAuthConfig(
        serverUrl: c.url,
        networkScope: c.allowLocalNetwork ? NetworkScope.loopback : NetworkScope.publicOnly,
        allowHttp: c.allowLocalNetwork,
      );

  McpServerConfig? _config(Uri url) {
    final c = _configForUrl(url);
    if (c != null && !_knownConfigs.any((k) => k.id == c.id)) _knownConfigs.add(c);
    return c;
  }

  // ---------------------------------------------------------------- McpAuthHook

  @override
  Future<Map<String, String>> headersFor(Uri serverUrl) async {
    final c = _config(serverUrl);
    if (c == null) return const {};
    try {
      final token = await authorizer.tokenFor(authConfigOf(c));
      return token == null ? const {} : {'authorization': 'Bearer $token'};
    } on AuthException {
      // Offline refresh and the like: send without; the server's 401 brings
      // us back to onAuthChallenge, which never opens a browser.
      return const {};
    }
  }

  @override
  Future<AuthRetry> onAuthChallenge(Uri serverUrl, int status, Map<String, String> responseHeaders) async {
    final c = _config(serverUrl);
    if (c == null) return AuthRetry.fail;
    final outcome = await authorizer.onResponse(authConfigOf(c), statusCode: status, headers: responseHeaders);
    switch (outcome) {
      case McpAuthorized():
        _set(c.id, stateOf(c.id).copyWith(clearConsent: true, clearFailure: true, declined: false));
        return AuthRetry.retry;
      case McpNeedsUserConsent(:final request):
        _set(c.id, stateOf(c.id).copyWith(consent: request, clearFailure: true, declined: false));
        return AuthRetry.needsUserConsent;
      case McpAuthFailed(:final reason, :final cause):
        if (reason == McpAuthFailure.notAnAuthChallenge) return AuthRetry.fail;
        _set(c.id, stateOf(c.id).copyWith(failure: describeFailure(reason, cause)));
        return AuthRetry.fail;
    }
  }

  // ---------------------------------------------------------------- UI

  /// The consent to show for [serverId]: the one the server asked for, or
  /// (for an explicit "Sign in") a fresh discovery. Returns null with
  /// [McpAuthState.failure] set when discovery failed.
  Future<McpConsentRequest?> prepareConsent(String serverId) async {
    final pending = stateOf(serverId).consent;
    if (pending != null) return pending;
    final c = _configForId(serverId);
    if (c == null) return null;
    if (!_knownConfigs.any((k) => k.id == c.id)) _knownConfigs.add(c);
    final outcome = await authorizer.consentFor(authConfigOf(c));
    switch (outcome) {
      case McpNeedsUserConsent(:final request):
        _set(serverId, stateOf(serverId).copyWith(consent: request, clearFailure: true));
        return request;
      case McpAuthFailed(:final reason, :final cause):
        _set(serverId, stateOf(serverId).copyWith(failure: describeFailure(reason, cause)));
        return null;
      case McpAuthorized():
        return null;
    }
  }

  /// Runs the authorization the user approved in the consent sheet (from
  /// their tap only), then reconnects the server.
  Future<McpSignInResult> authorize(String serverId, McpConsentRequest consent) async {
    _set(serverId, stateOf(serverId).copyWith(busy: true, clearFailure: true));
    final outcome = await authorizer.authorize(consent);
    switch (outcome) {
      case McpAuthorized():
        _set(serverId, const McpAuthState());
        await onAuthorized?.call(serverId);
        return const McpSignedIn();
      case McpAuthFailed(:final reason, :final cause):
        final message = describeFailure(reason, cause);
        final cancelled = reason == McpAuthFailure.cancelled;
        _set(serverId, stateOf(serverId).copyWith(busy: false, failure: cancelled ? null : message, clearFailure: cancelled));
        return McpSignInFailed(message, cancelled: cancelled);
      case McpNeedsUserConsent(:final request):
        _set(serverId, stateOf(serverId).copyWith(busy: false, consent: request));
        return const McpSignInFailed('The server asked for another sign-in. Try again.');
    }
  }

  /// "Not now": a step-up is not asked again for a while; the server stays
  /// waiting for sign-in.
  void decline(String serverId) {
    final s = stateOf(serverId);
    final consent = s.consent;
    if (consent != null) authorizer.decline(consent);
    _set(serverId, s.copyWith(declined: true));
  }

  /// Whether Sherpa holds tokens for [serverId].
  Future<bool> hasCredentials(String serverId) async {
    final c = _configForId(serverId);
    if (c == null) return false;
    final b = await oauth.store.readBinding(authConfigOf(c).serverKey);
    if (b == null) return false;
    return await oauth.storedTokens(b.resource, issuer: b.issuer) != null;
  }

  /// Revokes (best effort) and deletes the server's tokens and flows.
  Future<void> signOut(McpServerConfig config, {bool revoke = true}) async {
    try {
      await authorizer.signOut(authConfigOf(config), revoke: revoke);
    } on AuthException {
      // Revocation is best effort; the local wipe below still happens.
      await authorizer.signOut(authConfigOf(config), revoke: false);
    }
    _knownConfigs.removeWhere((k) => k.id == config.id);
    _set(config.id, const McpAuthState());
  }

  /// Forgets UI state of a removed server.
  void forget(String serverId) {
    _states.remove(serverId);
    _knownConfigs.removeWhere((k) => k.id == serverId);
  }

  /// A failure in words for the server list.
  static String describeFailure(McpAuthFailure reason, AuthException? cause) => switch (reason) {
        McpAuthFailure.network => "Couldn't reach the sign-in server. Check your connection and try again.",
        McpAuthFailure.serverError => 'The sign-in server is having problems. Try again later.',
        McpAuthFailure.notAnAuthChallenge => 'The server refused the request.',
        McpAuthFailure.unauthorizedAfterAuthorization =>
          'The server rejected the new sign-in. Its sign-in may be misconfigured; try again later.',
        McpAuthFailure.insufficientScope => 'The server needs a permission that was not granted.',
        McpAuthFailure.stepUpDeclined => 'You declined the extra permission this server asked for.',
        McpAuthFailure.discovery => "This server's sign-in settings could not be read.",
        McpAuthFailure.issuerMismatch =>
          'The sign-in server did not identify itself correctly, so Sherpa stopped (possible impersonation).',
        McpAuthFailure.pkceUnsupported => "The sign-in server doesn't support a security feature Sherpa requires (PKCE).",
        McpAuthFailure.policyBlocked => 'The sign-in uses an address Sherpa does not allow (not https, or a private address).',
        McpAuthFailure.clientIdRequired =>
          "The sign-in server doesn't let new apps register. It needs a client id registered for Sherpa.",
        McpAuthFailure.registrationRejected => 'The sign-in server refused to register Sherpa.',
        McpAuthFailure.authorizationServerMismatch => 'The server now uses a different sign-in server than the one configured.',
        McpAuthFailure.invalidClient => "The sign-in server didn't accept Sherpa's registration. Try again.",
        McpAuthFailure.cancelled => 'Sign-in was cancelled.',
        McpAuthFailure.denied => 'Access was not granted on the sign-in page.',
        McpAuthFailure.callbackRejected => 'The sign-in response could not be verified. Try again.',
        McpAuthFailure.interactionNotAllowed => 'Sign-in can only start while Sherpa is open.',
        McpAuthFailure.browserUnavailable => 'No browser is available to sign in.',
        McpAuthFailure.signInRequired => 'The sign-in expired. Sign in again.',
        McpAuthFailure.tokenRejected => 'The sign-in server refused to issue a token.',
        McpAuthFailure.protocol => 'The sign-in server sent an invalid response.',
      };

  Future<void> dispose() => _changes.close();
}
