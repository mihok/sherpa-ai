import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../ffi/bindings.dart';
import '../ffi/library_loader.dart';
import 'engine_host.dart';
import 'engine_types.dart';
import 'ffi_isolates.dart';

/// [EngineHost] over Dart FFI into the engine in this process.
///
/// The UI isolate never calls FFI: blocking calls go to a long-lived worker
/// isolate and generation events are pumped by a second one (see
/// ffi_isolates.dart for why there are two). This class is the message
/// broker between them and the caller.
///
/// Crash semantics: if either background isolate dies (an unexpected Dart
/// error there), all in-flight calls and streams fail with
/// [EngineCrashedException], [events] reports [EngineHostCrashed] with
/// `nativeStateLost: false`, both isolates are respawned, sessions that may
/// still be generating are cancelled and drained, and
/// [EngineHostRestarted] follows. Native handles stay valid (the process
/// survived), so [epoch] does not change. A native crash (SIGSEGV, a
/// GGML_ABORT) ends the process; it is reported on the next start through
/// the crash breadcrumb passed to [start].
final class FfiEngineHost implements EngineHost {
  /// [libraryPath]: explicit library (else [EngineLibrary.defaultLocator]).
  /// [crashBreadcrumbPath]: `se_init_params.crash_breadcrumb_path`.
  FfiEngineHost({String? libraryPath, this.crashBreadcrumbPath, this.backendDir}) : _libraryPath = libraryPath;

  final String? _libraryPath;
  final String? crashBreadcrumbPath;
  final String? backendDir;

  @override
  EngineHostKind get kind => EngineHostKind.inProcessFfi;

  @override
  int get epoch => 0;

  final StreamController<EngineHostEvent> _events = StreamController.broadcast();

  @override
  Stream<EngineHostEvent> get events => _events.stream;

  Future<EngineInfo>? _starting;
  EngineInfo? _info;
  bool _disposed = false;

  // worker
  Isolate? _worker;
  SendPort? _workerPort;
  ReceivePort? _workerRx;
  ReceivePort? _workerExit;
  final Map<int, Completer<Object?>> _calls = {};
  final Map<int, void Function(double)> _progress = {};

  // pump
  Isolate? _pump;
  SendPort? _pumpPort;
  ReceivePort? _pumpRx;
  ReceivePort? _pumpExit;
  final Map<int, Completer<int>> _pumpAcks = {};
  final Map<int, _StreamState> _streams = {};

  int _nextId = 1;

  String get _resolvedLibraryPath => _libraryPath ?? EngineLibrary.defaultLocator();

  @override
  Future<EngineInfo> start() {
    if (_disposed) return Future.error(StateError('FfiEngineHost was disposed'));
    final info = _info;
    if (info != null) return Future.value(info);
    return _starting ??= _startOnce().whenComplete(() => _starting = null);
  }

  Future<EngineInfo> _startOnce() async {
    await _spawnWorker();
    await _spawnPump();
    final r = (await _call('init', [crashBreadcrumbPath, backendDir]))! as List<Object?>;
    return _info = EngineInfo(
      abiVersion: r[0]! as int,
      version: r[1]! as String,
      systemInfoJson: r[2]! as String,
      hostKind: kind,
      libraryLocator: _resolvedLibraryPath,
    );
  }

  Future<void> _spawnWorker() async {
    final rx = ReceivePort();
    final exit = ReceivePort();
    final ready = Completer<SendPort>();
    rx.listen((Object? msg) {
      switch (msg) {
        case SendPort():
          if (!ready.isCompleted) ready.complete(msg);
        case WorkerReply(id: -1, :final errorMessage):
          if (!ready.isCompleted) ready.completeError(EngineUnavailableException(errorMessage ?? 'engine unavailable'));
        case WorkerReply():
          final c = _calls.remove(msg.id);
          _progress.remove(msg.id);
          if (c == null) return;
          if (msg.errorCode != null) {
            c.completeError(EngineException(msg.errorCode!, msg.errorMessage ?? ''));
          } else {
            c.complete(msg.result);
          }
        case WorkerProgress(:final id, :final progress):
          _progress[id]?.call(progress);
      }
    });
    _workerRx = rx;
    _workerExit = exit;
    _worker = await Isolate.spawn(engineWorkerMain, [rx.sendPort, _resolvedLibraryPath],
        debugName: 'sherpa-engine-worker', onExit: exit.sendPort, errorsAreFatal: true);
    exit.listen((_) => _onIsolateDeath('engine worker isolate exited'));
    try {
      _workerPort = await ready.future;
    } on Object {
      _killAll();
      rethrow;
    }
  }

  Future<void> _spawnPump() async {
    final rx = ReceivePort();
    final exit = ReceivePort();
    final ready = Completer<SendPort>();
    rx.listen((Object? msg) {
      switch (msg) {
        case PumpReady(:final port):
          if (!ready.isCompleted) ready.complete(port);
        case PumpStartFailed(streamId: -1, :final message):
          if (!ready.isCompleted) ready.completeError(EngineUnavailableException(message));
        case PumpAck(:final requestId, :final value):
          _pumpAcks.remove(requestId)?.complete(value);
        case PumpStarted(:final streamId, :final generationId):
          _streams[streamId]?.generationId = generationId;
        case PumpStartFailed(:final streamId, :final code, :final message):
          _streams.remove(streamId)?.fail(EngineException(code, message));
        case PumpBatch(:final streamId, :final events, :final last):
          final s = _streams[streamId];
          if (s == null) return;
          s.deliver(events, last: last);
          if (last) _streams.remove(streamId);
        case PumpSessionIdle():
          break;
      }
    });
    _pumpRx = rx;
    _pumpExit = exit;
    _pump = await Isolate.spawn(enginePumpMain, [rx.sendPort, _resolvedLibraryPath],
        debugName: 'sherpa-engine-pump', onExit: exit.sendPort, errorsAreFatal: true);
    exit.listen((_) => _onIsolateDeath('engine event pump isolate exited'));
    try {
      _pumpPort = await ready.future;
    } on Object {
      _killAll();
      rethrow;
    }
  }

  void _killAll() {
    _worker?.kill(priority: Isolate.immediate);
    _pump?.kill(priority: Isolate.immediate);
    _closePorts();
  }

  void _closePorts() {
    _workerRx?.close();
    _workerExit?.close();
    _pumpRx?.close();
    _pumpExit?.close();
    _workerRx = _workerExit = _pumpRx = _pumpExit = null;
    _worker = _pump = null;
    _workerPort = _pumpPort = null;
  }

  bool _recovering = false;

  Future<void> _onIsolateDeath(String reason) async {
    if (_disposed || _recovering) return;
    _recovering = true;
    try {
      final crash = EngineCrashedException(reason);
      final calls = Map.of(_calls);
      _calls.clear();
      _progress.clear();
      for (final c in calls.values) {
        c.completeError(crash);
      }
      final acks = Map.of(_pumpAcks);
      _pumpAcks.clear();
      for (final c in acks.values) {
        c.completeError(crash);
      }
      final streams = Map.of(_streams);
      _streams.clear();
      final sessions = <int>{for (final s in streams.values) s.session};
      for (final s in streams.values) {
        s.fail(crash);
      }
      _events.add(EngineHostCrashed(epoch, reason, nativeStateLost: false));
      _worker?.kill(priority: Isolate.immediate);
      _pump?.kill(priority: Isolate.immediate);
      _closePorts();
      _info = null;
      if (_disposed) return;
      try {
        await (_starting ??= _startOnce().whenComplete(() => _starting = null));
        if (sessions.isNotEmpty) _pumpPort?.send(PumpRecover(sessions.toList()));
        _events.add(EngineHostRestarted(epoch));
      } on Object catch (e) {
        _events.add(EngineHostCrashed(epoch, 'restart failed: $e', nativeStateLost: false));
      }
    } finally {
      _recovering = false;
    }
  }

  /// Test hook: kills the worker isolate as an unexpected crash would.
  void debugKillWorker() => _worker?.kill(priority: Isolate.immediate);

  Future<Object?> _call(String op, List<Object?> args, {void Function(double)? onProgress}) {
    final port = _workerPort;
    if (port == null) return Future.error(const EngineCrashedException('engine worker is not running'));
    final id = _nextId++;
    final c = Completer<Object?>();
    _calls[id] = c;
    if (onProgress != null) _progress[id] = onProgress;
    port.send(WorkerRequest(id, op, args));
    return c.future;
  }

  Future<int> _pumpRequest(PumpCommand Function(int id) build) {
    final port = _pumpPort;
    if (port == null) return Future.error(const EngineCrashedException('engine pump is not running'));
    final id = _nextId++;
    final c = Completer<int>();
    _pumpAcks[id] = c;
    port.send(build(id));
    return c.future;
  }

  Future<void> _ready() async {
    if (_info == null) await start();
  }

  void _checkEpoch(EngineHandle h) {
    if (h.epoch != epoch) throw StaleHandleException(h);
  }

  /// Runs [body] with an engine canceller wired to [cancel]. The canceller
  /// is created, cancelled and freed by the pump isolate (all from this
  /// isolate's single message stream, so a cancel can never reach a freed
  /// token), while the worker blocks inside the call that uses it.
  Future<T> _withCanceller<T>(CancellationToken? cancel, Future<T> Function(int canceller) body) async {
    if (cancel == null) return body(0);
    cancel.throwIfCancelled();
    final addr = await _pumpRequest(PumpCreateCanceller.new);
    unawaited(cancel.whenCancelled.then((_) => _pumpPort?.send(PumpCancelCanceller(addr))));
    try {
      return await body(addr);
    } finally {
      _pumpPort?.send(PumpFreeCanceller(addr));
    }
  }

  // ---------------------------------------------------------------------------
  // EngineHost

  @override
  Future<String> systemInfoJson() async {
    await _ready();
    return (await _call('systemInfo', const []))! as String;
  }

  @override
  Future<EngineModel> loadModel(
    ModelLoadOptions options, {
    CancellationToken? cancel,
    void Function(double progress)? onProgress,
  }) async {
    await _ready();
    final r = await _withCanceller(cancel, (canceller) async {
      return (await _call('loadModel', [options, canceller, onProgress != null], onProgress: onProgress))!
          as List<Object?>;
    });
    return EngineModel(ref: ModelRef(r[0]! as int, epoch), infoJson: r[1]! as String, options: options);
  }

  @override
  Future<void> freeModel(ModelRef model) async {
    _checkEpoch(model);
    await _call('freeModel', [model.id]);
  }

  @override
  Future<MemoryEstimate> estimateMemory(ModelLoadOptions model, SessionConfig session) async {
    await _ready();
    return (await _call('estimate', [model, session]))! as MemoryEstimate;
  }

  @override
  Future<EngineSession> createSession(ModelRef model, SessionConfig config) async {
    _checkEpoch(model);
    final r = (await _call('createSession', [model.id, config]))! as List<Object?>;
    return EngineSession(ref: SessionRef(r[0]! as int, epoch), model: model, config: config, infoJson: r[1]! as String);
  }

  @override
  Future<void> freeSession(SessionRef session) async {
    _checkEpoch(session);
    // The pump must stop polling the session before the worker frees it.
    await _pumpRequest((id) => PumpRelease(id, session.id));
    for (final e in _streams.entries.where((e) => e.value.session == session.id).toList()) {
      _streams.remove(e.key);
      e.value.fail(const EngineException(SeStatus.invalidArg, 'session was freed during generation'));
    }
    await _call('freeSession', [session.id]);
  }

  @override
  Future<void> resetSession(SessionRef session) async {
    _checkEpoch(session);
    await _call('resetSession', [session.id]);
  }

  @override
  Future<void> setThreads(SessionRef session, int nThreads, int nThreadsBatch) async {
    _checkEpoch(session);
    await _call('setThreads', [session.id, nThreads, nThreadsBatch]);
  }

  @override
  Future<String> sessionInfoJson(SessionRef session) async {
    _checkEpoch(session);
    return (await _call('sessionInfo', [session.id]))! as String;
  }

  @override
  Future<MemoryEstimate> sessionMemory(SessionRef session) async {
    _checkEpoch(session);
    return (await _call('sessionMemory', [session.id]))! as MemoryEstimate;
  }

  @override
  Stream<EngineEvent> generate(SessionRef session, String requestJson) {
    late final _StreamState state;
    // Closed by _StreamState on FINISH, failure or cancel.
    // ignore: close_sinks
    final controller = StreamController<EngineEvent>();
    state = _StreamState(session.id, controller, (n) {
      final port = _pumpPort;
      if (port != null) port.send(PumpCredit(state.streamId, n));
    });
    controller
      ..onListen = () {
        if (session.epoch != epoch) {
          state.fail(StaleHandleException(session));
          return;
        }
        final port = _pumpPort;
        if (port == null) {
          state.fail(const EngineCrashedException('engine pump is not running'));
          return;
        }
        state.streamId = _nextId++;
        _streams[state.streamId] = state;
        port.send(PumpStart(state.streamId, session.id, requestJson));
      }
      ..onResume = state.onResume
      ..onCancel = () {
        if (!state.done) {
          state.done = true;
          _streams.remove(state.streamId);
          _pumpPort?.send(PumpCancelStream(state.streamId));
        }
      };
    return controller.stream;
  }

  @override
  Future<void> cancelGeneration(SessionRef session) async {
    _checkEpoch(session);
    _pumpPort?.send(PumpCancelSession(session.id));
  }

  @override
  Future<List<int>> tokenize(ModelRef model, String text, {bool addSpecial = false, bool parseSpecial = false}) async {
    _checkEpoch(model);
    return ((await _call('tokenize', [model.id, text, addSpecial, parseSpecial]))! as List<Object?>).cast<int>();
  }

  @override
  Future<String> detokenize(ModelRef model, List<int> tokens, {bool renderSpecial = false}) async {
    _checkEpoch(model);
    return (await _call('detokenize', [model.id, tokens, renderSpecial]))! as String;
  }

  @override
  Future<int> countChatTokens(ModelRef model, String requestJson) async {
    _checkEpoch(model);
    return (await _call('countChat', [model.id, requestJson]))! as int;
  }

  @override
  Future<List<int>> countBatch(ModelRef model, {List<String> texts = const [], List<String> chatRequests = const []}) async {
    _checkEpoch(model);
    return ((await _call('countBatch', [model.id, texts, chatRequests]))! as List<Object?>).cast<int>();
  }

  @override
  Future<int> saveState(SessionRef session, String path) async {
    _checkEpoch(session);
    await _call('stateSave', [session.id, path]);
    return File(path).length();
  }

  @override
  Future<int> loadState(SessionRef session, String path) async {
    _checkEpoch(session);
    return (await _call('stateLoad', [session.id, path]))! as int;
  }

  @override
  Future<LoraRef> loadLora(ModelRef model, String path) async {
    _checkEpoch(model);
    return LoraRef((await _call('loraLoad', [model.id, path]))! as int, epoch);
  }

  @override
  Future<void> freeLora(LoraRef lora) async {
    _checkEpoch(lora);
    await _call('loraFree', [lora.id]);
  }

  @override
  Future<void> setLoras(SessionRef session, List<(LoraRef, double)> loras) async {
    _checkEpoch(session);
    await _call('setLoras', [
      session.id,
      [for (final l in loras) l.$1.id],
      [for (final l in loras) l.$2],
    ]);
  }

  @override
  Future<BenchResult> bench(ModelRef model, BenchConfig config, {CancellationToken? cancel}) async {
    _checkEpoch(model);
    return _withCanceller(cancel, (c) async => (await _call('bench', [model.id, config, c]))! as BenchResult);
  }

  @override
  SyncTokenizer? syncTokenizer(ModelRef model) => _FfiSyncTokenizer(_resolvedLibraryPath, model.id);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final s in _streams.values.toList()) {
      s.fail(const EngineCrashedException('engine host disposed'));
    }
    _streams.clear();
    try {
      if (_pumpPort != null) {
        await _pumpRequest(PumpShutdown.new).timeout(const Duration(seconds: 2));
      }
      if (_workerPort != null) await _call('shutdown', const []).timeout(const Duration(seconds: 2));
    } on Object {
      // Best effort: the isolates are killed below either way.
    }
    _killAll();
    await _events.close();
  }
}

/// Main-isolate state of one generation stream.
final class _StreamState {
  _StreamState(this.session, this.controller, this._sendCredit);

  final int session;
  final StreamController<EngineEvent> controller;
  final void Function(int n) _sendCredit;
  int streamId = 0;
  int generationId = -1;
  bool done = false;

  /// Credits withheld while the subscription is paused (backpressure).
  int _owed = 0;

  void deliver(List<EngineEvent> events, {required bool last}) {
    if (done) return;
    for (final e in events) {
      controller.add(e);
    }
    if (last) {
      done = true;
      unawaited(controller.close());
      return;
    }
    if (controller.isPaused) {
      _owed++;
    } else {
      _sendCredit(1);
    }
  }

  void onResume() {
    if (_owed > 0 && !done) {
      final n = _owed;
      _owed = 0;
      _sendCredit(n);
    }
  }

  void fail(Object error) {
    if (done) return;
    done = true;
    // Buffered until listened to, so an early failure still surfaces.
    controller.addError(error);
    unawaited(controller.close());
  }
}

/// Direct, synchronous FFI tokenizer for the calling isolate. Model handles
/// are immutable and shareable across threads (header "Threading") and
/// llama.cpp's tokenizer is thread-safe (llama.h:1262), so this is safe
/// next to a running generation; the chat-count path takes the model's
/// template mutex for one render.
final class _FfiSyncTokenizer implements SyncTokenizer {
  _FfiSyncTokenizer(this._path, this._model);

  final String _path;
  final int _model;
  SherpaEngineBindings? _b;

  SherpaEngineBindings get _bindings => _b ??= EngineLibrary.open(path: _path).bindings;

  @override
  int countText(String text) {
    final b = _bindings;
    return using((arena) {
      final u = text.toNativeUtf8(allocator: arena);
      final n = b.se_tokenize(Pointer<Void>.fromAddress(_model), u, u.length, 0, 0, nullptr, 0);
      if (n < 0) throw EngineException(n, b.lastError());
      return n;
    });
  }

  @override
  int countChat(String requestJson) {
    final b = _bindings;
    return using((arena) {
      final n = b.se_count_chat_tokens(Pointer<Void>.fromAddress(_model), requestJson.toNativeUtf8(allocator: arena));
      if (n < 0) throw EngineException(n, b.lastError());
      return n;
    });
  }
}
