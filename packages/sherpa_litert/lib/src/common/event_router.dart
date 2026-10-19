import 'dart:async';
import 'dart:math';

import '../backend.dart';
import '../messages.pigeon.dart';

/// Batches a native stream may have in flight before Dart returns credits.
/// Matches `HubConfig.credits` in Kotlin (stream/StreamHub.kt).
const int kStreamCredits = 4;

/// Whether [e] ends its stream.
bool isTerminal(LiteRtEvent e) => switch (e.kind) {
      EventKind.done ||
      EventKind.cancelled ||
      EventKind.error ||
      EventKind.downloadCompleted ||
      EventKind.downloadFailed =>
        true,
      _ => false,
    };

/// Routes the backend's event batches to per-stream listeners and returns
/// flow-control credits.
///
/// A [NativeStream] credits one batch back to Kotlin as soon as its events
/// were handed to an unpaused listener. While the listener is paused the
/// credits are owed instead, so Kotlin stops sending after [kStreamCredits]
/// batches, coalesces up to its byte cap and then blocks the engine's
/// callback thread: decoding stops (end-to-end backpressure).
final class LiteRtEventRouter {
  LiteRtEventRouter(this._backend, {int? firstStreamId})
      // A random start keeps ids of a hot-restarted isolate away from
      // streams the old isolate left running natively.
      : _nextId = firstStreamId ?? (Random().nextInt(1 << 30) + 1);

  final LiteRtBackend _backend;
  int _nextId;
  StreamSubscription<EventBatch>? _sub;
  final Map<int, NativeStream> _streams = {};
  final StreamController<LiteRtEvent> _global = StreamController.broadcast();

  /// Global events (trim memory, engine released).
  Stream<LiteRtEvent> get globalEvents {
    _ensureListening();
    return _global.stream;
  }

  void _ensureListening() {
    _sub ??= _backend.events().listen(_onBatch, onError: (Object _) {});
  }

  /// A new stream id with its listener. Register before starting the native
  /// work so no early batch is missed.
  NativeStream open() {
    _ensureListening();
    final id = _nextId++;
    final s = NativeStream._(id, this);
    _streams[id] = s;
    return s;
  }

  void _onBatch(EventBatch batch) {
    if (batch.streamId == 0) {
      for (final e in batch.events) {
        _global.add(e);
      }
      return;
    }
    _streams[batch.streamId]?._deliver(batch.events);
  }

  void _forget(int id) => _streams.remove(id);

  /// Streams still registered (tests).
  int get openStreams => _streams.length;

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    for (final s in _streams.values.toList()) {
      s._close();
    }
    await _global.close();
  }
}

/// One native stream's events, in order, ending after the terminal event.
final class NativeStream {
  NativeStream._(this.id, this._router) {
    _controller = StreamController<LiteRtEvent>(
      onPause: () {},
      onResume: _payOwed,
      onCancel: () => _router._forget(id),
    );
  }

  final int id;
  final LiteRtEventRouter _router;
  late final StreamController<LiteRtEvent> _controller;
  int _owed = 0;
  bool _ended = false;

  Stream<LiteRtEvent> get events => _controller.stream;

  void _deliver(List<LiteRtEvent> events) {
    if (_ended) return;
    var terminal = false;
    for (final e in events) {
      _controller.add(e);
      if (isTerminal(e)) {
        terminal = true;
        break;
      }
    }
    if (terminal) {
      _close();
      return;
    }
    if (_controller.isPaused) {
      _owed++;
    } else {
      _credit(1);
    }
  }

  void _payOwed() {
    if (_owed == 0 || _ended) return;
    final n = _owed;
    _owed = 0;
    _credit(n);
  }

  void _credit(int n) => unawaited(_router._backend.credit(id, n).catchError((Object _) {}));

  void _close() {
    if (_ended) return;
    _ended = true;
    _router._forget(id);
    unawaited(_controller.close());
  }

  /// Stops listening without waiting for the terminal event (after a cancel
  /// grace period).
  void abandon() => _close();
}
