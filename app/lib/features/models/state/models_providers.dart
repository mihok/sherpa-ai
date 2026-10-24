import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier, immutable, listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:sherpa_data/sherpa_data.dart' show DocumentCollections;
import 'package:sherpa_hub/sherpa_hub.dart';

import '../../../app_info.dart';
import '../../../services/device/device_profile_source.dart';
import '../../../services/downloads/downloads.dart';
import '../../../services/inference/app_foreground.dart';
import '../../../state/connectivity.dart';
import '../../../state/providers.dart';
import '../../diagnostics/app_error_ring.dart';
import 'hub_account.dart';
import 'model_fit.dart';

// ---------------------------------------------------------------------------
// Roots the integrator overrides in bootstrap() — see models_bootstrap.dart.
// ---------------------------------------------------------------------------

/// Where model records live (the encrypted `JsonDocumentStore` in
/// production, wrapped in [JsonDocumentRecordStore]).
final modelRecordStoreProvider = Provider<ModelRecordStore>(
  (ref) => throw UnimplementedError('modelRecordStoreProvider must be overridden (see modelFeatureOverrides)'),
);

/// Where model bytes live (`<app support>/models`).
final modelStorageLayoutProvider = Provider<ModelStorageLayout>(
  (ref) => throw UnimplementedError('modelStorageLayoutProvider must be overridden (see modelFeatureOverrides)'),
);

/// The byte mover. background_downloader on devices; a fake in tests.
/// It is told when Sherpa is on screen: only then does a Wi-Fi-only
/// download Android hasn't started count as held (see
/// [BackgroundTransferBackend.foreground]).
final transferBackendProvider = Provider<TransferBackend>((ref) {
  final app = AppLifecycleForeground();
  final onScreen = ValueNotifier<bool>(app.isForeground);
  final sub = app.changes.listen((v) => onScreen.value = v);
  ref.onDispose(() {
    unawaited(sub.cancel());
    app.dispose();
    onScreen.dispose();
  });
  return BackgroundTransferBackend(foreground: onScreen);
});

/// In-process transfers for files served from huggingface.co itself (the
/// only transfer path that may carry the Hub token).
final hubTransferBackendProvider = Provider<TransferBackend>(
  (ref) => InProcessTransferBackend(client: ref.watch(hubHttpClientProvider), token: ref.watch(hubAccountProvider).token),
);

/// HTTP client for Hub API calls. `resolveDownload` needs
/// `followRedirects = false` honoured, which both `IOClient` and
/// `CupertinoClient` do.
final hubHttpClientProvider = Provider<http.Client>((ref) {
  final c = http.Client();
  ref.onDispose(c.close);
  return c;
});

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

final hubAccountProvider = Provider<HubAccount>((ref) {
  final a = HubAccount(
    secrets: ref.watch(secretStoreProvider),
    store: ref.watch(modelRecordStoreProvider),
    client: ref.watch(hubHttpClientProvider),
  );
  ref.onDispose(a.dispose);
  return a;
});

/// The signed-in Hugging Face user, live (null when signed out).
final hubProfileProvider = StreamProvider<HubProfile?>((ref) async* {
  final a = ref.watch(hubAccountProvider);
  yield await a.profile();
  yield* a.changes;
});

/// Hub client with the user's token (attached on huggingface.co only).
final hfHubClientProvider = Provider<HfHubClient>((ref) {
  final account = ref.watch(hubAccountProvider);
  return HfHubClient(
    httpClient: ref.watch(hubHttpClientProvider),
    tokenProvider: account.token,
    clock: ref.watch(clockProvider),
    userAgent: 'sherpa/${AppInfo.version}',
  );
});

/// The browser's data source (a fixture catalog in tests).
final modelCatalogProvider = Provider<ModelCatalog>((ref) => HfHubCatalog(ref.watch(hfHubClientProvider)));

/// GGUF header peeks for device fit.
final modelShapeSourceProvider = Provider<ModelShapeSource>((ref) => HubModelShapeSource(ref.watch(hfHubClientProvider)));

/// Wi-Fi / mobile data / offline for the download manager. It listens to
/// the same connectivity feed as the offline banner (which subscribes
/// first, on the first frame); a feed that fails leaves it at "unknown"
/// (never blocks) and is recorded, instead of failing the manager.
final networkMonitorProvider = Provider<NetworkMonitor>(
  (ref) {
    final ring = ref.read(appErrorRingProvider);
    final m = ConnectivityNetworkMonitor(
      ref.watch(connectivityStreamProvider),
      onError: (e) => ring.record(e, source: 'downloads', code: 'network_monitor'),
    );
    ref.onDispose(m.dispose);
    return m;
  },
  name: 'networkMonitorProvider',
);

final modelLibraryProvider = Provider<ModelLibrary>((ref) {
  final lib = ModelLibrary(
    store: ref.watch(modelRecordStoreProvider),
    layout: ref.watch(modelStorageLayoutProvider),
    clock: ref.watch(clockProvider),
    ids: ref.watch(idGeneratorProvider),
  );
  ref.onDispose(lib.dispose);
  return lib;
});

final downloadManagerProvider = Provider<DownloadManager>((ref) {
  final ring = ref.read(appErrorRingProvider);
  final m = DownloadManager(
    store: ref.watch(modelRecordStoreProvider),
    layout: ref.watch(modelStorageLayoutProvider),
    backend: ref.watch(transferBackendProvider),
    hubBackend: ref.watch(hubTransferBackendProvider),
    resolver: HubDownloadResolver(ref.watch(hfHubClientProvider)),
    library: ref.watch(modelLibraryProvider),
    device: ref.watch(deviceProfileSourceProvider),
    network: ref.watch(networkMonitorProvider),
    clock: ref.watch(clockProvider),
    ids: ref.watch(idGeneratorProvider),
    onError: (e, code) => ring.record(e, source: 'downloads', code: code),
  );
  // Reported through onError; enqueue retries init and explains a failure.
  unawaited(m.init().catchError((Object _) {}));
  ref.onDispose(m.dispose);
  return m;
}, name: 'downloadManagerProvider');

/// Download jobs, live.
final downloadJobsProvider = StreamProvider<List<DownloadJobView>>((ref) async* {
  final m = ref.watch(downloadManagerProvider);
  if (!m.isReady) await m.init();
  yield m.jobs;
  yield* m.changes;
});

/// Installed models, live.
final libraryModelsProvider = StreamProvider<List<LibraryModel>>((ref) async* {
  final m = ref.watch(downloadManagerProvider);
  if (!m.isReady) await m.init();
  yield m.library.models;
  yield* m.library.changes;
});

/// Global Wi-Fi-only policy (persisted by the manager).
final wifiOnlyProvider = Provider<bool>((ref) {
  ref.watch(downloadJobsProvider);
  return ref.watch(downloadManagerProvider).wifiOnly;
});

// ---------------------------------------------------------------------------
// Browser preferences
// ---------------------------------------------------------------------------

/// Publishers whose quantizations are pinned in the browser (R08 §13.3),
/// in the order the row shows them.
const List<String> defaultTrustedQuantizers = [
  'bartowski',
  'unsloth',
  'ggml-org',
  'lmstudio-community',
  'mradermacher',
  'mlx-community',
  'litert-community',
];

@immutable
final class ModelBrowserPrefs {
  const ModelBrowserPrefs({this.trustedQuantizers = defaultTrustedQuantizers, this.showUncensored = false});

  /// Pinned publisher chips; editable.
  final List<String> trustedQuantizers;

  /// Uncensored / abliterated fine-tunes are hidden by default (PLAN §7 Q7,
  /// R08 §16 risk 12).
  final bool showUncensored;

  ModelBrowserPrefs copyWith({List<String>? trustedQuantizers, bool? showUncensored}) => ModelBrowserPrefs(
        trustedQuantizers: trustedQuantizers ?? this.trustedQuantizers,
        showUncensored: showUncensored ?? this.showUncensored,
      );

  @override
  bool operator ==(Object other) =>
      other is ModelBrowserPrefs &&
      listEquals(other.trustedQuantizers, trustedQuantizers) &&
      other.showUncensored == showUncensored;

  @override
  int get hashCode => Object.hash(Object.hashAll(trustedQuantizers), showUncensored);
}

/// Browser preferences, persisted next to the Wi-Fi policy in
/// `preferences/models`.
final modelBrowserPrefsProvider = NotifierProvider<ModelBrowserPrefsNotifier, ModelBrowserPrefs>(
  ModelBrowserPrefsNotifier.new,
);

final class ModelBrowserPrefsNotifier extends Notifier<ModelBrowserPrefs> {
  static const _collection = DocumentCollections.preferences;

  @override
  ModelBrowserPrefs build() {
    unawaited(_load());
    return const ModelBrowserPrefs();
  }

  Future<void> _load() async {
    final doc = await ref.read(modelRecordStoreProvider).get(_collection, ModelPreferenceIds.models);
    if (doc == null || !ref.mounted) return;
    final list = doc['trustedQuantizers'];
    state = ModelBrowserPrefs(
      trustedQuantizers: list is List ? [for (final e in list) '$e'] : defaultTrustedQuantizers,
      showUncensored: doc['showUncensored'] == true,
    );
  }

  Future<void> _save() async {
    final store = ref.read(modelRecordStoreProvider);
    final doc = await store.get(_collection, ModelPreferenceIds.models) ?? <String, Object?>{};
    await store.put(_collection, ModelPreferenceIds.models, {
      ...doc,
      'trustedQuantizers': state.trustedQuantizers,
      'showUncensored': state.showUncensored,
    });
  }

  Future<void> setShowUncensored(bool v) async {
    state = state.copyWith(showUncensored: v);
    await _save();
  }

  /// Adds a Hub namespace (validated: letters, digits, `-`, `_`, `.`).
  Future<bool> addQuantizer(String raw) async {
    final name = raw.trim().replaceFirst(RegExp(r'^https?://huggingface\.co/'), '').split('/').first;
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$').hasMatch(name)) return false;
    if (state.trustedQuantizers.any((q) => q.toLowerCase() == name.toLowerCase())) return true;
    state = state.copyWith(trustedQuantizers: [...state.trustedQuantizers, name]);
    await _save();
    return true;
  }

  Future<void> removeQuantizer(String name) async {
    state = state.copyWith(trustedQuantizers: [for (final q in state.trustedQuantizers) if (q != name) q]);
    await _save();
  }

  Future<void> resetQuantizers() async {
    state = state.copyWith(trustedQuantizers: defaultTrustedQuantizers);
    await _save();
  }
}

// ---------------------------------------------------------------------------
// Detail screen data
// ---------------------------------------------------------------------------

/// Details pinned to one commit (one Hub API call, R08 §15.2).
final modelDetailsProvider = FutureProvider.autoDispose.family<CatalogModelDetails, String>(
  (ref, id) => ref.watch(modelCatalogProvider).details(id),
);

/// The header peek of a repo file, keyed by (repo, commit, path).
final modelShapeProvider = FutureProvider.autoDispose.family<ModelShape, (String, String, String)>(
  (ref, key) => ref.watch(modelShapeSourceProvider).peek(key.$1, key.$2, key.$3),
);
