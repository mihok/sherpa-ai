import 'dart:async';

import 'package:sherpa_core/sherpa_core.dart';

/// A one-shot signal that aborts an in-flight HTTP exchange.
///
/// It is the bridge between Sherpa's [CancellationToken] / subscription
/// cancellation and `package:http`'s `AbortableRequest.abortTrigger`, which
/// tears down the socket so a remote server stops generating (and billing)
/// and a local one frees its slot.
final class AbortSignal {
  final Completer<void> _completer = Completer<void>();

  bool get isAborted => _completer.isCompleted;

  /// Completes when [abort] is called; never errors (required by
  /// `AbortableRequest`).
  Future<void> get future => _completer.future;

  void abort() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

/// Wraps a provider's streaming body into the [ModelProvider.stream]
/// contract:
///
/// * cold: [body] runs only when the stream is listened to;
/// * a cancelled [cancel] token aborts the HTTP request and ends the stream
///   with `Finish(FinishReason.cancelled)` instead of an error;
/// * cancelling the subscription aborts the request too, without waiting
///   for the body to notice (an `async*` body parked on an `await` would
///   otherwise delay `cancel()` until the next server chunk);
/// * pause/resume is forwarded, so an `async*` body stops at its next
///   `yield` and its `await for` stops reading the socket (backpressure).
///
/// [body] is expected to be an `async*` generator that throws
/// [ProviderException]s for failures and simply returns once [AbortSignal]
/// fired.
Stream<ModelEvent> guardModelStream(
  Stream<ModelEvent> Function(AbortSignal abort) body, {
  CancellationToken? cancel,
}) {
  late final StreamController<ModelEvent> out;
  // Cancelled in detachInner (on token cancel or subscription cancel) or
  // dropped once the body completes.
  // ignore: cancel_subscriptions
  StreamSubscription<ModelEvent>? inner;
  final abort = AbortSignal();
  var finished = false;

  void detachInner() {
    abort.abort();
    final s = inner;
    inner = null;
    // Not awaited: the body may be parked on a socket read that only ends
    // once the abort propagates, and stream consumers must not hang on it.
    // Errors raised while it unwinds (the abort itself) have no listener
    // left and are dropped.
    s?.cancel().ignore();
  }

  void endCancelled() {
    if (finished) return;
    finished = true;
    detachInner();
    out.add(const Finish(FinishReason.cancelled));
    unawaited(out.close());
  }

  out = StreamController<ModelEvent>(
    onListen: () {
      final token = cancel;
      if (token != null && token.isCancelled) {
        endCancelled();
        return;
      }
      // `CancellationToken.none` never fires; registering on it would pin
      // this closure for the life of the process.
      if (token != null && !identical(token, CancellationToken.none)) {
        unawaited(token.whenCancelled.then((_) => endCancelled()));
      }
      inner = body(abort).listen(
        (e) {
          if (!finished) out.add(e);
        },
        onError: (Object e, StackTrace st) {
          if (finished) return;
          if (e is CancelledException) {
            endCancelled();
          } else {
            out.addError(e, st);
          }
        },
        onDone: () {
          if (finished) return;
          finished = true;
          inner = null;
          unawaited(out.close());
        },
      );
    },
    onPause: () => inner?.pause(),
    onResume: () => inner?.resume(),
    onCancel: () {
      finished = true;
      detachInner();
    },
  );
  return out.stream;
}
