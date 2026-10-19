import 'dart:io' show InternetAddress;

import 'package:meta/meta.dart';
import 'package:sherpa_net/sherpa_net.dart';

import '../common/redaction.dart';
import '../discovery/authorization_server.dart';
import '../discovery/protected_resource.dart';
import '../discovery/resource_uri.dart';
import '../errors.dart';
import '../flow/oauth_client.dart';
import '../flow/pending.dart';
import '../flow/scopes.dart';
import '../http/network_policy.dart';
import '../registration/client_registration.dart';
import '../store/auth_state_store.dart';
import '../www_authenticate.dart';

/// Per-server authorization settings, owned by the user.
@immutable
final class McpServerAuthConfig {
  const McpServerAuthConfig({
    required this.serverUrl,
    this.networkScope = NetworkScope.publicOnly,
    this.allowHttp = false,
    this.extraLocalHosts = const {},
    this.allowMissingPkceSupport = false,
    this.preRegisteredClients = const [],
    this.resourceMatch = ResourceMatchPolicy.sameOriginPathPrefix,
    this.ephemeralBrowser = false,
    this.requestOfflineAccess = true,
    this.maxStepUpAttempts = 1,
  });

  /// The MCP endpoint URL as configured.
  final Uri serverUrl;

  /// `publicOnly` unless the user added this as a LAN/loopback server; the
  /// wider scope then applies to this server's host only.
  final NetworkScope networkScope;

  /// Plain http on this server's host (LAN/loopback development only).
  final bool allowHttp;

  /// Other hosts the user explicitly trusts under [networkScope] for this
  /// server, e.g. a self-hosted AS on another LAN machine. Empty by default:
  /// a private address on any host but the server's own stays blocked.
  final Set<String> extraLocalHosts;

  /// R02 Q6/R3 override, default **off**: proceed when the AS omits
  /// `code_challenge_methods_supported` (PKCE S256 is still used). The UI
  /// must show a warning when enabling it.
  final bool allowMissingPkceSupport;

  /// Client ids the user registered by hand, each bound to its issuer.
  final List<PreRegisteredClient> preRegisteredClients;
  final ResourceMatchPolicy resourceMatch;
  final bool ephemeralBrowser;

  /// Append `offline_access` when the AS lists it (A26 L308).
  final bool requestOfflineAccess;

  /// Interactive step-ups per (server, operation, scope set) before a 403
  /// is final (TS2 `DEFAULT_MAX_STEP_UP_RETRIES` = 1).
  final int maxStepUpAttempts;

  /// Canonical server URL; the key for bindings and pending flows.
  String get serverKey => canonicalResourceUri(serverUrl);

  AuthNetworkPolicy networkPolicy({Future<List<InternetAddress>> Function(String host)? resolver}) =>
      AuthNetworkPolicy.forServer(serverUrl,
          scope: networkScope, allowHttp: allowHttp, extraLocalHosts: extraLocalHosts, resolver: resolver);

  @override
  String toString() => 'McpServerAuthConfig($serverUrl)';
}

/// What an interactive authorization would ask for. The UI shows the
/// server, the **authorization server host** (RFC 9728 §7.8 phishing
/// guidance) and the scopes, and calls [McpAuthorizer.authorize] only from
/// the user's tap.
@immutable
final class McpConsentRequest {
  const McpConsentRequest({
    required this.server,
    required this.authorizationServer,
    required this.resource,
    required this.scopes,
    required this.purpose,
    this.resourceMetadata,
    this.operation,
  });

  final McpServerAuthConfig server;
  final AuthorizationServerMetadata authorizationServer;

  /// RFC 8707 resource to request (PRM `resource` verbatim).
  final String resource;
  final List<String> scopes;
  final AuthPurpose purpose;
  final ProtectedResourceMetadata? resourceMetadata;

  /// The operation that hit `insufficient_scope` (e.g. `tools/call:write_file`).
  final String? operation;

  String get serverHost => server.serverUrl.host;

  String get issuer => authorizationServer.issuer;

  String get authorizationServerHost => authorizationServer.authorizationEndpoint.host;

  /// The AS does not advertise PKCE and the user override is what allows
  /// this flow; the sheet should say so.
  bool get pkceOverrideInEffect => authorizationServer.codeChallengeMethodsSupported == null;

  /// Untrusted PRM `resource_name`, sanitised for plain-text display.
  String? get resourceName {
    final n = resourceMetadata?.resourceName;
    return n == null ? null : AuthRedact.untrusted(n, max: 80);
  }

  @override
  String toString() => 'McpConsentRequest(${purpose.name}, $serverHost via $authorizationServerHost, ${scopes.join(' ')})';
}

/// The result of reacting to a 401/403 or of an interactive authorization.
sealed class McpAuthOutcome {
  const McpAuthOutcome();
}

/// Retry the request once with `Authorization: Bearer <accessToken>`.
final class McpAuthorized extends McpAuthOutcome {
  const McpAuthorized(this.accessToken);

  final String accessToken;

  String get authorizationHeader => 'Bearer $accessToken';

  @override
  String toString() => 'McpAuthorized(«redacted»)';
}

/// Interactive authorization is needed. Show [request] and, on the user's
/// tap, call [McpAuthorizer.authorize]; on "not now", [McpAuthorizer.decline].
/// Background runs report "sign-in required" instead.
final class McpNeedsUserConsent extends McpAuthOutcome {
  const McpNeedsUserConsent(this.request);

  final McpConsentRequest request;

  @override
  String toString() => 'McpNeedsUserConsent($request)';
}

enum McpAuthFailure {
  /// Offline / timeout. Keep tokens, back off, never open a browser.
  network,

  /// 5xx or `temporarily_unavailable` from the AS or metadata host.
  serverError,

  /// Not an OAuth signal (e.g. 403 without `insufficient_scope`, which can
  /// be an invalid `Origin`; 2026-07-28 Streamable HTTP L58-61).
  notAnAuthChallenge,

  /// 401 on the retry right after authorizing: circuit breaker.
  unauthorizedAfterAuthorization,

  /// Step-up exhausted: "permission not granted".
  insufficientScope,

  /// The user declined this step-up recently.
  stepUpDeclined,
  discovery,

  /// Mix-up / impersonation signal. Fatal.
  issuerMismatch,

  /// The AS does not support PKCE S256; see [PkceNotSupportedException.overridable].
  pkceUnsupported,

  /// SSRF or URL policy refused a URL.
  policyBlocked,

  /// Ask the user for a client id (show [ClientIdRequiredException.redirectUri]).
  clientIdRequired,
  registrationRejected,
  authorizationServerMismatch,
  invalidClient,
  cancelled,
  denied,
  callbackRejected,
  interactionNotAllowed,
  browserUnavailable,

  /// The grant is gone; show "Sign in required".
  signInRequired,

  /// The token endpoint refused the request (`invalid_scope`,
  /// `invalid_target`, …); see [TokenEndpointException.error].
  tokenRejected,
  protocol,
}

final class McpAuthFailed extends McpAuthOutcome {
  const McpAuthFailed(this.reason, {this.cause});

  final McpAuthFailure reason;
  final AuthException? cause;

  bool get retryable => cause?.retryable ?? false;

  @override
  String toString() => 'McpAuthFailed(${reason.name}${cause == null ? '' : ': $cause'})';
}

/// Looks up the auth config of a server by its canonical key, for flows
/// resumed after process death.
typedef McpServerConfigLookup = McpServerAuthConfig? Function(String serverKey);

final class _Discovered {
  const _Discovered(this.prm, this.server, this.at);

  final ProtectedResourceMetadata prm;
  final AuthorizationServerMetadata server;
  final DateTime at;
}

/// Glue between the MCP transport and [OAuthClient] (R02 §16).
///
/// The MCP client:
/// 1. attaches [tokenFor] to every request (proactively refreshed);
/// 2. on 401/403 calls [onResponse] and acts on the outcome: retry once
///    with [McpAuthorized], surface [McpNeedsUserConsent] to the UI (never
///    auto-open a browser — interactive auth starts only from a user tap),
///    or report [McpAuthFailed];
/// 3. passes `retried: true` when the response is to the retry, which
///    trips the circuit breaker instead of looping.
///
/// Algorithm decisions:
/// - **401**: a token already replaced by a concurrent refresh is reused;
///   else a refresh (single-flight) is tried; else discovery → consent. A
///   challenge naming a different `resource_metadata` forces re-discovery
///   (RFC 9728 §5.2) and an AS change drops the old grant (CR26 L185-191).
/// - **403 `insufficient_scope`**: consent for previously requested ∪
///   granted ∪ challenged scopes (A26 L389-394), always interactive (a
///   refresh cannot widen scope), bounded per (server, operation, scopes).
///   A 403 without that error is not an auth signal.
/// - **AS selection**: the first `authorization_servers` entry whose
///   metadata validates and passes PKCE (the previous choice first;
///   pre-registered issuers preferred), not blindly `[0]` as the SDKs do.
final class McpAuthorizer {
  McpAuthorizer({
    required this.oauth,
    McpServerConfigLookup? serverConfig,
    Future<List<InternetAddress>> Function(String host)? resolver,
    this.discoveryTtl = const Duration(hours: 1),
    this.stepUpWindow = const Duration(minutes: 10),
    this.maxAuthorizationServers = 4,
    this.freshTokenGrace = const Duration(seconds: 30),
    AuthLogger? logger,
  })  : _serverConfig = serverConfig,
        _resolver = resolver,
        _log = AuthLog(logger ?? oauth.logger);

  final OAuthClient oauth;
  final McpServerConfigLookup? _serverConfig;
  final Future<List<InternetAddress>> Function(String host)? _resolver;
  final AuthLog _log;

  /// How long discovered metadata is reused without re-fetching.
  final Duration discoveryTtl;

  /// How long step-up attempts and declines are remembered.
  final Duration stepUpWindow;
  final int maxAuthorizationServers;

  /// A 401 for a token this authorizer minted less than this long ago is
  /// treated as the failed retry (circuit breaker), even when the caller
  /// cannot pass `retried` — otherwise a server that rejects every token
  /// would cost one refresh (and one rotation) per call.
  final Duration freshTokenGrace;

  final Map<String, _Discovered> _discovered = {};
  final Map<String, String> _handedOut = {};
  final Map<String, (String, DateTime)> _minted = {};
  final Map<String, (int, DateTime)> _stepUps = {};
  final Map<String, DateTime> _declined = {};

  AuthStateStore get _store => oauth.store;

  AuthNetworkPolicy _policy(McpServerAuthConfig s) => s.networkPolicy(resolver: _resolver);

  /// The bearer token to send, or null (send without; expect a 401).
  /// Throws [AuthNetworkException] when a needed refresh is offline.
  Future<String?> tokenFor(McpServerAuthConfig server) async {
    final key = server.serverKey;
    final b = await _store.readBinding(key);
    if (b == null) return null;
    final before = await oauth.storedTokens(b.resource, issuer: b.issuer);
    final token = await oauth.accessTokenFor(b.resource, issuer: b.issuer, policy: _policy(server));
    if (token == null) {
      _handedOut.remove(key);
    } else {
      _handedOut[key] = token;
      if (before != null && before.accessToken != token) _mint(key, token);
    }
    return token;
  }

  void _mint(String key, String token) => _minted[key] = (token, oauth.clock.now());

  bool _mintedRecently(String key, String? token) {
    final m = _minted[key];
    return token != null && m != null && m.$1 == token && oauth.clock.now().difference(m.$2) < freshTokenGrace;
  }

  McpAuthorized _authorized(McpServerAuthConfig server, String token, {bool minted = true}) {
    if (minted) _mint(server.serverKey, token);
    _handedOut[server.serverKey] = token;
    return McpAuthorized(token);
  }

  /// Reacts to an MCP HTTP response. Only 401 and 403 are auth signals.
  ///
  /// [usedAccessToken] is the token the failed request carried; when the
  /// transport cannot say, the last token [tokenFor] handed out for this
  /// server is assumed. Pass [retried] for the response to the retry after
  /// [McpAuthorized]; a 401 for a token minted within [freshTokenGrace] is
  /// treated the same way.
  Future<McpAuthOutcome> onResponse(
    McpServerAuthConfig server, {
    required int statusCode,
    required Map<String, String> headers,
    String? usedAccessToken,
    bool retried = false,
    String? operation,
  }) async {
    final challenge = BearerChallenge.fromHeaders(headers);
    if (challenge != null && challenge.duplicateParams.isNotEmpty) {
      _log.warning('WWW-Authenticate repeats ${challenge.duplicateParams.join(', ')}; first values used');
    }
    final used = usedAccessToken ?? _handedOut[server.serverKey];
    try {
      return switch (statusCode) {
        401 => await _onUnauthorized(server, challenge, used, retried),
        403 => await _onForbidden(server, challenge, operation),
        _ => const McpAuthFailed(McpAuthFailure.notAnAuthChallenge),
      };
    } on AuthException catch (e) {
      return _failure(e);
    }
  }

  Future<McpAuthOutcome> _onUnauthorized(
    McpServerAuthConfig server,
    BearerChallenge? challenge,
    String? usedAccessToken,
    bool retried,
  ) async {
    if (retried) {
      _log.warning('401 from ${server.serverUrl} right after authorizing; not retrying');
      return const McpAuthFailed(McpAuthFailure.unauthorizedAfterAuthorization);
    }
    final key = server.serverKey;
    var binding = await _store.readBinding(key);
    _Discovered? discovered;
    final newMetadata = challenge?.resourceMetadata;
    if (binding != null && newMetadata != null && binding.resourceMetadataUrl != newMetadata.toString()) {
      _log.info('resource_metadata for ${server.serverUrl} changed; re-discovering');
      discovered = await _discover(server, resourceMetadataUrl: newMetadata, force: true);
      binding = await _store.readBinding(key);
    }
    final purpose = binding == null ? AuthPurpose.initial : AuthPurpose.reauthorize;
    if (binding != null) {
      final t = await oauth.storedTokens(binding.resource, issuer: binding.issuer);
      if (t != null) {
        final now = oauth.clock.now();
        if (t.accessToken != usedAccessToken && t.isFresh(now, skew: oauth.refreshSkew)) {
          // Someone refreshed (or authorized) since this request was sent.
          return _authorized(server, t.accessToken, minted: false);
        }
        if (_mintedRecently(key, usedAccessToken)) {
          _log.warning('${server.serverUrl} rejected a token issued moments ago; not refreshing again');
          return const McpAuthFailed(McpAuthFailure.unauthorizedAfterAuthorization);
        }
        if (t.canRefresh) {
          try {
            final next = await oauth.refresh(t.issuer, t.resource, ifAccessTokenIs: t.accessToken, policy: _policy(server));
            return _authorized(server, next.accessToken, minted: next.accessToken != t.accessToken);
          } on SignInRequiredException {
            // invalid_grant: tokens are gone; fall through to consent.
          } on InvalidClientException catch (e) {
            if (!e.recovered) rethrow;
          }
        }
      }
    }
    discovered ??= await _discover(server, resourceMetadataUrl: newMetadata);
    final scopes = selectScopes(
      challenged: challenge?.scopes ?? const [],
      resourceScopesSupported: discovered.prm.scopesSupported,
      serverScopesSupported: discovered.server.scopesSupported,
      requestOfflineAccess: server.requestOfflineAccess,
    );
    return McpNeedsUserConsent(McpConsentRequest(
      server: server,
      authorizationServer: discovered.server,
      resource: discovered.prm.resource,
      scopes: scopes,
      purpose: purpose,
      resourceMetadata: discovered.prm,
    ));
  }

  Future<McpAuthOutcome> _onForbidden(McpServerAuthConfig server, BearerChallenge? challenge, String? operation) async {
    if (challenge == null || !challenge.isInsufficientScope) {
      return const McpAuthFailed(McpAuthFailure.notAnAuthChallenge);
    }
    final binding = await _store.readBinding(server.serverKey);
    final union = binding == null
        ? challenge.scopes
        : await oauth.onInsufficientScope(challenge, resource: binding.resource, issuer: binding.issuer);
    if (union == null) {
      // The token already has every scope the server names.
      return const McpAuthFailed(McpAuthFailure.insufficientScope);
    }
    final key = _stepUpKey(server, operation, union);
    _expireStepUps();
    if (_declined.containsKey(key)) return const McpAuthFailed(McpAuthFailure.stepUpDeclined);
    final attempts = _stepUps[key]?.$1 ?? 0;
    if (attempts >= server.maxStepUpAttempts) {
      _log.info('step-up for ${server.serverUrl} exhausted; permission not granted');
      return const McpAuthFailed(McpAuthFailure.insufficientScope);
    }
    final discovered = await _discover(server, resourceMetadataUrl: challenge.resourceMetadata);
    return McpNeedsUserConsent(McpConsentRequest(
      server: server,
      authorizationServer: discovered.server,
      resource: discovered.prm.resource,
      scopes: union,
      purpose: AuthPurpose.stepUp,
      resourceMetadata: discovered.prm,
      operation: operation,
    ));
  }

  /// Consent for an explicit "Sign in" from server settings (no 401 yet).
  Future<McpAuthOutcome> consentFor(McpServerAuthConfig server, {List<String> scopes = const []}) async {
    try {
      final binding = await _store.readBinding(server.serverKey);
      final d = await _discover(server);
      return McpNeedsUserConsent(McpConsentRequest(
        server: server,
        authorizationServer: d.server,
        resource: d.prm.resource,
        scopes: selectScopes(
          challenged: scopes,
          resourceScopesSupported: d.prm.scopesSupported,
          serverScopesSupported: d.server.scopesSupported,
          requestOfflineAccess: server.requestOfflineAccess,
        ),
        purpose: binding == null ? AuthPurpose.initial : AuthPurpose.reauthorize,
        resourceMetadata: d.prm,
      ));
    } on AuthException catch (e) {
      return _failure(e);
    }
  }

  /// Runs the interactive authorization the user just approved.
  Future<McpAuthOutcome> authorize(McpConsentRequest consent) async {
    if (!oauth.canInteract) return const McpAuthFailed(McpAuthFailure.interactionNotAllowed);
    final server = consent.server;
    try {
      final tokens = await oauth.authorize(AuthorizationSpec(
        server: consent.authorizationServer,
        resource: consent.resource,
        scopes: consent.scopes,
        preRegistered: server.preRegisteredClients,
        purpose: consent.purpose,
        serverKey: server.serverKey,
        allowMissingPkce: server.allowMissingPkceSupport,
        ephemeral: server.ephemeralBrowser,
        policy: _policy(server),
      ));
      if (consent.purpose == AuthPurpose.stepUp) {
        final key = _stepUpKey(server, consent.operation, consent.scopes);
        _stepUps[key] = ((_stepUps[key]?.$1 ?? 0) + 1, oauth.clock.now());
        _declined.remove(key);
      }
      return _authorized(server, tokens.accessToken);
    } on AuthException catch (e) {
      return _failure(e);
    }
  }

  /// The user said "not now". For a step-up the same request is answered
  /// with [McpAuthFailure.stepUpDeclined] for [stepUpWindow] (SBP26:
  /// cache recent denials to avoid prompt loops); the tool call fails.
  void decline(McpConsentRequest consent) {
    if (consent.purpose == AuthPurpose.stepUp) {
      _declined[_stepUpKey(consent.server, consent.operation, consent.scopes)] = oauth.clock.now();
    }
  }

  /// Finishes a flow whose callback arrived in a new process (the app was
  /// killed while the browser was open).
  Future<McpAuthOutcome> completeFromCallback(Uri callback) async {
    try {
      final pending = await oauth.pendingFor(callback);
      final key = pending?.serverKey;
      final config = key == null ? null : _serverConfig?.call(key);
      final tokens = await oauth.completeAuthorization(callback, policy: config == null ? null : _policy(config));
      if (config != null) return _authorized(config, tokens.accessToken);
      return McpAuthorized(tokens.accessToken);
    } on AuthException catch (e) {
      return _failure(e);
    }
  }

  /// Revokes (best effort) and wipes this server's tokens, pending flows,
  /// binding and cached metadata. The issuer's client registration stays.
  Future<void> signOut(McpServerAuthConfig server, {bool revoke = true}) async {
    final key = server.serverKey;
    final b = await _store.readBinding(key);
    if (b != null) await oauth.signOut(b.resource, issuer: b.issuer, revoke: revoke, policy: _policy(server));
    for (final p in await _store.listPending()) {
      if (p.serverKey == key) await _store.deletePending(p.state);
    }
    await _store.deleteBinding(key);
    _discovered.remove(key);
    _handedOut.remove(key);
    _minted.remove(key);
    _stepUps.removeWhere((k, _) => k.startsWith('$key\n'));
    _declined.removeWhere((k, _) => k.startsWith('$key\n'));
  }

  // ---- discovery --------------------------------------------------------------

  Future<_Discovered> _discover(McpServerAuthConfig server, {Uri? resourceMetadataUrl, bool force = false}) async {
    final key = server.serverKey;
    final now = oauth.clock.now();
    final cached = _discovered[key];
    if (!force &&
        cached != null &&
        now.difference(cached.at) < discoveryTtl &&
        (resourceMetadataUrl == null || resourceMetadataUrl == cached.prm.metadataUrl)) {
      return cached;
    }
    final policy = _policy(server);
    final prm = await discoverProtectedResource(
      serverUrl: server.serverUrl,
      http: oauth.httpFor(policy),
      resourceMetadataUrl: resourceMetadataUrl,
      matchPolicy: server.resourceMatch,
      logger: oauth.logger,
    );
    final binding = await _store.readBinding(key);
    final as = await _selectAuthorizationServer(server, prm, binding, policy);

    if (binding != null && (binding.issuer != as.issuer || binding.resource != prm.resource)) {
      // CR26 L185-191: credentials are per issuer; a server that moved to
      // another AS (or renamed its resource) must not get the old token.
      _log.info('${server.serverUrl} moved to ${as.issuer}; dropping the grant from ${binding.issuer}');
      await _store.deleteTokens(binding.issuer, binding.resource);
    }
    await _store.writeBinding(ServerBinding(
      serverKey: key,
      resource: prm.resource,
      issuer: as.issuer,
      updatedAt: now,
      resourceMetadataUrl: prm.metadataUrl.toString(),
    ));
    final d = _Discovered(prm, as, now);
    _discovered[key] = d;
    return d;
  }

  Future<AuthorizationServerMetadata> _selectAuthorizationServer(
    McpServerAuthConfig server,
    ProtectedResourceMetadata prm,
    ServerBinding? binding,
    AuthNetworkPolicy policy,
  ) async {
    var issuers = prm.authorizationServers.take(maxAuthorizationServers).toList();
    final pre = server.preRegisteredClients;
    if (pre.isNotEmpty) {
      final preIssuers = {for (final p in pre) p.issuer};
      final usable = issuers.where(preIssuers.contains).toList();
      if (usable.isEmpty) {
        throw AuthorizationServerMismatchException(configuredIssuers: preIssuers.toList(), discoveredIssuers: issuers);
      }
      issuers = usable;
    }
    final previous = binding?.issuer;
    if (previous != null && issuers.remove(previous)) issuers.insert(0, previous);
    final problems = <AuthException>[];
    for (final issuer in issuers) {
      try {
        final as = await discoverAuthorizationServer(issuer, http: oauth.httpFor(policy), logger: oauth.logger);
        as.checkPkce(allowMissing: server.allowMissingPkceSupport, logger: oauth.logger);
        as.checkEndpoints(policy);
        return as;
      } on AuthNetworkException {
        rethrow;
      } on AuthServerException {
        rethrow;
      } on AuthException catch (e) {
        _log.info('authorization server $issuer unusable: ${e.message}');
        problems.add(e);
      }
    }
    // Prefer the most security-relevant reason.
    problems.sort((a, b) => _severity(b) - _severity(a));
    throw problems.first;
  }

  static int _severity(AuthException e) => switch (e) {
        IssuerMismatchException() => 4,
        PkceNotSupportedException() => 3,
        AuthPolicyException() => 2,
        _ => 1,
      };

  // ---- helpers --------------------------------------------------------------

  static String _stepUpKey(McpServerAuthConfig s, String? operation, List<String> scopes) =>
      '${s.serverKey}\n${operation ?? ''}\n${([...scopes]..sort()).join(' ')}';

  void _expireStepUps() {
    final now = oauth.clock.now();
    _stepUps.removeWhere((_, v) => now.difference(v.$2) >= stepUpWindow);
    _declined.removeWhere((_, at) => now.difference(at) >= stepUpWindow);
  }

  McpAuthFailed _failure(AuthException e) => McpAuthFailed(
        switch (e) {
          AuthNetworkException() => McpAuthFailure.network,
          AuthServerException() => McpAuthFailure.serverError,
          AuthPolicyException() => McpAuthFailure.policyBlocked,
          AuthProtocolException() => McpAuthFailure.protocol,
          DiscoveryException() => McpAuthFailure.discovery,
          IssuerMismatchException() => McpAuthFailure.issuerMismatch,
          PkceNotSupportedException() => McpAuthFailure.pkceUnsupported,
          ClientIdRequiredException() => McpAuthFailure.clientIdRequired,
          AuthorizationServerMismatchException() => McpAuthFailure.authorizationServerMismatch,
          RegistrationRejectedException() => McpAuthFailure.registrationRejected,
          TokenEndpointException() => McpAuthFailure.tokenRejected,
          InvalidClientException() => McpAuthFailure.invalidClient,
          AuthorizationDeniedException() => McpAuthFailure.denied,
          CallbackRejectedException(:final isSecurityViolation) =>
            isSecurityViolation ? McpAuthFailure.issuerMismatch : McpAuthFailure.callbackRejected,
          AuthCancelledException() => McpAuthFailure.cancelled,
          BrowserUnavailableException() => McpAuthFailure.browserUnavailable,
          SignInRequiredException() => McpAuthFailure.signInRequired,
          InteractiveAuthNotAllowedException() => McpAuthFailure.interactionNotAllowed,
        },
        cause: e,
      );
}
