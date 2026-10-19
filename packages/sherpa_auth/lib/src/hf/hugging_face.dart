import 'package:sherpa_core/sherpa_core.dart';

import '../discovery/authorization_server.dart';
import '../flow/device_flow.dart';
import '../flow/oauth_client.dart';
import '../flow/pending.dart';
import '../flow/tokens.dart';
import '../registration/client_registration.dart';

/// "Sign in with Hugging Face" on top of [OAuthClient] (R08 §8).
///
/// - Public (secretless) OAuth app registered at
///   `huggingface.co/settings/applications/new`; [clientId] is that app's
///   id and [redirectUri] must match its registered redirect **exactly**
///   (custom schemes are exact-match, R08 §8.2).
/// - Authorization code + PKCE S256 (the only method HF advertises); the
///   verifier is 43 chars, the minimum HF enforces.
/// - Scopes `openid profile gated-repos inference-api` (R08 §15.5);
///   `inference-api` lets the app spend the user's HF credits, so the UI
///   should explain it (R08 Q2).
/// - HF's discovery omits `none` from `token_endpoint_auth_methods_supported`
///   although public apps work; the client is used as a public client
///   anyway. No `scopes_supported` → no `offline_access`. Whether HF
///   issues refresh tokens to public clients is UNVERIFIED (R08 risk 6);
///   without one, [accessToken] returns null after ~8 h and the user signs
///   in again.
/// - The RFC 8707 `resource` parameter is **not** sent: HF does not
///   document it and an AS that does not implement RFC 8707 may reject it
///   (`invalid_target`). [resource] is only the local storage key.
/// - `openid` is requested, so a `nonce` is sent; the `id_token` is not
///   used (identity comes from `/api/whoami-v2` or `/oauth/userinfo`).
final class HuggingFaceOAuth {
  HuggingFaceOAuth({
    required this.oauth,
    required this.clientId,
    String? redirectUri,
    this.scopes = defaultScopes,
    Uri? hubUri,
    AuthorizationServerMetadata? metadata,
  })  : hubUri = hubUri ?? defaultHub,
        redirectUri = redirectUri ?? oauth.identity.redirectUri,
        _metadata = metadata {
    OAuthClientIdentity.checkRedirectUri(this.redirectUri);
  }

  static const List<String> defaultScopes = ['openid', 'profile', 'gated-repos', 'inference-api'];

  static final Uri defaultHub = Uri.parse('https://huggingface.co');

  final OAuthClient oauth;
  final String clientId;
  final String redirectUri;
  final List<String> scopes;
  final Uri hubUri;
  AuthorizationServerMetadata? _metadata;

  /// `https://huggingface.co` (the live discovery `issuer`).
  String get issuer => hubUri.origin;

  /// Storage key for the grant (not sent to HF).
  String get resource => issuer;

  /// The live discovery document as of 2026-10-18 (R08 §8.1), so sign-in
  /// needs no discovery round trip. [refreshMetadata] re-fetches it.
  AuthorizationServerMetadata get metadata => _metadata ??= staticMetadata(hubUri);

  static AuthorizationServerMetadata staticMetadata(Uri hub) {
    Uri at(String path) => hub.replace(path: path);
    return AuthorizationServerMetadata(
      issuer: hub.origin,
      authorizationEndpoint: at('/oauth/authorize'),
      tokenEndpoint: at('/oauth/token'),
      registrationEndpoint: at('/oauth/register'),
      deviceAuthorizationEndpoint: at('/oauth/device'),
      userinfoEndpoint: at('/oauth/userinfo'),
      responseTypesSupported: const ['code'],
      codeChallengeMethodsSupported: const ['S256'],
      tokenEndpointAuthMethodsSupported: const ['client_secret_basic', 'client_secret_post'],
      grantTypesSupported: const [
        'urn:ietf:params:oauth:grant-type:token-exchange',
        'urn:ietf:params:oauth:grant-type:device_code',
        'authorization_code',
        'refresh_token',
      ],
      clientIdMetadataDocumentSupported: true,
    );
  }

  /// Re-reads the discovery document (issuer echo checked as for MCP).
  Future<AuthorizationServerMetadata> refreshMetadata() async =>
      _metadata = await discoverAuthorizationServer(issuer, http: oauth.httpFor(), logger: oauth.logger);

  ClientRegistration get client => ClientRegistration(
        kind: RegistrationKind.preRegistered,
        issuer: issuer,
        clientId: clientId,
        redirectUri: redirectUri,
      );

  /// Interactive sign-in. Call only from a user tap. [orgId] restricts
  /// the grant to one organisation (HF `orgIds`).
  Future<TokenSet> signIn({bool ephemeral = false, List<String>? scopes, String? orgId}) => oauth.authorize(AuthorizationSpec(
        server: metadata,
        resource: resource,
        scopes: scopes ?? this.scopes,
        client: client,
        purpose: AuthPurpose.initial,
        serverKey: resource,
        ephemeral: ephemeral,
        sendResource: false,
        extraParameters: {'orgIds': ?orgId},
      ));

  /// The current access token (refreshed when possible), or null when the
  /// user must sign in.
  Future<String?> accessToken() => oauth.accessTokenFor(resource, issuer: issuer);

  Future<TokenSet?> tokens() => oauth.storedTokens(resource, issuer: issuer);

  Future<void> signOut() => oauth.signOut(resource, issuer: issuer, revoke: false);

  /// RFC 8628 fallback (TV-style): show [DeviceAuthorization.userCode] and
  /// [DeviceAuthorization.verificationUri], then [completeDeviceSignIn].
  Future<DeviceAuthorization> startDeviceSignIn({List<String>? scopes}) => oauth.startDeviceAuthorization(
        server: metadata,
        client: client,
        resource: resource,
        scopes: scopes ?? this.scopes,
        sendResource: false,
      );

  Future<TokenSet> completeDeviceSignIn(DeviceAuthorization authorization, {CancellationToken? cancel}) =>
      oauth.pollDeviceAuthorization(authorization, cancel: cancel);
}
