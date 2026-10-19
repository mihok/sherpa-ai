/// Test doubles for code that depends on sherpa_litert: a scriptable
/// [LiteRtBackend] (the Pigeon layer) and a [AppForeground].
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/services.dart';

import 'sherpa_litert.dart';

/// Drives one native stream from a test: push events as Kotlin would.
final class FakeStream {
  FakeStream._(this.backend, this.id, {this.send, this.nano});

  final FakeLiteRtBackend backend;
  final int id;

  /// The LiteRT-LM request (null for Gemini Nano / downloads).
  final SendRequestMsg? send;

  /// The Gemini Nano request.
  final NanoRequestMsg? nano;

  bool get cancelled => backend.cancels.any((c) => c.streamId == id);

  void batch(List<LiteRtEvent> events) => backend.deliver(id, events);

  void text(String delta) => batch([LiteRtEvent(kind: EventKind.textDelta, text: delta)]);

  void reasoning(String delta) => batch([LiteRtEvent(kind: EventKind.reasoningDelta, text: delta)]);

  void toolCalls(List<ToolCallMsg> calls) => batch([LiteRtEvent(kind: EventKind.toolCalls, toolCalls: calls)]);

  void done([GenerationStatsMsg? stats]) =>
      batch([LiteRtEvent(kind: EventKind.done, stats: stats ?? GenerationStatsMsg())]);

  void cancelledWith(String reason) => batch([LiteRtEvent(kind: EventKind.cancelled, detail: reason)]);

  void error(ErrorMsg error) => batch([LiteRtEvent(kind: EventKind.error, error: error)]);
}

/// A script for one `sendMessage` / `nanoGenerate` / `nanoDownload`.
typedef FakeScript = FutureOr<void> Function(FakeStream stream);

/// Scriptable [LiteRtBackend]: set [platform], [models], [nano]; queue
/// [scripts]; inspect what the code under test asked for.
final class FakeLiteRtBackend implements LiteRtBackend {
  FakeLiteRtBackend({
    PlatformInfoMsg? platform,
    Map<String, ModelInfoMsg>? models,
    NanoStatusMsg? nano,
    this.supported = true,
  })  : platform = platform ?? androidPlatform(),
        models = models ?? {},
        nano = nano ?? NanoStatusMsg(featureStatus: 3, baseModelName: 'nano-v3', tokenLimit: 4000, systemPrompt: true);

  /// A Pixel-like Android 16 device.
  static PlatformInfoMsg androidPlatform({String? socModel = 'Tensor G5', bool liteRtAvailable = true}) =>
      PlatformInfoMsg(
        apiLevel: 36,
        supportedAbis: const ['arm64-v8a'],
        socManufacturer: 'Google',
        socModel: socModel,
        nativeLibraryDir: '/data/app/lib/arm64',
        cacheDir: '/data/user/0/app/cache',
        liteRtAvailable: liteRtAvailable,
        mlKitAvailable: true,
      );

  /// A Gemma-like `.litertlm` with native function calling.
  static ModelInfoMsg modelInfo({
    bool functionCalling = true,
    bool thinking = false,
    bool vision = false,
    List<String> backends = const ['gpu', 'cpu'],
    int maxContext = 32768,
    String modelType = 'llm',
    String? npuBrand,
    String? socName,
    String? minRuntimeVersion,
  }) =>
      ModelInfoMsg(
        modelType: modelType,
        maxContextTokens: maxContext,
        dynamicContext: false,
        vision: vision,
        audio: false,
        textBackends: backends,
        npuBrand: npuBrand,
        socName: socName,
        minRuntimeVersion: minRuntimeVersion,
        supportsFunctionCalling: functionCalling,
        supportsThinking: thinking,
        speculativeDecoding: false,
        defaultTemperature: 1.0,
        defaultTopK: 64,
        defaultTopP: 0.95,
        fileBytes: 2000000000,
      );

  bool supported;
  PlatformInfoMsg platform;

  /// `inspectModel` answers by path; a missing path fails like Kotlin
  /// (`litert_status`, NOT_FOUND).
  final Map<String, ModelInfoMsg> models;
  NanoStatusMsg nano;

  /// Decides `loadEngine`; default: the first backend succeeds.
  FutureOr<LoadResultMsg> Function(LoadRequestMsg request)? onLoad;

  /// Thrown by the next host call of that name, when set.
  final Map<String, Object> failNext = {};

  /// Consumed one per `sendMessage` / `nanoGenerate` / `nanoDownload`;
  /// without one the stream ends with `done` and no output.
  final Queue<FakeScript> scripts = Queue();

  /// Answer `cancel` with a `cancelled` terminal echoing the reason (as
  /// Kotlin does). Off = an engine that never answers (grace timeout).
  bool answerCancel = true;

  bool appInForeground = true;

  /// `LoadResultMsg.templateRendersTools` of the default [onLoad].
  bool? templateRendersTools;

  final List<LoadRequestMsg> loads = [];
  final List<ConversationSpecMsg> opened = [];
  final List<String> closed = [];
  final List<SendRequestMsg> sends = [];
  final List<NanoRequestMsg> nanoRequests = [];
  final List<({int streamId, String reason})> cancels = [];
  final List<({int streamId, int batches})> credits = [];
  final List<String> releases = [];
  final List<int> trimPolicies = [];
  final List<String> inspected = [];
  final Map<int, FakeStream> streams = {};

  final StreamController<EventBatch> _events = StreamController.broadcast(sync: true);
  String? _loadedKey;

  /// Delivers [events] of [streamId] as one batch.
  void deliver(int streamId, List<LiteRtEvent> events) => _events.add(EventBatch(streamId: streamId, events: events));

  /// A global event (stream 0).
  void emitGlobal(LiteRtEvent e) => deliver(0, [e]);

  /// Simulates `onTrimMemory` at or above the threshold while [streamId]
  /// runs: the turn ends with `cancelled(memory_pressure)` and the engine is
  /// released.
  void trimRelease({int? streamId}) {
    emitGlobal(LiteRtEvent(kind: EventKind.trimMemory, value: 40));
    if (streamId != null) deliver(streamId, [LiteRtEvent(kind: EventKind.cancelled, detail: 'memory_pressure')]);
    _loadedKey = null;
    emitGlobal(LiteRtEvent(kind: EventKind.engineReleased, detail: 'memory_pressure'));
  }

  int get totalCredits => credits.fold(0, (a, c) => a + c.batches);

  void _maybeFail(String call) {
    final e = failNext.remove(call);
    if (e != null) throw e;
  }

  void _checkSupported() {
    if (!supported) throw PlatformException(code: 'unsupported', message: 'Android only');
  }

  Future<void> _run(FakeStream s) async {
    final script = scripts.isEmpty ? null : scripts.removeFirst();
    // Like Kotlin: events start after the host call returned.
    await Future<void>.delayed(Duration.zero);
    if (script == null) {
      s.done();
    } else {
      await script(s);
    }
  }

  @override
  bool get isSupported => supported;

  @override
  Stream<EventBatch> events() => _events.stream;

  @override
  Future<PlatformInfoMsg> platformInfo() async {
    _checkSupported();
    _maybeFail('platformInfo');
    return platform;
  }

  @override
  Future<ModelInfoMsg> inspectModel(String path) async {
    _checkSupported();
    _maybeFail('inspectModel');
    inspected.add(path);
    final m = models[path];
    if (m == null) {
      throw PlatformException(code: 'litert_status', message: 'model file not found: $path', details: [5]);
    }
    return m;
  }

  @override
  Future<LoadResultMsg> loadEngine(LoadRequestMsg request) async {
    _checkSupported();
    _maybeFail('loadEngine');
    final key = '${request.path}|${request.backends}|${request.maxNumTokens}|${request.vision}';
    if (_loadedKey == key) {
      return LoadResultMsg(
        backend: request.backends.first,
        failures: const [],
        initMs: 0,
        reused: true,
        templateRendersTools: templateRendersTools,
      );
    }
    loads.add(request);
    final result = await (onLoad?.call(request) ??
        LoadResultMsg(
          backend: request.backends.first,
          failures: const [],
          initMs: 1200,
          reused: false,
          templateRendersTools: templateRendersTools,
        ));
    _loadedKey = key;
    return result;
  }

  @override
  Future<void> releaseEngine(String reason) async {
    releases.add(reason);
    _loadedKey = null;
  }

  @override
  Future<void> openConversation(ConversationSpecMsg spec) async {
    _checkSupported();
    _maybeFail('openConversation');
    opened.add(spec);
  }

  @override
  Future<void> closeConversation(String conversationId) async => closed.add(conversationId);

  @override
  Future<void> sendMessage(SendRequestMsg request) async {
    _checkSupported();
    _maybeFail('sendMessage');
    sends.add(request);
    final s = streams[request.streamId] = FakeStream._(this, request.streamId, send: request);
    unawaited(_run(s));
  }

  @override
  Future<void> cancel(int streamId, String reason) async {
    cancels.add((streamId: streamId, reason: reason));
    if (answerCancel && streams.containsKey(streamId)) {
      await Future<void>.delayed(Duration.zero);
      deliver(streamId, [LiteRtEvent(kind: EventKind.cancelled, detail: reason)]);
    }
  }

  @override
  Future<void> credit(int streamId, int batches) async => credits.add((streamId: streamId, batches: batches));

  @override
  Future<void> setTrimPolicy(int releaseAtLevel) async => trimPolicies.add(releaseAtLevel);

  @override
  Future<NanoStatusMsg> nanoStatus(NanoConfigMsg config) async {
    _checkSupported();
    _maybeFail('nanoStatus');
    return nano;
  }

  @override
  Future<void> nanoDownload(int streamId, NanoConfigMsg config) async {
    _checkSupported();
    _maybeFail('nanoDownload');
    final s = streams[streamId] = FakeStream._(this, streamId);
    unawaited(_run(s));
  }

  @override
  Future<void> nanoWarmup(NanoConfigMsg config) async => _checkSupported();

  @override
  Future<void> nanoGenerate(NanoRequestMsg request) async {
    _checkSupported();
    _maybeFail('nanoGenerate');
    nanoRequests.add(request);
    final s = streams[request.streamId] = FakeStream._(this, request.streamId, nano: request);
    unawaited(_run(s));
  }

  @override
  Future<bool> isAppInForeground() async => appInForeground;

  Future<void> dispose() => _events.close();
}

/// A [AppForeground] the test flips.
final class FakeForeground implements AppForeground {
  FakeForeground({bool foreground = true}) : _fg = foreground;

  bool _fg;
  final StreamController<bool> _changes = StreamController.broadcast(sync: true);

  @override
  bool get isForeground => _fg;

  set foreground(bool value) {
    if (value == _fg) return;
    _fg = value;
    _changes.add(value);
  }

  @override
  Stream<bool> get changes => _changes.stream;

  Future<void> dispose() => _changes.close();
}
