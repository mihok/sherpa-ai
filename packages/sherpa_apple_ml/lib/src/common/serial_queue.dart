import 'dart:async';

import 'package:sherpa_core/sherpa_core.dart';

/// Runs jobs one at a time, in order. A job whose token is cancelled while
/// it waits is skipped (its future fails with [CancelledException] at once);
/// once started, a job handles cancellation itself.
final class SerialQueue {
  Future<void> _tail = Future<void>.value();
  int _waiting = 0;

  /// Jobs queued or running.
  int get length => _waiting;

  Future<T> run<T>(Future<T> Function() job, {CancellationToken? cancel}) {
    final done = Completer<T>();
    var started = false;
    final previous = _tail;
    _waiting++;
    final mine = () async {
      try {
        await previous;
      } on Object {
        // a failed job does not block the next one
      }
      if (done.isCompleted) return; // cancelled while queued
      started = true;
      try {
        done.complete(await job());
      } on Object catch (e, st) {
        if (!done.isCompleted) done.completeError(e, st);
      }
    }();
    _tail = mine.whenComplete(() => _waiting--);
    if (cancel != null) {
      unawaited(
        cancel.whenCancelled.then((reason) {
          if (!started && !done.isCompleted) done.completeError(CancelledException(reason));
        }),
      );
    }
    return done.future;
  }
}
