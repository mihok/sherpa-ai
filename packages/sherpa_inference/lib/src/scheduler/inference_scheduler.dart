import 'dart:async';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

/// Who is waiting for the result. Lower index = more urgent.
enum InferencePriority {
  /// A reply the user is watching (first model call after a user message).
  foreground,

  /// The next step of an agent run after tool results came back.
  toolFollowUp,

  /// Compaction, summaries, embeddings, autotune: nobody is watching.
  background;

  bool isMoreUrgentThan(InferencePriority other) => index < other.index;
}

/// Thrown into a job's code path when the scheduler preempted it.
final class PreemptedException implements Exception {
  const PreemptedException(this.by);

  /// Label of the job that took the engine.
  final String by;

  @override
  String toString() => 'PreemptedException: preempted by $by';
}

/// Decides whether an [incoming] job may cancel a [running] one.
typedef PreemptionPolicy = bool Function(InferencePriority running, InferencePriority incoming);

/// Default: anything more urgent than background preempts background work;
/// a tool follow-up is never cancelled for another conversation's
/// foreground reply (it would only be retried, wasting its prefill), it just
/// yields at the next queue decision.
bool defaultPreemptionPolicy(InferencePriority running, InferencePriority incoming) =>
    running == InferencePriority.background && incoming.isMoreUrgentThan(running);

enum SchedulerJobState { queued, running }

/// UI-facing description of one job.
@immutable
final class SchedulerJobInfo {
  const SchedulerJobInfo({
    required this.id,
    required this.label,
    required this.priority,
    required this.state,
    required this.enqueuedAt,
    this.startedAt,
    this.preemptions = 0,
  });

  final int id;
  final String label;
  final InferencePriority priority;
  final SchedulerJobState state;
  final DateTime enqueuedAt;
  final DateTime? startedAt;

  /// Times this job was preempted and transparently re-queued.
  final int preemptions;
}

/// Snapshot of the queue for the UI ("waiting for the model…").
@immutable
final class SchedulerState {
  const SchedulerState({required this.running, required this.queued});

  static const idle = SchedulerState(running: [], queued: []);

  final List<SchedulerJobInfo> running;

  /// In the order they will run.
  final List<SchedulerJobInfo> queued;

  bool get isIdle => running.isEmpty && queued.isEmpty;
}

/// Handed to a running job.
final class InferenceJobContext {
  InferenceJobContext._(this.priority, this.label, this.preempt);

  final InferencePriority priority;
  final String label;

  /// Cancelled when the scheduler preempts this job. The job must stop its
  /// engine work promptly (se_cancel is observed between tokens) and throw
  /// [PreemptedException].
  final CancellationToken preempt;

  bool _hasOutput = false;

  /// Marks that the job delivered partial output to its consumer; from now
  /// on a preemption cannot be hidden by re-running it.
  void markOutput() => _hasOutput = true;

  bool get hasOutput => _hasOutput;
}

/// One queue for the single on-device engine.
///
/// The engine decodes one generation at a time well (a phone has 4–8
/// performance cores; two concurrent decodes halve each other's speed and
/// double KV memory), so [maxConcurrent] defaults to 1 and the queue orders
/// work by [InferencePriority], FIFO within a priority. When a more urgent
/// job arrives and [PreemptionPolicy] allows it, the running job's
/// [InferenceJobContext.preempt] token is cancelled; because `se_cancel` is
/// prompt (between tokens and inside prefill chunks) this really frees the
/// cores within milliseconds. A preempted job that had not produced output
/// yet is re-queued transparently; otherwise its [run] fails with
/// [PreemptedException] (the provider maps it to a retryable error).
final class InferenceScheduler {
  InferenceScheduler({this.maxConcurrent = 1, PreemptionPolicy? policy, Clock clock = const SystemClock()})
      : _policy = policy ?? defaultPreemptionPolicy,
        _clock = clock;

  final int maxConcurrent;
  final PreemptionPolicy _policy;
  final Clock _clock;

  final List<_Job<Object?>> _queue = [];
  final List<_Job<Object?>> _running = [];
  final StreamController<SchedulerState> _changes = StreamController.broadcast();
  int _nextId = 1;

  Stream<SchedulerState> get changes => _changes.stream;

  SchedulerState get state => SchedulerState(
        running: [for (final j in _running) j.info(SchedulerJobState.running)],
        queued: [for (final j in _queue) j.info(SchedulerJobState.queued)],
      );

  /// Runs [job] when the engine is free for [priority]. [cancel] removes a
  /// queued job (the future fails with [CancelledException]) and is passed
  /// through to a running one via the job's own token handling.
  Future<T> run<T>(
    InferencePriority priority,
    Future<T> Function(InferenceJobContext ctx) job, {
    String label = 'inference',
    CancellationToken? cancel,
  }) {
    if (cancel?.isCancelled ?? false) return Future.error(CancelledException(cancel!.reason ?? 'cancelled'));
    final j = _Job<T>(_nextId++, priority, label, job, _clock.now());
    _enqueue(j);
    if (cancel != null) {
      unawaited(cancel.whenCancelled.then((reason) {
        if (_queue.remove(j)) {
          j.completer.completeError(CancelledException(reason));
          _publish();
        }
      }));
    }
    _pump();
    return j.completer.future;
  }

  void _enqueue(_Job<Object?> j, {bool front = false}) {
    var at = _queue.length;
    for (var i = 0; i < _queue.length; i++) {
      final q = _queue[i];
      if (j.priority.isMoreUrgentThan(q.priority) || (front && q.priority == j.priority)) {
        at = i;
        break;
      }
    }
    _queue.insert(at, j);
  }

  void _pump() {
    while (_queue.isNotEmpty && _running.length < maxConcurrent) {
      _start(_queue.removeAt(0));
    }
    if (_queue.isNotEmpty) {
      final next = _queue.first;
      for (final r in _running) {
        if (!r.ctx.preempt.isCancelled && _policy(r.priority, next.priority)) {
          r.preemptedBy = next.label;
          r.ctx.preempt.cancel('preempted by ${next.label}');
          break;
        }
      }
    }
    _publish();
  }

  void _start(_Job<Object?> j) {
    _running.add(j);
    j.startedAt = _clock.now();
    j.ctx = InferenceJobContext._(j.priority, j.label, CancellationToken());
    unawaited(_execute(j));
  }

  Future<void> _execute(_Job<Object?> j) async {
    try {
      final v = await j.body(j.ctx);
      _running.remove(j);
      j.completer.complete(v);
    } on Object catch (e, st) {
      _running.remove(j);
      final preempted = j.ctx.preempt.isCancelled;
      if (preempted && !j.ctx.hasOutput) {
        j.preemptions++;
        j.preemptedBy = null;
        _enqueue(j, front: true);
      } else if (preempted && e is! PreemptedException && e is! CancelledException) {
        j.completer.completeError(e, st);
      } else if (preempted) {
        j.completer.completeError(PreemptedException(j.preemptedBy ?? 'a more urgent job'), st);
      } else {
        j.completer.completeError(e, st);
      }
    }
    _pump();
  }

  void _publish() {
    if (!_changes.isClosed && _changes.hasListener) _changes.add(state);
  }

  Future<void> dispose() => _changes.close();
}

final class _Job<T> {
  _Job(this.id, this.priority, this.label, this.body, this.enqueuedAt);

  final int id;
  final InferencePriority priority;
  final String label;
  final Future<T> Function(InferenceJobContext ctx) body;
  final DateTime enqueuedAt;
  final Completer<T> completer = Completer<T>();
  late InferenceJobContext ctx;
  DateTime? startedAt;
  int preemptions = 0;
  String? preemptedBy;

  SchedulerJobInfo info(SchedulerJobState s) => SchedulerJobInfo(
        id: id,
        label: label,
        priority: priority,
        state: s,
        enqueuedAt: enqueuedAt,
        startedAt: s == SchedulerJobState.running ? startedAt : null,
        preemptions: preemptions,
      );
}
