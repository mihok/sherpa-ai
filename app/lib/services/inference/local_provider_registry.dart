import 'dart:async';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import '../../state/services.dart';
import 'local_inference.dart';

/// A [ProviderRegistry] that adds the built-in on-device provider
/// ([localProviderId]) to any registry of remote configs.
///
/// Why a decorator rather than a `ProviderConfig` for the local engine or
/// an entry inside each registry:
/// * the local provider has nothing a config holds — no endpoint, key,
///   flavor or quirks — and must never be edited, removed, exported as a
///   provider or offered in provider settings, all of which iterate
///   [configs];
/// * both registries (encrypted documents, in-memory) and test fakes get
///   the same behaviour from one place, without either learning about the
///   engine;
/// * the id is reserved here: adding or updating a config called `local`
///   fails instead of shadowing the engine.
///
/// [changes] also re-emits the (unchanged) configs when the set of local
/// models changes, so chats and pickers that refresh on it pick up new or
/// deleted library models.
final class LocalProviderRegistry implements ProviderRegistry {
  LocalProviderRegistry(this.inner, this.local);

  final ProviderRegistry inner;
  final LocalInference local;

  static bool _isLocal(String id) => id == localProviderId;

  @override
  List<ProviderConfig> get configs => inner.configs;

  late final StreamController<List<ProviderConfig>> _changes =
      StreamController<List<ProviderConfig>>.broadcast(onListen: _listen, onCancel: _unlisten);
  StreamSubscription<List<ProviderConfig>>? _innerSub;
  StreamSubscription<void>? _localSub;

  void _listen() {
    _innerSub = inner.changes.listen(_changes.add, onError: _changes.addError);
    _localSub = local.modelChanges.listen((_) => _changes.add(inner.configs));
  }

  void _unlisten() {
    unawaited(_innerSub?.cancel());
    unawaited(_localSub?.cancel());
    _innerSub = null;
    _localSub = null;
  }

  @override
  Stream<List<ProviderConfig>> get changes => _changes.stream;

  Future<void> dispose() => _changes.close();

  void _reserve(ProviderConfig config) {
    if (_isLocal(config.id)) {
      throw StateError('"$localProviderId" is reserved for the on-device provider');
    }
  }

  @override
  Future<ProviderConfig> add(ProviderConfig config, {String? apiKey}) {
    _reserve(config);
    return inner.add(config, apiKey: apiKey);
  }

  @override
  Future<ProviderConfig> update(ProviderConfig config, {String? apiKey, bool clearApiKey = false}) {
    _reserve(config);
    return inner.update(config, apiKey: apiKey, clearApiKey: clearApiKey);
  }

  /// The built-in provider can't be removed (its models are deleted from
  /// the library instead).
  @override
  Future<void> remove(String providerId) async {
    if (_isLocal(providerId)) return;
    await inner.remove(providerId);
  }

  @override
  Future<bool> hasApiKey(String providerId) async => _isLocal(providerId) ? false : inner.hasApiKey(providerId);

  /// For [localProviderId]: starts the engine if needed (so the runner's
  /// exact token counter exists by the time the runner is built) and
  /// returns the [LocalModelProvider], also when the engine turned out to be
  /// unavailable — its requests then fail with the reason.
  @override
  Future<ModelProvider> resolve(String providerId) async {
    if (!_isLocal(providerId)) return inner.resolve(providerId);
    await local.start();
    return local.provider;
  }

  /// For [localProviderId]: the library's runnable models with their
  /// capabilities (the warm model's are exact). Never needs the engine.
  @override
  Future<List<ModelDescriptor>> models(String providerId, {bool refresh = false}) =>
      _isLocal(providerId) ? local.listModels() : inner.models(providerId, refresh: refresh);

  @override
  Future<EndpointStatus> probe(String providerId) async {
    if (!_isLocal(providerId)) return inner.probe(providerId);
    final s = await local.start();
    return s.isReady ? EndpointStatus.ok : EndpointStatus.error;
  }
}
