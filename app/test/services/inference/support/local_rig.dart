import 'dart:async';
import 'dart:io';

import 'package:sherpa/features/models/state/model_fit.dart' show ModelShape;
import 'package:sherpa/services/downloads/downloads.dart';
import 'package:sherpa/services/inference/autotune_scheduler.dart';
import 'package:sherpa/services/inference/local_inference.dart';
import 'package:sherpa/services/inference/record_key_value_store.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart'
    show DevicePlatform, DeviceProfile, FileRole, GgufMetadata, ModelArchitecture, ModelFormat;
import 'package:sherpa_inference/sherpa_inference.dart';
import 'package:sherpa_inference/testing.dart';
import 'package:sherpa_providers/sherpa_providers.dart' show ProviderConfig;

/// A library record as a download or import leaves it.
LibraryModel libraryModel(
  String id, {
  String name = 'Qwen3 0.6B',
  String? sha = 'ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12',
  int sizeBytes = 400 << 20,
  bool toolUse = true,
  bool reasoning = true,
  int? defaultContext,
  int? trainContext = 40960,
  String? mmproj,
  LibraryIssue issue = LibraryIssue.none,
  ModelFormat format = ModelFormat.gguf,
  DateTime? installedAt,
}) {
  final load = 'imported/$id/model.gguf';
  return LibraryModel(
    id: id,
    source: LibrarySource.imported,
    displayName: name,
    format: format,
    files: [
      LibraryFile(path: load, role: FileRole.model, sizeBytes: sizeBytes, sha256: sha),
      if (mmproj != null) LibraryFile(path: mmproj, role: FileRole.mmproj, sizeBytes: 50 << 20, sha256: 'ee' * 32),
    ],
    loadPath: load,
    installedAt: installedAt ?? DateTime.utc(2026, 10, 1),
    quant: 'Q4_K_M',
    mmprojPath: mmproj,
    contextLength: trainContext,
    defaultContextLength: defaultContext,
    architecture: 'qwen3',
    parameterCount: 596049920,
    toolUse: toolUse,
    reasoning: reasoning,
    issue: issue,
  );
}

/// A [LocalInference] over [FakeEngineHost] in a temp directory, with an
/// in-memory library. Real time: use plain `test()` (or `runAsync`).
final class LocalRig {
  LocalRig._(this.dir, this.records, this.layout, this.library, this.memory, this._hostFor, this.config, this.clock);

  static Future<LocalRig> create({
    FakeEngineHost Function()? host,
    AutotunePolicy autotune = AutotunePolicy.off,
    BackgroundPolicy backgroundPolicy = BackgroundPolicy.none,
    bool observeAppLifecycle = false,
    InMemoryRecordStore? records,
    Directory? dir,
    FakeMemoryMonitor? memory,
  }) async {
    final d = dir ?? await Directory.systemTemp.createTemp('sherpa_local_rig_');
    final r = records ?? InMemoryRecordStore();
    final layout = ModelStorageLayout('${d.path}/models');
    final clock = FakeClock(DateTime.utc(2026, 10, 19, 9));
    final library = ModelLibrary(store: r, layout: layout, clock: clock);
    final rig = LocalRig._(
      d,
      r,
      layout,
      library,
      memory ?? FakeMemoryMonitor(),
      host ?? FakeEngineHost.new,
      null,
      clock,
    );
    rig.config = LocalInferenceConfig(
      supportDirectory: '${d.path}/support',
      cacheDirectory: '${d.path}/caches',
      hostFactory: rig._factory,
      backgroundPolicy: backgroundPolicy,
      recordProcessState: false,
      autoStart: false,
      observeAppLifecycle: observeAppLifecycle,
      autotune: autotune,
    );
    return rig;
  }

  final Directory dir;
  final InMemoryRecordStore records;
  final ModelStorageLayout layout;
  final ModelLibrary library;
  final FakeMemoryMonitor memory;
  final FakeEngineHost Function() _hostFor;
  LocalInferenceConfig? config;
  final FakeClock clock;

  /// Every host the factory built, in order.
  final List<FakeEngineHost> hosts = [];

  FakeEngineHost get host => hosts.last;

  Future<EngineHost> _factory({String? crashBreadcrumbPath}) async {
    final h = _hostFor();
    hosts.add(h);
    return h;
  }

  LocalInference? _local;

  LocalInference get local => _local ??= newService();

  /// A fresh service over the same files and records (an app relaunch).
  LocalInference newService({LocalInferenceConfig? config}) => LocalInference(
        library: library,
        layout: layout,
        store: RecordKeyValueStore(records),
        config: config ?? this.config!,
        memory: memory,
        clock: clock,
      );

  Future<LibraryModel> add(LibraryModel m) => library.add(m);

  Future<void> dispose() async {
    await _local?.dispose();
    if (dir.existsSync()) await dir.delete(recursive: true);
  }
}

/// Text of a model stream, failing on errors.
Future<String> replyText(ModelProvider p, String modelId, String text, {String? session}) async {
  final out = StringBuffer();
  await for (final e in p.stream(request(modelId, text, session: session))) {
    if (e is TextDelta) out.write(e.text);
  }
  return out.toString();
}

ModelRequest request(String modelId, String text, {String? session}) => ModelRequest(
      modelId: modelId,
      messages: [
        Message(id: 'u1', role: Role.user, content: [TextPart(text)], createdAt: DateTime.utc(2026)),
      ],
      cache: CacheHints(sessionId: session),
    );

/// Polls [condition] in real time.
Future<void> until(bool Function() condition, {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met', timeout);
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// The shape a Llama 3.2 1B GGUF header gives (16 layers, 8 KV heads).
final ModelShape llama1bLikeShape = ModelShape(
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
);

const int gib = 1024 * 1024 * 1024;

/// A 12 GB Android phone, availability estimated.
const DeviceProfile phone12gb = DeviceProfile(platform: DevicePlatform.android, totalRamBytes: 12 * gib);

/// A remote provider that lists [models] and replies "remote".
final class StubRemoteProvider implements ModelProvider {
  StubRemoteProvider(this.config, {this.models = const ['big-cloud']});

  final ProviderConfig config;
  final List<String> models;

  @override
  ProviderInfo get info => ProviderInfo(
        id: config.id,
        kind: ProviderKind.fake,
        displayName: config.displayName,
        location: ExecutionLocation.remote,
        baseUrl: config.baseUrl,
      );

  @override
  Future<List<ModelDescriptor>> listModels() async => [
        for (final m in models)
          ModelDescriptor(id: m, providerId: config.id, displayName: m, capabilities: const ModelCapabilities(contextLength: 32768)),
      ];

  @override
  Future<ModelCapabilities> capabilities(String modelId) async => const ModelCapabilities(contextLength: 32768);

  @override
  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel}) =>
      Stream.fromIterable(const [TextDelta('remote'), Finish(FinishReason.stop)]);
}
