import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/app.dart';
import 'package:sherpa/bootstrap.dart' show noRetry;
import 'package:sherpa/features/models/model_library_screen.dart' show modelFilePickerProvider;
import 'package:sherpa/features/models/state/local_model_choice.dart';
import 'package:sherpa/features/models/state/model_fit.dart';
import 'package:sherpa/features/models/state/models_providers.dart';
import 'package:sherpa/services/device/device_profile_source.dart';
import 'package:sherpa/services/downloads/downloads.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa/state/ui_preferences.dart';
import 'package:sherpa_hub/sherpa_hub.dart';
import 'package:sherpa_hub/testing.dart';

import '../../../services/support/fake_hub.dart';
import '../../../services/support/gguf_fixture.dart';
import '../../../support/harness.dart';

const int gib = 1024 * 1024 * 1024;

/// A 4 GB and a 12 GB Android phone, availability estimated (the fallback
/// source's situation until the platform plugin lands).
const phone4 = DeviceProfile(platform: DevicePlatform.android, totalRamBytes: 4 * gib, freeStorageBytes: 40 * gib);
const phone12 = DeviceProfile(platform: DevicePlatform.android, totalRamBytes: 12 * gib, freeStorageBytes: 80 * gib);

const llama1b = 'bartowski/Llama-3.2-1B-Instruct-GGUF';
const fixtureCommit = '067b946cf014b7c697f3654f621d577a3e3afd1c';

String _sha(String seed) => sha256Hex(utf8.encode(seed));

HubRepoFile _file(String path, int size, {HubFileSecurity? security}) =>
    HubRepoFile(path: path, size: size, lfsSha256: _sha(path), lfsSize: size, xetHash: 'xet${_sha(path).substring(0, 20)}', security: security);

/// Real file sizes of bartowski's Llama 3.2 1B repo (R08 §3.2, §14 row 29)
/// plus a removed-quant file and a pickle, so every row kind shows up.
final List<HubRepoFile> llama1bFiles = [
  _file('Llama-3.2-1B-Instruct-f16.gguf', 2479595360),
  _file('Llama-3.2-1B-Instruct-Q8_0.gguf', 1321082528),
  _file('Llama-3.2-1B-Instruct-Q4_K_M.gguf', 807694464),
  _file('Llama-3.2-1B-Instruct-Q2_K.gguf', 540000000),
  _file('Llama-3.2-1B-Instruct-Q4_0_4_4.gguf', 773025920),
  _file('Llama-3.2-1B-Instruct.imatrix', 1843200),
  const HubRepoFile(path: 'README.md', size: 9400, oid: '1d3a'),
];

CatalogModelDetails fixtureDetails(
  String repo,
  List<HubRepoFile> files, {
  HubGating gating = HubGating.none,
  String? license = 'llama3.2',
  HubRepoSecurity? security = const HubRepoSecurity(scansDone: true),
  bool toolUse = true,
  int? downloads = 155390,
  int? likes = 184,
}) =>
    CatalogModelDetails(
      id: repo,
      commit: fixtureCommit,
      name: parseModelName(repo),
      variants: groupVariants(repo, files, repoSecurity: security),
      files: [for (final f in files) CatalogFile(file: f, name: parseModelName(repo, fileName: f.path))],
      gating: gating,
      license: license,
      security: security,
      toolUseHint: toolUse,
      info: HubModelInfo(id: repo, sha: fixtureCommit, downloads: downloads, likes: likes, gating: gating),
    );

/// The shape a Llama 3.2 1B GGUF header peek returns.
final ModelShape llama1bShape = ModelShape(
  architecture: ModelArchitecture.dense(
    layers: 16,
    kvHeads: 8,
    headDim: 64,
    trainContextLength: 131072,
    embeddingLength: 2048,
    feedForwardLength: 8192,
    vocabSize: 128256,
    headCount: 32,
    parameterCount: 1235814400,
    architecture: 'llama',
  ),
  metadata: const GgufMetadata({}),
  parameterCount: 1235814400,
  bytesFetched: 7831525,
);

CatalogEntry entry(String id, {List<String> tags = const ['gguf'], int? downloads, int? likes, bool toolUse = false, HubGating gating = HubGating.none}) =>
    CatalogEntry(
      id: id,
      name: parseModelName(id),
      downloads: downloads,
      likes: likes,
      tags: tags,
      toolUseHint: toolUse,
      gating: gating,
    );

final List<CatalogEntry> fixtureEntries = [
  entry(llama1b, downloads: 155390, likes: 184, toolUse: true),
  entry('unsloth/Qwen3-8B-GGUF', downloads: 2400000, likes: 812, toolUse: true),
  entry('ggml-org/gemma-3-270m-it-GGUF', downloads: 48000, likes: 61),
  entry('mradermacher/Llama-3.3-70B-Instruct-abliterated-GGUF', downloads: 9100, likes: 40),
  entry('lmstudio-community/Mistral-7B-Instruct-v0.3-GGUF', downloads: 310000, likes: 95, gating: HubGating.auto),
  entry('mlx-community/Qwen3-8B-4bit', tags: const ['mlx'], downloads: 51000, likes: 33),
];

/// Shape source answering from a map (null = "header unreadable").
final class FakeShapeSource implements ModelShapeSource {
  FakeShapeSource(this.shapes);

  final Map<String, ModelShape> shapes;
  final List<String> peeked = [];

  @override
  Future<ModelShape> peek(String repo, String commit, String path) async {
    peeked.add(path);
    final s = shapes[repo];
    if (s == null) throw const GgufFormatException('no fixture shape');
    return s;
  }
}

/// whoami for the HF account screen, resolve for downloads.
http.Client hubMock(FakeHub hub) => MockClient((req) async {
      if (req.url.path == '/api/whoami-v2') {
        if (req.headers['authorization'] != 'Bearer $hfToken') {
          return http.Response('{"error":"Invalid username or password."}', 401);
        }
        return http.Response(
          jsonEncode({
            'name': 'sherpa-tester',
            'fullname': 'Sherpa Tester',
            'orgs': [
              {'name': 'sherpa-org'},
            ],
            'auth': {
              'accessToken': {'role': 'read'},
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return hub.client.send(req).then(http.Response.fromStream);
    });

/// The real app with the model feature wired to fakes over a temp dir.
final class ModelsRig {
  ModelsRig._(this.app, this.dir, this.device, this.catalog, this.shapes, this.hub, this.manager, this.library, this.store,
      this.backend, this.network);

  static Future<ModelsRig> create(
    WidgetTester tester, {
    DeviceProfile device = phone12,
    ThemeMode mode = ThemeMode.light,
    List<CatalogEntry>? entries,
    Map<String, CatalogModelDetails>? details,
    Map<String, ModelShape>? shapes,
    NetworkKind network = NetworkKind.wifi,
    bool onboarded = true,
  }) async {
    final app = Harness(ui: UiSettings(themeMode: mode), onboarded: onboarded);
    late ModelsRig rig;
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('sherpa_models_ui_');
      final store = InMemoryRecordStore();
      final layout = ModelStorageLayout('${dir.path}/models');
      final source = FixedDeviceProfileSource(device);
      var seed = 0;
      final hub = FakeHub(llama1b, [
        for (final f in llama1bFiles.where((f) => f.isLfs))
          RemoteFile(f.path, f.path.endsWith('.gguf') ? syntheticGguf(totalBytes: 64 << 10, seed: ++seed) : fillBytes(64)),
      ]);
      hub.commit = fixtureCommit;
      final backend = FakeCdnBackend(hub);
      final net = FakeNetworkMonitor(network);
      final library = ModelLibrary(store: store, layout: layout, clock: app.clock, ids: app.ids);
      final manager = DownloadManager(
        store: store,
        layout: layout,
        backend: backend,
        hubBackend: InProcessTransferBackend(client: hub.client, token: () async => null),
        resolver: HubDownloadResolver(hub.hubClient()),
        library: library,
        device: source,
        network: net,
        clock: app.clock,
        ids: app.ids,
        sleep: (_) async {},
      );
      await manager.init();
      rig = ModelsRig._(
        app,
        dir,
        source,
        FixtureModelCatalog(entries: entries ?? fixtureEntries, detailsById: details ?? {llama1b: fixtureDetails(llama1b, llama1bFiles)}),
        FakeShapeSource(shapes ?? {llama1b: llama1bShape}),
        hub,
        manager,
        library,
        store,
        backend,
        net,
      );
    });
    addTearDown(() async {
      await tester.runAsync(() async {
        await rig.manager.dispose();
        if (rig.dir.existsSync()) await rig.dir.delete(recursive: true);
      });
    });
    return rig;
  }

  final Harness app;
  final Directory dir;
  final FixedDeviceProfileSource device;
  final FixtureModelCatalog catalog;
  final FakeShapeSource shapes;
  final FakeHub hub;
  final DownloadManager manager;
  final ModelLibrary library;
  final InMemoryRecordStore store;
  final FakeCdnBackend backend;
  final FakeNetworkMonitor network;

  /// "Use in chat" calls.
  final List<ModelChoice> usedInChat = [];

  /// Replaces the live job list (goldens, deterministic numbers).
  List<DownloadJobView>? staticJobs;

  /// What the file picker returns.
  LocalModelFile? pickedFile;

  /// Replaces the prebuilt download manager's override (e.g. one that fails
  /// to build first).
  Override? managerOverride;

  List<Override> get overrides => [
        ...app.overrides,
        modelRecordStoreProvider.overrideWithValue(store),
        modelStorageLayoutProvider.overrideWithValue(manager.layout),
        modelCatalogProvider.overrideWithValue(catalog),
        modelShapeSourceProvider.overrideWithValue(shapes),
        deviceProfileSourceProvider.overrideWithValue(device),
        networkMonitorProvider.overrideWithValue(network),
        transferBackendProvider.overrideWithValue(backend),
        hubHttpClientProvider.overrideWithValue(hubMock(hub)),
        modelLibraryProvider.overrideWithValue(library),
        managerOverride ?? downloadManagerProvider.overrideWithValue(manager),
        useLocalModelInChatProvider.overrideWithValue((context, choice) async => usedInChat.add(choice)),
        modelFilePickerProvider.overrideWithValue(() async => pickedFile),
        if (staticJobs != null) downloadJobsProvider.overrideWith((ref) => Stream.value(staticJobs!)),
      ];

  Widget widget() => ProviderScope(overrides: overrides, retry: noRetry, child: const SherpaApp());

  Future<void> pump(WidgetTester tester, {Size size = phone, String? location, double textScale = 1}) async {
    setWindow(tester, size, textScale: textScale);
    await tester.pumpWidget(widget());
    await tester.pumpAndSettle();
    if (location != null) await goTo(tester, location);
  }
}

/// Small deterministic bytes for files the fake CDN serves.
Uint8List fillBytes(int n) => Uint8List.fromList(List<int>.generate(n, (i) => (i * 7 + 3) & 0xff));
