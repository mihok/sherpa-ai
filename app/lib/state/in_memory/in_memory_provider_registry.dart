import 'dart:async';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import '../services.dart';

/// Builds the adapter for a config. The key is passed in (read from the
/// [SecretStore] just before) so adapters never touch storage themselves.
typedef ModelProviderFactory = FutureOr<ModelProvider> Function(ProviderConfig config, String? apiKey);

/// [ProviderRegistry] that keeps configs in memory and API keys in the given
/// [SecretStore]. The integrator replaces the config persistence with
/// sherpa_data; the probe/model logic here is meant to be reused as-is.
final class InMemoryProviderRegistry implements ProviderRegistry {
  InMemoryProviderRegistry({
    required SecretStore secrets,
    required ModelProviderFactory factory,
    Iterable<ProviderConfig> initial = const [],
  })  : _secrets = secrets,
        _factory = factory {
    for (final c in initial) {
      _configs[c.id] = c;
    }
  }

  final SecretStore _secrets;
  final ModelProviderFactory _factory;
  final Map<String, ProviderConfig> _configs = {};
  final Map<String, ModelProvider> _resolved = {};
  final Map<String, List<ModelDescriptor>> _models = {};
  final StreamController<List<ProviderConfig>> _changes = StreamController.broadcast();

  @override
  List<ProviderConfig> get configs => List.unmodifiable(_configs.values);

  @override
  Stream<List<ProviderConfig>> get changes => _changes.stream;

  void _emit() => _changes.add(configs);

  void _invalidate(String id) {
    _resolved.remove(id);
    _models.remove(id);
  }

  ProviderConfig _require(String id) =>
      _configs[id] ?? (throw StateError('Unknown provider "$id"'));

  @override
  Future<ProviderConfig> add(ProviderConfig config, {String? apiKey}) async {
    if (_configs.containsKey(config.id)) throw StateError('Provider "${config.id}" already exists');
    if (apiKey != null && apiKey.trim().isNotEmpty) await _secrets.write(config.secretKey, apiKey.trim());
    _configs[config.id] = config;
    _emit();
    return config;
  }

  @override
  Future<ProviderConfig> update(ProviderConfig config, {String? apiKey, bool clearApiKey = false}) async {
    _require(config.id);
    if (clearApiKey) {
      await _secrets.delete(config.secretKey);
    } else if (apiKey != null && apiKey.trim().isNotEmpty) {
      await _secrets.write(config.secretKey, apiKey.trim());
    }
    _configs[config.id] = config;
    _invalidate(config.id);
    _emit();
    return config;
  }

  @override
  Future<void> remove(String providerId) async {
    _configs.remove(providerId);
    _invalidate(providerId);
    // Every secret this provider owns lives under its prefix.
    for (final key in await _secrets.keys(prefix: 'provider/$providerId/')) {
      await _secrets.delete(key);
    }
    _emit();
  }

  @override
  Future<bool> hasApiKey(String providerId) async {
    final config = _configs[providerId];
    if (config == null) return false;
    final key = await _secrets.read(config.secretKey);
    return key != null && key.isNotEmpty;
  }

  @override
  Future<ModelProvider> resolve(String providerId) async {
    final cached = _resolved[providerId];
    if (cached != null) return cached;
    final config = _require(providerId);
    final provider = await _factory(config, await _secrets.read(config.secretKey));
    return _resolved[providerId] = provider;
  }

  @override
  Future<List<ModelDescriptor>> models(String providerId, {bool refresh = false}) async {
    if (!refresh) {
      final cached = _models[providerId];
      if (cached != null) return cached;
    }
    final provider = await resolve(providerId);
    final list = await provider.listModels();
    return _models[providerId] = List.unmodifiable(list);
  }

  @override
  Future<EndpointStatus> probe(String providerId) async {
    if (!_configs.containsKey(providerId)) return EndpointStatus.unknown;
    try {
      await models(providerId, refresh: true);
      return EndpointStatus.ok;
    } on ProviderException catch (e) {
      return statusForError(e);
    } on UrlPolicyViolation {
      return EndpointStatus.unreachable;
    } on Object {
      return EndpointStatus.error;
    }
  }
}

/// Maps a provider failure to what the settings UI can explain.
EndpointStatus statusForError(ProviderException e) => switch (e.kind) {
      ProviderErrorKind.auth => EndpointStatus.unauthorized,
      ProviderErrorKind.network || ProviderErrorKind.timeout => EndpointStatus.unreachable,
      _ => EndpointStatus.error,
    };
