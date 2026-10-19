import 'dart:async';
import 'dart:io';

import 'package:sherpa/features/perf/state/perf_lab.dart';
import 'package:sherpa/services/downloads/downloads.dart';
import 'package:sherpa/services/inference/autotune_scheduler.dart';
import 'package:sherpa/services/inference/local_engine_host.dart';
import 'package:sherpa/services/inference/local_inference.dart';
import 'package:sherpa/services/inference/record_key_value_store.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart' show DevicePlatform;
import 'package:sherpa_inference/sherpa_inference.dart';
import 'package:sherpa_inference/testing.dart';
import 'package:sherpa_platform/sherpa_platform.dart';

import '../../../services/inference/support/local_rig.dart' show libraryModel;

export '../../../services/inference/support/local_rig.dart' show libraryModel, replyText, request, until;

const int mib = 1024 * 1024;

/// `SE_ERR_CANCELLED` (the bindings' status codes are not exported).
const int seErrCancelled = -7;

/// A [FakeEngineHost] whose `bench` can be held open ([holdBenches]) until
/// [releaseBenches] or its cancel token fires, and which logs the order of
/// benches and generations ([log]), so tests can see preemption and
/// queueing.
final class GatedHost implements EngineHost {
  GatedHost(this.inner);

  final FakeEngineHost inner;

  /// "bench start", "bench cancelled", "bench done", "generate start",
  /// "generate done", in order.
  final List<String> log = [];
  Completer<void>? _gate;
  int benchesStarted = 0;
  int benchesCancelled = 0;

  void holdBenches() => _gate ??= Completer<void>();

  void releaseBenches() {
    final g = _gate;
    _gate = null;
    if (g != null && !g.isCompleted) g.complete();
  }

  @override
  Future<BenchResult> bench(ModelRef model, BenchConfig config, {CancellationToken? cancel}) async {
    benchesStarted++;
    log.add('bench start');
    final gate = _gate;
    if (gate != null) {
      await Future.any([gate.future, if (cancel != null) cancel.whenCancelled]);
      if (cancel?.isCancelled ?? false) {
        benchesCancelled++;
        log.add('bench cancelled');
        throw const EngineException(seErrCancelled, 'bench cancelled');
      }
    }
    final r = await inner.bench(model, config, cancel: cancel);
    log.add('bench done');
    return r;
  }

  @override
  Stream<EngineEvent> generate(SessionRef session, String requestJson) async* {
    log.add('generate start');
    yield* inner.generate(session, requestJson);
    log.add('generate done');
  }

  @override
  EngineHostKind get kind => inner.kind;

  @override
  int get epoch => inner.epoch;

  @override
  Stream<EngineHostEvent> get events => inner.events;

  @override
  Future<EngineInfo> start() => inner.start();

  @override
  Future<String> systemInfoJson() async => '{"cpu_variant":"","cpu_backend_features":{"KLEIDIAI":"1","REPACK":"1"},'
      '"backends":[{"name":"CPU","n_devices":1}],'
      '"cpu":{"arch":"arm64","logical_cores":8,"performance_cores":4,"features":{"dotprod":true,"i8mm":true,"sve":false}}}';

  @override
  Future<EngineModel> loadModel(ModelLoadOptions options, {CancellationToken? cancel, void Function(double)? onProgress}) =>
      inner.loadModel(options, cancel: cancel, onProgress: onProgress);

  @override
  Future<void> freeModel(ModelRef model) => inner.freeModel(model);

  @override
  Future<MemoryEstimate> estimateMemory(ModelLoadOptions model, SessionConfig session) => inner.estimateMemory(model, session);

  @override
  Future<EngineSession> createSession(ModelRef model, SessionConfig config) => inner.createSession(model, config);

  @override
  Future<void> freeSession(SessionRef session) => inner.freeSession(session);

  @override
  Future<void> resetSession(SessionRef session) => inner.resetSession(session);

  @override
  Future<void> setThreads(SessionRef session, int nThreads, int nThreadsBatch) =>
      inner.setThreads(session, nThreads, nThreadsBatch);

  @override
  Future<String> sessionInfoJson(SessionRef session) => inner.sessionInfoJson(session);

  @override
  Future<MemoryEstimate> sessionMemory(SessionRef session) => inner.sessionMemory(session);

  @override
  Future<void> cancelGeneration(SessionRef session) => inner.cancelGeneration(session);

  @override
  Future<List<int>> tokenize(ModelRef model, String text, {bool addSpecial = false, bool parseSpecial = false}) =>
      inner.tokenize(model, text, addSpecial: addSpecial, parseSpecial: parseSpecial);

  @override
  Future<String> detokenize(ModelRef model, List<int> tokens, {bool renderSpecial = false}) =>
      inner.detokenize(model, tokens, renderSpecial: renderSpecial);

  @override
  Future<int> countChatTokens(ModelRef model, String requestJson) => inner.countChatTokens(model, requestJson);

  @override
  Future<List<int>> countBatch(ModelRef model, {List<String> texts = const [], List<String> chatRequests = const []}) =>
      inner.countBatch(model, texts: texts, chatRequests: chatRequests);

  @override
  Future<int> saveState(SessionRef session, String path) => inner.saveState(session, path);

  @override
  Future<int> loadState(SessionRef session, String path) => inner.loadState(session, path);

  @override
  Future<LoraRef> loadLora(ModelRef model, String path) => inner.loadLora(model, path);

  @override
  Future<void> freeLora(LoraRef lora) => inner.freeLora(lora);

  @override
  Future<void> setLoras(SessionRef session, List<(LoraRef, double)> loras) => inner.setLoras(session, loras);

  @override
  SyncTokenizer? syncTokenizer(ModelRef model) => inner.syncTokenizer(model);

  @override
  Future<void> dispose() => inner.dispose();
}

/// Bench results from a table keyed by thread count, with optional noise
/// per call: `{2: (pp: 100, tg: 10)}`.
BenchResult Function(BenchConfig) scriptedBench(
  Map<int, ({double pp, double tg})> byThreads, {
  List<double> noise = const [0],
}) {
  var i = 0;
  return (c) {
    final r = byThreads[c.nThreads] ?? (pp: 50.0, tg: 5.0);
    final n = noise[i++ % noise.length];
    final pp = r.pp * (1 + n);
    final tg = r.tg * (1 + n);
    return BenchResult(
      nPrompt: c.nPrompt,
      nGen: c.nGen,
      nThreads: c.nThreads,
      promptTokensPerSec: pp,
      genTokensPerSec: tg,
      promptMs: c.nPrompt * 1000 / pp,
      genMs: c.nGen * 1000 / tg,
    );
  };
}

/// A 6 GB Android-like device as `sherpa_platform` reports it.
DeviceSnapshot fakeDevice({ThermalLevel thermal = ThermalLevel.nominal}) => DeviceSnapshot(
      platform: DevicePlatform.android,
      osVersion: '16',
      apiLevel: 36,
      manufacturer: 'Google',
      model: 'Pixel 8a',
      socManufacturer: 'Google',
      socModel: 'Tensor G3',
      capturedAt: DateTime.utc(2026, 10, 19, 9),
      totalRamBytes: 8 * 1024 * mib,
      availableRamBytes: 3 * 1024 * mib,
      batteryLevel: 0.82,
      charging: false,
      thermal: thermal,
      cpu: const CpuInfo(cores: 9, performanceCores: 4, features: {'dotprod', 'i8mm', 'bf16'}),
    );

/// [LocalInference] + [PerfLab] over a [GatedHost] in a temp directory.
/// Real time: use `test()` or `tester.runAsync`.
final class PerfRig {
  PerfRig._(this.dir, this.records, this.layout, this.library, this.memory, this.clock, this.host, this.config);

  static Future<PerfRig> create({
    FakeEngineHost? host,
    EngineHostFactory? hostFactory,
    FakeMemoryMonitor? memory,
    SessionConfig sessionDefaults = const SessionConfig(),
    int maxContext = 32768,
  }) async {
    final d = await Directory.systemTemp.createTemp('sherpa_perf_rig_');
    final records = InMemoryRecordStore();
    final layout = ModelStorageLayout('${d.path}/models');
    final clock = FakeClock(DateTime.utc(2026, 10, 19, 9));
    final library = ModelLibrary(store: records, layout: layout, clock: clock);
    final gated = GatedHost(host ?? FakeEngineHost());
    final config = LocalInferenceConfig(
      supportDirectory: '${d.path}/support',
      cacheDirectory: '${d.path}/caches',
      hostFactory: hostFactory ?? ({String? crashBreadcrumbPath}) async => gated,
      backgroundPolicy: BackgroundPolicy.none,
      recordProcessState: false,
      autoStart: false,
      observeAppLifecycle: false,
      autotune: AutotunePolicy.off,
      sessionDefaults: sessionDefaults,
      maxContext: maxContext,
    );
    return PerfRig._(d, records, layout, library, memory ?? FakeMemoryMonitor(), clock, gated, config);
  }

  final Directory dir;
  final InMemoryRecordStore records;
  final ModelStorageLayout layout;
  final ModelLibrary library;
  final FakeMemoryMonitor memory;
  final FakeClock clock;
  final GatedHost host;
  final LocalInferenceConfig config;

  FakeEngineHost get fake => host.inner;

  late final LocalInference local = LocalInference(
    library: library,
    layout: layout,
    store: RecordKeyValueStore(records),
    config: config,
    memory: memory,
    clock: clock,
  );

  /// Peak-memory readings the lab sees, in order (then the last repeats).
  List<int> memoryReadings = [500 * mib, 620 * mib, 610 * mib];
  int _reading = 0;

  Future<int?> _readMemory() async => memoryReadings[_reading < memoryReadings.length ? _reading++ : memoryReadings.length - 1];

  late final PerfLab lab = PerfLab(
    local: local,
    memory: memory,
    device: () async => fakeDevice(),
    memoryReader: _readMemory,
    clock: clock,
    samplePeriod: const Duration(milliseconds: 5),
  );

  /// Adds the default test model ("m1") and starts the engine.
  Future<void> addModelAndStart({String id = 'm1', bool toolUse = true}) async {
    await library.add(libraryModel(id, toolUse: toolUse));
    await local.start();
  }

  /// Bounded: in widget tests, work started in the fake zone can't finish
  /// once frames stop, and must not hang the next test.
  Future<void> dispose() async {
    host.releaseBenches();
    await local.dispose().timeout(const Duration(seconds: 3), onTimeout: () {});
    if (dir.existsSync()) await dir.delete(recursive: true);
  }
}

/// Memory state with a known budget: [availableMib] free, reported by a
/// real-looking source (so thermal counts as reported).
MemoryState memoryState({int availableMib = 4096, ThermalLevel thermal = ThermalLevel.nominal, int? footprintMib}) =>
    MemoryState(
      pressure: MemoryPressure.normal,
      availableBytes: availableMib * mib,
      totalBytes: 8192 * mib,
      appFootprintBytes: footprintMib == null ? null : footprintMib * mib,
      thermal: thermal,
      source: 'android:sample',
    );
