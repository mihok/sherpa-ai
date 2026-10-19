import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../common/redaction.dart';
import '../errors.dart';
import '../http/auth_http.dart';
import '../http/network_policy.dart';

/// OAuth 2.0 Authorization Server Metadata (RFC 8414 §2) or an OpenID
/// Provider configuration (OIDC Discovery §3), parsed by one lenient model.
///
/// Only what OAuth needs is required (`issuer`, `authorization_endpoint`,
/// `token_endpoint`, `response_types_supported` ∋ `code`): TS2's OIDC schema
/// also demands `jwks_uri`, `subject_types_supported` and
/// `id_token_signing_alg_values_supported`, which makes OAuth-only servers
/// that publish `openid-configuration` fail (R02 §4.3). Endpoints must be
/// absolute http(s) URLs without fragments; `javascript:`, `data:`, `file:`
/// and every other scheme make the document invalid (SBP26 "OAuth
/// Authorization URL Validation"). Whether plain http is acceptable is a
/// network-policy decision made when an endpoint is used.
///
/// Boolean capabilities count only as a literal JSON `true` (CIMD-02 §6,
/// RFC 9207 §3; TS2 `isIssParameterSupported`): `"true"` is not true.
@immutable
final class AuthorizationServerMetadata {
  const AuthorizationServerMetadata({
    required this.issuer,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    this.responseTypesSupported = const ['code'],
    this.registrationEndpoint,
    this.revocationEndpoint,
    this.deviceAuthorizationEndpoint,
    this.userinfoEndpoint,
    this.grantTypesSupported,
    this.codeChallengeMethodsSupported,
    this.tokenEndpointAuthMethodsSupported,
    this.scopesSupported,
    this.clientIdMetadataDocumentSupported = false,
    this.authorizationResponseIssParameterSupported = false,
    this.metadataUrl,
  });

  /// Throws [FormatError] when a required member is missing or unsafe.
  factory AuthorizationServerMetadata.fromJson(JsonMap j, {Uri? metadataUrl}) {
    final issuer = j.req<String>('issuer');
    final responseTypes = _strings(j, 'response_types_supported');
    if (responseTypes == null) throw const FormatError('"response_types_supported" is required');
    if (!responseTypes.contains('code')) {
      throw const FormatError('authorization server does not support response_type=code');
    }
    return AuthorizationServerMetadata(
      issuer: issuer,
      authorizationEndpoint: _endpoint(j, 'authorization_endpoint', required: true)!,
      tokenEndpoint: _endpoint(j, 'token_endpoint', required: true)!,
      responseTypesSupported: responseTypes,
      registrationEndpoint: _endpoint(j, 'registration_endpoint'),
      revocationEndpoint: _endpoint(j, 'revocation_endpoint'),
      deviceAuthorizationEndpoint: _endpoint(j, 'device_authorization_endpoint'),
      userinfoEndpoint: _endpoint(j, 'userinfo_endpoint'),
      grantTypesSupported: _strings(j, 'grant_types_supported'),
      codeChallengeMethodsSupported: _strings(j, 'code_challenge_methods_supported'),
      tokenEndpointAuthMethodsSupported: _strings(j, 'token_endpoint_auth_methods_supported'),
      scopesSupported: _strings(j, 'scopes_supported'),
      clientIdMetadataDocumentSupported: j['client_id_metadata_document_supported'] == true,
      authorizationResponseIssParameterSupported: j['authorization_response_iss_parameter_supported'] == true,
      metadataUrl: metadataUrl,
    );
  }

  /// The validated issuer: recorded with every pending authorization for
  /// the RFC 9207 `iss` check and used to key client credentials and tokens.
  final String issuer;
  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;
  final List<String> responseTypesSupported;
  final Uri? registrationEndpoint;
  final Uri? revocationEndpoint;
  final Uri? deviceAuthorizationEndpoint;
  final Uri? userinfoEndpoint;
  final List<String>? grantTypesSupported;

  /// Null when absent, which MCP treats as "no PKCE" (see [checkPkce]).
  final List<String>? codeChallengeMethodsSupported;
  final List<String>? tokenEndpointAuthMethodsSupported;
  final List<String>? scopesSupported;
  final bool clientIdMetadataDocumentSupported;
  final bool authorizationResponseIssParameterSupported;

  /// Where the document came from; null for built-in presets.
  final Uri? metadataUrl;

  /// SC26 L50-61: refuse unless `S256` is advertised. When the list is
  /// *absent*, [allowMissing] (a per-server user override, default off;
  /// R02 Q6/R3) lets the flow proceed — PKCE S256 is still sent, the AS
  /// simply never promised to verify it. A list without `S256` is never
  /// overridable.
  void checkPkce({bool allowMissing = false, AuthLogger? logger}) {
    final methods = codeChallengeMethodsSupported;
    if (methods == null) {
      if (!allowMissing) throw PkceNotSupportedException(issuer, advertised: false);
      AuthLog(logger).warning('$issuer does not advertise PKCE; proceeding because the user override is on');
      return;
    }
    if (!methods.contains('S256')) throw PkceNotSupportedException(issuer, advertised: true);
  }

  /// Checks the endpoints this process will open or call against
  /// [policy] (syntax only; the fetch layer resolves DNS at send time).
  void checkEndpoints(AuthNetworkPolicy policy) {
    policy.checkSyntax(authorizationEndpoint);
    policy.checkSyntax(tokenEndpoint);
  }

  JsonMap toJson() => compact({
        'issuer': issuer,
        'authorization_endpoint': authorizationEndpoint.toString(),
        'token_endpoint': tokenEndpoint.toString(),
        'response_types_supported': responseTypesSupported,
        'registration_endpoint': registrationEndpoint?.toString(),
        'revocation_endpoint': revocationEndpoint?.toString(),
        'device_authorization_endpoint': deviceAuthorizationEndpoint?.toString(),
        'userinfo_endpoint': userinfoEndpoint?.toString(),
        'grant_types_supported': grantTypesSupported,
        'code_challenge_methods_supported': codeChallengeMethodsSupported,
        'token_endpoint_auth_methods_supported': tokenEndpointAuthMethodsSupported,
        'scopes_supported': scopesSupported,
        if (clientIdMetadataDocumentSupported) 'client_id_metadata_document_supported': true,
        if (authorizationResponseIssParameterSupported) 'authorization_response_iss_parameter_supported': true,
      });

  @override
  String toString() => 'AuthorizationServerMetadata($issuer)';
}

List<String>? _strings(JsonMap j, String key) {
  final v = j[key];
  if (v == null) return null;
  if (v is! List) throw FormatError('"$key" must be an array of strings');
  return List.unmodifiable([
    for (final e in v)
      if (e is String) e else throw FormatError('"$key" must be an array of strings'),
  ]);
}

Uri? _endpoint(JsonMap j, String key, {bool required = false}) {
  final v = j[key];
  if (v == null) {
    if (required) throw FormatError('"$key" is required');
    return null;
  }
  if (v is! String) throw FormatError('"$key" must be a string');
  final u = Uri.tryParse(v);
  final scheme = u?.scheme.toLowerCase();
  if (u == null || !u.isAbsolute || u.host.isEmpty || u.userInfo.isNotEmpty || (scheme != 'https' && scheme != 'http')) {
    throw FormatError('"$key" is not an absolute http(s) URL');
  }
  return u;
}

/// Parses an issuer identifier: an absolute http(s) URL with no query or
/// fragment (RFC 8414 §2). Throws [DiscoveryException] otherwise.
Uri parseIssuer(String issuer) {
  final u = Uri.tryParse(issuer);
  final scheme = u?.scheme.toLowerCase();
  if (u == null || !u.hasScheme || u.host.isEmpty || u.hasQuery || u.hasFragment || u.userInfo.isNotEmpty ||
      (scheme != 'https' && scheme != 'http')) {
    throw DiscoveryException(
        DiscoveryFailure.authorizationServerInvalid, 'not a valid issuer identifier: ${AuthRedact.untrusted(issuer, max: 120)}');
  }
  return u;
}

/// The discovery URLs for [issuer], in the order ASD26 L75-92 mandates.
///
/// With a path (`https://as/tenant1`):
/// 1. `/.well-known/oauth-authorization-server/tenant1` (RFC 8414 insertion)
/// 2. `/.well-known/openid-configuration/tenant1` (OIDC with insertion)
/// 3. `/tenant1/.well-known/openid-configuration` (OIDC Discovery appending)
///
/// Without a path: `/.well-known/oauth-authorization-server`, then
/// `/.well-known/openid-configuration`. One trailing `/` is stripped first,
/// so `https://as/` is pathless. mcp_dart's fourth probe
/// (`{path}/.well-known/oauth-authorization-server`) is not in the spec and
/// is not tried.
List<Uri> authorizationServerMetadataUrls(String issuer) {
  final u = parseIssuer(issuer);
  final path = u.path.endsWith('/') ? u.path.substring(0, u.path.length - 1) : u.path;
  final origin = u.origin;
  if (path.isEmpty) {
    return [
      Uri.parse('$origin/.well-known/oauth-authorization-server'),
      Uri.parse('$origin/.well-known/openid-configuration'),
    ];
  }
  return [
    Uri.parse('$origin/.well-known/oauth-authorization-server$path'),
    Uri.parse('$origin/.well-known/openid-configuration$path'),
    Uri.parse('$origin$path/.well-known/openid-configuration'),
  ];
}

/// ASD26 L94 / RFC 8414 §3.3: the document's `issuer` MUST be identical to
/// the issuer the URL was built from. Comparison is by code point on the
/// raw strings (RFC 9728 §6, RFC 3986 §6.2.1) — no URL normalisation, so
/// case, default ports and percent-encoding all matter.
///
/// One tolerance, in one direction only (TS2 L1152-1155): an expected
/// issuer ending in `/` matches a document issuer without it, because
/// some PRMs publish `https://as/` for an AS whose issuer is `https://as`.
/// The reverse is not accepted.
bool issuerMatches(String expected, String documentIssuer) {
  if (expected == documentIssuer) return true;
  return expected.endsWith('/') && expected.substring(0, expected.length - 1) == documentIssuer;
}

/// Discovers and validates the metadata of [issuer] (a raw string taken
/// from PRM `authorization_servers`).
///
/// Per candidate (R02 §4.2, Sherpa column):
/// - no response → [AuthNetworkException] (offline is a hard error);
/// - 4xx, 502 or an unfollowed (cross-origin) redirect → next;
/// - other 5xx → [AuthServerException];
/// - 200 with invalid JSON/schema → next, remembering the error;
/// - 200 whose `issuer` is not identical → the document is not used, next.
///
/// When nothing validates: [IssuerMismatchException] if any document
/// claimed another issuer (the ASD26 attacker example), else the last
/// schema error, else [DiscoveryFailure.authorizationServerNotFound]. There
/// is no 2025-03-26 default-endpoint fallback.
Future<AuthorizationServerMetadata> discoverAuthorizationServer(
  String issuer, {
  required AuthHttp http,
  AuthLogger? logger,
}) async {
  final log = AuthLog(logger);
  IssuerMismatchException? mismatch;
  DiscoveryException? invalid;
  for (final url in authorizationServerMetadataUrls(issuer)) {
    final resp = await http.get(url);
    final status = resp.statusCode;
    if (resp.ok) {
      final json = resp.jsonObject();
      if (json == null) {
        invalid = DiscoveryException(DiscoveryFailure.authorizationServerInvalid, 'AS metadata is not a JSON object', url: url);
        log.info('AS metadata at ${AuthRedact.uri(url)} is not JSON; trying the next location');
        continue;
      }
      final docIssuer = json['issuer'];
      if (docIssuer is String && !issuerMatches(issuer, docIssuer)) {
        mismatch = IssuerMismatchException(expected: issuer, actual: docIssuer, url: url);
        log.warning('AS metadata at ${AuthRedact.uri(url)} claims issuer ${mismatch.actual}, expected $issuer; ignored');
        continue;
      }
      if (docIssuer is String && docIssuer != issuer) {
        log.info('issuer $issuer accepted for document issuer $docIssuer (trailing-slash tolerance)');
      }
      try {
        return AuthorizationServerMetadata.fromJson(json, metadataUrl: resp.url);
      } on FormatError catch (e) {
        invalid = DiscoveryException(DiscoveryFailure.authorizationServerInvalid, 'invalid AS metadata: ${e.message}', url: url);
        log.info('invalid AS metadata at ${AuthRedact.uri(url)}: ${e.message}');
        continue;
      }
    }
    if (status >= 500 && status != 502) {
      throw AuthServerException('AS metadata request failed with HTTP $status', statusCode: status, url: url);
    }
    log.debug('no AS metadata at ${AuthRedact.uri(url)} (HTTP $status)');
  }
  if (mismatch != null) throw mismatch;
  throw invalid ??
      DiscoveryException(DiscoveryFailure.authorizationServerNotFound, 'no authorization server metadata for $issuer');
}
