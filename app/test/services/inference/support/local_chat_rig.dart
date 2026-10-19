import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sherpa/features/chat/state/chat_controller.dart';
import 'package:sherpa/features/chat/state/chat_dependencies.dart';
import 'package:sherpa/features/chat/state/chat_view_state.dart';
import 'package:sherpa/features/models/models_bootstrap.dart';
import 'package:sherpa/features/models/state/local_inference_providers.dart';
import 'package:sherpa/features/models/state/models_providers.dart';
import 'package:sherpa/services/downloads/downloads.dart';
import 'package:sherpa/services/inference/autotune_scheduler.dart';
import 'package:sherpa/services/inference/local_engine_host.dart';
import 'package:sherpa/services/inference/local_inference.dart';
import 'package:sherpa/state/in_memory/in_memory_preferences_store.dart';
import 'package:sherpa/state/in_memory/in_memory_provider_registry.dart';
import 'package:sherpa/state/observable_session_store.dart';
import 'package:sherpa/state/providers.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa/state/sessions.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart' show BackgroundPolicy, SessionConfig;

import '../../../features/chat/support/fakes.dart' show MicrotaskFrameScheduler, RecordingPlatformActions;

/// The app's in-memory wiring (`bootstrap(inMemory: true)`'s stores plus
/// [localInferenceOverrides]) in a [ProviderContainer], with the real chat
/// controller, `AgentRunner`, tool router and context ladder. Only the
/// frame scheduler, platform actions and retry sleep are test doubles.
final class LocalChatRig {
  LocalChatRig._(this.dir, this.container, this.store);

  static Future<LocalChatRig> create({
    required EngineHostFactory hostFactory,
    AgentConfig agentConfig = const AgentConfig(),
    SessionConfig sessionDefaults = const SessionConfig(),
    int maxContext = 32768,
  }) async {
    final dir = await Directory.systemTemp.createTemp('sherpa_local_chat_');
    final secrets = InMemorySecretStore();
    final store = ObservableSessionStore(InMemorySessionStore());
    final registry = InMemoryProviderRegistry(
      secrets: secrets,
      factory: (config, key) => throw StateError('no remote providers in this test'),
    );
    final local = await localInferenceOverrides(
      registry: registry,
      config: LocalInferenceConfig(
        supportDirectory: '${dir.path}/support',
        cacheDirectory: '${dir.path}/caches',
        hostFactory: hostFactory,
        backgroundPolicy: BackgroundPolicy.none,
        recordProcessState: false,
        autoStart: false,
        observeAppLifecycle: false,
        autotune: AutotunePolicy.off,
        sessionDefaults: sessionDefaults,
        maxContext: maxContext,
      ),
    );
    final container = ProviderContainer(
      overrides: [
        secretStoreProvider.overrideWithValue(secrets),
        sessionStoreProvider.overrideWithValue(store),
        preferencesProvider.overrideWithValue(InMemoryPreferencesStore()),
        modelRecordStoreProvider.overrideWithValue(InMemoryRecordStore()),
        modelStorageLayoutProvider.overrideWithValue(ModelStorageLayout('${dir.path}/models')),
        chatContextManagerProvider.overrideWith(
          (ref) => LadderContextManager(toolLookup: ref.watch(toolRouterProvider).lookup),
        ),
        chatFrameSchedulerProvider.overrideWithValue(MicrotaskFrameScheduler()),
        chatPlatformProvider.overrideWithValue(RecordingPlatformActions()),
        chatAgentConfigProvider.overrideWithValue(agentConfig),
        chatRetrySleepProvider.overrideWithValue((_) async {}),
        ...local,
      ],
    );
    return LocalChatRig._(dir, container, store);
  }

  final Directory dir;
  final ProviderContainer container;
  final ObservableSessionStore store;

  ModelLibrary get library => container.read(modelLibraryProvider);

  LocalInference get local => container.read(localInferenceProvider)!;

  ProviderRegistry get registry => container.read(providerRegistryProvider);

  /// Draft texts the chat published while streaming.
  final List<String> streamed = [];

  /// Starts a new chat the way the home screen does and opens its
  /// controller (kept alive).
  Future<ChatController> openNewChat() async {
    final session = await container.read(sessionActionsProvider).create();
    final sub = container.listen<ChatViewState>(chatControllerProvider(session.id), (_, s) {
      final d = s.draft?.text;
      if (d != null && d.isNotEmpty && (streamed.isEmpty || streamed.last != d)) streamed.add(d);
    }, fireImmediately: true);
    _subs.add(sub);
    final c = container.read(chatControllerProvider(session.id).notifier);
    await c.loaded;
    return c;
  }

  final List<ProviderSubscription<ChatViewState>> _subs = [];

  ChatViewState stateOf(ChatController c) => container.read(chatControllerProvider(c.sessionId));

  /// The persisted active path of [c]'s chat.
  Future<List<Message>> path(ChatController c) async {
    final s = await store.getSession(c.sessionId);
    return s?.activeLeafId == null ? const [] : store.path(c.sessionId, s!.activeLeafId!);
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      s.close();
    }
    container.dispose();
    // Let the service finish disposing before its files go.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (dir.existsSync()) await dir.delete(recursive: true);
  }
}

/// [createLocalEngineHost], the production factory (FFI on a desktop host).
const EngineHostFactory productionHostFactory = createLocalEngineHost;
