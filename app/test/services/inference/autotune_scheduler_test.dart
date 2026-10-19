import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/services/inference/autotune_scheduler.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';

import 'support/local_rig.dart' show until;

/// A sweep that runs until released or cancelled.
final class FakeSweep {
  final List<String> started = [];
  final List<CancellationToken> tokens = [];
  Completer<bool> release = Completer<bool>();
  Object? failWith;

  Future<bool> run(String modelId, CancellationToken cancel) async {
    started.add(modelId);
    tokens.add(cancel);
    final f = failWith;
    if (f != null) throw f;
    final r = await Future.any([release.future, cancel.whenCancelled.then<bool>((_) => throw const CancelledException())]);
    return r;
  }
}

void main() {
  late InferenceScheduler scheduler;
  late FakeSweep sweep;
  late AutotuneScheduler tune;
  var tuned = <String>{};

  AutotuneScheduler build({AutotunePolicy policy = const AutotunePolicy(quietPeriod: Duration(milliseconds: 20))}) =>
      AutotuneScheduler(scheduler: scheduler, run: sweep.run, isTuned: (id) async => tuned.contains(id), policy: policy);

  setUp(() {
    scheduler = InferenceScheduler();
    sweep = FakeSweep();
    tuned = {};
    tune = build();
  });

  tearDown(() async {
    if (!sweep.release.isCompleted) sweep.release.complete(true);
    await tune.dispose();
    await scheduler.dispose();
  });

  test('starts only after a quiet period on an idle scheduler, as background work', () async {
    final user = Completer<void>();
    final job = scheduler.run(InferencePriority.foreground, (_) => user.future, label: 'user reply');
    tune.onReplySucceeded('m1');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(sweep.started, isEmpty, reason: 'the engine is busy with a reply');

    user.complete();
    await job;
    await until(() => sweep.started.isNotEmpty);
    expect(scheduler.state.running.single.priority, InferencePriority.background);
    expect(scheduler.state.running.single.label, 'autotune m1');
    sweep.release.complete(true);
    await tune.idle;
    expect(tune.isRunning, isFalse);

    // Done for this model.
    tune.onReplySucceeded('m1');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(sweep.started, ['m1']);
  });

  test('a more urgent job preempts the sweep (cancelled), and it is retried after the next reply', () async {
    tune.onReplySucceeded('m1');
    await until(() => sweep.started.isNotEmpty);
    final reply = scheduler.run(InferencePriority.foreground, (_) async => 'answer', label: 'user reply');
    await until(() => sweep.tokens.single.isCancelled); // preemption cancels the bench
    expect(await reply, 'answer');
    // The reply succeeded while the cancelled sweep drained: try again.
    tune.onReplySucceeded('m1');
    await until(() => sweep.started.length == 2);
    expect(sweep.tokens.last.isCancelled, isFalse);
  });

  test('cancel() stops a waiting and a running sweep', () async {
    tune.onReplySucceeded('m1');
    tune.cancel('user request');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sweep.started, isEmpty);
    expect(tune.pendingModel, isNull);

    tune.onReplySucceeded('m1');
    await until(() => sweep.started.isNotEmpty);
    tune.cancel('app in background');
    expect(sweep.tokens.single.isCancelled, isTrue);
    await tune.idle;
    expect(tune.pendingModel, isNull);
  });

  test('skips models with a tune record, and gives up after a failure', () async {
    tuned.add('m1');
    tune.onReplySucceeded('m1');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sweep.started, isEmpty);

    sweep.failWith = const EngineException(-3, 'out of memory');
    tune.onReplySucceeded('m2');
    await until(() => sweep.started.isNotEmpty);
    await tune.idle;
    tune.onReplySucceeded('m2');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sweep.started, ['m2'], reason: 'not retried in this process');
  });

  test('a sweep that chose not to run (hot device) is retried after the next reply', () async {
    tune.onReplySucceeded('m1');
    await until(() => sweep.started.isNotEmpty);
    sweep.release.complete(false);
    await tune.idle;
    sweep.release = Completer<bool>();
    tune.onReplySucceeded('m1');
    await until(() => sweep.started.length == 2);
  });

  test('a disabled policy never runs', () async {
    await tune.dispose();
    tune = build(policy: AutotunePolicy.off);
    tune.onReplySucceeded('m1');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sweep.started, isEmpty);
  });
}
