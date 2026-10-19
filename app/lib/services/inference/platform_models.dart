import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:sherpa_apple_ml/sherpa_apple_ml.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart' show DevicePlatform;
import 'package:sherpa_litert/sherpa_litert.dart';

import '../downloads/model_library.dart';
import '../downloads/storage_layout.dart';
import 'on_device_ids.dart';
import 'platform_model_specs.dart';

/// Whether an on-device engine (or the system model) can serve requests,
/// in one vocabulary for the four platform engines: MLX and Apple
/// Foundation Models report an `AppleMlAvailability`, LiteRT-LM and Gemini
/// Nano a `ProviderAvailability`.
enum EngineAvailabilityState {
  available,

  /// The user or the system can fix it: Gemini Nano can be downloaded,
  /// Apple Intelligence is off or its model is still downloading, an MLX
  /// directory is incomplete.
  downloadable,

  /// A download is in progress (Gemini Nano).
  downloading,

  /// Can't run on this device, platform or build; [EngineAvailability.reason]
  /// says why.
  unsupported,
}

@immutable
final class EngineAvailability {
  const EngineAvailability(this.state, this.reason, {this.code = 'unknown', this.details = const {}});

  const EngineAvailability.unsupported(String reason, {String code = 'unsupported'})
      : this(EngineAvailabilityState.unsupported, reason, code: code);

  factory EngineAvailability.fromApple(AppleMlAvailability a) => EngineAvailability(
        switch (a.status) {
          AppleMlStatus.available => EngineAvailabilityState.available,
          AppleMlStatus.downloadable => EngineAvailabilityState.downloadable,
          AppleMlStatus.unsupported => EngineAvailabilityState.unsupported,
        },
        a.message,
        code: a.reason.name,
        details: a.details,
      );

  factory EngineAvailability.fromLiteRt(ProviderAvailability a) => EngineAvailability(
        switch (a.state) {
          AvailabilityState.available => EngineAvailabilityState.available,
          AvailabilityState.downloadable => EngineAvailabilityState.downloadable,
          AvailabilityState.downloading => EngineAvailabilityState.downloading,
          AvailabilityState.unsupported => EngineAvailabilityState.unsupported,
        },
        a.reason,
        code: a.code,
        details: a.details,
      );

  final EngineAvailabilityState state;

  /// One sentence for the UI.
  final String reason;

  /// Stable, machine-readable (`not_android`, `wrong_soc`, `deviceNotEligible`…).
  final String code;
  final Map<String, Object?> details;

  bool get isAvailable => state == EngineAvailabilityState.available;

  @override
  String toString() => 'EngineAvailability(${state.name}, $code: $reason)';
}

/// How the platform providers are built (bootstrap passes the default;
/// tests pass a platform and fake backends).
@immutable
final class PlatformModelsConfig {
  const PlatformModelsConfig({
    this.platform,
    this.appleBackend,
    this.liteRtBackend,
    this.mlx = const MlxProviderConfig(),
    this.liteRt = const LiteRtLmOptions(),
    this.nano = const GeminiNanoOptions(),
  });

  /// Null = this device's platform.
  final DevicePlatform? platform;

  /// Null = `AppleMl.backend` (Pigeon on iOS).
  final AppleMlBackend? appleBackend;

  /// Null = `SherpaLitert.backend` (Pigeon on Android).
  final LiteRtBackend? liteRtBackend;
  final MlxProviderConfig mlx;

  /// `releaseAtTrimLevel` stays at `TRIM_MEMORY_BACKGROUND` (40): the plugin
  /// releases the engine on `onTrimMemory` itself; the app adds no second
  /// memory-pressure release on top.
  final LiteRtLmOptions liteRt;
  final GeminiNanoOptions nano;

  DevicePlatform get effectivePlatform =>
      platform ?? (Platform.isIOS ? DevicePlatform.ios : Platform.isAndroid ? DevicePlatform.android : DevicePlatform.other);
}

/// The four platform model providers, each built lazily and only on its
/// platform: [mlxProviderId] and [appleFmProviderId] on iOS,
/// [liteRtProviderId] and [geminiNanoProviderId] on Android. Elsewhere
/// [resolve] hands out an [UnavailableOnDeviceProvider] and [models] is
/// empty.
///
/// * **Library sync.** MLX and LiteRT library models are registered as
///   [MlxModelSpec]s / [LiteRtModelSpec]s ([mlxModelSpec],
///   [liteRtModelSpec]) once their provider exists, and kept in sync with
///   the [ModelLibrary]; [modelChanges] fires on every change.
/// * **System models.** `models(apple_fm)` / `models(gemini_nano)` list the
///   system model only while its status is available or downloadable.
/// * **One engine holds weights.** MLX and LiteRT-LM load gigabytes into
///   this process, like llama.cpp: before either serves a request
///   [onClaimInAppEngine] (llama.cpp's unload) runs, and [releaseForLlama]
///   frees them before llama.cpp loads. Apple's and Google's system models
///   run out of process and claim nothing.
/// * **Lifecycle.** [forgetConversation] (a chat was deleted), [onThermal]
///   (critical → `mlx.interrupt('thermal_critical')`). Memory pressure is
///   the plugins' own: sherpa_litert releases LiteRT-LM on `onTrimMemory`
///   (≥ [LiteRtLmOptions.releaseAtTrimLevel]) and sherpa_apple_ml clears
///   MLX caches on memory warnings; nothing here duplicates that.
/// * **Priority.** None of these engines has a scheduling priority (each
///   runs one request at a time, first come first served), so background
///   work (summaries, MCP sampling) simply queues behind the reply.
final class PlatformModelProviders {
  PlatformModelProviders({
    required this.library,
    required this.layout,
    this.config = const PlatformModelsConfig(),
    AppForeground? foreground,
  }) : _foreground = foreground;

  final ModelLibrary library;
  final ModelStorageLayout layout;
  final PlatformModelsConfig config;
  final AppForeground? _foreground;

  /// Frees llama.cpp's weights before MLX or LiteRT-LM loads (set by the
  /// app's wiring; null = nothing to free).
  Future<void> Function()? onClaimInAppEngine;

  MlxProvider? _mlx;
  AppleFoundationModelsProvider? _appleFm;
  LiteRtLmProvider? _liteRt;
  GeminiNanoProvider? _nano;
  OnDeviceEngineView? _mlxView;
  OnDeviceEngineView? _liteRtView;
  StreamSubscription<List<LibraryModel>>? _librarySub;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  ThermalLevel _thermal = ThermalLevel.nominal;
  bool _disposed = false;

  DevicePlatform get platform => config.effectivePlatform;

  /// Whether [providerId]'s engine exists on this platform at all.
  bool runsHere(String providerId) => switch (providerId) {
        mlxProviderId || appleFmProviderId => platform == DevicePlatform.ios,
        liteRtProviderId || geminiNanoProviderId => platform == DevicePlatform.android,
        _ => false,
      };

  /// Why [providerId] can't run on this platform.
  static String notHereReason(String providerId) => switch (providerId) {
        mlxProviderId => 'MLX models run on iPhone and iPad only.',
        appleFmProviderId => 'Apple Intelligence runs on iPhone and iPad only.',
        liteRtProviderId => 'LiteRT-LM models run on Android only.',
        geminiNanoProviderId => 'Gemini Nano runs on Android only.',
        _ => 'This on-device provider is not available.',
      };

  /// The set of models (library or system) changed.
  Stream<void> get modelChanges => _changes.stream;

  /// The MLX provider (created on first use; null off iOS).
  MlxProvider? get mlx {
    if (_disposed || !runsHere(mlxProviderId)) return null;
    final existing = _mlx;
    if (existing != null) return existing;
    final p = _mlx = MlxProvider(
      backend: config.appleBackend,
      id: mlxProviderId,
      displayName: onDeviceProviderName(mlxProviderId)!,
      config: config.mlx,
      models: [for (final m in library.models) if (isLibraryModelFor(m, mlxProviderId)) mlxModelSpec(m, layout)],
    );
    _watchLibrary();
    return p;
  }

  /// Apple Foundation Models (created on first use; null off iOS).
  AppleFoundationModelsProvider? get appleFm {
    if (_disposed || !runsHere(appleFmProviderId)) return null;
    return _appleFm ??= AppleFoundationModelsProvider(
      backend: config.appleBackend,
      id: appleFmProviderId,
      displayName: onDeviceProviderName(appleFmProviderId)!,
    );
  }

  /// LiteRT-LM (created on first use; null off Android).
  LiteRtLmProvider? get liteRt {
    if (_disposed || !runsHere(liteRtProviderId)) return null;
    final existing = _liteRt;
    if (existing != null) return existing;
    final p = _liteRt = LiteRtLmProvider(
      backend: config.liteRtBackend,
      foreground: _foreground,
      id: liteRtProviderId,
      displayName: onDeviceProviderName(liteRtProviderId)!,
      options: config.liteRt,
      models: [for (final m in library.models) if (isLibraryModelFor(m, liteRtProviderId)) liteRtModelSpec(m, layout)],
    );
    _watchLibrary();
    return p;
  }

  /// Gemini Nano (created on first use; null off Android).
  GeminiNanoProvider? get nano {
    if (_disposed || !runsHere(geminiNanoProviderId)) return null;
    return _nano ??= GeminiNanoProvider(
      backend: config.liteRtBackend,
      foreground: _foreground,
      id: geminiNanoProviderId,
      displayName: onDeviceProviderName(geminiNanoProviderId)!,
      options: config.nano,
    );
  }

  /// The providers created so far (nothing is built to answer this).
  MlxProvider? get createdMlx => _mlx;
  LiteRtLmProvider? get createdLiteRt => _liteRt;
  AppleFoundationModelsProvider? get createdAppleFm => _appleFm;

  /// The provider for [providerId]: MLX and LiteRT-LM behind an
  /// [OnDeviceEngineView] (it frees llama.cpp first) with the library's
  /// models registered, the system models as they are, and an
  /// [UnavailableOnDeviceProvider] off their platform.
  Future<ModelProvider> resolve(String providerId) async {
    switch (providerId) {
      case mlxProviderId:
        final p = mlx;
        if (p != null) {
          await _synced();
          return _mlxView ??= OnDeviceEngineView(p, _claimForInAppEngine);
        }
      case liteRtProviderId:
        final p = liteRt;
        if (p != null) {
          await _synced();
          return _liteRtView ??= OnDeviceEngineView(p, _claimForInAppEngine);
        }
      case appleFmProviderId:
        final p = appleFm;
        if (p != null) return p;
      case geminiNanoProviderId:
        final p = nano;
        if (p != null) return p;
    }
    return UnavailableOnDeviceProvider(providerId, reason: notHereReason(providerId));
  }

  /// MLX / LiteRT: the library's models of that format; Apple Intelligence
  /// / Gemini Nano: the system model while it is available or
  /// downloadable. Empty off the provider's platform. Never throws.
  Future<List<ModelDescriptor>> models(String providerId) async {
    try {
      switch (providerId) {
        case mlxProviderId:
          final p = mlx;
          if (p == null) return const [];
          await _synced();
          return await p.listModels();
        case liteRtProviderId:
          final p = liteRt;
          if (p == null) return const [];
          await _synced();
          return await p.listModels();
        case appleFmProviderId:
          // Lists the model unless unsupported (downloadable included).
          return await appleFm?.listModels() ?? const [];
        case geminiNanoProviderId:
          final p = nano;
          if (p == null) return const [];
          final list = await p.listModels();
          final status = p.lastInfo?.featureStatus;
          final listed = status == NanoFeatureStatus.available || status == NanoFeatureStatus.downloadable;
          return listed ? list : const [];
      }
    } on Object catch (e) {
      debugPrint('On-device models of $providerId unavailable: ${e.runtimeType}');
    }
    return const [];
  }

  /// Reachability for the registry's probe: the system model is ready, or
  /// the engine exists here.
  Future<bool> probe(String providerId) async {
    if (!runsHere(providerId)) return false;
    if (isSystemModelProvider(providerId)) return (await systemStatus(providerId)).isAvailable;
    return true;
  }

  /// Whether this device can run library model [m] (MLX / LiteRT-LM):
  /// `MlxProvider.availability` / `LiteRtLmProvider.availability` with
  /// their reason. Null for models that don't run on a platform engine
  /// (GGUF: llama.cpp's own status applies). Never throws.
  Future<EngineAvailability?> modelAvailability(LibraryModel m) async {
    final id = libraryProviderIdFor(m.format);
    if (id != mlxProviderId && id != liteRtProviderId) return null;
    if (!runsHere(id!)) return EngineAvailability.unsupported(notHereReason(id), code: 'wrong_platform');
    if (!m.usable) return EngineAvailability.unsupported(m.issue.message, code: 'files');
    final path = layout.libraryPath(m.loadPath);
    try {
      if (id == mlxProviderId) {
        return EngineAvailability.fromApple(await MlxProvider.availability(
          path,
          backend: config.appleBackend,
          config: config.mlx,
          spec: mlxModelSpec(m, layout),
        ));
      }
      return EngineAvailability.fromLiteRt(await liteRt!.availability(path));
    } on Object catch (e) {
      return EngineAvailability.unsupported('Could not check this model: $e', code: 'status_error');
    }
  }

  /// Apple Intelligence's or Gemini Nano's status, with its reason. Never
  /// throws.
  Future<EngineAvailability> systemStatus(String providerId) async {
    if (!runsHere(providerId)) {
      return EngineAvailability.unsupported(notHereReason(providerId), code: 'wrong_platform');
    }
    try {
      return switch (providerId) {
        appleFmProviderId => EngineAvailability.fromApple(await AppleFoundationModelsProvider.status(backend: appleFm!.backend)),
        geminiNanoProviderId => EngineAvailability.fromLiteRt(await nano!.status()),
        _ => const EngineAvailability.unsupported('Not a system model.'),
      };
    } on Object catch (e) {
      return EngineAvailability.unsupported('Could not check the system model: $e', code: 'status_error');
    }
  }

  /// Downloads Gemini Nano (AICore manages the file); ends with
  /// [NanoDownloadCompleted] or [NanoDownloadFailed]. [modelChanges] fires
  /// when it completes, so pickers list it.
  Stream<NanoDownloadUpdate> downloadNano() {
    final p = nano;
    if (p == null) {
      return Stream.value(NanoDownloadFailed(ProviderException(
        ProviderErrorKind.unsupported,
        notHereReason(geminiNanoProviderId),
        providerId: geminiNanoProviderId,
      )));
    }
    return p.download().map((u) {
      if (u is NanoDownloadCompleted) _notify();
      return u;
    });
  }

  /// The system models' status may have changed (Settings, a download
  /// elsewhere): pickers re-list.
  void refreshSystemModels() => _notify();

  /// A chat was deleted: its native sessions (MLX KV cache and saved
  /// prompt cache, the Foundation Models session, LiteRT-LM's open
  /// conversation) go with it. Providers that were never created hold
  /// nothing. Gemini Nano is stateless.
  Future<void> forgetConversation(String sessionId) async {
    for (final forget in [
      if (_mlx != null) _mlx!.forgetConversation,
      if (_appleFm != null) _appleFm!.forgetConversation,
      if (_liteRt != null) _liteRt!.forgetConversation,
    ]) {
      try {
        await forget(sessionId);
      } on Object catch (e) {
        debugPrint('On-device clean-up of a deleted chat failed: ${e.runtimeType}');
      }
    }
  }

  /// sherpa_platform's thermal signal: entering [ThermalLevel.critical]
  /// pauses every MLX generation at a token boundary (`Finish(pause,
  /// rawReason: 'thermal_critical')`; the agent loop continues it later).
  /// MLX that was never created has nothing to pause.
  Future<void> onThermal(ThermalLevel level) async {
    final was = _thermal;
    _thermal = level;
    if (level != ThermalLevel.critical || was == ThermalLevel.critical) return;
    final m = _mlx;
    if (m == null) return;
    try {
      await m.interrupt('thermal_critical');
    } on Object catch (e) {
      debugPrint('MLX thermal interrupt failed: ${e.runtimeType}');
    }
  }

  /// Frees MLX's and LiteRT-LM's weights before llama.cpp loads (only what
  /// is loaded).
  Future<void> releaseForLlama() async {
    try {
      final m = _mlx;
      if (m != null && m.loaded != null) await m.unload();
      final l = _liteRt;
      if (l != null && l.loadedBackend != null) await l.release(reason: 'llama_cpp');
    } on Object catch (e) {
      debugPrint('Releasing the platform engine failed: ${e.runtimeType}');
    }
  }

  Future<void> _claimForInAppEngine() async {
    final claim = onClaimInAppEngine;
    if (claim == null) return;
    try {
      await claim();
    } on Object catch (e) {
      debugPrint('Freeing llama.cpp for a platform engine failed: ${e.runtimeType}');
    }
  }

  Future<void> _synced() async {
    await library.load();
    _sync(library.models, notify: false);
  }

  void _watchLibrary() {
    _librarySub ??= library.changes.listen(_sync);
  }

  void _sync(List<LibraryModel> models, {bool notify = true}) {
    if (_disposed) return;
    final m = _mlx;
    if (m != null) {
      final wanted = {for (final x in models) if (isLibraryModelFor(x, mlxProviderId)) x.id: x};
      for (final s in m.models) {
        if (!wanted.containsKey(s.id)) m.unregister(s.id);
      }
      for (final x in wanted.values) {
        m.register(mlxModelSpec(x, layout));
      }
    }
    final l = _liteRt;
    if (l != null) {
      final wanted = {for (final x in models) if (isLibraryModelFor(x, liteRtProviderId)) x.id: x};
      for (final s in l.models) {
        if (!wanted.containsKey(s.id)) l.unregister(s.id);
      }
      for (final x in wanted.values) {
        l.register(liteRtModelSpec(x, layout));
      }
    }
    if (notify) _notify();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _librarySub?.cancel();
    try {
      await _mlx?.dispose();
      await _appleFm?.dispose();
      await _liteRt?.dispose();
    } on Object {
      // Shutting down.
    }
    await _changes.close();
  }
}

/// MLX or LiteRT-LM behind a view that frees the other in-process engine
/// (llama.cpp) before it loads weights: before [capabilities] (which loads
/// MLX) and before every [stream]. [inner] is the real provider.
final class OnDeviceEngineView implements ModelProvider {
  OnDeviceEngineView(this.inner, this._claim);

  final ModelProvider inner;
  final Future<void> Function() _claim;

  @override
  ProviderInfo get info => inner.info;

  @override
  Future<List<ModelDescriptor>> listModels() => inner.listModels();

  @override
  Future<ModelCapabilities> capabilities(String modelId) async {
    await _claim();
    return inner.capabilities(modelId);
  }

  @override
  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel}) async* {
    await _claim();
    yield* inner.stream(request, cancel: cancel);
  }
}

/// A reserved on-device provider off its platform (MLX on Android, Gemini
/// Nano on iOS…): it lists nothing and fails every request with
/// [ProviderErrorKind.unsupported] and the reason.
final class UnavailableOnDeviceProvider implements ModelProvider {
  UnavailableOnDeviceProvider(this.id, {required this.reason});

  final String id;
  final String reason;

  @override
  ProviderInfo get info => ProviderInfo(
        id: id,
        kind: switch (id) {
          mlxProviderId => ProviderKind.localMlx,
          liteRtProviderId => ProviderKind.localLiteRt,
          _ => ProviderKind.localSystem,
        },
        displayName: onDeviceProviderName(id) ?? id,
        location: ExecutionLocation.onDevice,
      );

  ProviderException get _error => ProviderException(ProviderErrorKind.unsupported, reason, providerId: id);

  @override
  Future<List<ModelDescriptor>> listModels() async => const [];

  @override
  Future<ModelCapabilities> capabilities(String modelId) async => throw _error;

  @override
  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel}) => Stream.error(_error);
}
