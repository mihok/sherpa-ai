import 'dart:async';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import '../../state/services.dart';
import 'local_inference.dart';
import 'on_device_ids.dart';
import 'platform_models.dart';

/// A [ProviderRegistry] that adds the on-device providers to any registry
/// of remote configs: the built-in llama.cpp provider ([localProviderId])
/// and, when [platform] is given, the platform providers
/// ([platformProviderIds]: `mlx` and `apple_fm` on iOS, `litert_lm` and
/// `gemini_nano` on Android).
///
/// Why a decorator rather than a `ProviderConfig` for each engine or an
/// entry inside each registry:
/// * an on-device provider has nothing a config holds — no endpoint, key,
///   flavor or quirks — and must never be edited, removed, exported as a
///   provider or offered in provider settings, all of which iterate
///   [configs];
/// * both registries (encrypted documents, in-memory) and test fakes get
///   the same behaviour from one place, without either learning about the
///   engines;
/// * the ids are reserved here, on every platform: adding or updating a
///   config called `local`, `mlx`, `apple_fm`, `litert_lm` or `gemini_nano`
///   fails instead of shadowing an engine.
///
/// Each platform provider is built lazily and only on its platform
/// ([PlatformModelProviders]); elsewhere [resolve] returns a provider whose
/// requests fail with the reason, [models] is empty and [probe] reports an
/// error.
///
/// [changes] also re-emits the (unchanged) configs when the set of
/// on-device models changes (library edits, Gemini Nano downloaded), so
/// chats and pickers that refresh on it pick them up.
final class LocalProviderRegistry implements ProviderRegistry {
  LocalProviderRegistry(this.inner, this.local, {this.platform});

  final ProviderRegistry inner;
  final LocalInference local;
  final PlatformModelProviders? platform;

  static bool _isReserved(String id) => isOnDeviceProviderId(id);

  @override
  List<ProviderConfig> get configs => inner.configs;

  late final StreamController<List<ProviderConfig>> _changes =
      StreamController<List<ProviderConfig>>.broadcast(onListen: _listen, onCancel: _unlisten);
  StreamSubscription<List<ProviderConfig>>? _innerSub;
  StreamSubscription<void>? _localSub;
  StreamSubscription<void>? _platformSub;

  void _listen() {
    _innerSub = inner.changes.listen(_changes.add, onError: _changes.addError);
    _localSub = local.modelChanges.listen((_) => _changes.add(inner.configs));
    _platformSub = platform?.modelChanges.listen((_) => _changes.add(inner.configs));
  }

  void _unlisten() {
    unawaited(_innerSub?.cancel());
    unawaited(_localSub?.cancel());
    unawaited(_platformSub?.cancel());
    _innerSub = null;
    _localSub = null;
    _platformSub = null;
  }

  @override
  Stream<List<ProviderConfig>> get changes => _changes.stream;

  Future<void> dispose() => _changes.close();

  void _reserve(ProviderConfig config) {
    if (_isReserved(config.id)) {
      throw StateError('"${config.id}" is reserved for an on-device provider');
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

  /// On-device providers can't be removed (their models are deleted from
  /// the library instead).
  @override
  Future<void> remove(String providerId) async {
    if (_isReserved(providerId)) return;
    await inner.remove(providerId);
  }

  @override
  Future<bool> hasApiKey(String providerId) async => _isReserved(providerId) ? false : inner.hasApiKey(providerId);

  /// For [localProviderId]: starts the engine if needed (so the runner's
  /// exact token counter exists by the time the runner is built) and
  /// returns the [LocalModelProvider], also when the engine turned out to be
  /// unavailable — its requests then fail with the reason.
  ///
  /// For a platform id: that provider on its platform (MLX and LiteRT-LM
  /// with the library registered), else one that fails with the reason.
  @override
  Future<ModelProvider> resolve(String providerId) async {
    if (platformProviderIds.contains(providerId)) {
      final p = platform;
      if (p == null) {
        return UnavailableOnDeviceProvider(providerId, reason: 'On-device models are not set up in this build.');
      }
      return p.resolve(providerId);
    }
    if (providerId != localProviderId) return inner.resolve(providerId);
    await local.start();
    return local.provider;
  }

  /// For [localProviderId]: the library's runnable GGUF models with their
  /// capabilities (the warm model's are exact). Never needs the engine.
  /// For a platform id: [PlatformModelProviders.models] (library models of
  /// that format, or the system model while available or downloadable).
  @override
  Future<List<ModelDescriptor>> models(String providerId, {bool refresh = false}) async {
    if (platformProviderIds.contains(providerId)) return await platform?.models(providerId) ?? const [];
    return providerId == localProviderId ? local.listModels() : inner.models(providerId, refresh: refresh);
  }

  @override
  Future<EndpointStatus> probe(String providerId) async {
    if (platformProviderIds.contains(providerId)) {
      final p = platform;
      return p != null && await p.probe(providerId) ? EndpointStatus.ok : EndpointStatus.error;
    }
    if (providerId != localProviderId) return inner.probe(providerId);
    final s = await local.start();
    return s.isReady ? EndpointStatus.ok : EndpointStatus.error;
  }
}
