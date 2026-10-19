import 'dart:async';

import '../backend.dart';
import '../messages.pigeon.dart';

/// Demultiplexes the one native event stream into per-generation routes and
/// returns flow-control credits.
///
/// Credits: Swift keeps at most [kMaxOutstandingBatches] batches per
/// generation in flight and coalesces text natively while it waits. A route
/// hands each batch to its listener, which calls [GenerationRoute.ack] when
/// the batch has been consumed. Consumers withhold acks while their own
/// subscriber is paused, which is what bounds the channel buffer.
final class EventRouter {
  EventRouter(this._backend);

  /// The router shared by every provider on [backend] (there is one native
  /// event stream; two routers would each see the other's batches). Pair
  /// with [release].
  static EventRouter acquire(AppleMlBackend backend) {
    final r = _shared[backend] ??= EventRouter(backend);
    r._refs++;
    return r;
  }

  static final Expando<EventRouter> _shared = Expando('sherpa_apple_ml.EventRouter');

  /// Mirrors `EventPump.maxOutstanding` in Swift.
  static const int kMaxOutstandingBatches = 4;

  final AppleMlBackend _backend;
  final Map<String, GenerationRoute> _routes = {};

  /// Recently closed generations whose late batches are still acked (so
  /// the native pump can finish); bounded.
  final Set<String> _closed = <String>{};
  int _refs = 0;
  final StreamController<AmEvent> _global = StreamController<AmEvent>.broadcast(sync: true);
  StreamSubscription<AmEventBatch>? _sub;

  /// Events not tied to a generation (memory warnings, lifecycle changes).
  Stream<AmEvent> get global {
    _ensureListening();
    return _global.stream;
  }

  void _ensureListening() {
    _sub ??= _backend.events().listen(_onBatch, onError: _onError);
  }

  /// Opens the route for [generationId] before the native call is made, so
  /// no early batch is lost.
  GenerationRoute open(String generationId) {
    _ensureListening();
    final route = GenerationRoute._(this, generationId);
    _routes[generationId] = route;
    return route;
  }

  void _onBatch(AmEventBatch batch) {
    if (batch.generationId.isEmpty) {
      for (final e in batch.events) {
        _global.add(e);
      }
      return;
    }
    final route = _routes[batch.generationId];
    if (route == null) {
      // Late batch of a generation this router closed: return the credit so
      // the native pump can finish and free its state. Unknown ids are not
      // ours to ack.
      if (_closed.contains(batch.generationId)) _ack(batch.generationId, batch.seq);
      return;
    }
    route._deliver(batch);
  }

  void _onError(Object error) {
    for (final r in [..._routes.values]) {
      r._fail(error);
    }
  }

  void _ack(String generationId, int seq) {
    unawaited(_backend.ack(generationId, seq).catchError((Object _) {}));
  }

  void _closedRoute(String generationId) {
    _routes.remove(generationId);
    _closed.add(generationId);
    if (_closed.length > 256) _closed.remove(_closed.first);
  }

  /// Drops one [acquire] reference; the last one disposes the router.
  Future<void> release() async {
    if (--_refs > 0) return;
    if (_shared[_backend] == this) _shared[_backend] = null;
    await dispose();
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    if (!_global.isClosed) await _global.close();
  }
}

/// The events of one native generation.
final class GenerationRoute {
  GenerationRoute._(this._router, this.generationId);

  final EventRouter _router;
  final String generationId;
  void Function(AmEventBatch batch)? _onBatch;
  void Function(Object error)? _onError;
  final List<AmEventBatch> _early = [];
  Object? _earlyError;
  bool _closed = false;

  bool get isClosed => _closed;

  /// Attaches the (only) consumer; batches that arrived first are replayed.
  void listen(void Function(AmEventBatch batch) onBatch, {required void Function(Object error) onError}) {
    _onBatch = onBatch;
    _onError = onError;
    final early = [..._early];
    _early.clear();
    for (final b in early) {
      onBatch(b);
    }
    final err = _earlyError;
    if (err != null) onError(err);
  }

  void _deliver(AmEventBatch batch) {
    if (_closed) {
      _router._ack(generationId, batch.seq);
      return;
    }
    final l = _onBatch;
    if (l == null) {
      _early.add(batch);
    } else {
      l(batch);
    }
  }

  void _fail(Object error) {
    if (_closed) return;
    final l = _onError;
    if (l == null) {
      _earlyError = error;
    } else {
      l(error);
    }
  }

  /// Returns the credit for batch [seq].
  void ack(int seq) => _router._ack(generationId, seq);

  /// Detaches; later batches are acked and dropped.
  void close() {
    if (_closed) return;
    _closed = true;
    _router._closedRoute(generationId);
    for (final b in _early) {
      _router._ack(generationId, b.seq);
    }
    _early.clear();
  }
}

/// Holds back credits while a consumer is paused (or detached).
final class CreditGate {
  CreditGate(this._route);

  final GenerationRoute _route;
  final List<int> _held = [];
  bool _holding = false;

  bool get holding => _holding;

  void consumed(int seq) {
    if (_holding) {
      _held.add(seq);
    } else {
      _route.ack(seq);
    }
  }

  void hold() => _holding = true;

  void release() {
    _holding = false;
    final held = [..._held];
    _held.clear();
    for (final s in held) {
      _route.ack(s);
    }
  }
}
