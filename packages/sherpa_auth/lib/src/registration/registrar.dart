import 'package:sherpa_core/sherpa_core.dart';

import '../common/redaction.dart';
import '../discovery/authorization_server.dart';
import '../errors.dart';
import '../flow/scopes.dart';
import '../http/auth_http.dart';
import '../store/auth_state_store.dart';
import 'client_registration.dart';

/// Obtains a client id for an authorization server, in the CR26 L13-18
/// priority order:
///
/// 1. **Pre-registered** credentials for exactly that issuer (config wins
///    over anything stored). Pre-registered credentials for *other*
///    issuers only are an [AuthorizationServerMismatchException], never a
///    silent fallback (CR26 L193-197).
/// 2. A **stored registration** for the issuer (an earlier DCR result, or
///    the CIMD id if still applicable) — TS2 treats stored client info as
///    step 1 too.
/// 3. **CIMD**, only when the AS metadata has
///    `client_id_metadata_document_supported: true` (literal `true`) and
///    Sherpa has a metadata document URL.
/// 4. **DCR** (deprecated, still functional) when there is a
///    `registration_endpoint`.
/// 5. Otherwise [ClientIdRequiredException]: the UI asks the user.
///
/// Every resolved registration is persisted under its issuer, so the
/// callback leg of a flow (possibly in a new process) finds the same client.
final class ClientRegistrar {
  ClientRegistrar({
    required AuthStateStore store,
    required this.identity,
    Clock clock = const SystemClock(),
    AuthLogger? logger,
  })  : _store = store,
        _clock = clock,
        _log = AuthLog(logger);

  final AuthStateStore _store;
  final OAuthClientIdentity identity;
  final Clock _clock;
  final AuthLog _log;
  final Map<String, Future<ClientRegistration>> _inFlight = {};

  Future<ClientRegistration> resolve(
    AuthorizationServerMetadata server, {
    required AuthHttp http,
    List<PreRegisteredClient> preRegistered = const [],
    List<String> scopes = const [],
  }) async {
    final issuer = server.issuer;
    if (preRegistered.isNotEmpty) {
      final match = preRegistered.where((p) => p.issuer == issuer).firstOrNull;
      if (match == null) {
        throw AuthorizationServerMismatchException(
          configuredIssuers: [for (final p in preRegistered) p.issuer],
          discoveredIssuers: [issuer],
        );
      }
      final reg = match.toRegistration(identity.redirectUri);
      await _store.writeRegistration(reg);
      return reg;
    }

    final stored = await _store.readRegistration(issuer);
    if (stored != null && _storedStillValid(stored, server)) {
      _log.debug('using stored ${stored.kind.name} registration for $issuer');
      return stored;
    }

    final cimd = identity.metadataDocumentUrl;
    if (server.clientIdMetadataDocumentSupported && cimd != null) {
      final reg = ClientRegistration(
        kind: RegistrationKind.metadataDocument,
        issuer: issuer,
        clientId: cimd,
        redirectUri: identity.cimdRedirectUri,
        registeredAt: _clock.now(),
      );
      await _store.writeRegistration(reg);
      return reg;
    }

    if (server.registrationEndpoint != null) {
      final existing = _inFlight[issuer];
      if (existing != null) return existing;
      final flight = _register(server, http, scopes);
      _inFlight[issuer] = flight;
      try {
        return await flight;
      } finally {
        _inFlight.removeWhere((k, v) => k == issuer && identical(v, flight));
      }
    }

    throw ClientIdRequiredException(issuer, identity.redirectUri);
  }

  bool _storedStillValid(ClientRegistration r, AuthorizationServerMetadata server) => switch (r.kind) {
        // The config is authoritative for pre-registered clients; a stale
        // copy whose config was removed is not used.
        RegistrationKind.preRegistered => false,
        RegistrationKind.metadataDocument =>
          server.clientIdMetadataDocumentSupported && r.clientId == identity.metadataDocumentUrl,
        RegistrationKind.dynamic => !r.secretExpired(_clock.now()),
      };

  /// The DCR attempt ladder (R02 §5.4; at most 3 attempts):
  /// 1. `native` + claimed https (literal MCP compliance);
  /// 2. `web` + claimed https (strict OIDC ASes reject native + https);
  /// 3. `native` + the private-use scheme (classic RFC 8252 client).
  ///
  /// Only an RFC 7591 400-class rejection moves to the next rung; a
  /// network error or 5xx stops immediately.
  Future<ClientRegistration> _register(AuthorizationServerMetadata server, AuthHttp http, List<String> scopes) async {
    final endpoint = server.registrationEndpoint!;
    final httpsRedirect = identity.httpsRedirectUri ?? (identity.redirectUri.startsWith('https:') ? identity.redirectUri : null);
    final customRedirect = identity.redirectUri.startsWith('https:') ? null : identity.redirectUri;
    final attempts = <(String, String)>[
      if (httpsRedirect != null) ('native', httpsRedirect),
      if (httpsRedirect != null) ('web', httpsRedirect),
      if (customRedirect != null) ('native', customRedirect),
    ].take(3);
    var lastError = 'invalid_client_metadata';
    int? lastStatus;
    for (final (appType, redirect) in attempts) {
      final body = compact({
        'client_name': identity.clientName,
        'client_uri': identity.clientUri,
        'logo_uri': identity.logoUri,
        'policy_uri': identity.policyUri,
        'tos_uri': identity.tosUri,
        'software_id': identity.softwareId,
        'software_version': identity.softwareVersion,
        'redirect_uris': [redirect],
        'grant_types': const ['authorization_code', 'refresh_token'],
        'response_types': const ['code'],
        'token_endpoint_auth_method': 'none',
        'application_type': appType,
        'scope': joinScopes(scopes),
      });
      final resp = await http.postJson(endpoint, body);
      final status = resp.statusCode;
      if (resp.ok) {
        final j = resp.jsonObject();
        final clientId = j?['client_id'];
        if (j == null || clientId is! String || clientId.isEmpty) {
          throw AuthProtocolException('registration response has no client_id', statusCode: status, url: endpoint);
        }
        final echoed = j['redirect_uris'];
        if (echoed is List && echoed.isNotEmpty && !echoed.contains(redirect)) {
          // The AS substituted a redirect we cannot receive.
          lastError = 'invalid_redirect_uri';
          lastStatus = status;
          _log.warning('registration at ${server.issuer} replaced the redirect URI; trying the next option');
          continue;
        }
        final secret = j['client_secret'] is String ? j['client_secret']! as String : null;
        final expiresAt = j['client_secret_expires_at'];
        final method = j['token_endpoint_auth_method'];
        final reg = ClientRegistration(
          kind: RegistrationKind.dynamic,
          issuer: server.issuer,
          clientId: clientId,
          redirectUri: redirect,
          clientSecret: secret,
          clientSecretExpiresAt: expiresAt is num && expiresAt > 0
              ? DateTime.fromMillisecondsSinceEpoch(expiresAt.toInt() * 1000, isUtc: true)
              : null,
          tokenEndpointAuthMethod: method is String ? method : (secret == null ? 'none' : 'client_secret_basic'),
          registrationAccessToken: j['registration_access_token'] is String ? j['registration_access_token']! as String : null,
          registrationClientUri: j['registration_client_uri'] is String ? j['registration_client_uri']! as String : null,
          applicationType: appType,
          registeredAt: _clock.now(),
        );
        await _store.writeRegistration(reg);
        _log.info('registered dynamically with ${server.issuer} ($appType)');
        return reg;
      }
      if (status >= 500) {
        throw AuthServerException('client registration failed with HTTP $status', statusCode: status, url: endpoint);
      }
      final err = resp.jsonObject()?['error'];
      lastError = err is String && RegExp(r'^[a-z0-9_]{1,64}$').hasMatch(err) ? err : 'http_$status';
      lastStatus = status;
      _log.info('registration at ${server.issuer} rejected ($lastError) for $appType ${AuthRedact.untrusted(redirect)}');
      if (status != 400) break; // 401/403 (initial access token required), redirects: no point retrying.
    }
    throw RegistrationRejectedException(lastError, statusCode: lastStatus, url: endpoint);
  }
}
