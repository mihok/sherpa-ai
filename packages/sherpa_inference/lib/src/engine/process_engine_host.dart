import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../ffi/bindings.dart';
import '../ffi/library_loader.dart';
import 'engine_host.dart';
import 'engine_types.dart';
import 'process_exit.dart';
import 'process_messages.pigeon.dart';
import 'process_transport.dart';

/// The `:inference` service could not be bound (no plugin, no service in
/// the merged manifest, refused, timed out). Carried as the `cause` of the
/// [EngineUnavailableException] that [ProcessEngineHost.start] throws, so
/// [createDefaultEngineHost] can fall back to the in-process host.
final class EngineHostBindException implements Exception {
  const EngineHostBindException(this.message);

  final String message;

  @override
  String toString() => 'EngineHostBindException: $message';
}

/// [EngineHost] for Android: the engine runs in the app's private
/// `:inference` process (InferenceService, a bound service; see
/// android/src/main/AndroidManifest.xml), reached through
/// SherpaInferencePlugin over Pigeon and Binder. A native crash or an OS
/// memory kill there ends that process, not the app.
///
/// Semantics are FfiEngineHost's (the [EngineHost] contract), plus:
/// * **Handles** are ids minted by the service, tagged with [epoch]. A dead
///   process takes every native object with it: the epoch bumps and older
///   handles throw [StaleHandleException].
/// * **Ordering**: calls are shipped synchronously in call order on one
///   ordered channel (Pigeon serial TaskQueue → one oneway Binder node), and
///   the service runs each session's calls in arrival order.
/// * **Generation** streams are flow-controlled end to end: the service has
///   at most 4 batches outstanding per stream (each ≤ 16 KiB), Dart returns
///   a credit per delivered batch and withholds them while the subscription
///   is paused, so a paused consumer stops the service's pump, the engine
///   ring fills and decode blocks.
/// * **Crashes**: on a process death every pending call and stream fails at
///   once with [EngineCrashedException] and the epoch bumps; when Android's
///   exit record arrives (≤ a few seconds) [events] gets
///   [EngineHostCrashed] (`nativeStateLost: true`, reason from
///   [EngineProcessCrash.reason]) and [crashes] the structured report; then
///   the host restarts with [restartPolicy]'s backoff and emits
///   [EngineHostRestarted]. Calls without handles issued meanwhile wait for
///   the restart. A crash loop stops restarting: [terminalReason] is set and
///   calls fail with [EngineUnavailableException] until [retry].
/// * **Importance**: while calls or streams are in flight the plugin holds a
///   second, `BIND_IMPORTANT` binding ([bindPolicy]); [busyHold] after the
///   last one it is dropped. With no handles left for [idleUnbindAfter] the
///   host unbinds, the service frees everything and the process can go; the
///   next call reconnects transparently (same epoch: nothing was lost).
/// * **Forensics**: the service records its phase with
///   `setProcessStateSummary`; the main process reads it back from the
///   exit record ([EngineProcessExit.phase]). [crashBreadcrumbPath] is the
///   engine's breadcrumb (EngineForensics.engineBreadcrumbPath); after a
///   live crash its message is folded into the crash report and the file is
///   consumed ([consumeBreadcrumbOnCrash]) so the next app start does not
///   report the same crash again.
///
/// [syncTokenizer] returns null: there is no engine in this process. One
/// host per app (the plugin has one event channel).
final class ProcessEngineHost implements EngineHost {
  ProcessEngineHost({
    InferenceTransport? transport,
    this.library = 'libsherpa_engine.so',
    this.crashBreadcrumbPath,
    this.backendDir,
    this.bindPolicy = BindPolicy.adaptive,
    this.restartPolicy = const ProcessRestartPolicy(),
    this.idleUnbindAfter = const Duration(seconds: 60),
    this.busyHold = const Duration(seconds: 2),
    this.connectTimeout = const Duration(seconds: 20),
    this.exitInfoTimeout = const Duration(seconds: 4),
    this.consumeBreadcrumbOnCrash = true,
    DateTime Function()? now,
  })  : _transport = transport ?? PigeonInferenceTransport(),
        _now = now ?? DateTime.now;

  final InferenceTransport _transport;

  /// The engine library the service dlopens (bare name inside the APK).
  final String library;
  final String? crashBreadcrumbPath;
  final String? backendDir;
  final BindPolicy bindPolicy;
  final ProcessRestartPolicy restartPolicy;

  /// Unbind after this long without handles or work; null = stay bound.
  final Duration? idleUnbindAfter;
  final Duration busyHold;
  final Duration connectTimeout;
  final Duration exitInfoTimeout;
  final bool consumeBreadcrumbOnCrash;
  final DateTime Function() _now;

  @override
  EngineHostKind get kind => EngineHostKind.isolatedProcess;

  int _epoch = 0;

  @override
  int get epoch => _epoch;

  final StreamController<EngineHostEvent> _events = StreamController.broadcast();
  final StreamController<EngineProcessCrash> _crashes = StreamController.broadcast();

  @override
  Stream<EngineHostEvent> get events => _events.stream;

  /// Structured crash reports (exit record, phase, tombstone excerpt).
  Stream<EngineProcessCrash> get crashes => _crashes.stream;

  EngineProcessCrash? _lastCrash;

  EngineProcessCrash? get lastCrash => _lastCrash;

  /// Set once the crash loop limit was hit (see [ProcessRestartPolicy]).
  String? get terminalReason => _terminal;

  /// The service process, while connected.
  int? get pid => _conn == null ? null : _pid;

  StreamSubscription<InferenceMessage>? _sub;
  int? _conn;
  int? _pid;
  DateTime? _connectedAt;
  int? _pendingConn;
  Completer<void>? _connectWaiter;
  Future<void>? _connecting;
  final Map<int, HostStatus> _earlyStatus = {};
  final Map<int, Completer<ProcessExitMsg?>> _exitWaiters = {};

  EngineInfo? _info;
  Future<EngineInfo>? _starting;
  bool _disposed = false;
  String? _terminal;
  Completer<void>? _recovery;
  bool _restarting = false;
  Timer? _restartTimer;
  final List<DateTime> _crashLog = [];
  int _restartAttempt = 0;

  final Map<int, _Pending> _pending = {};
  final Map<int, _ProcStream> _streams = {};
  final Set<int> _models = {};
  final Set<int> _sessions = {};
  final Set<int> _loras = {};
  int _nextId = 1;

  bool _busy = false;
  Timer? _busyOff;
  Timer? _idle;

  bool get _ready => _info != null && _conn != null && _recovery == null && _terminal == null && !_disposed;

  // ---------------------------------------------------------------------------
  // Connection and lifecycle

  void _listen() {
    _sub ??= _transport.messages.listen(_onMessage, onError: (Object _) {});
  }

  /// Binds the service without opening the engine (for
  /// [createDefaultEngineHost]). Throws [EngineUnavailableException] with an
  /// [EngineHostBindException] cause when binding fails.
  Future<void> bind() async {
    if (_disposed) throw StateError('ProcessEngineHost was disposed');
    _listen();
    await _connect();
  }

  Future<void> _connect() {
    if (_conn != null) return Future.value();
    return _connecting ??= _connectOnce().whenComplete(() => _connecting = null);
  }

  Future<void> _connectOnce() async {
    final waiter = Completer<void>();
    _connectWaiter = waiter;
    try {
      final int id;
      try {
        id = await _transport.connect(bindPolicy);
      } on MissingPluginException catch (e) {
        throw EngineUnavailableException('the inference plugin is not registered',
            cause: EngineHostBindException('$e'));
      } on PlatformException catch (e) {
        throw EngineUnavailableException('the inference service could not be bound',
            cause: EngineHostBindException('${e.code}: ${e.message}'));
      }
      _pendingConn = id;
      final early = _earlyStatus.remove(id);
      _earlyStatus.clear();
      if (early != null) _onStatus(early);
      try {
        await waiter.future.timeout(connectTimeout);
      } on TimeoutException {
        if (_pendingConn == id) _pendingConn = null;
        unawaited(_transport.disconnect(id).catchError((Object _) {}));
        throw EngineUnavailableException('the inference service did not connect',
            cause: EngineHostBindException('no connection within ${connectTimeout.inSeconds}s'));
      }
    } finally {
      if (identical(_connectWaiter, waiter)) _connectWaiter = null;
    }
  }

  @override
  Future<EngineInfo> start() {
    if (_disposed) return Future.error(StateError('ProcessEngineHost was disposed'));
    final t = _terminal;
    if (t != null) return Future.error(EngineUnavailableException(t));
    final info = _info;
    if (info != null && _conn != null) return Future.value(info);
    final recovery = _recovery;
    if (recovery != null && !_restarting) return recovery.future.then((_) => start());
    return _starting ??= _startOnce().whenComplete(() => _starting = null);
  }

  Future<EngineInfo> _startOnce() async {
    _listen();
    await _connect();
    final Object? r;
    try {
      r = await _send(StartCall(library: library, crashBreadcrumbPath: crashBreadcrumbPath, backendDir: backendDir));
    } on EngineException catch (e) {
      if (e.code == SeStatus.unsupported) throw EngineUnavailableException(e.message);
      rethrow;
    }
    final m = r! as EngineInfoMsg;
    _workChanged();
    return _info = EngineInfo(
      abiVersion: m.abiVersion,
      version: m.version,
      systemInfoJson: m.systemInfoJson,
      hostKind: kind,
      libraryLocator: ':inference (pid ${m.pid}): $library',
    );
  }

  /// Waits until the engine is serving (start, idle reconnect, or crash
  /// restart), or throws.
  Future<void> _awaitReady() async {
    while (!_ready) {
      if (_disposed) throw StateError('ProcessEngineHost was disposed');
      final t = _terminal;
      if (t != null) throw EngineUnavailableException(t);
      final r = _recovery;
      if (r != null) {
        await r.future;
        continue;
      }
      await start();
    }
  }

  /// Leaves the crash-loop state and starts again (a user's "retry").
  Future<EngineInfo> retry() async {
    if (_terminal == null) return start();
    _terminal = null;
    _crashLog.clear();
    _restartAttempt = 0;
    final info = await start();
    _events.add(EngineHostRestarted(_epoch));
    return info;
  }

  void _onMessage(InferenceMessage m) {
    switch (m) {
      case CallResult(:final requestId, :final value):
        final p = _pending.remove(requestId);
        if (p == null) return;
        p.completer.complete(value);
        _workChanged();
      case CallError(:final requestId, :final code, :final message):
        final p = _pending.remove(requestId);
        if (p == null) return;
        p.completer.completeError(EngineException(code, message));
        _workChanged();
      case LoadProgress(:final requestId, :final progress):
        _pending[requestId]?.onProgress?.call(progress);
      case StreamStarted(:final streamId, :final generationId):
        _streams[streamId]?.generationId = generationId;
      case StreamFailed(:final streamId, :final code, :final message):
        _streams.remove(streamId)?.fail(EngineException(code, message));
        _workChanged();
      case EventBatch(:final streamId, :final events, :final last):
        final s = _streams[streamId];
        if (s == null) return;
        if (last) _streams.remove(streamId);
        s.deliver([for (final e in events) _event(e)], last: last);
        if (last) _workChanged();
      case HostStatus():
        _onStatus(m);
    }
  }

  void _onStatus(HostStatus s) {
    final c = s.connection;
    switch (s.kind) {
      case HostStatusKind.connected:
        if (c == _pendingConn) {
          _pendingConn = null;
          _conn = c;
          _pid = s.pid;
          _connectedAt = _now();
          _busy = false;
          final w = _connectWaiter;
          if (w != null && !w.isCompleted) w.complete();
        } else if (_pendingConn == null && _conn == null) {
          _earlyStatus[c] = s; // arrived before connect() returned its id
        }
      case HostStatusKind.bindFailed:
        if (c == _pendingConn) {
          _pendingConn = null;
          final w = _connectWaiter;
          if (w != null && !w.isCompleted) {
            w.completeError(EngineUnavailableException('the inference service could not be bound',
                cause: EngineHostBindException(s.detail ?? 'bind failed')));
          }
        } else if (_pendingConn == null && _conn == null) {
          _earlyStatus[c] = s;
        }
      case HostStatusKind.disconnected:
        if (c == _conn) {
          _onDeath(c, s.pid, s.detail);
        } else if (c == _pendingConn) {
          // Died while attaching: a failed start, counted like a crash.
          _pendingConn = null;
          final w = _connectWaiter;
          if (w != null && !w.isCompleted) {
            w.completeError(EngineCrashedException(s.detail ?? 'the inference process died while connecting'));
          }
          _onDeath(c, s.pid, s.detail, wasConnected: false);
        }
      case HostStatusKind.exitInfo:
        final w = _exitWaiters.remove(c);
        if (w != null && !w.isCompleted) w.complete(s.exit);
    }
  }

  /// The process died: fail everything now, report when the exit record is
  /// in, then restart with backoff (or give up).
  void _onDeath(int connection, int? pid, String? detail, {bool wasConnected = true}) {
    if (_disposed) return;
    final exitInfo = _exitWaiters[connection] = Completer<ProcessExitMsg?>();
    if (wasConnected) _conn = null;
    _info = null;
    _busy = false;
    _busyOff?.cancel();
    _busyOff = null;
    _idle?.cancel();
    _idle = null;
    final crash = EngineCrashedException('the on-device engine process died${detail == null ? '' : ' ($detail)'}');
    final pending = Map.of(_pending);
    _pending.clear();
    for (final p in pending.values) {
      p.completer.completeError(crash);
    }
    final streams = Map.of(_streams);
    _streams.clear();
    for (final s in streams.values) {
      s.fail(crash);
    }
    final crashedEpoch = _epoch;
    if (wasConnected || _models.isNotEmpty || _sessions.isNotEmpty || _loras.isNotEmpty) _epoch++;
    _models.clear();
    _sessions.clear();
    _loras.clear();
    final now = _now();
    final connectedAt = _connectedAt;
    if (connectedAt != null && now.difference(connectedAt) >= restartPolicy.stableAfter) _restartAttempt = 0;
    _connectedAt = null;
    _crashLog
      ..add(now)
      ..removeWhere((t) => now.difference(t) > restartPolicy.window);
    final gaveUp = _crashLog.length >= restartPolicy.maxCrashes;
    _recovery ??= Completer<void>();
    unawaited(_finishCrash(exitInfo.future, crashedEpoch, pid, detail, now, gaveUp));
  }

  Future<void> _finishCrash(
    Future<ProcessExitMsg?> exitInfo,
    int crashedEpoch,
    int? pid,
    String? detail,
    DateTime at,
    bool gaveUp,
  ) async {
    final exit = await exitInfo.timeout(exitInfoTimeout, onTimeout: () => null);
    final report = EngineProcessCrash(
      epoch: crashedEpoch,
      at: at,
      pid: pid,
      exit: exit == null ? null : EngineProcessExit.fromMessage(exit),
      engineMessage: await _takeBreadcrumb(),
      transportDetail: detail,
      recentCrashes: _crashLog.length,
      gaveUp: gaveUp,
    );
    if (_disposed) return;
    _lastCrash = report;
    _events.add(EngineHostCrashed(crashedEpoch, report.reason, nativeStateLost: true));
    _crashes.add(report);
    if (gaveUp) {
      _terminal = report.reason;
      _endRecovery();
      return;
    }
    _restartTimer?.cancel();
    _restartTimer = Timer(restartPolicy.delayFor(_restartAttempt++), () => unawaited(_restart()));
  }

  Future<void> _restart() async {
    if (_disposed || _terminal != null) return;
    _restarting = true;
    try {
      await start();
      _restarting = false;
      _endRecovery();
      _events.add(EngineHostRestarted(_epoch));
    } on EngineCrashedException {
      // It died again while starting: that death was reported and scheduled
      // the next attempt.
      _restarting = false;
    } on Object catch (e) {
      _restarting = false;
      if (_disposed) return;
      // Could not bind, or the engine refused to open: count it like a crash.
      final now = _now();
      _crashLog
        ..add(now)
        ..removeWhere((t) => now.difference(t) > restartPolicy.window);
      final gaveUp = _crashLog.length >= restartPolicy.maxCrashes;
      final reason = 'restart failed: $e';
      _events.add(EngineHostCrashed(_epoch, gaveUp ? '$reason; not restarting automatically' : reason,
          nativeStateLost: true));
      if (gaveUp) {
        _terminal = 'the on-device engine keeps failing to start ($e)';
        _endRecovery();
      } else {
        _restartTimer = Timer(restartPolicy.delayFor(_restartAttempt++), () => unawaited(_restart()));
      }
    }
  }

  void _endRecovery() {
    final r = _recovery;
    _recovery = null;
    if (r != null && !r.isCompleted) r.complete();
  }

  /// The engine's last fatal message (it appends before aborting), consumed
  /// so that EngineForensics does not report this crash again next launch.
  Future<String?> _takeBreadcrumb() async {
    final path = crashBreadcrumbPath;
    if (path == null) return null;
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      final lines = (await f.readAsString()).split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      if (consumeBreadcrumbOnCrash) await f.delete();
      if (lines.isEmpty) return null;
      final last = lines.last;
      return last.length <= 300 ? last : '${last.substring(0, 299)}…';
    } on Object {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Busy / idle

  void _workChanged() {
    if (_disposed) return;
    final conn = _conn;
    final working = _pending.isNotEmpty || _streams.isNotEmpty;
    if (working) {
      _busyOff?.cancel();
      _busyOff = null;
      _idle?.cancel();
      _idle = null;
      if (!_busy && conn != null) {
        _busy = true;
        unawaited(_transport.setBusy(conn, true).catchError((Object _) {}));
      }
      return;
    }
    if (_busy && conn != null) {
      _busyOff ??= Timer(busyHold, () {
        _busyOff = null;
        final c = _conn;
        if (_busy && c != null && _pending.isEmpty && _streams.isEmpty) {
          _busy = false;
          unawaited(_transport.setBusy(c, false).catchError((Object _) {}));
        }
      });
    }
    final idleAfter = idleUnbindAfter;
    if (idleAfter != null && conn != null && _models.isEmpty && _sessions.isEmpty && _loras.isEmpty) {
      _idle ??= Timer(idleAfter, _idleDisconnect);
    }
  }

  void _idleDisconnect() {
    _idle = null;
    final c = _conn;
    if (c == null || _disposed || _pending.isNotEmpty || _streams.isNotEmpty) return;
    if (_models.isNotEmpty || _sessions.isNotEmpty || _loras.isNotEmpty || _starting != null) return;
    _conn = null;
    _info = null;
    _busy = false;
    _busyOff?.cancel();
    _busyOff = null;
    unawaited(_transport.disconnect(c).catchError((Object _) {}));
  }

  /// Test hook: true while the importance-raising binding is held.
  @visibleForTesting
  bool get debugBusy => _busy;

  // ---------------------------------------------------------------------------
  // Calls

  void _checkEpoch(EngineHandle h) {
    if (h.epoch != _epoch) throw StaleHandleException(h);
  }

  /// Ships [call] synchronously when serving (so calls keep their order),
  /// else after the engine is ready.
  Future<Object?> _call(
    EngineCall call, {
    List<EngineHandle> handles = const [],
    void Function(double)? onProgress,
    void Function()? onSent,
  }) {
    try {
      handles.forEach(_checkEpoch);
    } on Object catch (e) {
      return Future.error(e);
    }
    if (_ready) return _send(call, onProgress: onProgress, onSent: onSent);
    return _awaitReady().then((_) {
      handles.forEach(_checkEpoch);
      return _send(call, onProgress: onProgress, onSent: onSent);
    });
  }

  Future<Object?> _send(EngineCall call, {void Function(double)? onProgress, void Function()? onSent}) {
    final conn = _conn;
    if (conn == null) return Future.error(const EngineCrashedException('the engine process is not running'));
    final id = _nextId++;
    final p = _Pending(onProgress);
    _pending[id] = p;
    _workChanged();
    unawaited(_transport.send(conn, id, call).then((_) => onSent?.call(), onError: (Object e) {
      if (_pending.remove(id) != null) {
        p.completer.completeError(EngineCrashedException('the engine process is not reachable (${_describe(e)})'));
        _workChanged();
      }
    }));
    return p.completer.future;
  }

  /// Fire-and-forget (credits, cancels).
  void _fire(EngineCall call) {
    final conn = _conn;
    if (conn == null) return;
    _transport.send(conn, 0, call).ignore();
  }

  static String _describe(Object e) => e is PlatformException ? '${e.code}: ${e.message}' : '$e';

  Future<T> _withCancel<T>(CancellationToken? cancel, Future<T> Function(int cancelId, void Function() onSent) body) {
    if (cancel == null) return body(0, () {});
    cancel.throwIfCancelled();
    final cancelId = _nextId++;
    var sent = false;
    var fired = false;
    void fire() {
      if (fired) return;
      fired = true;
      _fire(CancelCall(cancelId: cancelId));
    }

    unawaited(cancel.whenCancelled.then((_) {
      if (sent) fire();
    }));
    return body(cancelId, () {
      sent = true;
      if (cancel.isCancelled) fire();
    });
  }

  // ---------------------------------------------------------------------------
  // EngineHost

  @override
  Future<String> systemInfoJson() async => (await _call(SystemInfoCall()))! as String;

  @override
  Future<EngineModel> loadModel(
    ModelLoadOptions options, {
    CancellationToken? cancel,
    void Function(double progress)? onProgress,
  }) async {
    final r = await _withCancel(
        cancel,
        (cancelId, onSent) => _call(
              LoadModelCall(
                options: _modelOptions(options),
                cancelId: cancelId,
                progress: onProgress != null,
                phaseTag: phaseTagFor(options),
              ),
              onProgress: onProgress,
              onSent: onSent,
            ));
    final h = r! as HandleInfoMsg;
    _models.add(h.handle);
    return EngineModel(ref: ModelRef(h.handle, _epoch), infoJson: h.infoJson, options: options);
  }

  @override
  Future<void> freeModel(ModelRef model) async {
    _checkEpoch(model);
    _models.remove(model.id);
    await _call(FreeModelCall(model: model.id), handles: [model]);
    _workChanged();
  }

  @override
  Future<MemoryEstimate> estimateMemory(ModelLoadOptions model, SessionConfig session) async =>
      _estimate((await _call(EstimateMemoryCall(model: _modelOptions(model), session: _sessionConfig(session))))!
          as MemoryEstimateMsg);

  @override
  Future<EngineSession> createSession(ModelRef model, SessionConfig config) async {
    final r = (await _call(CreateSessionCall(model: model.id, config: _sessionConfig(config)), handles: [model]))!
        as HandleInfoMsg;
    _sessions.add(r.handle);
    return EngineSession(ref: SessionRef(r.handle, _epoch), model: model, config: config, infoJson: r.infoJson);
  }

  @override
  Future<void> freeSession(SessionRef session) async {
    _checkEpoch(session);
    for (final e in _streams.entries.where((e) => e.value.session == session.id).toList()) {
      _streams.remove(e.key);
      e.value.fail(const EngineException(SeStatus.invalidArg, 'session was freed during generation'));
    }
    _sessions.remove(session.id);
    await _call(FreeSessionCall(session: session.id), handles: [session]);
    _workChanged();
  }

  @override
  Future<void> resetSession(SessionRef session) async {
    await _call(ResetSessionCall(session: session.id), handles: [session]);
  }

  @override
  Future<void> setThreads(SessionRef session, int nThreads, int nThreadsBatch) async {
    await _call(SetThreadsCall(session: session.id, nThreads: nThreads, nThreadsBatch: nThreadsBatch),
        handles: [session]);
  }

  @override
  Future<String> sessionInfoJson(SessionRef session) async =>
      (await _call(SessionInfoCall(session: session.id), handles: [session]))! as String;

  @override
  Future<MemoryEstimate> sessionMemory(SessionRef session) async =>
      _estimate((await _call(SessionMemoryCall(session: session.id), handles: [session]))! as MemoryEstimateMsg);

  @override
  Stream<EngineEvent> generate(SessionRef session, String requestJson) {
    late final _ProcStream state;
    // Closed by _ProcStream on FINISH, failure or cancel.
    // ignore: close_sinks
    final controller = StreamController<EngineEvent>();
    state = _ProcStream(session.id, controller, (n) => _fire(CreditCall(streamId: state.streamId, n: n)));
    controller
      ..onListen = () {
        if (session.epoch != _epoch) {
          state.fail(StaleHandleException(session));
        } else if (_ready) {
          _beginStream(state, session, requestJson);
        } else {
          _awaitReady().then((_) {
            if (state.done) return;
            if (session.epoch != _epoch) {
              state.fail(StaleHandleException(session));
            } else {
              _beginStream(state, session, requestJson);
            }
          }, onError: state.fail);
        }
      }
      ..onResume = state.onResume
      ..onCancel = () {
        if (!state.done) {
          state.done = true;
          if (_streams.remove(state.streamId) != null) {
            _fire(CancelStreamCall(streamId: state.streamId));
            _workChanged();
          }
        }
      };
    return controller.stream;
  }

  void _beginStream(_ProcStream state, SessionRef session, String requestJson) {
    final conn = _conn;
    if (conn == null) {
      state.fail(const EngineCrashedException('the engine process is not running'));
      return;
    }
    state.streamId = _nextId++;
    _streams[state.streamId] = state;
    _workChanged();
    unawaited(_transport
        .send(conn, 0, GenerateCall(streamId: state.streamId, session: session.id, requestJson: requestJson))
        .catchError((Object e) {
      if (_streams.remove(state.streamId) != null) {
        state.fail(EngineCrashedException('the engine process is not reachable (${_describe(e)})'));
        _workChanged();
      }
    }));
  }

  @override
  Future<void> cancelGeneration(SessionRef session) async {
    _checkEpoch(session);
    _fire(CancelSessionCall(session: session.id));
  }

  @override
  Future<List<int>> tokenize(ModelRef model, String text, {bool addSpecial = false, bool parseSpecial = false}) async {
    final r = await _call(TokenizeCall(model: model.id, text: text, addSpecial: addSpecial, parseSpecial: parseSpecial),
        handles: [model]);
    return List<int>.of(r! as List<int>);
  }

  @override
  Future<String> detokenize(ModelRef model, List<int> tokens, {bool renderSpecial = false}) async =>
      (await _call(DetokenizeCall(model: model.id, tokens: Int32List.fromList(tokens), renderSpecial: renderSpecial),
          handles: [model]))! as String;

  @override
  Future<int> countChatTokens(ModelRef model, String requestJson) async =>
      (await _call(CountChatCall(model: model.id, requestJson: requestJson), handles: [model]))! as int;

  @override
  Future<List<int>> countBatch(ModelRef model, {List<String> texts = const [], List<String> chatRequests = const []}) async {
    final r = await _call(CountBatchCall(model: model.id, texts: texts, chatRequests: chatRequests), handles: [model]);
    return List<int>.of(r! as List<int>);
  }

  @override
  Future<int> saveState(SessionRef session, String path) async =>
      (await _call(SaveStateCall(session: session.id, path: path), handles: [session]))! as int;

  @override
  Future<int> loadState(SessionRef session, String path) async =>
      (await _call(LoadStateCall(session: session.id, path: path), handles: [session]))! as int;

  @override
  Future<LoraRef> loadLora(ModelRef model, String path) async {
    final id = (await _call(LoadLoraCall(model: model.id, path: path), handles: [model]))! as int;
    _loras.add(id);
    return LoraRef(id, _epoch);
  }

  @override
  Future<void> freeLora(LoraRef lora) async {
    _checkEpoch(lora);
    _loras.remove(lora.id);
    await _call(FreeLoraCall(lora: lora.id), handles: [lora]);
    _workChanged();
  }

  @override
  Future<void> setLoras(SessionRef session, List<(LoraRef, double)> loras) async {
    await _call(
        SetLorasCall(session: session.id, loras: [for (final l in loras) l.$1.id], scales: [for (final l in loras) l.$2]),
        handles: [session, for (final l in loras) l.$1]);
  }

  @override
  Future<BenchResult> bench(ModelRef model, BenchConfig config, {CancellationToken? cancel}) async {
    _checkEpoch(model);
    final r = (await _withCancel(
        cancel,
        (cancelId, onSent) => _call(BenchCall(model: model.id, config: _benchConfig(config), cancelId: cancelId),
            handles: [model], onSent: onSent)))! as BenchResultMsg;
    return BenchResult(
      nPrompt: r.nPrompt,
      nGen: r.nGen,
      nThreads: r.nThreads,
      promptTokensPerSec: r.promptTokensPerSec,
      genTokensPerSec: r.genTokensPerSec,
      promptMs: r.promptMs,
      genMs: r.genMs,
    );
  }

  /// No engine in this process, so no synchronous tokenizer: callers use
  /// [countBatch] (one hop for many texts).
  @override
  SyncTokenizer? syncTokenizer(ModelRef model) => null;

  /// Debuggable builds only: makes the service process die ([mode]:
  /// `abort` (SIGABRT, like GGML_ABORT), `segv`, `kill` (SIGKILL), `exit`)
  /// to exercise crash handling on a device.
  Future<void> debugCrashEngineProcess(String mode) async {
    try {
      await _call(DebugCrashCall(mode: mode));
    } on EngineCrashedException {
      // expected
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _restartTimer?.cancel();
    _busyOff?.cancel();
    _idle?.cancel();
    const gone = EngineCrashedException('engine host disposed');
    for (final s in _streams.values.toList()) {
      s.fail(gone);
    }
    _streams.clear();
    for (final p in _pending.values.toList()) {
      p.completer.completeError(gone);
    }
    _pending.clear();
    final c = _conn ?? _pendingConn;
    _conn = null;
    _pendingConn = null;
    if (c != null) {
      // Unbinding destroys the service, which frees every native object.
      await _transport.disconnect(c).catchError((Object _) {});
    }
    _endRecovery();
    await _sub?.cancel();
    await _events.close();
    await _crashes.close();
  }

  // ---------------------------------------------------------------------------
  // Mapping

  /// A short, non-identifying model tag for the process state summary: the
  /// head of a `sha256:` identity, else a hash of the file name.
  @visibleForTesting
  static String phaseTagFor(ModelLoadOptions o) {
    final id = o.modelId;
    if (id != null && id.startsWith('sha256:') && id.length >= 15) return 'sha256:${id.substring(7, 15)}';
    var h = 0x811c9dc5;
    for (final c in (id ?? o.path.split('/').last).codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
    }
    return 'f${h.toRadixString(16).padLeft(8, '0')}';
  }

  static ModelOptionsMsg _modelOptions(ModelLoadOptions o) => ModelOptionsMsg(
        path: o.path,
        modelId: o.modelId,
        nGpuLayers: o.nGpuLayers,
        loadMode: o.loadMode.code,
        useExtraBuffers: o.useExtraBuffers,
        vocabOnly: o.vocabOnly,
        loadMtp: o.loadMtp,
        chatTemplateOverride: o.chatTemplateOverride,
        mmprojPath: o.mmprojPath,
        draftModelPath: o.draftModelPath,
      );

  static SessionConfigMsg _sessionConfig(SessionConfig c) => SessionConfigMsg(
        nCtx: c.nCtx,
        nBatch: c.nBatch,
        nUbatch: c.nUbatch,
        nThreads: c.nThreads,
        nThreadsBatch: c.nThreadsBatch,
        typeK: c.typeK.code,
        typeV: c.typeV.code,
        flashAttention: c.flashAttention.code,
        nOutputsMax: c.nOutputsMax,
        swaFull: c.swaFull,
        seed: c.seed,
        speculative: c.speculative.code,
        specMaxDraft: c.specMaxDraft,
        eventCapacity: c.eventCapacity,
      );

  static BenchConfigMsg _benchConfig(BenchConfig c) => BenchConfigMsg(
        nThreads: c.nThreads,
        nThreadsBatch: c.nThreadsBatch,
        nBatch: c.nBatch,
        nUbatch: c.nUbatch,
        nCtx: c.nCtx,
        nPrompt: c.nPrompt,
        nGen: c.nGen,
        nReps: c.nReps,
        typeK: c.typeK.code,
        typeV: c.typeV.code,
        flashAttention: c.flashAttention.code,
      );

  static MemoryEstimate _estimate(MemoryEstimateMsg e) => MemoryEstimate(
        nCtx: e.nCtx,
        nCtxSeq: e.nCtxSeq,
        flashAttention: e.flashAttention,
        modelBytes: e.modelBytes,
        modelMappedBytes: e.modelMappedBytes,
        kvBytes: e.kvBytes,
        computeBytes: e.computeBytes,
        outputBytes: e.outputBytes,
        totalBytes: e.totalBytes,
        kvBytesPerToken: e.kvBytesPerToken,
        fileBytes: e.fileBytes,
      );

  static EngineEvent _event(EngineEventMsg e) => EngineEvent(
        type: EngineEventType.of(e.type),
        generationId: e.generationId,
        index: e.index,
        code: e.code,
        text: e.text,
        id: e.id,
        name: e.name,
        promptTokens: e.promptTokens,
        cachedTokens: e.cachedTokens,
        completionTokens: e.completionTokens,
        nDrafted: e.nDrafted,
        nAccepted: e.nAccepted,
        progressDone: e.progressDone,
        progressTotal: e.progressTotal,
        ttftMs: e.ttftMs,
        prefillTps: e.prefillTps,
        decodeTps: e.decodeTps,
        draftAcceptRate: e.draftAcceptRate,
        prefillMs: e.prefillMs,
        decodeMs: e.decodeMs,
      );
}

final class _Pending {
  _Pending(this.onProgress);

  final Completer<Object?> completer = Completer<Object?>();
  final void Function(double)? onProgress;
}

/// Main-isolate state of one generation stream (FfiEngineHost's
/// `_StreamState`): one credit back per delivered batch, withheld while
/// paused.
final class _ProcStream {
  _ProcStream(this.session, this.controller, this._sendCredit);

  final int session;
  final StreamController<EngineEvent> controller;
  final void Function(int n) _sendCredit;
  int streamId = 0;
  int generationId = -1;
  bool done = false;
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
    controller.addError(error);
    unawaited(controller.close());
  }
}
