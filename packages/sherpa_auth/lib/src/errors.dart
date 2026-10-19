import 'common/redaction.dart';
import 'registration/client_registration.dart' show RegistrationKind;

/// Typed OAuth failures. Branch on the subtype (or on [retryable] /
/// [requiresSignIn]); never on [message].
///
/// Messages and URLs are redacted at construction, and nothing the server
/// sent is included verbatim: `error_description`, callback errors and
/// metadata strings are attacker-controlled (R02 §14.9), so subclasses keep
/// only enumerated codes or sanitised, length-capped text.
sealed class AuthException implements Exception {
  AuthException(String message, {Uri? url})
      : message = AuthRedact.text(message),
        url = url == null ? null : AuthRedact.uri(url);

  final String message;
  final Uri? url;

  /// Whether retrying later *without user interaction* can succeed
  /// (offline, 5xx). The caller backs off; it never opens a browser.
  bool get retryable => false;

  /// Whether the right next step is an interactive sign-in started from a
  /// user tap (R02 Q4: interactive OAuth never starts on its own).
  bool get requiresSignIn => false;

  /// Stable label for [toString]; `runtimeType` is obfuscated in release builds.
  String get label;

  @override
  String toString() => '$label: $message${url == null ? '' : ' [$url]'}';
}

/// No response: DNS failure, refused connection, TLS failure or timeout.
///
/// Deliberately *not* a reason to start an interactive authorization
/// (R02 §9: the TS SDKs fall through to a new authorization on a refresh
/// network error, which opens a browser while the user is offline).
final class AuthNetworkException extends AuthException {
  AuthNetworkException(super.message, {super.url});

  @override
  bool get retryable => true;

  @override
  String get label => 'AuthNetworkException';
}

/// The authorization server or resource answered 5xx (or an OAuth
/// `server_error` / `temporarily_unavailable`).
final class AuthServerException extends AuthException {
  AuthServerException(super.message, {this.statusCode, super.url});

  final int? statusCode;

  @override
  bool get retryable => true;

  @override
  String get label => 'AuthServerException';
}

/// A URL was refused before any request was sent: SSRF policy (private,
/// loopback, link-local, non-canonical numeric host), a non-https endpoint,
/// a dangerous scheme (`javascript:`, `data:`, …) or a redirect that left the
/// origin.
final class AuthPolicyException extends AuthException {
  AuthPolicyException(super.message, {super.url});

  @override
  String get label => 'AuthPolicyException';
}

/// A response did not have the shape the protocol requires (oversized
/// body, non-JSON token response, unsupported `token_type`, …).
final class AuthProtocolException extends AuthException {
  AuthProtocolException(super.message, {this.statusCode, super.url});

  final int? statusCode;

  @override
  String get label => 'AuthProtocolException';
}

enum DiscoveryFailure {
  /// No Protected Resource Metadata at the header URL or either well-known URL.
  resourceMetadataNotFound,

  /// A PRM document was found but is not valid RFC 9728 JSON.
  resourceMetadataInvalid,

  /// The PRM `resource` does not identify the server we are talking to
  /// (RFC 9728 §3.3, §7.3 impersonation defence).
  resourceMismatch,

  /// The PRM lists no authorization server (required by MCP, ASD26 L14-15).
  noAuthorizationServers,

  /// No AS metadata at any of the RFC 8414 / OIDC Discovery URLs.
  authorizationServerNotFound,

  /// AS metadata was found but is unusable (missing endpoints, no `code`
  /// response type, unsafe endpoint URLs, malformed issuer).
  authorizationServerInvalid,
}

/// Discovery could not produce usable metadata.
final class DiscoveryException extends AuthException {
  DiscoveryException(this.failure, super.message, {super.url});

  final DiscoveryFailure failure;

  @override
  String get label => 'DiscoveryException(${failure.name})';
}

/// AS metadata whose `issuer` is not identical to the issuer the discovery
/// URL was built from (ASD26 L94, RFC 8414 §3.3). Fatal: it is the signature
/// of a mix-up or impersonation attempt, so it is never retried.
final class IssuerMismatchException extends AuthException {
  IssuerMismatchException({required this.expected, required String actual, super.url})
      : actual = AuthRedact.untrusted(actual, max: 120),
        super('metadata issuer does not match the expected issuer $expected');

  final String expected;

  /// Sanitised copy of what the document claimed.
  final String actual;

  @override
  String get label => 'IssuerMismatchException';
}

/// The authorization server does not advertise PKCE `S256`.
///
/// MCP requires clients to refuse when `code_challenge_methods_supported`
/// is absent (SC26 L50-61); both TS SDKs proceed anyway. Sherpa refuses,
/// with a per-server user override for the *absent* case only
/// ([overridable]); a list that is present but lacks `S256` is never
/// overridable.
final class PkceNotSupportedException extends AuthException {
  PkceNotSupportedException(this.issuer, {required this.advertised})
      : super(advertised
            ? 'authorization server $issuer does not support PKCE S256'
            : 'authorization server $issuer does not advertise PKCE support (code_challenge_methods_supported is absent)');

  final String issuer;

  /// True when the list exists but lacks `S256`.
  final bool advertised;

  /// Whether the per-server "I accept the risk" override may bypass it.
  bool get overridable => !advertised;

  @override
  String get label => 'PkceNotSupportedException';
}

/// No way to obtain a client id: nothing pre-registered for [issuer], no
/// CIMD support and no registration endpoint (CR26 L13-18, step 4). The UI
/// asks the user to register an OAuth app with [redirectUri] and paste the
/// client id.
final class ClientIdRequiredException extends AuthException {
  ClientIdRequiredException(this.issuer, this.redirectUri)
      : super('authorization server $issuer needs a pre-registered client id');

  final String issuer;
  final String redirectUri;

  @override
  String get label => 'ClientIdRequiredException';
}

/// The server now points at an authorization server for which the user's
/// pre-registered credentials were not issued. Surfaced instead of silently
/// sending the wrong client id (CR26 L193-197).
final class AuthorizationServerMismatchException extends AuthException {
  AuthorizationServerMismatchException({required this.configuredIssuers, required this.discoveredIssuers})
      : super('pre-registered client is for ${configuredIssuers.join(', ')}, '
            'but the server uses ${discoveredIssuers.join(', ')}');

  final List<String> configuredIssuers;
  final List<String> discoveredIssuers;

  @override
  String get label => 'AuthorizationServerMismatchException';
}

/// Dynamic Client Registration was refused (RFC 7591 §3.2.2) after the
/// attempt ladder was exhausted.
final class RegistrationRejectedException extends AuthException {
  RegistrationRejectedException(this.errorCode, {this.statusCode, super.url})
      : super('client registration rejected ($errorCode)');

  /// `invalid_redirect_uri`, `invalid_client_metadata`, … or `http_<status>`.
  final String errorCode;
  final int? statusCode;

  @override
  String get label => 'RegistrationRejectedException';
}

/// An OAuth error response from the token (or device authorization)
/// endpoint (RFC 6749 §5.2, RFC 8707 §2, RFC 8628 §3.5).
final class TokenEndpointException extends AuthException {
  TokenEndpointException(this.error, {this.statusCode, String? description, super.url})
      : description = description == null ? null : AuthRedact.untrusted(description),
        super('token endpoint returned $error${statusCode == null ? '' : ' (HTTP $statusCode)'}');

  /// The `error` code, e.g. `invalid_grant`.
  final String error;
  final int? statusCode;

  /// Sanitised `error_description`; display-only, untrusted.
  final String? description;

  bool get isInvalidGrant => error == 'invalid_grant';

  bool get isInvalidClient => error == 'invalid_client' || error == 'unauthorized_client';

  @override
  String get label => 'TokenEndpointException';
}

/// The authorization server rejected the client itself (`invalid_client`
/// / `unauthorized_client`).
///
/// For a DCR registration the stale registration and its tokens have been
/// dropped once ([recovered]); the next user-initiated sign-in registers
/// afresh. A pre-registered or CIMD client id is never dropped silently
/// (R02 §9): the user must fix the configuration.
final class InvalidClientException extends AuthException {
  InvalidClientException(this.issuer, this.registrationKind, {required this.recovered})
      : super(recovered
            ? 'authorization server $issuer no longer accepts the dynamic registration; it was removed'
            : 'authorization server $issuer rejected the ${registrationKind.name} client id');

  final String issuer;
  final RegistrationKind registrationKind;
  final bool recovered;

  @override
  bool get requiresSignIn => recovered;

  @override
  String get label => 'InvalidClientException';
}

/// Authorization error codes a callback or device poll may carry
/// (RFC 6749 §4.1.2.1, OIDC Core §3.1.2.6, RFC 8707, RFC 8628).
enum AuthorizationErrorCode {
  accessDenied('access_denied'),
  invalidRequest('invalid_request'),
  unauthorizedClient('unauthorized_client'),
  unsupportedResponseType('unsupported_response_type'),
  invalidScope('invalid_scope'),
  invalidTarget('invalid_target'),
  serverError('server_error'),
  temporarilyUnavailable('temporarily_unavailable'),
  loginRequired('login_required'),
  consentRequired('consent_required'),
  interactionRequired('interaction_required'),
  expiredToken('expired_token'),
  other('other');

  const AuthorizationErrorCode(this.wire);

  final String wire;

  /// Maps a wire value; unknown or malformed values become [other] so the
  /// server's string is never echoed.
  static AuthorizationErrorCode parse(String? wire) {
    for (final c in values) {
      if (c.wire == wire && c != other) return c;
    }
    return other;
  }
}

/// The authorization server answered the authorization request with an
/// error, *after* `state` and `iss` were validated. Only the enumerated
/// [code] survives; `error_description` and `error_uri` are dropped.
final class AuthorizationDeniedException extends AuthException {
  AuthorizationDeniedException(this.code) : super('authorization failed: ${code.wire}');

  final AuthorizationErrorCode code;

  /// `access_denied`: the user said no (or closed the consent page).
  bool get userDenied => code == AuthorizationErrorCode.accessDenied;

  @override
  bool get retryable =>
      code == AuthorizationErrorCode.temporarilyUnavailable || code == AuthorizationErrorCode.serverError;

  @override
  String get label => 'AuthorizationDeniedException';
}

/// Why a callback was dropped before its code or error was looked at.
enum CallbackRejection {
  /// No `state` parameter.
  missingState,

  /// No pending authorization has this `state` (forged, replayed or used).
  unknownState,

  /// The pending authorization expired.
  expired,

  /// The browser returned a callback for a different flow than it was opened for.
  stateMismatch,

  /// The callback URL is not the redirect URI registered for the flow.
  redirectMismatch,

  /// `iss` differs from the recorded issuer (RFC 9207 mix-up defence).
  issuerMismatch,

  /// The AS advertises `iss` support but the response lacks it.
  issuerMissing,

  /// A response parameter appeared more than once (RFC 6749 §3.1).
  duplicateParameter,

  /// Neither `code` nor `error`.
  missingCode,
}

/// A callback that failed validation. Nothing from it is surfaced; in
/// particular an `error_description` arriving with a mismatched `iss` is
/// never displayed (A26 L213).
final class CallbackRejectedException extends AuthException {
  CallbackRejectedException(this.reason) : super('authorization response rejected: ${reason.name}');

  final CallbackRejection reason;

  /// Issuer failures are security events, not user errors.
  bool get isSecurityViolation =>
      reason == CallbackRejection.issuerMismatch || reason == CallbackRejection.issuerMissing;

  @override
  String get label => 'CallbackRejectedException';
}

/// The user closed the browser or auth session. Thrown by the app's
/// `BrowserLauncher` implementation.
final class AuthCancelledException extends AuthException {
  AuthCancelledException([super.message = 'authorization cancelled by the user']);

  @override
  String get label => 'AuthCancelledException';
}

/// No system authentication session could be opened (no browser, Auth Tab
/// verification failure, …). Thrown by the app's `BrowserLauncher`.
final class BrowserUnavailableException extends AuthException {
  BrowserUnavailableException(super.message);

  @override
  String get label => 'BrowserUnavailableException';
}

enum SignInReason {
  /// No tokens for this resource.
  notSignedIn,

  /// The access token expired and there is no refresh token.
  expired,

  /// The refresh token was rejected (`invalid_grant`); tokens were deleted.
  refreshRejected,

  /// The server moved to another authorization server; old tokens were dropped.
  authorizationServerChanged,
}

/// An interactive sign-in is needed. Callers surface "Sign in required" and
/// wait for a user tap; they never start the browser themselves.
final class SignInRequiredException extends AuthException {
  SignInRequiredException(this.reason, {super.url}) : super('sign-in required (${reason.name})');

  final SignInReason reason;

  @override
  bool get requiresSignIn => true;

  @override
  String get label => 'SignInRequiredException';
}

/// An interactive authorization was requested while the app is not in the
/// foreground, or without a user gesture. Background runs fail fast with
/// "sign-in required" instead (R02 Q4, R06/R07 background limits).
final class InteractiveAuthNotAllowedException extends AuthException {
  InteractiveAuthNotAllowedException() : super('interactive authorization is only allowed from the foreground');

  @override
  bool get requiresSignIn => true;

  @override
  String get label => 'InteractiveAuthNotAllowedException';
}
