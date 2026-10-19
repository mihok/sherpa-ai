/// Test doubles for code that uses sherpa_apple_ml: a fake of the Pigeon
/// layer that behaves like the Swift side (credits, coalescing, cancel →
/// `finished(cancelled)`, interrupt → `paused`, suspended FM tool calls).
library;

import 'dart:async';

import 'src/backend.dart';
import 'src/messages.pigeon.dart';

export 'src/messages.pigeon.dart';

/// A scriptable [AppleMlBackend].
final class FakeAppleMlBackend implements AppleMlBackend {
  FakeAppleMlBackend({this.supported = true, AmPlatformInfo? platform, AmFmAvailability? fm, this.maxOutstanding = 4})
    : platform = platform ?? iosDevice(),
      fm =
          fm ??
          AmFmAvailability(
            available: true,
            reason: AmFmUnavailableReason.none,
            localeSupported: true,
            contextSize: 4096,
          );

  /// An iPhone on iOS 27 with MLX compiled in and 6 GB available.
  static AmPlatformInfo iosDevice({
    String osVersion = '27.0.1',
    bool simulator = false,
    bool metal = true,
    bool mlx = true,
    int available = 6 << 30,
  }) => AmPlatformInfo(
    osVersion: osVersion,
    isSimulator: simulator,
    hasMetalDevice: metal,
    mlxCompiled: mlx,
    fmCompiled: true,
    appActive: true,
    procAvailableBytes: available,
    physicalMemoryBytes: 8 << 30,
    thermalState: 0,
    lowPowerMode: false,
  );

  final bool supported;
  AmPlatformInfo platform;
  AmFmAvailability fm;

  /// Mirrors Swift's `EventPump.maxOutstanding`.
  final int maxOutstanding;

  final List<AmMlxLoadRequest> loads = [];
  final List<String> unloads = [];
  final List<AmMlxGenerateRequest> mlxRequests = [];
  final List<AmFmGenerateRequest> fmRequests = [];
  final List<String> cancels = [];
  final List<(String, int)> acks = [];
  final List<(String, List<AmToolResult>)> submittedToolResults = [];
  final List<String> interrupts = [];
  final List<(AmEngine, String)> drops = [];
  final List<(String, String)> savedCaches = [];
  final List<String?> prewarms = [];

  /// Info returned by [mlxLoad] (defaults to a Qwen3-style model).
  AmMlxModelInfo Function(AmMlxLoadRequest request) onLoad = (r) => qwen3Info(r.modelId);

  /// Thrown by the next [mlxLoad] / [mlxGenerate] / [fmGenerate] when set.
  Object? loadError;
  Object? generateError;

  /// Called synchronously when a generation is accepted; script it there or
  /// later through [generations].
  void Function(FakeGeneration g)? onGenerate;

  /// When true (default), [cancel] answers like Swift: `finished(cancelled)`.
  bool finishOnCancel = true;

  final Map<String, FakeGeneration> generations = {};
  FakeGeneration? _last;

  FakeGeneration get lastGeneration => _last ?? (throw StateError('no generation started'));

  final StreamController<AmEventBatch> _events = StreamController<AmEventBatch>.broadcast();

  static AmMlxModelInfo qwen3Info(String modelId) => AmMlxModelInfo(
    modelId: modelId,
    modelType: 'qwen3',
    toolCallFormat: 'json',
    reasoningStart: '<think>',
    reasoningEnd: '</think>',
    reasoningImplicitEnds: const [],
    reasoningToggleKey: 'enable_thinking',
    reasoningToggleDefaultOn: true,
    reasoningAlwaysOn: false,
    reasoningPrimed: false,
    weightsBytes: 2 << 30,
    loadMs: 800,
    memoryLimitBytes: 5 << 30,
    cacheLimitBytes: 32 << 20,
    procAvailableBytes: 3 << 30,
  );

  /// Pushes a global event (generation id '').
  void emitGlobal(AmEvent e) => _events.add(AmEventBatch(generationId: '', seq: 0, events: [e]));

  /// Fails the shared event stream (a broken channel).
  void failChannel(Object error) => _events.addError(error);

  @override
  bool get isSupported => supported;

  @override
  Stream<AmEventBatch> events() => _events.stream;

  @override
  Future<AmPlatformInfo> platformInfo() async => platform;

  @override
  Future<AmFmAvailability> fmAvailability() async => fm;

  @override
  Future<AmMlxModelInfo> mlxLoad(AmMlxLoadRequest request) async {
    loads.add(request);
    final e = loadError;
    if (e != null) {
      loadError = null;
      throw e;
    }
    return onLoad(request);
  }

  @override
  Future<void> mlxUnload(String modelId) async => unloads.add(modelId);

  @override
  Future<void> mlxGenerate(AmMlxGenerateRequest request) async {
    final e = generateError;
    if (e != null) {
      generateError = null;
      throw e;
    }
    mlxRequests.add(request);
    _start(FakeGeneration._(this, request.generationId, mlx: request));
  }

  @override
  Future<void> fmGenerate(AmFmGenerateRequest request) async {
    final e = generateError;
    if (e != null) {
      generateError = null;
      throw e;
    }
    fmRequests.add(request);
    _start(FakeGeneration._(this, request.generationId, fm: request));
  }

  void _start(FakeGeneration g) {
    generations[g.id] = g;
    _last = g;
    onGenerate?.call(g);
  }

  @override
  Future<int> mlxCountTokens(String modelId, String text) async => (text.length / 4).ceil();

  @override
  Future<bool> mlxSavePromptCache(String sessionKey, String path) async {
    savedCaches.add((sessionKey, path));
    return true;
  }

  @override
  Future<void> fmSubmitToolResults(String generationId, List<AmToolResult> results) async {
    submittedToolResults.add((generationId, results));
    generations[generationId]?._toolResults(results);
  }

  @override
  Future<void> fmPrewarm(String? instructions) async => prewarms.add(instructions);

  @override
  Future<void> cancel(String generationId) async {
    cancels.add(generationId);
    final g = generations[generationId];
    if (g == null) return;
    g._cancelRequested.complete();
    if (finishOnCancel && !g.ended) g.finish('cancelled');
  }

  @override
  Future<void> ack(String generationId, int seq) async {
    acks.add((generationId, seq));
    generations[generationId]?._ack(seq);
  }

  @override
  Future<void> interruptAll(String reason) async {
    interrupts.add(reason);
    for (final g in generations.values) {
      if (g.mlx != null && !g.ended) g.pause(reason);
    }
  }

  @override
  Future<void> dropSession(AmEngine engine, String sessionKey) async => drops.add((engine, sessionKey));

  Future<void> close() => _events.close();
}

/// One native generation, driven by the test like Swift would drive it:
/// events are queued, text coalesces, and at most
/// [FakeAppleMlBackend.maxOutstanding] batches are in flight until Dart acks.
final class FakeGeneration {
  FakeGeneration._(this._backend, this.id, {this.mlx, this.fm});

  final FakeAppleMlBackend _backend;
  final String id;
  final AmMlxGenerateRequest? mlx;
  final AmFmGenerateRequest? fm;

  final List<AmEvent> _pending = [];
  final Set<int> _outstanding = {};
  int _seq = 0;
  bool ended = false;
  final Completer<void> _cancelRequested = Completer<void>();
  Completer<List<AmToolResult>> _results = Completer<List<AmToolResult>>();

  /// Batches sent and not yet acked.
  int get outstanding => _outstanding.length;

  /// Events queued natively because no credit is left.
  int get queued => _pending.length;

  /// Batches sent so far.
  int get sentBatches => _seq;

  Future<void> get cancelRequested => _cancelRequested.future;

  /// Completes with the results Dart submits for suspended tool calls.
  Future<List<AmToolResult>> get toolResults => _results.future;

  void text(String t) => _push(AmEvent(kind: AmEventKind.text)..text = t);

  void toolCall(String name, String argumentsJson, {String? id}) => _push(
    AmEvent(kind: AmEventKind.toolCall)
      ..toolName = name
      ..argumentsJson = argumentsJson
      ..callId = id,
  );

  void rejectedToolCall(String reason, {String? toolName, String? preview, String? detail}) => _push(
    AmEvent(kind: AmEventKind.rejectedToolCall)
      ..code = reason
      ..toolName = toolName
      ..text = preview
      ..message = detail,
  );

  /// FM: the model called a tool; Swift's `Tool.call` now waits.
  void toolRequest(String callId, String name, String argumentsJson) => _push(
    AmEvent(kind: AmEventKind.toolRequest)
      ..callId = callId
      ..toolName = name
      ..argumentsJson = argumentsJson,
  );

  void info({
    int prompt = 10,
    int cached = 0,
    int generated = 5,
    int recovered = 0,
    double promptSec = 0.1,
    double genSec = 0.5,
  }) => _push(
    AmEvent(kind: AmEventKind.info)
      ..promptTokens = prompt
      ..cachedPromptTokens = cached
      ..generationTokens = generated
      ..recoveredToolCalls = recovered
      ..promptTimeSec = promptSec
      ..generateTimeSec = genSec,
  );

  void waiting([String reason = 'app_inactive']) => _push(AmEvent(kind: AmEventKind.waiting)..code = reason);

  void notice(String code, String message) => _push(
    AmEvent(kind: AmEventKind.notice)
      ..code = code
      ..message = message,
  );

  void finish([String code = 'stop']) {
    if (ended) return;
    ended = true;
    _push(AmEvent(kind: AmEventKind.finished)..code = code);
  }

  void pause([String reason = 'app_inactive']) {
    if (ended) return;
    ended = true;
    _push(AmEvent(kind: AmEventKind.paused)..code = reason);
  }

  void error(String code, String message) {
    if (ended) return;
    ended = true;
    _push(
      AmEvent(kind: AmEventKind.error)
        ..code = code
        ..message = message,
    );
  }

  void _push(AmEvent e) {
    // Swift coalesces consecutive text while it waits for a credit.
    final last = _pending.isEmpty ? null : _pending.last;
    if (e.kind == AmEventKind.text && last != null && last.kind == AmEventKind.text) {
      last.text = '${last.text ?? ''}${e.text ?? ''}';
    } else {
      _pending.add(e);
    }
    _flush();
  }

  void _flush() {
    if (_pending.isEmpty || _outstanding.length >= _backend.maxOutstanding) return;
    final seq = _seq++;
    _outstanding.add(seq);
    final batch = AmEventBatch(generationId: id, seq: seq, events: List.of(_pending));
    _pending.clear();
    _backend._events.add(batch);
  }

  void _ack(int seq) {
    _outstanding.remove(seq);
    _flush();
  }

  void _toolResults(List<AmToolResult> results) {
    final c = _results;
    _results = Completer<List<AmToolResult>>();
    c.complete(results);
  }
}
