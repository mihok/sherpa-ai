import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sherpa_core/sherpa_core.dart';

import '../engine/engine_host.dart';
import '../engine/engine_types.dart';
import '../ffi/bindings.dart';

const int _mib = 1024 * 1024;

/// Bytes per KV token by type for the fake estimator (Qwen3-0.6B's real
/// numbers, R04 §6).
const Map<KvType, int> kFakeKvBytesPerToken = {
  KvType.f16: 114688,
  KvType.engineDefault: 114688,
  KvType.q8_0: 60928,
  KvType.q4_0: 32256,
};

/// Model info JSON shaped like `se_model_info_json` for a Qwen3-0.6B.
String fakeModelInfoJson({
  String modelId = 'sha256:fake',
  int nParams = 596049920,
  String toolSupport = 'native_grammar',
  bool templateParallel = true,
  bool thinking = true,
  int nCtxTrain = 40960,
  Map<String, String> recommendedSampling = const {},
}) =>
    jsonEncode({
      'model_id': modelId,
      'fingerprint': modelId,
      'arch': 'qwen3',
      'name': 'Fake Qwen3',
      'ftype': 'Q4_K - Medium',
      'n_params': nParams,
      'size_bytes': 390753280,
      'file_bytes': 396705472,
      'n_ctx_train': nCtxTrain,
      'n_layer': 28,
      'n_vocab': 151936,
      'kv_bytes_per_token': {'f16': 114688, 'q8_0': 60928, 'q4_0': 32256},
      'chat_template': {
        'present': true,
        'usable': true,
        'caps': {'supports_system_role': true, 'supports_parallel_tool_calls': templateParallel},
      },
      'tool_calls': {'support': toolSupport, 'parallel': templateParallel, 'grammar_lazy': true},
      'thinking': {'supported': thinking},
      'recommended_sampling': recommendedSampling,
      'mmproj': {'loaded': false},
    });

/// A scripted generation for [FakeEngineHost.generate].
typedef FakeScript = List<EngineEvent> Function(String requestJson);

/// Builds a complete event sequence: deltas, USAGE, PERF, FINISH.
List<EngineEvent> fakeReply(
  String text, {
  int promptTokens = 20,
  int cachedTokens = 0,
  int chunk = 4,
  List<({String id, String name, String args})> toolCalls = const [],
}) {
  final out = <EngineEvent>[];
  for (var i = 0; i < text.length; i += chunk) {
    out.add(EngineEvent.text(text.substring(i, i + chunk > text.length ? text.length : i + chunk)));
  }
  for (final (i, c) in toolCalls.indexed) {
    out
      ..add(EngineEvent(type: EngineEventType.toolCallStart, index: i, id: c.id, name: c.name))
      ..add(EngineEvent(type: EngineEventType.toolCallArgsDelta, index: i, id: c.id, text: c.args))
      ..add(EngineEvent(type: EngineEventType.toolCallDone, index: i, id: c.id, name: c.name, text: c.args));
  }
  out
    ..add(EngineEvent(
        type: EngineEventType.usage,
        promptTokens: promptTokens,
        cachedTokens: cachedTokens,
        completionTokens: (text.length / 4).ceil()))
    ..add(const EngineEvent(type: EngineEventType.perf, ttftMs: 50, prefillTps: 100, decodeTps: 20, name: 'CPU'))
    ..add(EngineEvent(
        type: EngineEventType.finish,
        code: toolCalls.isEmpty ? SeFinish.stop : SeFinish.toolCalls,
        name: toolCalls.isEmpty ? 'stop' : 'tool_calls',
        text: '{"role":"assistant","content":${jsonEncode(text)}}'));
  return out;
}

/// An event sequence that fails with [status] (ERROR + USAGE + PERF +
/// FINISH(error)), as the engine reports template/context/decode errors.
List<EngineEvent> fakeError(int status, String message) => [
      EngineEvent(type: EngineEventType.error, code: status, text: message),
      const EngineEvent(type: EngineEventType.usage),
      const EngineEvent(type: EngineEventType.perf),
      const EngineEvent(type: EngineEventType.finish, code: SeFinish.error, name: 'error'),
    ];

/// In-memory [EngineHost] for tests of everything above the engine
/// boundary: scripted generations (with cancel and pause semantics),
/// a linear memory estimator, fake state files, bench results, and crash
/// simulation. Records every call for assertions.
final class FakeEngineHost implements EngineHost {
  FakeEngineHost({
    this.eventDelay = Duration.zero,
    this.modelInfoJson,
    this.modelBytes = 400 * _mib,
    this.mappedBytes = 380 * _mib,
    this.computeBytes = 30 * _mib,
    this.stateBytesPerToken = 1024,
    BenchResult Function(BenchConfig config)? bench,
  }) : _bench = bench;

  final Duration eventDelay;
  String? modelInfoJson;
  final int modelBytes;
  final int mappedBytes;
  final int computeBytes;
  final int stateBytesPerToken;
  final BenchResult Function(BenchConfig config)? _bench;

  /// Scripts consumed in order by [generate]; when empty, [defaultScript].
  final List<FakeScript> scripts = [];
  FakeScript defaultScript = (_) => fakeReply('ok');

  /// Requests passed to [generate], in order.
  final List<String> requests = [];
  final List<SessionConfig> sessionConfigs = [];
  final List<ModelLoadOptions> loads = [];
  final List<BenchConfig> benches = [];
  final List<String> saved = [];
  final List<String> loaded = [];
  final Set<int> liveSessions = {};
  final Set<int> liveModels = {};
  int estimates = 0;
  int cancels = 0;
  int countBatchCalls = 0;

  /// Thrown by the next [loadState] (e.g. SE_ERR_STATE_MISMATCH).
  EngineException? nextLoadStateError;

  /// Thrown by [createSession] while set (e.g. SE_ERR_CONTEXT_CREATE)...
  EngineException? createSessionError;

  /// ...for this many calls (then cleared); 0 = until cleared by hand.
  int createSessionFailures = 0;

  /// Tokens "in" each session's KV, set by generations and state loads.
  final Map<int, int> sessionTokens = {};

  int _epoch = 0;
  int _next = 1;
  bool _started = false;
  final StreamController<EngineHostEvent> _events = StreamController.broadcast();
  final Map<int, _FakeGen> _gens = {};

  @override
  EngineHostKind get kind => EngineHostKind.fake;

  @override
  int get epoch => _epoch;

  @override
  Stream<EngineHostEvent> get events => _events.stream;

  bool get started => _started;

  void _check(EngineHandle h) {
    if (h.epoch != _epoch) throw StaleHandleException(h);
  }

  /// Simulates the hosting worker/process dying.
  void simulateCrash({bool nativeStateLost = true}) {
    for (final g in _gens.values.toList()) {
      g.fail(const EngineCrashedException('simulated crash'));
    }
    _gens.clear();
    _events.add(EngineHostCrashed(_epoch, 'simulated', nativeStateLost: nativeStateLost));
    if (nativeStateLost) {
      _epoch++;
      liveSessions.clear();
      liveModels.clear();
    }
    _events.add(EngineHostRestarted(_epoch));
  }

  /// Thrown by [start] when set (e.g. `EngineUnavailableException`).
  Object? startError;

  @override
  Future<EngineInfo> start() async {
    final err = startError;
    if (err != null) throw err;
    _started = true;
    return const EngineInfo(abiVersion: 1, version: 'fake 1.0', systemInfoJson: '{}', hostKind: EngineHostKind.fake);
  }

  @override
  Future<String> systemInfoJson() async => '{"cpu":{"performance_cores":4}}';

  @override
  Future<EngineModel> loadModel(ModelLoadOptions options, {CancellationToken? cancel, void Function(double)? onProgress}) async {
    cancel?.throwIfCancelled();
    loads.add(options);
    onProgress?.call(1);
    final id = _next++;
    liveModels.add(id);
    return EngineModel(ref: ModelRef(id, _epoch), infoJson: modelInfoJson ?? fakeModelInfoJson(), options: options);
  }

  @override
  Future<void> freeModel(ModelRef model) async {
    _check(model);
    liveModels.remove(model.id);
  }

  static int _resolvedCtx(int nCtx) => nCtx <= 0 ? 4096 : ((nCtx + 255) ~/ 256) * 256;

  @override
  Future<MemoryEstimate> estimateMemory(ModelLoadOptions model, SessionConfig session) async {
    estimates++;
    final ctx = _resolvedCtx(session.nCtx);
    final perToken = kFakeKvBytesPerToken[session.typeK] ?? 114688;
    final kv = ctx * perToken;
    final total = modelBytes + kv + computeBytes;
    return MemoryEstimate(
      nCtx: ctx,
      nCtxSeq: ctx,
      flashAttention: session.typeV.isQuantized || session.flashAttention == FlashAttention.on,
      modelBytes: modelBytes,
      modelMappedBytes: mappedBytes,
      kvBytes: kv,
      computeBytes: computeBytes,
      outputBytes: 0,
      totalBytes: total,
      kvBytesPerToken: perToken,
      fileBytes: modelBytes,
    );
  }

  String _sessionInfo(SessionConfig c, {int history = 0}) {
    String kv(KvType t) => (t == KvType.engineDefault ? KvType.f16 : t).label;
    final ctx = _resolvedCtx(c.nCtx);
    return jsonEncode({
      'n_ctx': ctx,
      'n_batch': c.nBatch == 0 ? 512 : c.nBatch,
      'n_ubatch': c.nUbatch == 0 ? 512 : c.nUbatch,
      'n_threads': c.nThreads <= 0 ? 4 : c.nThreads,
      'type_k': kv(c.typeK),
      'type_v': kv(c.typeV),
      'flash_attn': c.typeV.isQuantized || c.flashAttention == FlashAttention.on,
      'prompt_cache': 'prefix',
      'history_tokens': history,
      'memory': {'total_bytes': modelBytes + ctx * (kFakeKvBytesPerToken[c.typeK] ?? 114688) + computeBytes},
    });
  }

  @override
  Future<EngineSession> createSession(ModelRef model, SessionConfig config) async {
    _check(model);
    final err = createSessionError;
    if (err != null) {
      if (createSessionFailures > 0 && --createSessionFailures == 0) createSessionError = null;
      throw err;
    }
    sessionConfigs.add(config);
    final id = _next++;
    liveSessions.add(id);
    return EngineSession(ref: SessionRef(id, _epoch), model: model, config: config, infoJson: _sessionInfo(config));
  }

  @override
  Future<void> freeSession(SessionRef session) async {
    _check(session);
    _gens.remove(session.id)?.fail(const EngineException(SeStatus.invalidArg, 'session was freed during generation'));
    liveSessions.remove(session.id);
    sessionTokens.remove(session.id);
  }

  @override
  Future<void> resetSession(SessionRef session) async {
    _check(session);
    sessionTokens[session.id] = 0;
  }

  @override
  Future<void> setThreads(SessionRef session, int nThreads, int nThreadsBatch) async => _check(session);

  @override
  Future<String> sessionInfoJson(SessionRef session) async {
    _check(session);
    return _sessionInfo(const SessionConfig(), history: sessionTokens[session.id] ?? 0);
  }

  @override
  Future<MemoryEstimate> sessionMemory(SessionRef session) => estimateMemory(const ModelLoadOptions(path: ''), const SessionConfig());

  /// Whether a generation is running on [session].
  bool isGenerating(SessionRef session) => _gens.containsKey(session.id);

  @override
  Stream<EngineEvent> generate(SessionRef session, String requestJson) {
    late final _FakeGen gen;
    // Closed by _FakeGen when the script ends or fails.
    // ignore: close_sinks
    final controller = StreamController<EngineEvent>();
    gen = _FakeGen(controller);
    controller
      ..onListen = () {
        if (session.epoch != _epoch) {
          gen.fail(StaleHandleException(session));
          return;
        }
        final running = _gens[session.id];
        if (running != null && !running.cancelled) {
          gen.fail(const EngineException(SeStatus.busy, 'a generation is already running on this session'));
          return;
        }
        // Like the real pump: a start queues behind a generation that is
        // still draining after a cancel.
        unawaited((running?.finished ?? Future<void>.value()).then((_) {
          if (gen.consumerGone) {
            unawaited(gen.close());
            return;
          }
          requests.add(requestJson);
          final script = scripts.isEmpty ? defaultScript : scripts.removeAt(0);
          _gens[session.id] = gen;
          unawaited(_play(session, gen, script(requestJson)));
        }));
      }
      ..onPause = gen.pause
      ..onResume = gen.resume
      ..onCancel = () {
        gen.cancelled = true;
        gen.consumerGone = true;
      };
    return controller.stream;
  }

  Future<void> _play(SessionRef session, _FakeGen gen, List<EngineEvent> events) async {
    try {
      for (final e in events) {
        await gen.waitResumed();
        if (gen.consumerGone || gen.failed) break;
        if (gen.cancelled && e.type != EngineEventType.finish) {
          gen
            ..add(const EngineEvent(type: EngineEventType.usage))
            ..add(const EngineEvent(type: EngineEventType.perf))
            ..add(const EngineEvent(type: EngineEventType.finish, code: SeFinish.cancelled, name: 'cancelled'));
          break;
        }
        if (eventDelay > Duration.zero) {
          await Future<void>.delayed(eventDelay);
        } else {
          await Future<void>.value();
        }
        if (gen.consumerGone || gen.failed) break;
        if (e.type == EngineEventType.usage) {
          sessionTokens[session.id] = e.promptTokens + e.completionTokens;
        }
        gen.add(e);
      }
    } finally {
      if (identical(_gens[session.id], gen)) _gens.remove(session.id);
      await gen.close();
      gen.done.complete();
    }
  }

  @override
  Future<void> cancelGeneration(SessionRef session) async {
    cancels++;
    _gens[session.id]?.cancelled = true;
  }

  @override
  Future<List<int>> tokenize(ModelRef model, String text, {bool addSpecial = false, bool parseSpecial = false}) async =>
      [for (var i = 0; i < fakeTokenCount(text); i++) i];

  @override
  Future<String> detokenize(ModelRef model, List<int> tokens, {bool renderSpecial = false}) async => 'x' * tokens.length;

  /// The fake tokenizer: one token per 4 UTF-16 units, rounded up.
  static int fakeTokenCount(String text) => (text.length / 4).ceil();

  /// The fake template: 5 scaffold tokens per message + content tokens, +3
  /// for the generation prompt, + the tools JSON.
  static int fakeChatCount(String requestJson) {
    final j = (jsonDecode(requestJson) as Map).cast<String, Object?>();
    var n = 0;
    for (final m in (j['messages']! as List).cast<Map<Object?, Object?>>()) {
      n += 5 + fakeTokenCount('${m['content'] ?? ''}');
      if (m['tool_calls'] != null) n += fakeTokenCount(jsonEncode(m['tool_calls']));
    }
    if (j['tools'] != null) n += fakeTokenCount(jsonEncode(j['tools']));
    if (j['add_generation_prompt'] != false) n += 3;
    return n;
  }

  @override
  Future<int> countChatTokens(ModelRef model, String requestJson) async {
    _check(model);
    return fakeChatCount(requestJson);
  }

  @override
  Future<List<int>> countBatch(ModelRef model, {List<String> texts = const [], List<String> chatRequests = const []}) async {
    _check(model);
    countBatchCalls++;
    return [for (final t in texts) fakeTokenCount(t), for (final c in chatRequests) fakeChatCount(c)];
  }

  @override
  Future<int> saveState(SessionRef session, String path) async {
    _check(session);
    if (_gens.containsKey(session.id)) throw const EngineException(SeStatus.busy, 'busy');
    final tokens = sessionTokens[session.id] ?? 0;
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode({'tokens': tokens, 'pad': 'x' * (tokens * stateBytesPerToken ~/ 1)}));
    saved.add(path);
    return f.length();
  }

  @override
  Future<int> loadState(SessionRef session, String path) async {
    _check(session);
    final err = nextLoadStateError;
    if (err != null) {
      nextLoadStateError = null;
      throw err;
    }
    final f = File(path);
    if (!await f.exists()) throw const EngineException(SeStatus.io, 'missing');
    final j = (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>();
    final n = (j['tokens']! as num).toInt();
    sessionTokens[session.id] = n;
    loaded.add(path);
    return n;
  }

  @override
  Future<LoraRef> loadLora(ModelRef model, String path) async => LoraRef(_next++, _epoch);

  @override
  Future<void> freeLora(LoraRef lora) async {}

  @override
  Future<void> setLoras(SessionRef session, List<(LoraRef, double)> loras) async {}

  @override
  Future<BenchResult> bench(ModelRef model, BenchConfig config, {CancellationToken? cancel}) async {
    _check(model);
    cancel?.throwIfCancelled();
    benches.add(config);
    final f = _bench;
    if (f != null) return f(config);
    return BenchResult(
      nPrompt: config.nPrompt,
      nGen: config.nGen,
      nThreads: config.nThreads,
      promptTokensPerSec: 50.0 * config.nThreads,
      genTokensPerSec: 10.0 * config.nThreads,
      promptMs: 0,
      genMs: 0,
    );
  }

  @override
  SyncTokenizer? syncTokenizer(ModelRef model) => _FakeSyncTokenizer();

  @override
  Future<void> dispose() async {
    await _events.close();
  }
}

final class _FakeSyncTokenizer implements SyncTokenizer {
  @override
  int countChat(String requestJson) => FakeEngineHost.fakeChatCount(requestJson);

  @override
  int countText(String text) => FakeEngineHost.fakeTokenCount(text);
}

final class _FakeGen {
  _FakeGen(this.controller);

  final StreamController<EngineEvent> controller;
  final Completer<void> done = Completer<void>();
  bool cancelled = false;
  bool consumerGone = false;
  bool failed = false;
  Completer<void>? _resumed;

  void pause() => _resumed ??= Completer<void>();

  void resume() {
    final r = _resumed;
    _resumed = null;
    r?.complete();
  }

  Future<void> waitResumed() async {
    while (_resumed != null) {
      await _resumed!.future;
    }
  }

  void add(EngineEvent e) {
    if (!controller.isClosed) controller.add(e);
  }

  void fail(Object error) {
    if (failed || controller.isClosed) return;
    failed = true;
    controller.addError(error);
    unawaited(controller.close());
  }

  /// Completes when playback ended (FINISH, cancel drain or failure).
  Future<void> get finished => done.future;

  Future<void> close() async {
    if (!controller.isClosed) await controller.close();
  }
}
