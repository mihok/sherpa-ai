import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, immutable, visibleForTesting;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';

/// When first-use tuning runs.
@immutable
final class AutotunePolicy {
  const AutotunePolicy({this.enabled = true, this.quietPeriod = const Duration(seconds: 20)});

  /// Never tune (tests, power users who pinned overrides).
  static const AutotunePolicy off = AutotunePolicy(enabled: false);

  final bool enabled;

  /// How long the engine must stay idle after a reply before tuning starts:
  /// a user reading the answer often types the next message within
  /// seconds, and a sweep started then would only be preempted.
  final Duration quietPeriod;
}

/// What tuning one model means: `lifecycle.autotune(id, cancel:)`. Returns
/// false when it chose not to run (hot device, battery saver), so the next
/// reply tries again.
typedef AutotuneRun = Future<bool> Function(String modelId, CancellationToken cancel);

/// Schedules the first-use `se_bench` sweep ([ModelLifecycleManager.autotune])
/// as background work.
///
/// * **Trigger:** the first successful reply on a model with no tune record
///   ([onReplySucceeded]); models already tuned in this environment are
///   skipped ([isTuned] reads the persisted profile).
/// * **Only when idle:** the job is submitted to the provider's
///   [InferenceScheduler] at [InferencePriority.background] after
///   [AutotunePolicy.quietPeriod] of an idle scheduler. The scheduler runs
///   one job at a time and starts background work only when nothing more
///   urgent is queued, so a sweep never overlaps a generation.
/// * **Cancellable:** a more urgent job preempts it (the scheduler cancels
///   the job's token, which cancels `se_bench` between runs), as do
///   [cancel] (a user request, the app going to the background) and
///   [dispose]. A cancelled sweep is retried after the next successful reply.
final class AutotuneScheduler {
  AutotuneScheduler({
    required InferenceScheduler scheduler,
    required AutotuneRun run,
    required Future<bool> Function(String modelId) isTuned,
    this.policy = const AutotunePolicy(),
  })  : _scheduler = scheduler,
        _run = run,
        _isTuned = isTuned;

  final InferenceScheduler _scheduler;
  final AutotuneRun _run;
  final Future<bool> Function(String modelId) _isTuned;
  final AutotunePolicy policy;

  /// Tuned (or given up on) in this process.
  final Set<String> _settled = {};
  String? _pending;
  Timer? _timer;
  StreamSubscription<SchedulerState>? _idleSub;
  CancellationToken? _token;
  Future<void>? _job;
  bool _retryAfterJob = false;
  bool _disposed = false;

  /// The model waiting for (or running) its sweep.
  String? get pendingModel => _pending;

  /// True while the sweep job is submitted or running.
  bool get isRunning => _job != null;

  /// Completes when the current sweep job ends (tests).
  @visibleForTesting
  Future<void> get idle => _job ?? Future<void>.value();

  /// A user-facing reply on [modelId] finished successfully.
  void onReplySucceeded(String modelId) {
    if (!policy.enabled || _disposed || _settled.contains(modelId)) return;
    if (_pending != null) {
      // A sweep that was just cancelled is still draining: try again once
      // it has.
      if (_pending == modelId && (_token?.isCancelled ?? false)) _retryAfterJob = true;
      return;
    }
    _pending = modelId;
    unawaited(_checkThenArm(modelId));
  }

  Future<void> _checkThenArm(String modelId) async {
    bool tuned;
    try {
      tuned = await _isTuned(modelId);
    } on Object {
      tuned = false;
    }
    if (_pending != modelId || _disposed) return;
    if (tuned) {
      _settled.add(modelId);
      _pending = null;
      return;
    }
    _arm();
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer(policy.quietPeriod, _fire);
  }

  void _fire() {
    _timer = null;
    final id = _pending;
    if (id == null || _disposed) return;
    if (!_scheduler.state.isIdle) {
      // Busy: wait for the queue to drain, then a fresh quiet period.
      unawaited(_idleSub?.cancel());
      _idleSub = _scheduler.changes.where((s) => s.isIdle).take(1).listen((_) {
        _idleSub = null;
        if (_pending == id && !_disposed) _arm();
      });
      return;
    }
    final token = _token = CancellationToken();
    final job = _scheduler.run<bool>(
      InferencePriority.background,
      (ctx) async {
        // A preempted job is re-queued by the scheduler; once cancelled this
        // sweep waits for the next successful reply instead.
        token.throwIfCancelled();
        // Preemption by the scheduler cancels the sweep like [cancel] does.
        unawaited(ctx.preempt.whenCancelled.then(token.cancel));
        return _run(id, token);
      },
      label: 'autotune $id',
      cancel: token,
    );
    _job = job.then((ran) {
      if (ran) _settled.add(id);
    }, onError: (Object e) {
      if (!_isCancellation(e)) {
        // A model that can't be benched now (admission refused, engine
        // error) is not retried in this process: tuning is optional.
        debugPrint('autotune $id skipped: ${e.runtimeType}');
        _settled.add(id);
      }
    }).whenComplete(() {
      if (identical(_token, token)) _token = null;
      _job = null;
      if (_pending == id) _pending = null;
      if (_retryAfterJob) {
        _retryAfterJob = false;
        onReplySucceeded(id);
      }
    });
  }

  static bool _isCancellation(Object e) =>
      e is CancelledException || e is PreemptedException || (e is EngineException && e.codeName == 'SE_ERR_CANCELLED');

  /// Stops a waiting or running sweep (it is retried after the next
  /// successful reply).
  void cancel([String reason = 'cancelled']) {
    _retryAfterJob = false;
    _timer?.cancel();
    _timer = null;
    unawaited(_idleSub?.cancel());
    _idleSub = null;
    _token?.cancel(reason);
    if (_job == null) _pending = null;
  }

  Future<void> dispose() async {
    _disposed = true;
    cancel('disposed');
    await idle;
  }
}
