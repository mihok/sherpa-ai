import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';

/// A job that runs until released (or preempted).
final class _Gate {
  final Completer<void> started = Completer();
  final Completer<void> release = Completer();
  bool emitOutput = false;
  int runs = 0;

  Future<String> body(InferenceJobContext ctx, String name) async {
    runs++;
    if (!started.isCompleted) started.complete();
    if (emitOutput) ctx.markOutput();
    await Future.any([release.future, ctx.preempt.whenCancelled]);
    if (ctx.preempt.isCancelled && !release.isCompleted) throw PreemptedException(ctx.preempt.reason ?? '');
    return name;
  }
}

void main() {
  group('InferenceScheduler', () {
    test('runs one job at a time in priority order, FIFO within a priority', () async {
      final s = InferenceScheduler();
      final order = <String>[];
      final gate = _Gate();
      final first = s.run(InferencePriority.background, (ctx) async {
        await gate.started.future;
        return 'warm';
      }, label: 'warm');
      // Hold the engine with a foreground job so the rest queue up.
      final blocker = s.run(InferencePriority.foreground, (ctx) => gate.body(ctx, 'blocker'), label: 'blocker');
      final jobs = [
        s.run(InferencePriority.background, (_) async => order.add('bg1'), label: 'bg1'),
        s.run(InferencePriority.toolFollowUp, (_) async => order.add('tool1'), label: 'tool1'),
        s.run(InferencePriority.foreground, (_) async => order.add('fg1'), label: 'fg1'),
        s.run(InferencePriority.toolFollowUp, (_) async => order.add('tool2'), label: 'tool2'),
        s.run(InferencePriority.foreground, (_) async => order.add('fg2'), label: 'fg2'),
      ];
      gate.started.complete();
      await first;
      await Future<void>.delayed(Duration.zero);
      expect(s.state.running.single.label, 'blocker');
      expect(s.state.queued.map((j) => j.label), ['fg1', 'fg2', 'tool1', 'tool2', 'bg1']);
      gate.release.complete();
      await blocker;
      await Future.wait(jobs);
      expect(order, ['fg1', 'fg2', 'tool1', 'tool2', 'bg1']);
      expect(s.state.isIdle, isTrue);
    });

    test('foreground preempts background; a job without output is re-queued transparently', () async {
      final s = InferenceScheduler();
      final bg = _Gate();
      final bgResult = s.run(InferencePriority.background, (ctx) async {
        if (bg.runs == 0) return bg.body(ctx, 'bg');
        return 'bg-rerun';
      }, label: 'compaction');
      await bg.started.future;
      final fg = s.run(InferencePriority.foreground, (_) async => 'fg', label: 'chat');
      expect(await fg, 'fg');
      expect(await bgResult, 'bg-rerun');
      expect(bg.runs, 1);
    });

    test('a preempted job that already produced output fails with PreemptedException', () async {
      final s = InferenceScheduler();
      final bg = _Gate()..emitOutput = true;
      final bgResult = s.run(InferencePriority.background, (ctx) => bg.body(ctx, 'bg'), label: 'summary');
      await bg.started.future;
      final fg = s.run(InferencePriority.foreground, (_) async => 'fg', label: 'chat');
      await expectLater(bgResult, throwsA(isA<PreemptedException>().having((e) => e.by, 'by', 'chat')));
      expect(await fg, 'fg');
    });

    test('the default policy never cancels a tool follow-up for another reply', () async {
      final s = InferenceScheduler();
      final tool = _Gate();
      final toolResult = s.run(InferencePriority.toolFollowUp, (ctx) => tool.body(ctx, 'tool'), label: 'tool');
      await tool.started.future;
      final fg = s.run(InferencePriority.foreground, (_) async => 'fg', label: 'chat');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(s.state.queued.single.label, 'chat');
      tool.release.complete();
      expect(await toolResult, 'tool');
      expect(await fg, 'fg');
    });

    test('a custom policy can preempt any less urgent work', () async {
      final s = InferenceScheduler(policy: (running, incoming) => incoming.isMoreUrgentThan(running));
      final tool = _Gate()..emitOutput = true;
      final toolResult = s.run(InferencePriority.toolFollowUp, (ctx) => tool.body(ctx, 'tool'), label: 'tool');
      await tool.started.future;
      final fg = s.run(InferencePriority.foreground, (_) async => 'fg', label: 'chat');
      await expectLater(toolResult, throwsA(isA<PreemptedException>()));
      expect(await fg, 'fg');
    });

    test('cancelling a queued job removes it', () async {
      final s = InferenceScheduler();
      final gate = _Gate();
      final running = s.run(InferencePriority.foreground, (ctx) => gate.body(ctx, 'a'), label: 'a');
      await gate.started.future;
      final token = CancellationToken();
      var ran = false;
      final queued = s.run(InferencePriority.foreground, (_) async => ran = true, label: 'b', cancel: token);
      expect(s.state.queued.single.label, 'b');
      token.cancel('user');
      await expectLater(queued, throwsA(isA<CancelledException>()));
      expect(s.state.queued, isEmpty);
      gate.release.complete();
      await running;
      expect(ran, isFalse);
      await expectLater(
          s.run(InferencePriority.foreground, (_) async => 1, cancel: token), throwsA(isA<CancelledException>()));
    });

    test('publishes state changes for the UI', () async {
      final s = InferenceScheduler();
      final states = <SchedulerState>[];
      final sub = s.changes.listen(states.add);
      await s.run(InferencePriority.background, (_) async => 1, label: 'x');
      await Future<void>.delayed(Duration.zero);
      expect(states.any((st) => st.running.any((j) => j.label == 'x' && j.startedAt != null)), isTrue);
      expect(states.last.isIdle, isTrue);
      await sub.cancel();
      await s.dispose();
    });

    test('errors propagate unchanged', () async {
      final s = InferenceScheduler();
      await expectLater(s.run(InferencePriority.foreground, (_) async => throw StateError('boom')), throwsStateError);
      expect(await s.run(InferencePriority.foreground, (_) async => 2), 2, reason: 'the slot was freed');
    });
  });
}
