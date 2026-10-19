import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sherpa_litert/sherpa_litert.dart'
    show AppForeground, NanoDownloadCompleted, NanoDownloadFailed, NanoDownloadProgress, NanoDownloadStarted, NanoDownloadUpdate;

import '../../../services/downloads/model_library.dart';
import '../../../services/inference/app_foreground.dart';
import '../../../services/inference/on_device_ids.dart';
import '../../../services/inference/platform_models.dart';
import '../../../state/providers.dart';
import '../../../state/sessions.dart' show SessionDeletedHook;
import 'local_inference_providers.dart';
import 'models_providers.dart';

/// **Integrator root.** Null (the default) leaves the platform providers
/// (MLX, Apple Intelligence, LiteRT-LM, Gemini Nano) unwired: the registry
/// reports them unavailable and the library shows no system models.
/// Overridden by `localInferenceOverrides` in bootstrap.
final platformModelsConfigProvider = Provider<PlatformModelsConfig?>((ref) => null);

/// Whether Sherpa is on screen, from one `AppLifecycleListener`, for
/// sherpa_litert's providers (Gemini Nano is foreground only; LiteRT-LM
/// reloads after a memory release only in the foreground). Tests override
/// it with `FakeForeground`.
final onDeviceForegroundProvider = Provider<AppForeground>((ref) {
  final f = AppLifecycleForeground();
  ref.onDispose(f.dispose);
  return f.asLiteRt;
});

/// The platform providers (null when not wired). Constructing it does no
/// IO; each engine is built on first use and only on its platform.
///
/// Wired here:
/// * one in-process engine holds weights at a time: MLX / LiteRT-LM free
///   llama.cpp's model before they load, llama.cpp frees theirs;
/// * sherpa_platform's thermal signal (the app's `MemoryMonitor`): critical
///   → `mlx.interrupt('thermal_critical')` (iOS only, where MLX exists).
final platformModelProvidersProvider = Provider<PlatformModelProviders?>((ref) {
  final config = ref.watch(platformModelsConfigProvider);
  if (config == null) return null;
  final p = PlatformModelProviders(
    library: ref.watch(modelLibraryProvider),
    layout: ref.watch(modelStorageLayoutProvider),
    config: config,
    foreground: ref.watch(onDeviceForegroundProvider),
  );
  ref.onDispose(p.dispose);
  final local = ref.watch(localInferenceProvider);
  if (local != null) {
    p.onClaimInAppEngine = local.unloadForOtherEngine;
    final release = p.releaseForLlama;
    local.beforeRequest = release;
    ref.onDispose(() {
      if (local.beforeRequest == release) local.beforeRequest = null;
    });
  }
  if (p.runsHere(mlxProviderId)) {
    final memory = ref.watch(memoryMonitorProvider);
    final sub = memory.changes.listen((s) => unawaited(p.onThermal(s.thermal)));
    ref.onDispose(sub.cancel);
  }
  return p;
});

/// Clean-up when a chat is deleted for good: its saved llama.cpp KV prefix
/// and the platform engines' native sessions (MLX, Apple Intelligence,
/// LiteRT-LM). For `sessionDeletedHooksProvider` (state/sessions.dart),
/// next to MCP's hooks.
final onDeviceSessionDeletedHooksProvider = Provider<List<SessionDeletedHook>>((ref) => [
      (sessionId) async {
        await ref.read(localInferenceProvider)?.forgetConversation(sessionId);
        await ref.read(platformModelProvidersProvider)?.forgetConversation(sessionId);
      },
    ]);

/// The platform engine's verdict on one installed MLX / LiteRT model
/// (`MlxProvider.availability`, `LiteRtLmProvider.availability`), keyed by
/// library model id. Null for GGUF models (llama.cpp's engine status
/// applies) and when the platform providers are not wired.
final libraryModelAvailabilityProvider = FutureProvider.autoDispose.family<EngineAvailability?, String>((ref, id) async {
  final p = ref.watch(platformModelProvidersProvider);
  if (p == null) return null;
  final library = ref.watch(modelLibraryProvider);
  await library.load();
  final LibraryModel? m = library.byId(id);
  if (m == null) return null;
  return p.modelAvailability(m);
});

/// Apple Intelligence's / Gemini Nano's status (`AppleFoundationModelsProvider.status()`,
/// `GeminiNanoProvider.status()`), with its reason. Null when not wired.
final systemModelStatusProvider = FutureProvider.autoDispose.family<EngineAvailability?, String>((ref, providerId) async {
  final p = ref.watch(platformModelProvidersProvider);
  if (p == null) return null;
  return p.systemStatus(providerId);
});

/// The system models this device's platform has (Apple Intelligence on
/// iOS, Gemini Nano on Android); empty elsewhere or when not wired.
final systemModelIdsProvider = Provider<List<String>>((ref) {
  final p = ref.watch(platformModelProvidersProvider);
  if (p == null) return const [];
  return [
    for (final id in const [appleFmProviderId, geminiNanoProviderId])
      if (p.runsHere(id)) id,
  ];
});

/// A Gemini Nano download in progress, as the library shows it.
final class NanoDownloadState {
  const NanoDownloadState({
    this.running = false,
    this.fraction,
    this.downloadedBytes,
    this.totalBytes,
    this.error,
    this.completed = false,
  });

  final bool running;

  /// The last download finished.
  final bool completed;

  /// 0..1 once AICore reports the total.
  final double? fraction;
  final int? downloadedBytes;
  final int? totalBytes;

  /// Why the last download failed.
  final String? error;
}

/// Starts and tracks Gemini Nano's download (`GeminiNanoProvider.download()`).
final nanoDownloadProvider = NotifierProvider<NanoDownloadController, NanoDownloadState>(NanoDownloadController.new);

final class NanoDownloadController extends Notifier<NanoDownloadState> {
  StreamSubscription<NanoDownloadUpdate>? _sub;

  @override
  NanoDownloadState build() {
    ref.onDispose(() => _sub?.cancel());
    return const NanoDownloadState();
  }

  /// Starts the download (no-op while one runs). Completes when it ends.
  Future<void> start() async {
    final p = ref.read(platformModelProvidersProvider);
    if (p == null || state.running) return;
    state = const NanoDownloadState(running: true);
    final done = Completer<void>();
    _sub = p.downloadNano().listen(
      (u) {
        if (!ref.mounted) return;
        state = switch (u) {
          NanoDownloadStarted(:final totalBytes) =>
            NanoDownloadState(running: true, fraction: 0, downloadedBytes: 0, totalBytes: totalBytes > 0 ? totalBytes : null),
          NanoDownloadProgress(:final downloadedBytes, :final totalBytes, :final fraction) =>
            NanoDownloadState(running: true, fraction: fraction, downloadedBytes: downloadedBytes, totalBytes: totalBytes),
          NanoDownloadCompleted() => const NanoDownloadState(fraction: 1, completed: true),
          NanoDownloadFailed(:final error) => NanoDownloadState(error: error.message),
        };
        if (u is NanoDownloadCompleted) ref.invalidate(systemModelStatusProvider(geminiNanoProviderId));
      },
      onError: (Object e) {
        if (ref.mounted) state = NanoDownloadState(error: '$e');
      },
      onDone: () {
        if (ref.mounted && state.running) state = const NanoDownloadState();
        if (ref.mounted) ref.invalidate(systemModelStatusProvider(geminiNanoProviderId));
        if (!done.isCompleted) done.complete();
      },
    );
    await done.future;
  }
}
