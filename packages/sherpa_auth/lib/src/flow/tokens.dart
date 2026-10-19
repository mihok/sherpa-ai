import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../errors.dart';
import 'scopes.dart';

/// Tokens for one (issuer, resource) grant.
///
/// Stored as a single JSON value so a rotated refresh token replaces the
/// old one atomically (OAuth 2.1 §4.3.2; a crash between two writes would
/// otherwise leave a revoked refresh token behind and trip reuse
/// detection). [clientId] is recorded because a refresh must be made by
/// the client the grant was issued to; tokens whose client no longer
/// matches the issuer's registration are unusable.
///
/// [tokenEndpoint] and [revocationEndpoint] were validated at authorization
/// time, so refresh and sign-out need no new discovery.
@immutable
final class TokenSet {
  const TokenSet({
    required this.issuer,
    required this.resource,
    required this.clientId,
    required this.accessToken,
    required this.tokenEndpoint,
    required this.obtainedAt,
    this.tokenType = 'Bearer',
    this.expiresAt,
    this.refreshToken,
    this.requestedScopes = const [],
    this.grantedScopes,
    this.revocationEndpoint,
    this.sendResource = true,
  });

  factory TokenSet.fromJson(JsonMap j) => TokenSet(
        issuer: j.req<String>('issuer'),
        resource: j.req<String>('resource'),
        clientId: j.req<String>('client_id'),
        accessToken: j.req<String>('access_token'),
        tokenType: j.opt<String>('token_type') ?? 'Bearer',
        tokenEndpoint: Uri.parse(j.req<String>('token_endpoint')),
        obtainedAt: DateTime.parse(j.req<String>('obtained_at')),
        expiresAt: j.optDate('expires_at'),
        refreshToken: j.opt<String>('refresh_token'),
        requestedScopes: List.unmodifiable((j.opt<List<Object?>>('requested_scope') ?? const []).cast<String>()),
        grantedScopes: j['granted_scope'] == null
            ? null
            : List.unmodifiable((j.req<List<Object?>>('granted_scope')).cast<String>()),
        revocationEndpoint: j.opt<String>('revocation_endpoint') == null ? null : Uri.parse(j.req<String>('revocation_endpoint')),
        sendResource: j.opt<bool>('send_resource') ?? true,
      );

  final String issuer;

  /// The RFC 8707 resource the token is bound to (the PRM `resource`
  /// verbatim, or the canonical server URL).
  final String resource;
  final String clientId;
  final String accessToken;
  final String tokenType;
  final Uri tokenEndpoint;
  final DateTime obtainedAt;

  /// From `expires_in`; null when the AS did not say (valid until a 401).
  final DateTime? expiresAt;
  final String? refreshToken;

  /// What was asked for.
  final List<String> requestedScopes;

  /// The response `scope`; null when omitted, which RFC 6749 §5.1 defines
  /// as "identical to the requested scope".
  final List<String>? grantedScopes;
  final Uri? revocationEndpoint;

  /// Whether the `resource` parameter is sent on refresh (always for MCP).
  final bool sendResource;

  List<String> get effectiveScopes => grantedScopes ?? requestedScopes;

  bool get canRefresh => refreshToken != null && refreshToken!.isNotEmpty;

  /// Usable without refreshing: unexpired with [skew] to spare.
  bool isFresh(DateTime now, {Duration skew = const Duration(seconds: 60)}) =>
      expiresAt == null || now.isBefore(expiresAt!.subtract(skew));

  /// The successor after a refresh: a new refresh token replaces this one;
  /// none returned keeps it (TS1 L921, TS2 L1331); an omitted `scope` keeps
  /// the previous grant (a refresh can never widen it, OAuth 2.1 §4.3.1).
  TokenSet refreshedWith(TokenResponse r, DateTime now) => TokenSet(
        issuer: issuer,
        resource: resource,
        clientId: clientId,
        accessToken: r.accessToken,
        tokenType: r.tokenType,
        tokenEndpoint: tokenEndpoint,
        obtainedAt: now,
        expiresAt: r.expiresIn == null ? null : now.add(r.expiresIn!),
        refreshToken: r.refreshToken ?? refreshToken,
        requestedScopes: requestedScopes,
        grantedScopes: r.scope != null ? splitScopes(r.scope) : grantedScopes,
        revocationEndpoint: revocationEndpoint,
        sendResource: sendResource,
      );

  JsonMap toJson() => compact({
        'issuer': issuer,
        'resource': resource,
        'client_id': clientId,
        'access_token': accessToken,
        'token_type': tokenType,
        'token_endpoint': tokenEndpoint.toString(),
        'obtained_at': obtainedAt.toUtc().toIso8601String(),
        'expires_at': expiresAt?.toUtc().toIso8601String(),
        'refresh_token': refreshToken,
        'requested_scope': requestedScopes,
        'granted_scope': grantedScopes,
        'revocation_endpoint': revocationEndpoint?.toString(),
        if (!sendResource) 'send_resource': false,
      });

  @override
  String toString() => 'TokenSet($issuer, $resource, expires: ${expiresAt?.toIso8601String() ?? '-'}, '
      'refresh: ${canRefresh ? 'yes' : 'no'}, scope: ${effectiveScopes.join(' ')})';
}

/// A successful token endpoint response (RFC 6749 §5.1).
@immutable
final class TokenResponse {
  const TokenResponse({
    required this.accessToken,
    this.tokenType = 'Bearer',
    this.expiresIn,
    this.refreshToken,
    this.scope,
  });

  /// Validates the response shape. Only `Bearer` tokens are accepted
  /// (case-insensitively, RFC 6749 §7.1); DPoP and others are out of scope
  /// until supported (R02 §8). `id_token` and unknown members are ignored.
  factory TokenResponse.fromJson(JsonMap j, {Uri? url}) {
    final access = j['access_token'];
    if (access is! String || access.isEmpty) {
      throw AuthProtocolException('token response has no access_token', url: url);
    }
    final type = j['token_type'];
    if (type is! String || type.toLowerCase() != 'bearer') {
      throw AuthProtocolException('unsupported token_type ${type is String ? type : '(missing)'}', url: url);
    }
    final exp = j['expires_in'];
    Duration? expiresIn;
    if (exp is num && exp >= 0) {
      expiresIn = Duration(seconds: exp.floor());
    } else if (exp is String && int.tryParse(exp) != null && int.parse(exp) >= 0) {
      // Some servers send a numeric string; tolerate it.
      expiresIn = Duration(seconds: int.parse(exp));
    }
    final refresh = j['refresh_token'];
    final scope = j['scope'];
    return TokenResponse(
      accessToken: access,
      tokenType: 'Bearer',
      expiresIn: expiresIn,
      refreshToken: refresh is String && refresh.isNotEmpty ? refresh : null,
      scope: scope is String ? scope : null,
    );
  }

  final String accessToken;
  final String tokenType;
  final Duration? expiresIn;
  final String? refreshToken;
  final String? scope;

  @override
  String toString() => 'TokenResponse(expires_in: ${expiresIn?.inSeconds}, refresh: ${refreshToken != null}, scope: $scope)';
}
