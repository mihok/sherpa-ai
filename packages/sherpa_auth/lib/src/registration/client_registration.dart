import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

/// Where a client id came from (CR26 L13-18).
enum RegistrationKind {
  /// Configured by the user or built into the app for a specific issuer.
  preRegistered,

  /// Client ID Metadata Document: the client id is Sherpa's HTTPS JSON URL.
  metadataDocument,

  /// RFC 7591 Dynamic Client Registration (deprecated in 2026-07-28).
  dynamic,
}

/// Client credentials for one authorization server, keyed by [issuer]
/// (CR26 L183-191: credentials MUST be bound to the issuer and are not
/// reused when a server moves to another AS).
///
/// [clientSecret] and [registrationAccessToken] are secrets: they only ever
/// live in the `SecretStore`-backed state store and never appear in
/// [toString].
@immutable
final class ClientRegistration {
  const ClientRegistration({
    required this.kind,
    required this.issuer,
    required this.clientId,
    required this.redirectUri,
    this.clientSecret,
    this.clientSecretExpiresAt,
    this.tokenEndpointAuthMethod = 'none',
    this.registrationAccessToken,
    this.registrationClientUri,
    this.applicationType,
    this.registeredAt,
  });

  factory ClientRegistration.fromJson(JsonMap j) => ClientRegistration(
        kind: RegistrationKind.values.byName(j.req<String>('kind')),
        issuer: j.req<String>('issuer'),
        clientId: j.req<String>('client_id'),
        redirectUri: j.req<String>('redirect_uri'),
        clientSecret: j.opt<String>('client_secret'),
        clientSecretExpiresAt: j.optDate('client_secret_expires_at'),
        tokenEndpointAuthMethod: j.opt<String>('token_endpoint_auth_method') ?? 'none',
        registrationAccessToken: j.opt<String>('registration_access_token'),
        registrationClientUri: j.opt<String>('registration_client_uri'),
        applicationType: j.opt<String>('application_type'),
        registeredAt: j.optDate('registered_at'),
      );

  final RegistrationKind kind;
  final String issuer;
  final String clientId;

  /// The one redirect URI registered for this client; every authorization
  /// request with this client uses exactly this string (OAuth 2.1 §2.3.1).
  final String redirectUri;
  final String? clientSecret;

  /// RFC 7591 `client_secret_expires_at`; null when the secret never expires.
  final DateTime? clientSecretExpiresAt;

  /// `none`, `client_secret_basic` or `client_secret_post`.
  final String tokenEndpointAuthMethod;
  final String? registrationAccessToken;
  final String? registrationClientUri;
  final String? applicationType;
  final DateTime? registeredAt;

  bool secretExpired(DateTime now) => clientSecretExpiresAt != null && !now.isBefore(clientSecretExpiresAt!);

  JsonMap toJson() => compact({
        'kind': kind.name,
        'issuer': issuer,
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'client_secret': clientSecret,
        'client_secret_expires_at': clientSecretExpiresAt?.toUtc().toIso8601String(),
        'token_endpoint_auth_method': tokenEndpointAuthMethod,
        'registration_access_token': registrationAccessToken,
        'registration_client_uri': registrationClientUri,
        'application_type': applicationType,
        'registered_at': registeredAt?.toUtc().toIso8601String(),
      });

  @override
  String toString() => 'ClientRegistration(${kind.name}, $issuer, $clientId${clientSecret == null ? '' : ', secret: «redacted»'})';
}

/// Client credentials the user (or the app build) registered by hand for
/// one issuer (CR26 L128-136). Sherpa is a public client and never ships a
/// secret; a secret entered by the user for their own OAuth app is stored in
/// the secret store like any other credential.
@immutable
final class PreRegisteredClient {
  const PreRegisteredClient({
    required this.issuer,
    required this.clientId,
    this.clientSecret,
    this.redirectUri,
    this.tokenEndpointAuthMethod,
  });

  /// Exact issuer string the credentials were issued by.
  final String issuer;
  final String clientId;
  final String? clientSecret;

  /// The redirect registered with the provider; defaults to the identity's.
  final String? redirectUri;
  final String? tokenEndpointAuthMethod;

  ClientRegistration toRegistration(String defaultRedirectUri) => ClientRegistration(
        kind: RegistrationKind.preRegistered,
        issuer: issuer,
        clientId: clientId,
        clientSecret: clientSecret,
        redirectUri: redirectUri ?? defaultRedirectUri,
        tokenEndpointAuthMethod:
            tokenEndpointAuthMethod ?? (clientSecret == null ? 'none' : 'client_secret_basic'),
      );

  @override
  String toString() => 'PreRegisteredClient($issuer, $clientId)';
}

/// Sherpa's identity as an OAuth client: the values of the Client ID
/// Metadata Document and of DCR requests, and the redirect URIs.
///
/// Redirects (R02 §11): [redirectUri] is the reverse-DNS private-use scheme
/// Sherpa uses today (RFC 8252 §7.1, e.g. `io.github.mihok.sherpa:/oauth/callback`).
/// [httpsRedirectUri] is the claimed-https callback once a Sherpa domain
/// exists (PLAN Q10); when set it is preferred for CIMD and DCR.
@immutable
final class OAuthClientIdentity {
  const OAuthClientIdentity({
    required this.clientName,
    required this.redirectUri,
    this.httpsRedirectUri,
    this.metadataDocumentUrl,
    this.metadataDocumentRedirectUri,
    this.clientUri,
    this.logoUri,
    this.policyUri,
    this.tosUri,
    this.softwareId,
    this.softwareVersion,
  });

  final String clientName;
  final String redirectUri;
  final String? httpsRedirectUri;

  /// The CIMD `client_id` (an https URL serving the JSON document). Null
  /// until Sherpa hosts one; CIMD is then skipped.
  final String? metadataDocumentUrl;

  /// The redirect listed in that document; defaults to [httpsRedirectUri],
  /// then [redirectUri].
  final String? metadataDocumentRedirectUri;
  final String? clientUri;
  final String? logoUri;
  final String? policyUri;
  final String? tosUri;
  final String? softwareId;
  final String? softwareVersion;

  String get cimdRedirectUri => metadataDocumentRedirectUri ?? httpsRedirectUri ?? redirectUri;

  /// Throws [ArgumentError] for an identity that would fail at an AS.
  void validate() {
    checkRedirectUri(redirectUri);
    if (httpsRedirectUri != null) {
      checkRedirectUri(httpsRedirectUri!);
      if (Uri.parse(httpsRedirectUri!).scheme != 'https') {
        throw ArgumentError.value(httpsRedirectUri, 'httpsRedirectUri', 'must be https');
      }
    }
    if (metadataDocumentUrl != null) checkMetadataDocumentUrl(metadataDocumentUrl!);
    if (metadataDocumentRedirectUri != null) checkRedirectUri(metadataDocumentRedirectUri!);
  }

  /// CIMD-02 §3: an https URL with a path other than `/`, no userinfo,
  /// fragment, query, or `.`/`..` segments (compared as a plain string by
  /// the AS, so it must be written in its final form).
  static void checkMetadataDocumentUrl(String url) {
    final u = Uri.tryParse(url);
    String? problem;
    if (u == null || u.scheme != 'https' || u.host.isEmpty) {
      problem = 'must be an https URL';
    } else if (u.userInfo.isNotEmpty) {
      problem = 'must not contain userinfo';
    } else if (u.hasFragment || url.contains('#')) {
      problem = 'must not contain a fragment';
    } else if (u.hasQuery || url.contains('?')) {
      problem = 'must not contain a query';
    } else if (u.path.isEmpty || u.path == '/') {
      problem = 'must have a path';
    } else if (url.split('?').first.split('/').skip(3).any((s) => s == '.' || s == '..')) {
      problem = 'must not contain dot segments';
    }
    if (problem != null) throw ArgumentError.value(url, 'metadataDocumentUrl', problem);
  }

  /// A redirect is https, loopback http, or a private-use scheme containing
  /// a dot (RFC 8252 §7.1, §8.4: ASes SHOULD reject schemes without one).
  /// Never a fragment.
  static void checkRedirectUri(String uri) {
    final u = Uri.tryParse(uri);
    if (u == null || !u.hasScheme || u.hasFragment) {
      throw ArgumentError.value(uri, 'redirectUri', 'not an absolute URI without fragment');
    }
    final scheme = u.scheme.toLowerCase();
    if (scheme == 'https') return;
    if (scheme == 'http') {
      final h = u.host.toLowerCase();
      if (h == 'localhost' || h == '127.0.0.1' || h == '::1') return;
      throw ArgumentError.value(uri, 'redirectUri', 'plain http is only allowed for loopback');
    }
    const dangerous = {'javascript', 'data', 'file', 'vbscript', 'about', 'blob'};
    if (dangerous.contains(scheme) || !scheme.contains('.')) {
      throw ArgumentError.value(uri, 'redirectUri', 'private-use schemes must be reverse-DNS (contain a dot)');
    }
  }
}

/// Client authentication method for the token endpoint (R02 §5.5, TS
/// `selectClientAuthMethod`), except that a method needing a secret is
/// never chosen without one.
String selectTokenEndpointAuthMethod(ClientRegistration client, List<String>? supported) {
  final hasSecret = client.clientSecret != null && client.clientSecret!.isNotEmpty;
  const known = {'none', 'client_secret_basic', 'client_secret_post'};
  final list = supported ?? const <String>[];
  final own = client.tokenEndpointAuthMethod;
  final ownUsable = known.contains(own) && (own == 'none' || hasSecret);
  if (ownUsable && (list.isEmpty || list.contains(own))) return own;
  if (!hasSecret) return 'none';
  if (list.isEmpty || list.contains('client_secret_basic')) return 'client_secret_basic';
  if (list.contains('client_secret_post')) return 'client_secret_post';
  if (list.contains('none')) return 'none';
  return 'client_secret_post';
}
