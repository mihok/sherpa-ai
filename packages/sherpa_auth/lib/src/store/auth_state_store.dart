import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../flow/pending.dart';
import '../flow/tokens.dart';
import '../registration/client_registration.dart';

/// Which authorization server and resource an MCP server is bound to,
/// remembered so the next 401 does not need discovery to find its tokens,
/// and so an AS change can be detected (CR26 L181-191).
@immutable
final class ServerBinding {
  const ServerBinding({
    required this.serverKey,
    required this.resource,
    required this.issuer,
    required this.updatedAt,
    this.resourceMetadataUrl,
  });

  factory ServerBinding.fromJson(JsonMap j) => ServerBinding(
        serverKey: j.req<String>('server_key'),
        resource: j.req<String>('resource'),
        issuer: j.req<String>('issuer'),
        updatedAt: DateTime.parse(j.req<String>('updated_at')),
        resourceMetadataUrl: j.opt<String>('resource_metadata_url'),
      );

  /// Canonical server URL.
  final String serverKey;

  /// The RFC 8707 resource tokens are bound to.
  final String resource;
  final String issuer;
  final DateTime updatedAt;

  /// The PRM URL last used; a challenge naming another one triggers
  /// re-discovery (RFC 9728 §5.2).
  final String? resourceMetadataUrl;

  JsonMap toJson() => compact({
        'server_key': serverKey,
        'resource': resource,
        'issuer': issuer,
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'resource_metadata_url': resourceMetadataUrl,
      });

  @override
  String toString() => 'ServerBinding($serverKey -> $issuer, $resource)';
}

/// Persistence for OAuth state. Client secrets, tokens and pending flows
/// are secrets (SC26 L30-31, A26 L306), so the app backs this with the
/// Keychain/Keystore via [SecretAuthStateStore]; nothing here may go to
/// SQLite, logs or backups.
///
/// Registrations are keyed by issuer (CR26 L183-191), tokens by
/// (issuer, resource) — together with the client id recorded inside the
/// token set this is the (issuer, resource, client_id) key R02 §9 asks for.
abstract interface class AuthStateStore {
  Future<ClientRegistration?> readRegistration(String issuer);

  Future<void> writeRegistration(ClientRegistration registration);

  Future<void> deleteRegistration(String issuer);

  Future<TokenSet?> readTokens(String issuer, String resource);

  /// One atomic write: access and (rotated) refresh token together.
  Future<void> writeTokens(TokenSet tokens);

  Future<void> deleteTokens(String issuer, String resource);

  /// Every token set, or those for [resource].
  Future<List<TokenSet>> listTokens({String? resource});

  Future<PendingAuthorization?> readPending(String state);

  Future<void> writePending(PendingAuthorization pending);

  Future<void> deletePending(String state);

  Future<List<PendingAuthorization>> listPending();

  Future<ServerBinding?> readBinding(String serverKey);

  Future<void> writeBinding(ServerBinding binding);

  Future<void> deleteBinding(String serverKey);
}

/// [AuthStateStore] on a [SecretStore], one JSON value per key:
///
/// ```
/// oauth/<h(issuer)>/client                  ClientRegistration
/// oauth/<h(issuer)>/tokens/<h(resource)>    TokenSet
/// oauth/pending/<h(state)>                  PendingAuthorization
/// oauth/servers/<h(serverKey)>              ServerBinding
/// ```
///
/// `h` is the first 128 bits of SHA-256 in hex: keys stay short and
/// key-safe for every backend, and no secret (`state`) or URL ends up in a
/// key name, which some keychains expose in plaintext. The full values are
/// inside the JSON and re-checked on read, so a hash collision cannot hand
/// out another server's tokens. Unreadable values are treated as absent.
final class SecretAuthStateStore implements AuthStateStore {
  SecretAuthStateStore(this._secrets, {this.prefix = 'oauth'});

  final SecretStore _secrets;
  final String prefix;

  static String hash(String value) => sha256.convert(utf8.encode(value)).toString().substring(0, 32);

  String _clientKey(String issuer) => '$prefix/${hash(issuer)}/client';

  String _tokenKey(String issuer, String resource) => '$prefix/${hash(issuer)}/tokens/${hash(resource)}';

  String _pendingKey(String state) => '$prefix/pending/${hash(state)}';

  String _bindingKey(String serverKey) => '$prefix/servers/${hash(serverKey)}';

  Future<JsonMap?> _readJson(String key) async {
    final raw = await _secrets.read(key);
    if (raw == null) return null;
    try {
      final v = jsonDecode(raw);
      return v is Map ? (normalizeJson(v)! as Map<Object?, Object?>).cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }

  Future<T?> _read<T>(String key, T Function(JsonMap) decode, bool Function(T) belongs) async {
    final j = await _readJson(key);
    if (j == null) return null;
    try {
      final v = decode(j);
      return belongs(v) ? v : null;
    } on Object {
      // FormatError, a renamed enum value or a type error from an older
      // build: the value is unusable, which is the same as absent.
      return null;
    }
  }

  Future<void> _write(String key, JsonMap value) => _secrets.write(key, jsonEncode(value));

  @override
  Future<ClientRegistration?> readRegistration(String issuer) =>
      _read(_clientKey(issuer), ClientRegistration.fromJson, (r) => r.issuer == issuer);

  @override
  Future<void> writeRegistration(ClientRegistration registration) =>
      _write(_clientKey(registration.issuer), registration.toJson());

  @override
  Future<void> deleteRegistration(String issuer) => _secrets.delete(_clientKey(issuer));

  @override
  Future<TokenSet?> readTokens(String issuer, String resource) =>
      _read(_tokenKey(issuer, resource), TokenSet.fromJson, (t) => t.issuer == issuer && t.resource == resource);

  @override
  Future<void> writeTokens(TokenSet tokens) => _write(_tokenKey(tokens.issuer, tokens.resource), tokens.toJson());

  @override
  Future<void> deleteTokens(String issuer, String resource) => _secrets.delete(_tokenKey(issuer, resource));

  @override
  Future<List<TokenSet>> listTokens({String? resource}) async {
    final suffix = resource == null ? null : '/tokens/${hash(resource)}';
    final out = <TokenSet>[];
    for (final key in await _secrets.keys(prefix: '$prefix/')) {
      if (!key.contains('/tokens/')) continue;
      if (suffix != null && !key.endsWith(suffix)) continue;
      final t = await _read(key, TokenSet.fromJson, (t) => resource == null || t.resource == resource);
      if (t != null) out.add(t);
    }
    return out;
  }

  @override
  Future<PendingAuthorization?> readPending(String state) =>
      _read(_pendingKey(state), PendingAuthorization.fromJson, (p) => p.state == state);

  @override
  Future<void> writePending(PendingAuthorization pending) => _write(_pendingKey(pending.state), pending.toJson());

  @override
  Future<void> deletePending(String state) => _secrets.delete(_pendingKey(state));

  @override
  Future<List<PendingAuthorization>> listPending() async {
    final out = <PendingAuthorization>[];
    for (final key in await _secrets.keys(prefix: '$prefix/pending/')) {
      final p = await _read(key, PendingAuthorization.fromJson, (_) => true);
      if (p != null) out.add(p);
    }
    return out;
  }

  @override
  Future<ServerBinding?> readBinding(String serverKey) =>
      _read(_bindingKey(serverKey), ServerBinding.fromJson, (b) => b.serverKey == serverKey);

  @override
  Future<void> writeBinding(ServerBinding binding) => _write(_bindingKey(binding.serverKey), binding.toJson());

  @override
  Future<void> deleteBinding(String serverKey) => _secrets.delete(_bindingKey(serverKey));
}

/// Volatile [AuthStateStore] for tests and evals. Values round-trip
/// through JSON so serialisation bugs surface in tests, not on devices.
final class InMemoryAuthStateStore implements AuthStateStore {
  final Map<String, String> _registrations = {};
  final Map<(String, String), String> _tokens = {};
  final Map<String, String> _pending = {};
  final Map<String, String> _bindings = {};

  static JsonMap _decode(String s) => (normalizeJson(jsonDecode(s))! as Map<Object?, Object?>).cast<String, Object?>();

  @override
  Future<ClientRegistration?> readRegistration(String issuer) async {
    final s = _registrations[issuer];
    return s == null ? null : ClientRegistration.fromJson(_decode(s));
  }

  @override
  Future<void> writeRegistration(ClientRegistration registration) async =>
      _registrations[registration.issuer] = jsonEncode(registration.toJson());

  @override
  Future<void> deleteRegistration(String issuer) async => _registrations.remove(issuer);

  @override
  Future<TokenSet?> readTokens(String issuer, String resource) async {
    final s = _tokens[(issuer, resource)];
    return s == null ? null : TokenSet.fromJson(_decode(s));
  }

  @override
  Future<void> writeTokens(TokenSet tokens) async => _tokens[(tokens.issuer, tokens.resource)] = jsonEncode(tokens.toJson());

  @override
  Future<void> deleteTokens(String issuer, String resource) async => _tokens.remove((issuer, resource));

  @override
  Future<List<TokenSet>> listTokens({String? resource}) async => [
        for (final e in _tokens.entries)
          if (resource == null || e.key.$2 == resource) TokenSet.fromJson(_decode(e.value)),
      ];

  @override
  Future<PendingAuthorization?> readPending(String state) async {
    final s = _pending[state];
    return s == null ? null : PendingAuthorization.fromJson(_decode(s));
  }

  @override
  Future<void> writePending(PendingAuthorization pending) async => _pending[pending.state] = jsonEncode(pending.toJson());

  @override
  Future<void> deletePending(String state) async => _pending.remove(state);

  @override
  Future<List<PendingAuthorization>> listPending() async =>
      [for (final s in _pending.values) PendingAuthorization.fromJson(_decode(s))];

  @override
  Future<ServerBinding?> readBinding(String serverKey) async {
    final s = _bindings[serverKey];
    return s == null ? null : ServerBinding.fromJson(_decode(s));
  }

  @override
  Future<void> writeBinding(ServerBinding binding) async => _bindings[binding.serverKey] = jsonEncode(binding.toJson());

  @override
  Future<void> deleteBinding(String serverKey) async => _bindings.remove(serverKey);
}
