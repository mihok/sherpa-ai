import 'dart:async';
import 'dart:io' show InternetAddress;

import 'package:http/http.dart' as http;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_data/sherpa_data.dart';
import 'package:sherpa_net/sherpa_net.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import '../services.dart';

/// [ProviderRegistry] backed by the encrypted document store (configs) and
/// the [SecretStore] (API keys). Configs are cached in memory after [load]
/// so the UI can read them synchronously.
///
/// [add] and [update] check a plain-http base URL against the provider's
/// own URL policy, DNS included, and throw [UrlPolicyViolation] instead of
/// saving a config it would refuse: plain http (the "my own network"
/// opt-in) to a host name that resolves to a public address. A host that does not
/// resolve right now is saved; the provider checks again before every
/// connection, so DNS changes after saving are caught there.
final class DocumentProviderRegistry implements ProviderRegistry {
  DocumentProviderRegistry({
    required JsonDocumentStore documents,
    required SecretStore secrets,
    required http.Client client,
    Clock clock = const SystemClock(),
    this.probeTimeout = const Duration(seconds: 8),
    Future<List<InternetAddress>> Function(String host)? resolver,
  })  : _docs = documents,
        _secrets = secrets,
        _client = client,
        _clock = clock,
        _resolver = resolver;

  final JsonDocumentStore _docs;
  final SecretStore _secrets;
  final http.Client _client;
  final Clock _clock;
  final Duration probeTimeout;
  final Future<List<InternetAddress>> Function(String host)? _resolver;

  final StreamController<List<ProviderConfig>> _changes = StreamController.broadcast();
  final Map<String, ProviderConfig> _configs = {};
  final Map<String, ModelProvider> _providers = {};
  final Map<String, List<ModelDescriptor>> _models = {};

  static const _collection = DocumentCollections.providerConfigs;

  /// Reads persisted configs. Malformed documents (e.g. written by a newer
  /// app version) are skipped rather than failing startup.
  Future<void> load() async {
    for (final doc in await _docs.list(_collection)) {
      try {
        final c = ProviderConfig.fromJson(doc);
        _configs[c.id] = c;
      } on Object {
        continue;
      }
    }
  }

  @override
  List<ProviderConfig> get configs => List.unmodifiable(_configs.values);

  @override
  Stream<List<ProviderConfig>> get changes => _changes.stream;

  @override
  Future<ProviderConfig> add(ProviderConfig config, {String? apiKey}) async {
    if (_configs.containsKey(config.id)) {
      throw StateError('a provider with id ${config.id} already exists');
    }
    return _save(config, apiKey: apiKey);
  }

  @override
  Future<ProviderConfig> update(ProviderConfig config, {String? apiKey, bool clearApiKey = false}) async {
    if (!_configs.containsKey(config.id)) throw StateError('unknown provider ${config.id}');
    if (clearApiKey) await _secrets.delete(config.secretKey);
    return _save(config, apiKey: apiKey);
  }

  Future<ProviderConfig> _save(ProviderConfig config, {String? apiKey}) async {
    await _checkBaseUrl(config);
    await _docs.put(_collection, config.id, config.toJson());
    if (apiKey != null && apiKey.isNotEmpty) await _secrets.write(config.secretKey, apiKey.trim());
    _configs[config.id] = config;
    _invalidate(config.id);
    _emit();
    return config;
  }

  @override
  Future<void> remove(String providerId) async {
    final c = _configs.remove(providerId);
    if (c == null) return;
    await _docs.delete(_collection, providerId);
    // Every secret a provider owns (API key now, OAuth tokens later) lives
    // under its prefix.
    for (final key in await _secrets.keys(prefix: 'provider/$providerId/')) {
      await _secrets.delete(key);
    }
    _invalidate(providerId);
    _emit();
  }

  @override
  Future<bool> hasApiKey(String providerId) async {
    final c = _configs[providerId];
    if (c == null) return false;
    final key = await _secrets.read(c.secretKey);
    return key != null && key.isNotEmpty;
  }

  @override
  Future<ModelProvider> resolve(String providerId) async {
    final cached = _providers[providerId];
    if (cached != null) return cached;
    final c = _configs[providerId];
    if (c == null) throw StateError('unknown provider $providerId');
    final provider = createProvider(c, apiKey: await _secrets.read(c.secretKey), client: _client, clock: _clock);
    return _providers[providerId] = provider;
  }

  @override
  Future<List<ModelDescriptor>> models(String providerId, {bool refresh = false}) async {
    if (!refresh && _models[providerId] != null) return _models[providerId]!;
    final provider = await resolve(providerId);
    final list = await provider.listModels();
    return _models[providerId] = list;
  }

  @override
  Future<EndpointStatus> probe(String providerId) async {
    try {
      await models(providerId, refresh: true).timeout(probeTimeout);
      return EndpointStatus.ok;
    } on ProviderException catch (e) {
      return switch (e.kind) {
        ProviderErrorKind.auth || ProviderErrorKind.quotaExceeded => EndpointStatus.unauthorized,
        ProviderErrorKind.network || ProviderErrorKind.timeout => EndpointStatus.unreachable,
        _ => EndpointStatus.error,
      };
    } on TimeoutException {
      return EndpointStatus.unreachable;
    } on Object {
      return EndpointStatus.error;
    }
  }

  /// Only plain http needs DNS here (the opt-in rule); https endpoints are
  /// fully checked by the provider before it connects.
  Future<void> _checkBaseUrl(ProviderConfig config) async {
    if (config.baseUrl.scheme.toLowerCase() != 'http') return;
    final policy = endpointUrlPolicy(allowLocalNetwork: config.allowLocalNetwork, resolver: _resolver);
    try {
      await policy.check(config.baseUrl.toString());
    } on UrlPolicyViolation catch (v) {
      if (v.reason.startsWith('host does not resolve')) return;
      rethrow;
    }
  }

  void _invalidate(String id) {
    _providers.remove(id);
    _models.remove(id);
  }

  void _emit() => _changes.add(configs);

  Future<void> dispose() => _changes.close();
}
