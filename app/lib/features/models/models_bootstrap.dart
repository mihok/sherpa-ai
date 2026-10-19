import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart' show ContextManager, ModelProvider, SessionRecord;
import 'package:sherpa_data/sherpa_data.dart' show JsonDocumentStore;

import '../../routing/routes.dart';
import '../../services/device/device_profile_source.dart';
import '../../services/downloads/downloads.dart';
import '../../services/inference/local_engine_host.dart';
import '../../services/inference/local_inference.dart';
import '../../services/inference/local_provider_registry.dart';
import '../../services/inference/runner_extras.dart';
import '../../state/providers.dart';
import '../../state/services.dart';
import '../../state/sessions.dart';
import '../chat/state/chat_dependencies.dart';
import 'state/local_inference_providers.dart';
import 'state/local_model_choice.dart';
import 'state/models_providers.dart';

/// `ProviderScope` overrides that wire the on-device model feature
/// (library, downloads, Hub browser). Spread into `bootstrap()`'s list:
///
/// ```dart
/// ...await modelFeatureOverrides(docs: docs, hubClient: _httpClient()),
/// ```
///
/// - [docs]: the encrypted document store; jobs go to
///   `DocumentCollections.downloads`, models to `.modelLibrary`, browser
///   prefs to `.preferences` (never a token or signed URL).
/// - [hubClient]: the platform HTTP client for Hub API calls (it must
///   honour `followRedirects = false`, which `IOClient` and
///   `CupertinoClient` do); defaults to `http.Client()`.
/// - [device]: the `sherpa_platform` [DeviceProfileSource] once it lands;
///   the conservative fallback is used meanwhile.
/// - [transfers]: replaces background_downloader (tests, previews).
Future<List<Override>> modelFeatureOverrides({
  required JsonDocumentStore docs,
  http.Client? hubClient,
  DeviceProfileSource? device,
  TransferBackend? transfers,
}) async {
  final layout = await ModelStorageLayout.fromSupportDirectory();
  await layout.ensure();
  return [
    modelRecordStoreProvider.overrideWithValue(JsonDocumentRecordStore(docs)),
    modelStorageLayoutProvider.overrideWithValue(layout),
    if (hubClient != null) hubHttpClientProvider.overrideWithValue(hubClient),
    if (device != null) deviceProfileSourceProvider.overrideWithValue(device),
    if (transfers != null) transferBackendProvider.overrideWithValue(transfers),
  ];
}

/// For `bootstrap(inMemory: true)`: volatile records and a temporary
/// directory for model bytes.
Future<List<Override>> inMemoryModelFeatureOverrides({TransferBackend? transfers}) async {
  final dir = await Directory.systemTemp.createTemp('sherpa_models_');
  return [
    modelRecordStoreProvider.overrideWithValue(InMemoryRecordStore()),
    modelStorageLayoutProvider.overrideWithValue(ModelStorageLayout(dir.path)),
    if (transfers != null) transferBackendProvider.overrideWithValue(transfers),
  ];
}

/// `ProviderScope` overrides that wire on-device inference. They REPLACE
/// the `providerRegistryProvider` override (pass the same [registry]):
///
/// ```dart
/// ...await localInferenceOverrides(registry: registry),
/// ```
///
/// - `providerRegistryProvider`: [registry] decorated with the built-in
///   `local` provider ([LocalProviderRegistry]).
/// - `localInferenceConfigProvider`: where the engine keeps its files
///   ([LocalInferenceConfig.platformDefault] unless [config] is given); the
///   engine starts 2 s after the first frame, never during launch.
/// - `useLocalModelInChatProvider`: "Use in chat" opens a chat on the model.
/// - `chatRunnerExtrasProvider`: runners on the local provider count tokens
///   exactly ([localChatRunnerExtras]).
///
/// Needs the model feature's overrides ([modelFeatureOverrides]) and, for
/// real memory signals, `memoryMonitorProvider`.
Future<List<Override>> localInferenceOverrides({
  required ProviderRegistry registry,
  LocalInferenceConfig? config,
}) async {
  final c = config ?? await LocalInferenceConfig.platformDefault();
  return [
    localInferenceConfigProvider.overrideWithValue(c),
    providerRegistryProvider.overrideWith((ref) {
      final local = ref.watch(localInferenceProvider);
      if (local == null) return registry;
      final decorated = LocalProviderRegistry(registry, local);
      ref.onDispose(decorated.dispose);
      return decorated;
    }),
    useLocalModelInChatProvider.overrideWith((ref) => (context, choice) => openChatOnModel(ref, context, choice)),
    chatRunnerExtrasProvider.overrideWithValue(localChatRunnerExtras),
  ];
}

/// The chat's [RunnerExtrasFor] for on-device inference: for the local
/// provider, the exact engine token counter and a warming context manager
/// whose ladder summarizes with the chat's own model at background priority
/// (extractive fallback); nothing for remote ones ([localRunnerExtras]).
RunnerExtras localChatRunnerExtras(ModelProvider provider, ModelChoice choice, ContextManager base) {
  final e = localRunnerExtras(provider, choice, base);
  return RunnerExtras(counter: e.counter, contextManager: e.contextManager);
}

/// [localInferenceOverrides] for `bootstrap(inMemory: true)`: engine files
/// in a temporary directory.
Future<List<Override>> inMemoryLocalInferenceOverrides({
  required ProviderRegistry registry,
  EngineHostFactory hostFactory = createLocalEngineHost,
}) async =>
    localInferenceOverrides(registry: registry, config: await LocalInferenceConfig.temporary(hostFactory: hostFactory));

/// "Use in chat": opens the newest still-empty chat on [choice] (so
/// tapping twice doesn't pile up empty chats), or starts one, and shows it.
Future<void> openChatOnModel(Ref ref, BuildContext context, ModelChoice choice) async {
  SessionRecord? target;
  try {
    for (final s in await ref.read(sessionStoreProvider).listSessions()) {
      if (s.providerId != choice.providerId || s.modelId != choice.modelId) continue;
      if (s.activeLeafId != null || s.archived) continue;
      if (target == null || s.updatedAt.isAfter(target.updatedAt)) target = s;
    }
    target ??= await ref.read(sessionActionsProvider).create(model: choice);
  } on Object {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text("Couldn't start a chat. Try again.")));
    }
    return;
  }
  if (context.mounted) context.go(Routes.chat(target.id));
}
