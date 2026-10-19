import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../common/redaction.dart';
import '../discovery/authorization_server.dart';
import '../errors.dart';
import '../http/auth_http.dart';
import '../http/network_policy.dart';
import '../registration/client_registration.dart';
import '../registration/registrar.dart';
import '../store/auth_state_store.dart';
import '../www_authenticate.dart';
import 'browser.dart';
import 'device_flow.dart';
import 'issuer_check.dart';
import 'pending.dart';
import 'pkce.dart';
import 'scopes.dart';
import 'tokens.dart';

/// What to authorize: the validated AS, the resource the token is for, and
/// the scopes chosen by the caller (see `selectScopes`).
@immutable
final class AuthorizationSpec {
  const AuthorizationSpec({
    required this.server,
    required this.resource,
    this.scopes = const [],
    this.client,
    this.preRegistered = const [],
    this.purpose = AuthPurpose.initial,
    this.serverKey,
    this.allowMissingPkce = false,
    this.ephemeral = false,
    this.sendResource = true,
    this.promptConsentForOfflineAccess = true,
    this.extraParameters = const {},
    this.policy,
  });

  final AuthorizationServerMetadata server;

  /// The RFC 8707 resource: the PRM `resource` verbatim, else the
  /// canonical server URL. Also the token storage key.
  final String resource;
  final List<String> scopes;

  /// A known client; when null the registrar resolves one.
  final ClientRegistration? client;
  final List<PreRegisteredClient> preRegistered;
  final AuthPurpose purpose;
  final String? serverKey;

  /// The per-server "AS omits code_challenge_methods_supported" override.
  final bool allowMissingPkce;
  final bool ephemeral;

  /// MCP always sends `resource` (A26 L215-252). Non-MCP presets whose AS
  /// does not document RFC 8707 (Hugging Face) turn it off.
  final bool sendResource;

  /// Adds `prompt=consent` when `offline_access` is requested (OIDC Core
  /// §11; TS1 L811-816, TS2 L1222).
  final bool promptConsentForOfflineAccess;

  /// Provider-specific parameters (e.g. HF `orgIds`). Cannot override the
  /// protocol parameters.
  final Map<String, String> extraParameters;
  final AuthNetworkPolicy? policy;
}

/// An authorization URL whose flow has been recorded.
@immutable
final class PreparedAuthorization {
  const PreparedAuthorization(this.url, this.pending);

  /// Contains `state` and the PKCE challenge: do not log it raw.
  final Uri url;
  final PendingAuthorization pending;

  String get callbackScheme => Uri.parse(pending.redirectUri).scheme;

  @override
  String toString() => 'PreparedAuthorization(${AuthRedact.uri(url)})';
}

/// OAuth 2.1 authorization-code + PKCE client for a native public client.
///
/// The flow (R02 §16, S5-S8 and S11):
/// 1. [prepareAuthorization]: refuse without PKCE S256, check endpoints,
///    resolve the client id, generate verifier/state, and **persist** a
///    [PendingAuthorization] carrying the issuer, endpoints and resource.
/// 2. [authorize]: only from the foreground ([InteractionGate]); opens
///    the [BrowserLauncher] and passes the callback on.
/// 3. [completeAuthorization]: `state` → one-time pending record →
///    redirect match → RFC 9207 `iss` table → `error` → `code`, then the
///    exchange at the *recorded* token endpoint with `code_verifier` and
///    `resource`.
/// 4. [accessTokenFor]: proactive refresh `refreshSkew` before expiry;
///    [refresh] is single-flight per (issuer, resource), persists the
///    rotated token before returning it, and deletes the grant on
///    `invalid_grant`. Network errors never lead to a browser.
final class OAuthClient {
  OAuthClient({
    required AuthStateStore store,
    required BrowserLauncher browser,
    required this.identity,
    required http.Client httpClient,
    AuthNetworkPolicy policy = const AuthNetworkPolicy(),
    AuthHttpLimits limits = const AuthHttpLimits(),
    Clock clock = const SystemClock(),
    Random? random,
    InteractionGate? canInteract,
    this.pendingTtl = const Duration(minutes: 10),
    this.refreshSkew = const Duration(seconds: 60),
    String userAgent = 'sherpa-auth/0.1',
    Future<void> Function(Duration)? sleep,
    AuthLogger? logger,
  })  : _store = store,
        _browser = browser,
        _clock = clock,
        _random = random ?? Random.secure(),
        _canInteract = canInteract ?? _always,
        _sleep = sleep ?? Future<void>.delayed,
        _logger = logger,
        _log = AuthLog(logger),
        _http = AuthHttp(client: httpClient, policy: policy, limits: limits, userAgent: userAgent, logger: logger) {
    identity.validate();
    registrar = ClientRegistrar(store: store, identity: identity, clock: clock, logger: logger);
  }

  static bool _always() => true;

  final AuthStateStore _store;
  final BrowserLauncher _browser;
  final OAuthClientIdentity identity;
  final Clock _clock;
  final Random _random;
  final InteractionGate _canInteract;
  final Future<void> Function(Duration) _sleep;
  final AuthLogger? _logger;
  final AuthLog _log;
  final AuthHttp _http;
  late final ClientRegistrar registrar;

  /// Lifetime of a pending authorization (R02 §6.2: about 10 minutes).
  final Duration pendingTtl;

  /// Refresh this long before `expires_at` (R02 §8: 30-60 s).
  final Duration refreshSkew;

  final Map<String, Future<TokenSet>> _refreshFlights = {};
  final Set<String> _invalidClientRecovered = {};

  AuthStateStore get store => _store;

  Clock get clock => _clock;

  AuthLogger? get logger => _logger;

  bool get canInteract => _canInteract();

  /// The transport, optionally with a per-server network policy.
  AuthHttp httpFor([AuthNetworkPolicy? policy]) => policy == null ? _http : _http.withPolicy(policy);

  static const Set<String> _reservedParams = {
    'response_type', 'client_id', 'redirect_uri', 'code_challenge', 'code_challenge_method', //
    'state', 'scope', 'resource', 'prompt', 'nonce', 'request', 'request_uri',
  };

  // ---- authorization request ---------------------------------------------

  /// Builds the authorization URL and persists the pending flow. Does not
  /// open a browser (callers that show their own consent sheet first, or
  /// tests, use it directly).
  Future<PreparedAuthorization> prepareAuthorization(AuthorizationSpec spec) async {
    final policy = spec.policy ?? _http.policy;
    final server = spec.server;
    server.checkPkce(allowMissing: spec.allowMissingPkce, logger: _logger);
    server.checkEndpoints(policy);
    final given = spec.client;
    if (given != null && given.issuer != server.issuer) {
      throw AuthorizationServerMismatchException(configuredIssuers: [given.issuer], discoveredIssuers: [server.issuer]);
    }
    // A caller-supplied client is persisted like a resolved one, so the
    // callback leg (possibly in a new process) authenticates the same way.
    if (given != null) await _store.writeRegistration(given);
    final client = given ??
        await registrar.resolve(server, http: httpFor(policy), preRegistered: spec.preRegistered, scopes: spec.scopes);
    final pkce = Pkce.generate(_random);
    final state = randomUrlSafe(_random);
    final nonce = spec.scopes.contains('openid') ? randomUrlSafe(_random) : null;
    final scope = joinScopes(spec.scopes);
    final params = <String, String>{
      for (final e in spec.extraParameters.entries)
        if (!_reservedParams.contains(e.key)) e.key: e.value,
      'response_type': 'code',
      'client_id': client.clientId,
      'redirect_uri': client.redirectUri,
      'code_challenge': pkce.challenge,
      'code_challenge_method': Pkce.method,
      'state': state,
      'scope': ?scope,
      if (spec.sendResource) 'resource': spec.resource,
      if (spec.promptConsentForOfflineAccess && spec.scopes.contains(offlineAccessScope)) 'prompt': 'consent',
      'nonce': ?nonce,
    };
    // RFC 6749 §3.1: the endpoint's own query component MUST be retained.
    final endpoint = server.authorizationEndpoint;
    final url = endpoint.replace(queryParameters: {
      for (final e in endpoint.queryParametersAll.entries)
        if (!params.containsKey(e.key)) e.key: e.value,
      for (final e in params.entries) e.key: [e.value],
    });
    final now = _clock.now();
    final pending = PendingAuthorization(
      state: state,
      codeVerifier: pkce.verifier,
      issuer: server.issuer,
      issParameterSupported: server.authorizationResponseIssParameterSupported,
      authorizationEndpoint: endpoint,
      tokenEndpoint: server.tokenEndpoint,
      clientId: client.clientId,
      registrationKind: client.kind,
      redirectUri: client.redirectUri,
      resource: spec.resource,
      scopes: spec.scopes,
      purpose: spec.purpose,
      createdAt: now,
      expiresAt: now.add(pendingTtl),
      serverKey: spec.serverKey,
      nonce: nonce,
      sendResource: spec.sendResource,
      revocationEndpoint: server.revocationEndpoint,
      tokenEndpointAuthMethodsSupported: server.tokenEndpointAuthMethodsSupported,
    );
    // A26 L192: the issuer is recorded with the verifier *before* the
    // browser opens, so the callback leg never trusts fresh discovery.
    await _store.writePending(pending);
    _log.info('prepared ${spec.purpose.name} authorization at ${server.issuer} for ${spec.resource}');
    return PreparedAuthorization(url, pending);
  }

  /// Runs the interactive flow end to end. Call only from a user tap.
  Future<TokenSet> authorize(AuthorizationSpec spec) async {
    if (!_canInteract()) throw InteractiveAuthNotAllowedException();
    final prepared = await prepareAuthorization(spec);
    final state = prepared.pending.state;
    final Uri callback;
    try {
      callback = await _browser.authorize(
        prepared.url,
        callbackScheme: prepared.callbackScheme,
        ephemeral: spec.ephemeral,
        redirectUri: Uri.parse(prepared.pending.redirectUri),
      );
    } on AuthException {
      await _store.deletePending(state);
      rethrow;
    } on Object catch (e) {
      await _store.deletePending(state);
      throw BrowserUnavailableException('the system browser failed (${e.runtimeType})');
    }
    return completeAuthorization(callback, expectedState: state, policy: spec.policy);
  }

  // ---- authorization response --------------------------------------------

  /// The pending flow a callback belongs to, without consuming it (lets a
  /// resumed process pick the right per-server policy first).
  Future<PendingAuthorization?> pendingFor(Uri callback) async {
    final states = callback.queryParametersAll['state'];
    if (states == null || states.length != 1) return null;
    return _store.readPending(states.single);
  }

  /// Validates [callback] and redeems its code (A26 L196-213; R02 §7).
  ///
  /// Nothing from a rejected callback is surfaced: no `error_description`,
  /// no `error_uri`, and no `error` unless `state` and `iss` passed.
  Future<TokenSet> completeAuthorization(Uri callback, {String? expectedState, AuthNetworkPolicy? policy}) async {
    final params = callback.queryParametersAll;
    final states = params['state'];
    if (states == null || states.isEmpty || states.first.isEmpty) {
      _log.warning('authorization response without state dropped');
      throw CallbackRejectedException(CallbackRejection.missingState);
    }
    if (states.length > 1) throw CallbackRejectedException(CallbackRejection.duplicateParameter);
    final state = states.single;
    if (expectedState != null && state != expectedState) {
      await _store.deletePending(expectedState);
      throw CallbackRejectedException(CallbackRejection.stateMismatch);
    }
    final pending = await _store.readPending(state);
    if (pending == null) {
      _log.warning('authorization response with unknown state dropped');
      throw CallbackRejectedException(CallbackRejection.unknownState);
    }
    // One-time use: consumed before any check or network I/O.
    await _store.deletePending(state);
    if (pending.isExpired(_clock.now())) throw CallbackRejectedException(CallbackRejection.expired);
    if (!_sameRedirect(callback, pending.redirectUri)) {
      throw CallbackRejectedException(CallbackRejection.redirectMismatch);
    }
    for (final k in const ['code', 'iss', 'error']) {
      if ((params[k]?.length ?? 0) > 1) throw CallbackRejectedException(CallbackRejection.duplicateParameter);
    }
    final iss = params['iss']?.single;
    switch (checkAuthorizationResponseIssuer(
      iss: iss,
      expectedIssuer: pending.issuer,
      issParameterSupported: pending.issParameterSupported,
    )) {
      case IssCheck.ok:
        break;
      case IssCheck.mismatch:
        _log.warning('authorization response iss does not match ${pending.issuer}; possible mix-up attack');
        throw CallbackRejectedException(CallbackRejection.issuerMismatch);
      case IssCheck.missing:
        _log.warning('authorization response lacks iss although ${pending.issuer} advertises it');
        throw CallbackRejectedException(CallbackRejection.issuerMissing);
    }
    final error = params['error']?.single;
    if (error != null) throw AuthorizationDeniedException(AuthorizationErrorCode.parse(error));
    final code = params['code']?.single;
    if (code == null || code.isEmpty) throw CallbackRejectedException(CallbackRejection.missingCode);

    final client = await _registrationFor(pending.issuer, pending.clientId, pending.registrationKind, pending.redirectUri);
    final form = {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': pending.redirectUri,
      'code_verifier': pending.codeVerifier,
      if (pending.sendResource) 'resource': pending.resource,
    };
    final TokenResponse r;
    try {
      r = await _tokenRequest(pending.tokenEndpoint, form, client, pending.tokenEndpointAuthMethodsSupported, policy,
          secrets: [code, pending.codeVerifier]);
    } on TokenEndpointException catch (e) {
      if (e.isInvalidClient) throw await _onInvalidClient(client, pending.resource);
      rethrow;
    }
    final now = _clock.now();
    final tokens = TokenSet(
      issuer: pending.issuer,
      resource: pending.resource,
      clientId: client.clientId,
      accessToken: r.accessToken,
      tokenType: r.tokenType,
      tokenEndpoint: pending.tokenEndpoint,
      obtainedAt: now,
      expiresAt: r.expiresIn == null ? null : now.add(r.expiresIn!),
      refreshToken: r.refreshToken,
      requestedScopes: pending.scopes,
      grantedScopes: r.scope == null ? null : splitScopes(r.scope),
      revocationEndpoint: pending.revocationEndpoint,
      sendResource: pending.sendResource,
    );
    await _store.writeTokens(tokens);
    _log.info('authorized ${pending.resource} at ${pending.issuer}');
    return tokens;
  }

  /// Scheme (case-insensitive), host, port and path must equal the
  /// registered redirect; the query carries the response.
  static bool _sameRedirect(Uri callback, String expected) {
    final e = Uri.tryParse(expected);
    if (e == null) return false;
    return callback.scheme.toLowerCase() == e.scheme.toLowerCase() &&
        callback.host.toLowerCase() == e.host.toLowerCase() &&
        callback.port == e.port &&
        callback.path == e.path &&
        callback.userInfo.isEmpty;
  }

  // ---- tokens ---------------------------------------------------------------

  /// The stored grant for [resource] (newest if several issuers have one).
  Future<TokenSet?> storedTokens(String resource, {String? issuer}) async {
    if (issuer != null) return _store.readTokens(issuer, resource);
    final all = await _store.listTokens(resource: resource);
    if (all.isEmpty) return null;
    all.sort((a, b) => b.obtainedAt.compareTo(a.obtainedAt));
    if (all.length > 1) _log.warning('several grants for $resource; using the newest');
    return all.first;
  }

  /// A usable access token for [resource], refreshing proactively when it
  /// expires within `refreshSkew`. Null means "sign-in required" (never
  /// signed in, expired without a refresh token, or the refresh token was
  /// rejected). Transient failures throw [AuthNetworkException] /
  /// [AuthServerException] and keep the tokens.
  Future<String?> accessTokenFor(String resource, {String? issuer, AuthNetworkPolicy? policy}) async {
    final t = await storedTokens(resource, issuer: issuer);
    if (t == null) return null;
    if (t.isFresh(_clock.now(), skew: refreshSkew)) return t.accessToken;
    if (!t.canRefresh) return null;
    try {
      return (await refresh(t.issuer, t.resource, ifAccessTokenIs: t.accessToken, policy: policy)).accessToken;
    } on SignInRequiredException {
      return null;
    }
  }

  /// Refreshes the (issuer, resource) grant. Single-flight: concurrent
  /// callers share one token request, because a refresh token presented
  /// twice trips reuse detection and revokes the whole grant
  /// (OAuth 2.1 §4.3.1). With [ifAccessTokenIs], a grant whose access token
  /// has already been replaced (another caller refreshed after a 401) is
  /// returned without a new request.
  ///
  /// This is single-flight within one isolate. If another isolate or an app
  /// extension ever refreshes, it needs a cross-process lock (R02 R5).
  Future<TokenSet> refresh(String issuer, String resource, {String? ifAccessTokenIs, AuthNetworkPolicy? policy}) async {
    final key = '$issuer\n$resource';
    final existing = _refreshFlights[key];
    if (existing != null) return existing;
    final flight = _doRefresh(issuer, resource, ifAccessTokenIs, policy);
    _refreshFlights[key] = flight;
    try {
      return await flight;
    } finally {
      _refreshFlights.removeWhere((k, v) => k == key && identical(v, flight));
    }
  }

  Future<TokenSet> _doRefresh(String issuer, String resource, String? ifAccessTokenIs, AuthNetworkPolicy? policy) async {
    final t = await _store.readTokens(issuer, resource);
    if (t == null) throw SignInRequiredException(SignInReason.notSignedIn);
    if (ifAccessTokenIs != null && t.accessToken != ifAccessTokenIs && t.isFresh(_clock.now(), skew: refreshSkew)) {
      return t;
    }
    final refreshToken = t.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) throw SignInRequiredException(SignInReason.expired);
    final client = await _registrationFor(issuer, t.clientId, null, null);
    final form = {
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      if (t.sendResource) 'resource': t.resource,
    };
    final TokenResponse r;
    try {
      r = await _tokenRequest(t.tokenEndpoint, form, client, null, policy, secrets: [refreshToken, t.accessToken]);
    } on TokenEndpointException catch (e) {
      if (e.isInvalidGrant) {
        await _store.deleteTokens(issuer, resource);
        _log.info('refresh token for $resource rejected (invalid_grant); sign-in required');
        throw SignInRequiredException(SignInReason.refreshRejected);
      }
      if (e.isInvalidClient) throw await _onInvalidClient(client, resource);
      rethrow;
    }
    final next = t.refreshedWith(r, _clock.now());
    // Persist before anyone uses it: the old refresh token is dead now.
    await _store.writeTokens(next);
    _log.debug('refreshed $resource${r.refreshToken != null ? ' (rotated)' : ''}');
    return next;
  }

  /// Step-up after a 403 `insufficient_scope` (A26 L379-405): the scopes
  /// to request in a **fresh interactive** authorization — previously
  /// requested ∪ granted ∪ challenged (a refresh can never widen a grant,
  /// OAuth 2.1 §4.3.1). Returns null when asking again cannot help: the
  /// token already covers every challenged scope, so the server's demand is
  /// not something this client can satisfy (and re-prompting would loop).
  Future<List<String>?> onInsufficientScope(BearerChallenge challenge, {required String resource, String? issuer}) async {
    final t = await storedTokens(resource, issuer: issuer);
    final challenged = challenge.scopes;
    if (t != null && challenged.isNotEmpty && scopesCover(t.effectiveScopes, challenged)) return null;
    return unionScopes([t?.requestedScopes ?? const [], t?.grantedScopes ?? const [], challenged]);
  }

  /// Drops the grant(s) for [resource] after best-effort RFC 7009
  /// revocation, and any pending flows for it. The issuer's client
  /// registration is kept: other servers may share that AS (R02 §13).
  Future<void> signOut(String resource, {String? issuer, bool revoke = true, AuthNetworkPolicy? policy}) async {
    final sets = issuer != null
        ? [?await _store.readTokens(issuer, resource)]
        : await _store.listTokens(resource: resource);
    for (final t in sets) {
      final endpoint = t.revocationEndpoint;
      if (revoke && endpoint != null) await _revoke(t, endpoint, policy);
      await _store.deleteTokens(t.issuer, t.resource);
    }
    for (final p in await _store.listPending()) {
      if (p.resource == resource && (issuer == null || p.issuer == issuer)) await _store.deletePending(p.state);
    }
  }

  Future<void> _revoke(TokenSet t, Uri endpoint, AuthNetworkPolicy? policy) async {
    final token = t.refreshToken ?? t.accessToken;
    try {
      final client = await _registrationFor(t.issuer, t.clientId, null, null);
      final (form, headers) = _clientAuth(client, null, {
        'token': token,
        'token_type_hint': t.refreshToken != null ? 'refresh_token' : 'access_token',
      });
      final resp = await httpFor(policy).postForm(endpoint, form, headers: headers, secrets: [token, client.clientSecret]);
      if (!resp.ok) _log.info('revocation at ${t.issuer} answered HTTP ${resp.statusCode}');
    } on AuthException catch (e) {
      _log.info('revocation at ${t.issuer} failed: ${e.message}');
    }
  }

  /// Deletes expired pending flows; returns how many.
  Future<int> purgeExpiredPending() async {
    final now = _clock.now();
    var n = 0;
    for (final p in await _store.listPending()) {
      if (p.isExpired(now)) {
        await _store.deletePending(p.state);
        n++;
      }
    }
    return n;
  }

  /// Removes the stored client registration for [issuer] (user "reset").
  Future<void> forgetRegistration(String issuer) async {
    _invalidClientRecovered.remove(issuer);
    await _store.deleteRegistration(issuer);
  }

  // ---- device authorization (RFC 8628) ----------------------------------------

  /// Starts a device authorization. User-initiated like [authorize], but
  /// needs no browser on this device.
  Future<DeviceAuthorization> startDeviceAuthorization({
    required AuthorizationServerMetadata server,
    required ClientRegistration client,
    required String resource,
    List<String> scopes = const [],
    bool sendResource = true,
    AuthNetworkPolicy? policy,
  }) async {
    final endpoint = server.deviceAuthorizationEndpoint;
    if (endpoint == null) {
      throw DiscoveryException(DiscoveryFailure.authorizationServerInvalid, '${server.issuer} has no device authorization endpoint');
    }
    final scope = joinScopes(scopes);
    final (form, headers) = _clientAuth(client, server.tokenEndpointAuthMethodsSupported, {
      'scope': ?scope,
      if (sendResource) 'resource': resource,
    });
    final resp = await httpFor(policy).postForm(endpoint, form, headers: headers, secrets: [client.clientSecret]);
    final j = _parseOAuthJson(resp, endpoint, const []);
    final deviceCode = j['device_code'];
    final userCode = j['user_code'];
    final verification = j['verification_uri'] ?? j['verification_url'];
    final expiresIn = j['expires_in'];
    if (deviceCode is! String || userCode is! String || verification is! String || expiresIn is! num) {
      throw AuthProtocolException('malformed device authorization response', url: endpoint);
    }
    final p = policy ?? _http.policy;
    final verificationUri = p.checkSyntax(Uri.parse(verification));
    final complete = j['verification_uri_complete'];
    final interval = j['interval'];
    return DeviceAuthorization(
      issuer: server.issuer,
      resource: resource,
      clientId: client.clientId,
      tokenEndpoint: server.tokenEndpoint,
      deviceCode: deviceCode,
      userCode: AuthRedact.untrusted(userCode, max: 32),
      verificationUri: verificationUri,
      verificationUriComplete: complete is String ? _safeUri(complete, p) : null,
      expiresAt: _clock.now().add(Duration(seconds: expiresIn.toInt())),
      interval: Duration(seconds: interval is num && interval > 0 ? interval.toInt() : 5),
      scopes: scopes,
      sendResource: sendResource,
      revocationEndpoint: server.revocationEndpoint,
    );
  }

  static Uri? _safeUri(String raw, AuthNetworkPolicy policy) {
    try {
      return policy.checkSyntax(Uri.parse(raw));
    } on Object {
      return null;
    }
  }

  /// Polls until the user approves, denies, or the code expires
  /// (RFC 8628 §3.4-3.5): `authorization_pending` waits, `slow_down` adds
  /// 5 s, a network error doubles the interval.
  Future<TokenSet> pollDeviceAuthorization(
    DeviceAuthorization d, {
    CancellationToken? cancel,
    AuthNetworkPolicy? policy,
  }) async {
    var interval = d.interval;
    final client = await _registrationFor(d.issuer, d.clientId, null, null);
    while (true) {
      cancel?.throwIfCancelled();
      if (!_clock.now().isBefore(d.expiresAt)) throw AuthorizationDeniedException(AuthorizationErrorCode.expiredToken);
      await _sleep(interval);
      cancel?.throwIfCancelled();
      final form = {
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        'device_code': d.deviceCode,
        if (d.sendResource) 'resource': d.resource,
      };
      final TokenResponse r;
      try {
        r = await _tokenRequest(d.tokenEndpoint, form, client, null, policy, secrets: [d.deviceCode]);
      } on TokenEndpointException catch (e) {
        switch (e.error) {
          case 'authorization_pending':
            continue;
          case 'slow_down':
            interval += const Duration(seconds: 5);
            continue;
          case 'access_denied':
            throw AuthorizationDeniedException(AuthorizationErrorCode.accessDenied);
          case 'expired_token':
            throw AuthorizationDeniedException(AuthorizationErrorCode.expiredToken);
        }
        rethrow;
      } on AuthNetworkException {
        interval *= 2;
        continue;
      }
      final now = _clock.now();
      final tokens = TokenSet(
        issuer: d.issuer,
        resource: d.resource,
        clientId: d.clientId,
        accessToken: r.accessToken,
        tokenType: r.tokenType,
        tokenEndpoint: d.tokenEndpoint,
        obtainedAt: now,
        expiresAt: r.expiresIn == null ? null : now.add(r.expiresIn!),
        refreshToken: r.refreshToken,
        requestedScopes: d.scopes,
        grantedScopes: r.scope == null ? null : splitScopes(r.scope),
        revocationEndpoint: d.revocationEndpoint,
        sendResource: d.sendResource,
      );
      await _store.writeTokens(tokens);
      return tokens;
    }
  }

  // ---- token endpoint -------------------------------------------------------

  /// The client a grant belongs to. If the stored registration is gone or
  /// was replaced, fall back to a public client with the recorded id: a
  /// public client needs nothing else, and a confidential one will get
  /// `invalid_client`, which is handled.
  Future<ClientRegistration> _registrationFor(String issuer, String clientId, RegistrationKind? kind, String? redirectUri) async {
    final stored = await _store.readRegistration(issuer);
    if (stored != null && stored.clientId == clientId) return stored;
    _log.debug('no stored registration for client at $issuer; using it as a public client');
    return ClientRegistration(
      kind: kind ?? stored?.kind ?? RegistrationKind.dynamic,
      issuer: issuer,
      clientId: clientId,
      redirectUri: redirectUri ?? stored?.redirectUri ?? identity.redirectUri,
    );
  }

  /// `invalid_client`: drop the tokens; drop a DCR registration once so the
  /// next user-initiated sign-in registers afresh (TS "invalidate and retry
  /// once", but without an automatic browser). Pre-registered and CIMD ids
  /// are never dropped silently.
  ///
  /// A grant whose client is no longer the stored registration (it was
  /// replaced meanwhile) only loses its tokens: the current registration
  /// is not touched.
  Future<InvalidClientException> _onInvalidClient(ClientRegistration client, String resource) async {
    await _store.deleteTokens(client.issuer, resource);
    if (client.kind != RegistrationKind.dynamic) {
      _log.warning('${client.kind.name} client at ${client.issuer} rejected (invalid_client)');
      return InvalidClientException(client.issuer, client.kind, recovered: false);
    }
    final stored = await _store.readRegistration(client.issuer);
    if (stored == null || stored.clientId != client.clientId) {
      return InvalidClientException(client.issuer, client.kind, recovered: true);
    }
    if (_invalidClientRecovered.add(client.issuer)) {
      await _store.deleteRegistration(client.issuer);
      _log.warning('dynamic registration at ${client.issuer} rejected; removed');
      return InvalidClientException(client.issuer, client.kind, recovered: true);
    }
    _log.warning('replacement registration at ${client.issuer} rejected too (invalid_client)');
    return InvalidClientException(client.issuer, client.kind, recovered: false);
  }

  /// Applies client authentication (R02 §5.5). `client_secret_basic` uses
  /// RFC 6749 §2.3.1 form-encoding of id and secret before base64 (the TS
  /// SDKs skip the encoding; mcp_dart does it right).
  (Map<String, String>, Map<String, String>) _clientAuth(
    ClientRegistration client,
    List<String>? supported,
    Map<String, String> form,
  ) {
    final method = selectTokenEndpointAuthMethod(client, supported);
    final body = {...form};
    final headers = <String, String>{};
    switch (method) {
      case 'client_secret_basic':
        final creds = '${Uri.encodeQueryComponent(client.clientId)}:${Uri.encodeQueryComponent(client.clientSecret!)}';
        headers['authorization'] = 'Basic ${base64.encode(utf8.encode(creds))}';
      case 'client_secret_post':
        body['client_id'] = client.clientId;
        body['client_secret'] = client.clientSecret!;
      default:
        body['client_id'] = client.clientId;
    }
    return (body, headers);
  }

  Future<TokenResponse> _tokenRequest(
    Uri endpoint,
    Map<String, String> form,
    ClientRegistration client,
    List<String>? supported,
    AuthNetworkPolicy? policy, {
    List<String?> secrets = const [],
  }) async {
    final (body, headers) = _clientAuth(client, supported, form);
    final allSecrets = [...secrets, client.clientSecret];
    final resp = await httpFor(policy).postForm(endpoint, body, headers: headers, secrets: allSecrets);
    final j = _parseOAuthJson(resp, endpoint, allSecrets);
    return TokenResponse.fromJson(j, url: endpoint);
  }

  static final RegExp _errorCode = RegExp(r'^[\x20\x21\x23-\x5b\x5d-\x7e]{1,64}$');

  /// Maps a token/device endpoint response (RFC 6749 §5.1-5.2): 2xx JSON
  /// without `error` is returned; a 200 carrying `error` (TS2 L1282-1288)
  /// and 4xx `error` bodies become [TokenEndpointException]; 5xx and
  /// `server_error` / `temporarily_unavailable` are retryable
  /// [AuthServerException]s; anything else is a protocol error.
  JsonMap _parseOAuthJson(AuthHttpResponse resp, Uri endpoint, List<String?> secrets) {
    final status = resp.statusCode;
    if (resp.oversized) throw AuthProtocolException('response too large', statusCode: status, url: endpoint);
    if (resp.isRedirect) throw AuthProtocolException('endpoint answered with a redirect', statusCode: status, url: endpoint);
    final j = resp.jsonObject();
    final err = j?['error'];
    if (err is String) {
      final code = _errorCode.hasMatch(err) ? err : 'invalid_error_code';
      if (code == 'server_error' || code == 'temporarily_unavailable' || status >= 500) {
        throw AuthServerException('authorization server error ($code)', statusCode: status, url: endpoint);
      }
      final desc = j!['error_description'];
      throw TokenEndpointException(code,
          statusCode: status,
          description: desc is String ? AuthRedact.untrusted(desc, secrets: secrets) : null,
          url: endpoint);
    }
    if (resp.ok) {
      if (j == null) throw AuthProtocolException('response is not a JSON object', statusCode: status, url: endpoint);
      return j;
    }
    if (status >= 500) throw AuthServerException('HTTP $status', statusCode: status, url: endpoint);
    if (status == 401) throw TokenEndpointException('invalid_client', statusCode: status, url: endpoint);
    throw AuthProtocolException('unexpected HTTP $status', statusCode: status, url: endpoint);
  }
}
