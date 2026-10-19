import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sherpa_inference/sherpa_inference.dart' show EngineCrashReport;

import '../../../services/device/device_profile_source.dart';
import '../../../services/downloads/model_library.dart';
import '../../../services/inference/local_inference.dart';
import '../../../services/inference/record_key_value_store.dart';
import '../../../state/observable_session_store.dart';
import '../../../state/providers.dart';
import 'models_providers.dart';

/// **Integrator root.** Null (the default) leaves on-device inference
/// unwired: no local provider, no "On this device" picker section, "Use in
/// chat" disabled. Overridden by `localInferenceOverrides` in bootstrap.
final localInferenceConfigProvider = Provider<LocalInferenceConfig?>((ref) => null);

/// The app's [LocalInference] (null when not wired). Constructing it does no
/// IO; the engine starts after the first frame
/// ([LocalInferenceConfig.autoStart]) or on first use.
final localInferenceProvider = Provider<LocalInference?>((ref) {
  final config = ref.watch(localInferenceConfigProvider);
  if (config == null) return null;
  final service = LocalInference(
    library: ref.watch(modelLibraryProvider),
    layout: ref.watch(modelStorageLayoutProvider),
    store: RecordKeyValueStore(ref.watch(modelRecordStoreProvider)),
    memory: ref.watch(memoryMonitorProvider),
    device: ref.watch(deviceProfileSourceProvider),
    clock: ref.watch(clockProvider),
    config: config,
  );
  ref.onDispose(service.dispose);
  // A deleted chat's saved KV prefix holds its tokens: delete it too.
  final sessions = _observableSessions(ref);
  if (sessions != null) {
    final sub = sessions.changes.listen((id) async {
      if (await sessions.getSession(id) == null) await service.forgetConversation(id);
    });
    ref.onDispose(sub.cancel);
  }
  if (config.observeAppLifecycle) service.attachAppLifecycle();
  if (config.autoStart) service.scheduleStart();
  return service;
});

ObservableSessionStore? _observableSessions(Ref ref) {
  try {
    final s = ref.watch(sessionStoreProvider);
    return s is ObservableSessionStore ? s : null;
  } on Object {
    return null; // Not overridden (widget tests of the models feature).
  }
}

/// The engine's status, live (null when local inference is not wired).
final localEngineStatusProvider = StreamProvider<LocalEngineStatus?>((ref) async* {
  final local = ref.watch(localInferenceProvider);
  if (local == null) {
    yield null;
    return;
  }
  yield local.status;
  yield* local.statusChanges;
});

/// The crash report from the engine's last start, until dismissed
/// ([LocalInference.acknowledgeCrashReport]): "The on-device engine crashed
/// while generating a reply with X (8192-token context)."
final engineCrashReportProvider = Provider<EngineCrashReport?>(
  (ref) => ref.watch(localEngineStatusProvider).value?.crashReport,
);

/// Installed models straight from the [ModelLibrary] (no download manager
/// needed), live.
final localLibraryModelsProvider = StreamProvider<List<LibraryModel>>((ref) async* {
  final library = ref.watch(modelLibraryProvider);
  await library.load();
  yield library.models;
  yield* library.changes;
});
