import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../registration/client_registration.dart';

/// Why an interactive authorization was started.
enum AuthPurpose {
  /// First sign-in for a server.
  initial,

  /// The grant was lost (refresh rejected, AS changed, signed out).
  reauthorize,

  /// 403 `insufficient_scope`: more scopes needed (A26 L379-405).
  stepUp,
}

/// Everything needed to finish an authorization after the browser returns,
/// recorded **before** the browser opens (A26 L192; RFC 9700 §4.4.2).
///
/// It is persisted because the OS may kill the app while the user is in
/// the browser (Android especially); the callback then arrives in a new
/// process. The record is one-time use and expires ([expiresAt], ~10 min).
///
/// The code is redeemed at the recorded [tokenEndpoint], never one derived
/// from fresh discovery, and `iss` is checked against the recorded [issuer]
/// (mix-up defence, R02 §14.6). [state] and [codeVerifier] are secrets.
@immutable
final class PendingAuthorization {
  const PendingAuthorization({
    required this.state,
    required this.codeVerifier,
    required this.issuer,
    required this.issParameterSupported,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    required this.clientId,
    required this.registrationKind,
    required this.redirectUri,
    required this.resource,
    required this.scopes,
    required this.purpose,
    required this.createdAt,
    required this.expiresAt,
    this.serverKey,
    this.nonce,
    this.sendResource = true,
    this.revocationEndpoint,
    this.tokenEndpointAuthMethodsSupported,
  });

  factory PendingAuthorization.fromJson(JsonMap j) => PendingAuthorization(
        state: j.req<String>('state'),
        codeVerifier: j.req<String>('code_verifier'),
        issuer: j.req<String>('issuer'),
        issParameterSupported: j.req<bool>('iss_param_supported'),
        authorizationEndpoint: Uri.parse(j.req<String>('authorization_endpoint')),
        tokenEndpoint: Uri.parse(j.req<String>('token_endpoint')),
        clientId: j.req<String>('client_id'),
        registrationKind: RegistrationKind.values.byName(j.req<String>('registration_kind')),
        redirectUri: j.req<String>('redirect_uri'),
        resource: j.req<String>('resource'),
        scopes: List.unmodifiable((j.opt<List<Object?>>('scope') ?? const []).cast<String>()),
        purpose: AuthPurpose.values.byName(j.req<String>('purpose')),
        createdAt: DateTime.parse(j.req<String>('created_at')),
        expiresAt: DateTime.parse(j.req<String>('expires_at')),
        serverKey: j.opt<String>('server_key'),
        nonce: j.opt<String>('nonce'),
        sendResource: j.opt<bool>('send_resource') ?? true,
        revocationEndpoint: j.opt<String>('revocation_endpoint') == null ? null : Uri.parse(j.req<String>('revocation_endpoint')),
        tokenEndpointAuthMethodsSupported: (j.opt<List<Object?>>('token_endpoint_auth_methods_supported'))?.cast<String>(),
      );

  final String state;
  final String codeVerifier;

  /// The validated metadata `issuer` the request was sent to.
  final String issuer;

  /// RFC 9207 `authorization_response_iss_parameter_supported` at that time.
  final bool issParameterSupported;
  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;
  final String clientId;
  final RegistrationKind registrationKind;
  final String redirectUri;
  final String resource;
  final List<String> scopes;
  final AuthPurpose purpose;
  final DateTime createdAt;
  final DateTime expiresAt;

  /// The canonical MCP server URL (or another caller-defined key) the flow
  /// belongs to, so a resumed process can route the result.
  final String? serverKey;

  /// OIDC `nonce`, sent only when `openid` is requested. The `id_token` is
  /// not used, so it is recorded but never verified.
  final String? nonce;
  final bool sendResource;
  final Uri? revocationEndpoint;
  final List<String>? tokenEndpointAuthMethodsSupported;

  bool isExpired(DateTime now) => !now.isBefore(expiresAt);

  JsonMap toJson() => compact({
        'state': state,
        'code_verifier': codeVerifier,
        'issuer': issuer,
        'iss_param_supported': issParameterSupported,
        'authorization_endpoint': authorizationEndpoint.toString(),
        'token_endpoint': tokenEndpoint.toString(),
        'client_id': clientId,
        'registration_kind': registrationKind.name,
        'redirect_uri': redirectUri,
        'resource': resource,
        'scope': scopes,
        'purpose': purpose.name,
        'created_at': createdAt.toUtc().toIso8601String(),
        'expires_at': expiresAt.toUtc().toIso8601String(),
        'server_key': serverKey,
        'nonce': nonce,
        if (!sendResource) 'send_resource': false,
        'revocation_endpoint': revocationEndpoint?.toString(),
        'token_endpoint_auth_methods_supported': tokenEndpointAuthMethodsSupported,
      });

  @override
  String toString() => 'PendingAuthorization($issuer, $resource, ${purpose.name}, expires: ${expiresAt.toIso8601String()})';
}
