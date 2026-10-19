import 'dart:async';

import 'package:sherpa_core/sherpa_core.dart';

import '../backend.dart';
import '../messages.pigeon.dart';
import 'errors.dart';
import 'event_router.dart';

/// Stop reason for a user cancel (token or subscription).
const String kStopUser = 'user';

/// One `stream()` call driving one native stream, implementing the core
/// `ModelProvider` contract shared by both providers:
///
/// * cold and single-subscription: [body] runs on listen;
/// * pausing the subscription pauses the native stream (credits stop, see
///   [LiteRtEventRouter]);
/// * cancelling the subscription or [cancel] asks Kotlin to stop at the next
///   token and ends with `Finish(cancelled)`; if the native terminal event
///   does not arrive within [cancelGrace] the stream ends anyway;
/// * a stop for another reason (memory pressure, app backgrounded) ends with
///   `Finish(pause)` so the agent loop continues the reply later;
/// * exactly one [Finish] on success; failures are [ProviderException]s.
abstract base class NativeGeneration {
  NativeGeneration({
    required this.backend,
    required this.router,
    required this.providerId,
    required this.cancel,
    required this.cancelGrace,
    this.nano = false,
  }) {
    controller = StreamController<ModelEvent>(
      onListen: () => unawaited(_run()),
      onPause: () => _sub?.pause(),
      onResume: () => _sub?.resume(),
      onCancel: _onCancel,
    );
  }

  final LiteRtBackend backend;
  final LiteRtEventRouter router;
  final String providerId;
  final CancellationToken? cancel;
  final Duration cancelGrace;
  final bool nano;
  late final StreamController<ModelEvent> controller;

  NativeStream? _native;
  StreamSubscription<LiteRtEvent>? _sub;
  Completer<void>? _done;
  Timer? _grace;
  bool _listenerGone = false;
  bool _finishSent = false;
  bool _stopRequested = false;
  String? _stopReason;
  final Completer<void> _gone = Completer<void>();

  bool get listenerGone => _listenerGone;

  bool get finishSent => _finishSent;

  /// Why the native turn was asked to stop ([kStopUser] or a policy reason).
  String? get stopReason => _stopReason;

  bool get userCancelled => _stopReason == kStopUser || (cancel?.isCancelled ?? false);

  /// The native stream id once [pump] started.
  int? get streamId => _native?.id;

  void emit(ModelEvent e) {
    if (_listenerGone || controller.isClosed) return;
    if (e is Finish) {
      if (_finishSent) return;
      _finishSent = true;
    }
    controller.add(e);
  }

  /// Everything the provider does for this call; awaits [pump] for the native
  /// turn. Throw [ProviderException] (or [CancelledException]) to fail.
  Future<void> body();

  /// One native event of the running turn. A terminal event must [emit] a
  /// [Finish] or throw a [ProviderException].
  void onEvent(LiteRtEvent e);

  /// The [Finish] when a requested stop got no native answer in time.
  Finish finishWithoutAnswer() => Finish(userCancelled ? FinishReason.cancelled : FinishReason.pause, rawReason: _stopReason);

  /// Waits for [future] unless the call is cancelled first (then throws
  /// [CancelledException]); the abandoned future's result is ignored.
  Future<T> guard<T>(Future<T> future) {
    final c = Completer<T>();
    future.then((v) {
      if (!c.isCompleted) c.complete(v);
    }, onError: (Object e, StackTrace s) {
      if (!c.isCompleted) c.completeError(e, s);
    });
    void stop(Object? _) {
      if (!c.isCompleted) c.completeError(const CancelledException());
    }

    cancel?.whenCancelled.then(stop);
    _gone.future.then(stop);
    return c.future;
  }

  /// Registers a native stream, runs [start] with its id (the host call
  /// that begins the turn) and waits for the terminal event.
  Future<void> pump(Future<void> Function(int streamId) start) async {
    if (_listenerGone) throw const CancelledException();
    cancel?.throwIfCancelled();
    final native = _native = router.open();
    final done = _done = Completer<void>();
    _sub = native.events.listen(
      (e) {
        if (done.isCompleted) return;
        try {
          onEvent(e);
        } on ProviderException catch (err) {
          done.completeError(err);
          return;
        }
        if (isTerminal(e)) done.complete();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );
    if (controller.isPaused) _sub!.pause();
    final token = cancel;
    if (token != null) unawaited(token.whenCancelled.then((_) => requestStop(kStopUser)));
    try {
      await start(native.id);
    } on Object {
      native.abandon();
      rethrow;
    }
    if (_listenerGone) requestStop(kStopUser);
    try {
      await done.future;
    } finally {
      _grace?.cancel();
    }
    if (!_finishSent && !_listenerGone) emit(finishWithoutAnswer());
  }

  /// Asks Kotlin to stop the running turn at the next token.
  void requestStop(String reason) {
    final native = _native;
    if (_stopRequested || native == null || (_done?.isCompleted ?? true)) {
      _stopReason ??= reason;
      return;
    }
    _stopRequested = true;
    _stopReason = reason;
    unawaited(backend.cancel(native.id, reason).catchError((Object _) {}));
    _grace = Timer(cancelGrace, () {
      // No terminal event in time (e.g. a paused consumer, an unresponsive
      // engine): end here; Kotlin drains the turn in the background.
      final sub = _sub;
      _sub = null;
      unawaited(sub?.cancel());
      native.abandon();
      final d = _done;
      if (d != null && !d.isCompleted) d.complete();
    });
  }

  Future<void> _onCancel() async {
    _listenerGone = true;
    if (!_gone.isCompleted) _gone.complete();
    requestStop(kStopUser);
  }

  Future<void> _run() async {
    try {
      await body();
    } on CancelledException {
      if (!_finishSent) emit(const Finish(FinishReason.cancelled));
    } on ProviderException catch (e) {
      _fail(e);
    } on Object catch (e) {
      _fail(hostError(e, providerId: providerId, nano: nano));
    } finally {
      _grace?.cancel();
      final sub = _sub;
      _sub = null;
      unawaited(sub?.cancel());
      _native?.abandon();
      if (!controller.isClosed) unawaited(controller.close());
    }
  }

  void _fail(ProviderException e) {
    if (_listenerGone || controller.isClosed || _finishSent) return;
    if (userCancelled) {
      emit(const Finish(FinishReason.cancelled));
      return;
    }
    controller.addError(e);
  }
}

/// A FIFO mutex: one native turn at a time per engine.
final class TurnLock {
  Future<void> _tail = Future<void>.value();

  /// Runs [job] after every job queued before it.
  Future<T> run<T>(Future<T> Function() job) {
    final prev = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return prev.then((_) => job()).whenComplete(done.complete);
  }
}
