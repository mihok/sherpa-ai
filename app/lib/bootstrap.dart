import 'dart:async';
import 'dart:io';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Ref;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_data/sherpa_data.dart';
import 'package:sherpa_platform/sherpa_platform.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import 'features/chat/state/chat_dependencies.dart';
import 'features/context/data/data_erase.dart';
import 'features/mcp/mcp_bootstrap.dart';
import 'features/models/models_bootstrap.dart';
import 'features/models/state/local_inference_providers.dart';
import 'features/models/state/models_providers.dart';
import 'routing/chat_route.dart';
import 'routing/chat_screen_binding.dart';
import 'routing/context_route.dart';
import 'services/device/platform_device_profile_source.dart';
import 'services/downloads/downloads.dart' show ModelStorageLayout;
import 'state/in_memory/in_memory_preferences_store.dart';
import 'state/in_memory/in_memory_provider_registry.dart';
import 'state/observable_session_store.dart';
import 'state/persistent/preferences_store.dart';
import 'state/persistent/provider_registry.dart';
import 'state/persistent/ui_preferences_store.dart';
import 'state/providers.dart';
import 'state/secure_secret_store.dart';
import 'state/ui_preferences.dart';

/// Riverpod's automatic retry is off app-wide: failed network calls belong to
/// the agent loop's own retry policy (which knows not to retry a spend-cap
/// 429), not to a silent UI-layer retry. Pass as `ProviderScope(retry:)`.
Duration? noRetry(int retryCount, Object error) => null;

/// Where the encrypted database lives inside the app's support directory.
const String databaseFileName = 'sherpa.db';

/// Wires the app's services and returns them as `ProviderScope` overrides.
///
/// Production wiring: secrets in the Keychain / Android Keystore, sessions
/// and documents in the SQLite3MultipleCiphers database whose key lives in
/// that secret store, and real remote providers over the platform HTTP
/// stack. [inMemory] swaps everything for volatile fakes (integration
/// tests, screenshots).
Future<List<Override>> bootstrap({bool inMemory = false}) async {
  WidgetsFlutterBinding.ensureInitialized();
  _installErrorHandlers();
  if (inMemory) return _inMemoryOverrides();

  final secrets = SecureSecretStore();
  final db = await _openDatabase(secrets);
  final docs = JsonDocumentStore(db);
  final sessions = ObservableSessionStore(DriftSessionStore(db));
  final registry = DocumentProviderRegistry(documents: docs, secrets: secrets, client: _httpClient());
  final prefs = DocumentPreferencesStore(docs);
  final ui = DocumentUiPreferencesStore(docs);
  await Future.wait([registry.load(), prefs.load(), ui.load()]);
  final models = await modelFeatureOverrides(docs: docs, hubClient: _httpClient(), device: PlatformDeviceProfileSource());
  // Wraps the registry with the on-device provider ("local").
  final local = await localInferenceOverrides(registry: registry);
  final mcp = await mcpFeatureOverrides(docs: docs, secrets: secrets);
  unawaited(_excludeModelStorageFromBackup());

  return [
    secretStoreProvider.overrideWithValue(secrets),
    sessionStoreProvider.overrideWithValue(sessions),
    preferencesProvider.overrideWithValue(prefs),
    uiPreferencesStoreProvider.overrideWithValue(ui),
    chatScreenBuilderProvider.overrideWithValue(buildChatScreen),
    contextScreensProvider.overrideWithValue(contextScreens),
    dataEraseHooksProvider.overrideWith((ref) => [() => _eraseModels(ref), () => _eraseLocalInference(ref)]),
    chatContextManagerProvider.overrideWith(_contextManager),
    memoryMonitorProvider.overrideWithValue(PlatformMemoryMonitor()),
    ...models,
    ...local,
    ...mcp,
  ];
}

/// Saved KV prefixes and engine notes of the on-device provider.
Future<void> _eraseLocalInference(Ref ref) async => ref.read(localInferenceProvider)?.eraseAll();

/// "Delete all data" also removes downloads in flight and every model in
/// the library (files first via the library's own record-then-files order).
Future<void> _eraseModels(Ref ref) async {
  final downloads = ref.read(downloadManagerProvider);
  for (final job in downloads.jobs) {
    await downloads.cancel(job.id);
  }
  await downloads.clearFinished();
  final library = ref.read(modelLibraryProvider);
  for (final model in library.models) {
    await library.delete(model.id);
  }
}

/// background_downloader keeps its task records (signed CDN URLs, valid
/// about an hour) in these Localstore collections under the support
/// directory.
const List<String> _downloaderStores = [
  'backgroundDownloaderTaskRecords',
  'backgroundDownloaderResumeData',
  'backgroundDownloaderPausedTasks',
];

/// Multi-GB model files and download bookkeeping do not belong in iCloud
/// (Android: the backup rules XML lists the same folders). The flag must
/// be set on an existing directory, so the stores are created first; it
/// covers everything inside.
Future<void> _excludeModelStorageFromBackup() async {
  if (!Platform.isIOS) return;
  try {
    final support = await getApplicationSupportDirectory();
    final layout = await ModelStorageLayout.fromSupportDirectory();
    for (final dir in [layout.root, for (final s in _downloaderStores) p.join(support.path, s)]) {
      await Directory(dir).create(recursive: true);
      await BackupExclusion.exclude(dir, includeSqliteSidecars: false);
    }
  } on Object catch (e) {
    debugPrint('Backup exclusion failed: ${e.runtimeType}');
  }
}

/// The escalation ladder (prune → truncate → compact → handoff → hard stop).
/// Summaries are extractive here: deterministic, offline and free. Per
/// chat, `chatContextExtrasProvider` swaps in a model-written summarizer
/// (the chat's own on-device model at background priority, or a remote
/// chat's model once the user opts in under Privacy → Long chats), with the
/// extractive one as fallback.
ContextManager _contextManager(Ref ref) => LadderContextManager(
      strategy: const ExtractiveContextStrategy(),
      toolLookup: ref.watch(toolRouterProvider).lookup,
      // The side-effect ledger believes declared hints only from trusted
      // sources, like the approval policy.
      annotationsFor: ref.watch(approvalPolicyProvider).annotationsFor,
    );

/// Opens the encrypted database, never falling back to plaintext.
///
/// The key is device-only (`first_unlock_this_device`), so a database
/// restored from a backup onto another device cannot be decrypted. Rather
/// than failing every launch, that file is moved aside (kept, in case the
/// key reappears) and a fresh database is created.
Future<SherpaDatabase> _openDatabase(SecretStore secrets) async {
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  final path = p.join(dir.path, databaseFileName);
  try {
    final key = await loadOrCreateDatabaseKey(secrets, databasePath: path);
    final db = await openSherpaDatabase(path: path, key: key);
    // iOS backs up Application Support by default; the ciphertext is useless
    // without the device-only key (Android: backup rules XML).
    unawaited(BackupExclusion.exclude(path).catchError((Object _) => const <String>[]));
    return db;
  } on DatabaseEncryptionException catch (e) {
    if (e.failure != EncryptionFailure.keyMissing && e.failure != EncryptionFailure.keyRejected) rethrow;
    final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('$path$suffix');
      if (f.existsSync()) await f.rename('$path.unreadable-$stamp$suffix');
    }
    // Keep a rejected key next to the quarantined file instead of losing it.
    final oldKey = await secrets.read(databaseKeySecretName);
    if (oldKey != null) await secrets.write('$databaseKeySecretName.unreadable-$stamp', oldKey);
    await secrets.delete(databaseKeySecretName);
    final key = await loadOrCreateDatabaseKey(secrets, databasePath: path);
    return openSherpaDatabase(path: path, key: key);
  }
}

/// The platform HTTP stack: URLSession on iOS (proxy settings, HTTP/2,
/// system trust), dart:io elsewhere. Both honour `AbortableRequest`.
http.Client _httpClient() {
  if (Platform.isIOS || Platform.isMacOS) return CupertinoClient.defaultSessionConfiguration();
  return IOClient(HttpClient()..connectionTimeout = const Duration(seconds: 20));
}

Future<List<Override>> _inMemoryOverrides() async {
  final secrets = InMemorySecretStore();
  final client = _httpClient();
  final models = await inMemoryModelFeatureOverrides();
  final registry = InMemoryProviderRegistry(
    secrets: secrets,
    factory: (config, apiKey) => createProvider(config, apiKey: apiKey, client: client),
  );
  final local = await inMemoryLocalInferenceOverrides(registry: registry);
  final mcp = await inMemoryMcpFeatureOverrides(secrets: secrets);
  return [
    secretStoreProvider.overrideWithValue(secrets),
    sessionStoreProvider.overrideWithValue(ObservableSessionStore(InMemorySessionStore())),
    preferencesProvider.overrideWithValue(InMemoryPreferencesStore()),
    uiPreferencesStoreProvider.overrideWithValue(InMemoryUiPreferencesStore()),
    chatScreenBuilderProvider.overrideWithValue(buildChatScreen),
    contextScreensProvider.overrideWithValue(contextScreens),
    dataEraseHooksProvider.overrideWith((ref) => [() => _eraseModels(ref), () => _eraseLocalInference(ref)]),
    chatContextManagerProvider.overrideWith(_contextManager),
    ...models,
    ...local,
    ...mcp,
  ];
}

/// Errors are reported without their arguments: a provider exception can
/// echo request details, and nothing here may ever print a secret.
void _installErrorHandlers() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    if (kDebugMode) {
      previous?.call(details);
    } else {
      debugPrint('FlutterError: ${details.exception.runtimeType}');
    }
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught ${error.runtimeType}');
    return true;
  };
}
