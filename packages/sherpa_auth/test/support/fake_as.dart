import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:sherpa_core/sherpa_core.dart';

import 'fake_http.dart';

/// A grant as the fake AS tracks it.
final class FakeGrant {
  FakeGrant({required this.clientId, required this.resource, required this.scopes});

  final String clientId;
  final String? resource;
  final List<String> scopes;
  bool revoked = false;
}

final class _Code {
  _Code(this.clientId, this.redirectUri, this.challenge, this.resource, this.scopes);

  final String clientId;
  final String redirectUri;
  final String challenge;
  final String? resource;
  final List<String> scopes;
}

/// A spec-faithful fake OAuth 2.1 authorization server:
/// RFC 8414 metadata at the path-inserted URL, PKCE S256 verification,
/// one-time codes bound to client/redirect/resource, RFC 9207 `iss`,
/// rotating refresh tokens with **reuse detection** (a retired refresh
/// token revokes the whole grant, OAuth 2.1 §4.3.1), DCR, revocation and
/// the RFC 8628 device grant.
final class FakeAuthServer {
  FakeAuthServer._(this.http, this.tenantPath, this.endpointPath);

  /// [endpointPath] prefixes the authorize/token/register/… endpoints
  /// (defaults to [tenantPath]; Hugging Face uses `/oauth`).
  static Future<FakeAuthServer> start({String tenantPath = '/tenant1', String? endpointPath}) async {
    final fake = FakeAuthServer._(await FakeHttp.start(), tenantPath, endpointPath ?? tenantPath);
    fake._install();
    return fake;
  }

  final FakeHttp http;
  final String tenantPath;
  final String endpointPath;

  String get issuer => '${http.origin}$tenantPath';

  String get base => '${http.origin}$endpointPath';

  // ---- knobs --------------------------------------------------------------

  /// Edits the metadata document before it is served.
  JsonMap Function(JsonMap metadata)? editMetadata;

  /// Where metadata is served; defaults to the RFC 8414 path-inserted URL.
  late Set<String> metadataPaths = {'/.well-known/oauth-authorization-server$tenantPath'};
  bool issSupported = true;
  bool cimdSupported = false;
  bool dcrSupported = true;
  bool includeIss = true;
  String? issOverride;
  bool issueRefreshTokens = true;
  bool rotateRefreshTokens = true;
  bool includeScopeInResponse = true;
  int? expiresIn = 3600;
  String tokenType = 'Bearer';
  Duration tokenDelay = Duration.zero;

  /// Returns a response to short-circuit the token endpoint.
  FutureOr<Response?> Function(Map<String, String> form)? tokenHook;

  /// Returns a response to short-circuit DCR.
  FutureOr<Response?> Function(JsonMap body)? registerHook;

  /// Scopes granted for a requested set (defaults to all requested).
  List<String> Function(List<String> requested)? grantScopes;

  /// Client ids the token endpoint rejects with `invalid_client`.
  final Set<String> rejectedClients = {};

  /// Confidential clients: id → secret.
  final Map<String, String> secrets = {};

  // ---- state --------------------------------------------------------------

  final Map<String, _Code> _codes = {};
  final Map<String, FakeGrant> accessTokens = {};
  final Map<String, FakeGrant> refreshTokens = {};
  final Set<String> retiredRefreshTokens = {};
  final Map<String, JsonMap> registered = {};
  final Map<String, ({String clientId, int polls, String outcome})> _deviceCodes = {};
  final List<Map<String, String>> authorizeRequests = [];
  int _n = 0;

  List<Seen> get tokenRequests => http.to('$endpointPath/token');

  List<Seen> get refreshRequests => [for (final r in tokenRequests) if (r.form['grant_type'] == 'refresh_token') r];

  List<Seen> get registerRequests => http.to('$endpointPath/register');

  String _id(String prefix) => '$prefix${++_n}x${sha256.convert(utf8.encode('$prefix$_n')).toString().substring(0, 12)}';

  JsonMap get metadata {
    final m = <String, Object?>{
      'issuer': issuer,
      'authorization_endpoint': '$base/authorize',
      'token_endpoint': '$base/token',
      if (dcrSupported) 'registration_endpoint': '$base/register',
      'revocation_endpoint': '$base/revoke',
      'device_authorization_endpoint': '$base/device',
      'response_types_supported': ['code'],
      'grant_types_supported': ['authorization_code', 'refresh_token'],
      'code_challenge_methods_supported': ['S256'],
      'token_endpoint_auth_methods_supported': ['none', 'client_secret_basic', 'client_secret_post'],
      'scopes_supported': ['files:read', 'files:write', 'offline_access'],
      if (cimdSupported) 'client_id_metadata_document_supported': true,
      if (issSupported) 'authorization_response_iss_parameter_supported': true,
    };
    return editMetadata == null ? m : editMetadata!(m);
  }

  void _install() {
    for (final suffix in const [
      '/.well-known/oauth-authorization-server',
      '/.well-known/openid-configuration',
    ]) {
      http.route('GET $suffix$tenantPath', (r, _) => _metadataAt('$suffix$tenantPath'));
    }
    http.route('GET $tenantPath/.well-known/openid-configuration', (r, _) => _metadataAt('$tenantPath/.well-known/openid-configuration'));
    http.route('POST $endpointPath/token', _token);
    http.route('POST $endpointPath/register', (r, body) => _register(body));
    http.route('POST $endpointPath/revoke', (r, body) {
      final t = Uri.splitQueryString(body)['token'];
      refreshTokens[t]?.revoked = true;
      accessTokens[t]?.revoked = true;
      return Response.ok('');
    });
    http.route('POST $endpointPath/device', (r, body) {
      final form = Uri.splitQueryString(body);
      final code = _id('DC');
      _deviceCodes[code] = (clientId: form['client_id'] ?? '', polls: 0, outcome: deviceOutcome);
      return json({
        'device_code': code,
        'user_code': 'WDJB-MJHT',
        'verification_uri': '$base/device/verify',
        'verification_uri_complete': '$base/device/verify?user_code=WDJB-MJHT',
        'expires_in': 900,
        'interval': 1,
      });
    });
  }

  /// `success`, `slow_down_then_success`, `denied`, `expired`.
  String deviceOutcome = 'success';

  Response _metadataAt(String path) {
    if (!metadataPaths.contains(path)) return json({'error': 'not_found'}, status: 404);
    return json(metadata);
  }

  Future<Response> _register(String body) async {
    final j = (jsonDecode(body) as Map).cast<String, Object?>();
    final hook = registerHook == null ? null : await registerHook!(j);
    if (hook != null) return hook;
    final id = _id('client');
    registered[id] = j;
    return json({...j, 'client_id': id, 'client_id_issued_at': 1}, status: 201);
  }

  /// The user approves in the browser: validates the authorization request
  /// like a real AS would and returns the callback URL.
  Uri approve(Uri url, {String? error}) {
    final q = url.queryParameters;
    authorizeRequests.add(q);
    final redirect = Uri.parse(q['redirect_uri']!);
    final iss = issOverride ?? issuer;
    Uri callback(Map<String, String> params) => redirect.replace(queryParameters: {
          ...params,
          'state': q['state']!,
          if (includeIss) 'iss': iss,
        });
    if (error != null) return callback({'error': error, 'error_description': 'the user said no to SECRET-DESCRIPTION'});
    if (q['response_type'] != 'code' || q['code_challenge_method'] != 'S256' || q['code_challenge'] == null) {
      return callback({'error': 'invalid_request'});
    }
    final requested = (q['scope'] ?? '').split(' ').where((s) => s.isNotEmpty).toList();
    final code = _id('CODE');
    _codes[code] = _Code(q['client_id']!, q['redirect_uri']!, q['code_challenge']!, q['resource'], requested);
    return callback({'code': code});
  }

  Future<Response> _token(Request r, String body) async {
    if (tokenDelay > Duration.zero) await Future<void>.delayed(tokenDelay);
    final form = Uri.splitQueryString(body);
    final hook = tokenHook == null ? null : await tokenHook!(form);
    if (hook != null) return hook;
    final clientId = _authenticate(r, form);
    if (clientId == null || rejectedClients.contains(clientId)) {
      return json({'error': 'invalid_client', 'error_description': 'unknown client'}, status: 401);
    }
    switch (form['grant_type']) {
      case 'authorization_code':
        final c = _codes.remove(form['code']);
        if (c == null) return _err('invalid_grant');
        if (c.clientId != clientId || c.redirectUri != form['redirect_uri']) return _err('invalid_grant');
        final verifier = form['code_verifier'] ?? '';
        final challenge = base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
        if (challenge != c.challenge) return _err('invalid_grant', 'PKCE verification failed');
        if (form['resource'] != c.resource) return _err('invalid_target');
        final granted = grantScopes == null ? c.scopes : grantScopes!(c.scopes);
        return _issue(FakeGrant(clientId: clientId, resource: c.resource, scopes: granted), refresh: true);
      case 'refresh_token':
        final rt = form['refresh_token'] ?? '';
        final g = refreshTokens[rt];
        if (g == null || g.revoked) return _err('invalid_grant');
        if (retiredRefreshTokens.contains(rt)) {
          // Reuse detection: revoke the active refresh token and the grant.
          g.revoked = true;
          return _err('invalid_grant', 'refresh token reuse detected');
        }
        if (g.clientId != clientId) return _err('invalid_grant');
        if (form['resource'] != g.resource) return _err('invalid_target');
        if (rotateRefreshTokens) retiredRefreshTokens.add(rt);
        return _issue(g, refresh: rotateRefreshTokens);
      case 'urn:ietf:params:oauth:grant-type:device_code':
        final dc = _deviceCodes[form['device_code']];
        if (dc == null) return _err('invalid_grant');
        final polls = dc.polls + 1;
        _deviceCodes[form['device_code']!] = (clientId: dc.clientId, polls: polls, outcome: dc.outcome);
        switch (dc.outcome) {
          case 'denied':
            return _err('access_denied');
          case 'expired':
            return _err('expired_token');
          case 'slow_down_then_success' when polls == 1:
            return _err('slow_down');
          case _ when polls < 2:
            return _err('authorization_pending');
        }
        return _issue(FakeGrant(clientId: clientId, resource: form['resource'], scopes: const ['openid', 'profile']), refresh: true);
    }
    return _err('unsupported_grant_type');
  }

  String? _authenticate(Request r, Map<String, String> form) {
    final auth = r.headers['authorization'];
    if (auth != null && auth.startsWith('Basic ')) {
      final decoded = utf8.decode(base64.decode(auth.substring(6)));
      final i = decoded.indexOf(':');
      final id = Uri.decodeQueryComponent(decoded.substring(0, i));
      final secret = Uri.decodeQueryComponent(decoded.substring(i + 1));
      return secrets[id] == secret ? id : null;
    }
    final id = form['client_id'];
    if (id == null) return null;
    final secret = secrets[id];
    if (secret != null && form['client_secret'] != secret) return null;
    return id;
  }

  Response _issue(FakeGrant g, {required bool refresh}) {
    final at = _id('ACCESS');
    accessTokens[at] = g;
    String? rt;
    if (refresh && issueRefreshTokens) {
      rt = _id('REFRESH');
      refreshTokens[rt] = g;
    }
    return json({
      'access_token': at,
      'token_type': tokenType,
      'expires_in': ?expiresIn,
      'refresh_token': ?rt,
      if (includeScopeInResponse) 'scope': g.scopes.join(' '),
    }, headers: {'cache-control': 'no-store'});
  }

  Response _err(String code, [String? description]) =>
      json({'error': code, 'error_description': ?description}, status: 400);

  Future<void> close() => http.close();
}
