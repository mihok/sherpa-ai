import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:sherpa_inference/src/ffi/bindings.dart';
import 'package:sherpa_inference/testing.dart';

/// Emulates SherpaInferencePlugin + InferenceService at the message level:
/// connection lifecycle, a tiny engine (handles, sessions), generations with
/// the service's credit-based flow control, and process deaths with exit
/// records. Messages are delivered in order on microtasks, like the event
/// channel.
final class FakeInferenceService implements InferenceTransport {
  final StreamController<InferenceMessage> _out = StreamController<InferenceMessage>();

  /// Every call shipped, in order (fire-and-forget ones included).
  final List<EngineCall> sent = [];
  final List<(int, bool)> busyCalls = [];
  final List<int> disconnects = [];
  final List<BindPolicy> connects = [];

  int _connections = 0;
  int? live;
  int pid = 4000;
  bool bindFails = false;
  bool connectThrowsMissingPlugin = false;

  /// StartCalls that make the process die instead of answering.
  int crashOnStart = 0;

  /// Reply for StartCall: null = success, else a CallError code.
  int? startError;

  /// Events per batch (1 makes credit accounting easy to observe).
  int eventsPerBatch = 1;

  /// Builds a generation's events; `generationId` is filled in.
  List<EngineEventMsg> Function(String requestJson) script = (_) => reply(['Hel', 'lo', ' world']);

  /// The next N replies are held until [releaseHeld].
  int holdReplies = 0;
  final List<InferenceMessage> _held = [];

  int _ids = 0;
  final Set<int> models = {};
  final Map<int, int> sessions = {}; // session -> model
  final Set<int> loras = {};
  final Map<int, FakeGen> gens = {};
  int _generation = 0;

  /// Largest number of batches a stream ever had sent but not credited.
  int maxOutstanding = 0;

  @override
  Stream<InferenceMessage> get messages => _out.stream;

  void emit(InferenceMessage m) => scheduleMicrotask(() {
        if (!_out.isClosed) _out.add(m);
      });

  @override
  Future<int> connect(BindPolicy policy) async {
    if (connectThrowsMissingPlugin) throw MissingPluginException('no plugin');
    connects.add(policy);
    final id = ++_connections;
    if (bindFails) {
      emit(HostStatus(kind: HostStatusKind.bindFailed, connection: id, detail: 'bindService returned false'));
    } else {
      live = id;
      pid++;
      emit(HostStatus(kind: HostStatusKind.connected, connection: id, pid: pid));
    }
    return id;
  }

  @override
  Future<void> disconnect(int connection) async {
    disconnects.add(connection);
    if (live == connection) {
      live = null;
      _resetEngine();
    }
  }

  @override
  Future<void> setBusy(int connection, bool busy) async => busyCalls.add((connection, busy));

  void _resetEngine() {
    models.clear();
    sessions.clear();
    loras.clear();
    gens.clear();
  }

  void _reply(InferenceMessage m) {
    if (holdReplies > 0) {
      holdReplies--;
      _held.add(m);
    } else {
      emit(m);
    }
  }

  void releaseHeld() {
    for (final m in _held) {
      emit(m);
    }
    _held.clear();
  }

  void _ok(int id, [Object? value]) {
    if (id != 0) _reply(CallResult(requestId: id, value: value));
  }

  void _err(int id, int code, String message) {
    if (id != 0) _reply(CallError(requestId: id, code: code, message: message));
  }

  int _handle() => (7 << 32) | ++_ids;

  @override
  Future<void> send(int connection, int requestId, EngineCall call) async {
    if (connection != live) throw PlatformException(code: 'not_connected', message: 'the inference service is not connected');
    sent.add(call);
    switch (call) {
      case StartCall():
        if (crashOnStart > 0) {
          crashOnStart--;
          crash(classification: 'nativeCrash', status: 4, transportDetail: 'died starting');
          return;
        }
        final e = startError;
        if (e != null) return _err(requestId, e, 'dlopen(libsherpa_engine.so) failed: not found');
        _ok(requestId, EngineInfoMsg(abiVersion: 1, version: 'sherpa_engine fake', systemInfoJson: '{}', pid: pid));
      case SystemInfoCall():
        _ok(requestId, '{"backends":["CPU"]}');
      case LoadModelCall(:final options, :final progress):
        if (progress) {
          for (final p in [0.0, 0.5, 1.0]) {
            emit(LoadProgress(requestId: requestId, progress: p));
          }
        }
        if (options.path.endsWith('missing.gguf')) return _err(requestId, SeStatus.io, 'no such file');
        final h = _handle();
        models.add(h);
        _ok(requestId, HandleInfoMsg(handle: h, infoJson: fakeModelInfoJson()));
      case FreeModelCall(:final model):
        models.remove(model) ? _ok(requestId) : _err(requestId, SeStatus.invalidArg, 'unknown model');
      case EstimateMemoryCall(:final session):
        final n = session.nCtx == 0 ? 4096 : session.nCtx;
        _ok(requestId, MemoryEstimateMsg(nCtx: n, nCtxSeq: n, flashAttention: false, modelBytes: 400 << 20,
            modelMappedBytes: 380 << 20, kvBytes: n * 114688, computeBytes: 30 << 20, outputBytes: 1 << 20,
            totalBytes: (431 << 20) + n * 114688, kvBytesPerToken: 114688, fileBytes: 396705472));
      case CreateSessionCall(:final model, :final config):
        if (!models.contains(model)) return _err(requestId, SeStatus.invalidArg, 'unknown or freed model handle');
        final h = _handle();
        sessions[h] = model;
        final n = config.nCtx == 0 ? 4096 : config.nCtx;
        _ok(requestId, HandleInfoMsg(handle: h, infoJson: jsonEncode({'n_ctx': n, 'type_k': 'f16', 'type_v': 'f16', 'flash_attn': false})));
      case FreeSessionCall(:final session):
        gens.removeWhere((_, g) => g.session == session);
        sessions.remove(session) != null ? _ok(requestId) : _err(requestId, SeStatus.invalidArg, 'unknown session');
      case ResetSessionCall(:final session) || SetThreadsCall(:final session) || LoadStateCall(:final session) ||
            SaveStateCall(:final session) || SetLorasCall(:final session):
        if (!sessions.containsKey(session)) return _err(requestId, SeStatus.invalidArg, 'unknown session');
        if (gens.values.any((g) => g.session == session)) return _err(requestId, SeStatus.busy, 'a generation is running');
        _ok(requestId, call is SaveStateCall ? 1234 : call is LoadStateCall ? 42 : null);
      case SessionInfoCall(:final session):
        _ok(requestId, '{"n_ctx":4096,"busy":${gens.values.any((g) => g.session == session)}}');
      case SessionMemoryCall():
        _ok(requestId, MemoryEstimateMsg(nCtx: 4096, nCtxSeq: 4096, flashAttention: false, modelBytes: 1,
            modelMappedBytes: 1, kvBytes: 2, computeBytes: 3, outputBytes: 4, totalBytes: 10, kvBytesPerToken: 5, fileBytes: 6));
      case GenerateCall(:final streamId, :final session, :final requestJson):
        if (!sessions.containsKey(session)) {
          return emit(StreamFailed(streamId: streamId, code: SeStatus.invalidArg, message: 'unknown session'));
        }
        if (gens.values.any((g) => g.session == session) || requestJson == 'busy') {
          return emit(StreamFailed(streamId: streamId, code: SeStatus.busy, message: 'a generation is running'));
        }
        final g = FakeGen(streamId, session, ++_generation, script(requestJson));
        gens[streamId] = g;
        emit(StreamStarted(streamId: streamId, generationId: g.generationId));
        _pump(g);
      case CreditCall(:final streamId, :final n):
        final g = gens[streamId];
        if (g == null) return;
        g.credits += n;
        g.credited += n;
        _pump(g);
      case CancelStreamCall(:final streamId):
        gens.remove(streamId);
      case CancelSessionCall(:final session):
        for (final g in gens.values.where((g) => g.session == session)) {
          g.cancel();
          _pump(g);
        }
      case CancelCall():
        break;
      case TokenizeCall(:final text):
        _ok(requestId, Int32List.fromList(List.generate(text.length, (i) => i)));
      case DetokenizeCall(:final tokens):
        _ok(requestId, 'x' * tokens.length);
      case CountChatCall(:final requestJson):
        _ok(requestId, requestJson.length);
      case CountBatchCall(:final texts, :final chatRequests):
        _ok(requestId, Int32List.fromList([for (final t in texts) t.length, for (final c in chatRequests) c.length]));
      case LoadLoraCall():
        final h = _handle();
        loras.add(h);
        _ok(requestId, h);
      case FreeLoraCall(:final lora):
        loras.remove(lora);
        _ok(requestId);
      case BenchCall(:final config):
        _ok(requestId, BenchResultMsg(nPrompt: config.nPrompt, nGen: config.nGen, nThreads: config.nThreads,
            promptTokensPerSec: 100, genTokensPerSec: 20, promptMs: 1, genMs: 2));
      case ShutdownCall():
        _resetEngine();
        _ok(requestId);
      case DebugCrashCall():
        crash(classification: 'nativeCrash', status: 6);
    }
  }

  void _pump(FakeGen g) {
    while (g.credits > 0 && g.remaining.isNotEmpty && gens[g.streamId] == g) {
      final n = eventsPerBatch.clamp(1, g.remaining.length);
      final batch = g.remaining.sublist(0, n);
      g.remaining.removeRange(0, n);
      g.credits--;
      g.sent++;
      final last = g.remaining.isEmpty;
      if (last) gens.remove(g.streamId);
      final outstanding = g.sent - g.credited;
      if (outstanding > maxOutstanding) maxOutstanding = outstanding;
      emit(EventBatch(streamId: g.streamId, events: [for (final e in batch) e.withGeneration(g.generationId)], last: last));
    }
  }

  /// The process dies: `disconnected` now, the exit record after [exitDelay]
  /// (null [classification] = no record found).
  void crash({
    String? classification = 'nativeCrash',
    int reason = 5,
    int status = 6,
    String? summary,
    String? tombstone,
    String transportDetail = 'the inference process died',
    Duration exitDelay = Duration.zero,
  }) {
    final c = live;
    if (c == null) return;
    live = null;
    _resetEngine();
    final deadPid = pid;
    emit(HostStatus(kind: HostStatusKind.disconnected, connection: c, pid: deadPid, detail: transportDetail));
    void exitInfo() => emit(HostStatus(
          kind: HostStatusKind.exitInfo,
          connection: c,
          pid: deadPid,
          exit: classification == null
              ? null
              : ProcessExitMsg(
                  pid: deadPid,
                  reason: reason,
                  reasonName: reason == 5 ? 'CRASH_NATIVE' : 'OTHER',
                  classification: classification,
                  status: status,
                  timestampMs: 1700000000000,
                  processStateSummary: summary == null ? null : Uint8List.fromList(utf8.encode(summary)),
                  tombstone: tombstone,
                ),
        ));
    if (exitDelay == Duration.zero) {
      exitInfo();
    } else {
      Timer(exitDelay, exitInfo);
    }
  }

  /// Never waits for a done event nobody listens to.
  Future<void> close() async {
    if (_out.hasListener) {
      await _out.close();
    } else {
      unawaited(_out.close());
    }
  }

  // -------------------------------------------------------------------------

  static EngineEventMsg ev(int type, {String text = '', int code = 0, String name = '', int completion = 0, double decodeMs = 0}) =>
      EngineEventMsg(type: type, generationId: 0, index: -1, code: code, text: text, id: '', name: name,
          promptTokens: 20, cachedTokens: 0, completionTokens: completion, nDrafted: 0, nAccepted: 0, progressDone: 0,
          progressTotal: 0, ttftMs: 5, prefillTps: 100, decodeTps: 20, draftAcceptRate: 0, prefillMs: 1, decodeMs: decodeMs);

  static List<EngineEventMsg> reply(List<String> deltas, {String finish = 'stop'}) => [
        for (final d in deltas) ev(SeEventType.textDelta, text: d),
        ev(SeEventType.usage, completion: deltas.length),
        ev(SeEventType.perf, name: 'CPU'),
        ev(SeEventType.finish, code: finish == 'cancelled' ? SeFinish.cancelled : SeFinish.stop, name: finish),
      ];
}

final class FakeGen {
  FakeGen(this.streamId, this.session, this.generationId, this.remaining);

  final int streamId;
  final int session;
  final int generationId;
  List<EngineEventMsg> remaining;
  int credits = 4;
  int sent = 0;
  int credited = 0;

  void cancel() {
    remaining = FakeInferenceService.reply(const [], finish: 'cancelled').sublist(0)..removeWhere((e) => e.type == SeEventType.textDelta);
  }
}

extension on EngineEventMsg {
  EngineEventMsg withGeneration(int g) => EngineEventMsg(type: type, generationId: g, index: index, code: code, text: text,
      id: id, name: name, promptTokens: promptTokens, cachedTokens: cachedTokens, completionTokens: completionTokens,
      nDrafted: nDrafted, nAccepted: nAccepted, progressDone: progressDone, progressTotal: progressTotal, ttftMs: ttftMs,
      prefillTps: prefillTps, decodeTps: decodeTps, draftAcceptRate: draftAcceptRate, prefillMs: prefillMs, decodeMs: decodeMs);
}
