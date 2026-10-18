import 'dart:async';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:test/test.dart';

/// Configurable in-process tool for loop tests.
final class FakeTool implements LocalTool {
  FakeTool(
    this.name, {
    this.annotations = const ToolAnnotations(readOnlyHint: true, openWorldHint: false),
    this.onRun,
  });

  final String name;
  final ToolAnnotations annotations;
  final Future<ToolResult> Function(Map<String, Object?> args, ToolExecutionContext ctx)? onRun;
  final List<Map<String, Object?>> calls = [];
  int running = 0;
  int maxConcurrent = 0;

  @override
  ToolDefinition get definition => ToolDefinition(
        name: name,
        description: 'test tool $name',
        inputSchema: const {'type': 'object'},
        annotations: annotations,
      );

  @override
  Future<ToolResult> run(Map<String, Object?> arguments, ToolExecutionContext context) async {
    calls.add(arguments);
    running++;
    if (running > maxConcurrent) maxConcurrent = running;
    try {
      if (onRun != null) return await onRun!(arguments, context);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return ToolResult.text('$name ok ${arguments['n'] ?? ''}'.trim());
    } finally {
      running--;
    }
  }
}

final class RecordingApprovals implements ApprovalHandler {
  RecordingApprovals(this.decision);
  final UserDecision decision;
  final List<String> asked = [];

  @override
  Future<ApprovalResponse> requestApproval({
    required String sessionId,
    required ToolCall call,
    required ToolDefinition? tool,
    required NeedsConfirmation requirement,
    required CancellationToken cancel,
  }) async {
    asked.add(call.name);
    return ApprovalResponse(decision);
  }
}

/// Approval handler that blocks until cancelled (simulates an open sheet).
final class HangingApprovals implements ApprovalHandler {
  final Completer<void> asked = Completer();

  @override
  Future<ApprovalResponse> requestApproval({
    required String sessionId,
    required ToolCall call,
    required ToolDefinition? tool,
    required NeedsConfirmation requirement,
    required CancellationToken cancel,
  }) async {
    if (!asked.isCompleted) asked.complete();
    await cancel.whenCancelled;
    return const ApprovalResponse(UserDecision.deny);
  }
}

class Harness {
  Harness(
    List<ScriptedTurn> turns, {
    List<LocalTool> tools = const [],
    ApprovalHandler? handler,
    AgentConfig config = const AgentConfig(),
    ModelCapabilities caps = const ModelCapabilities(contextLength: 32768),
    Duration eventDelay = Duration.zero,
    bool withPlanTool = false,
  }) : provider = ScriptedProvider(turns, capabilitiesValue: caps, eventDelay: eventDelay) {
    router = LocalToolRouter([
      ...tools,
      if (withPlanTool) UpdatePlanTool(store: store, clock: clock),
    ]);
    runner = AgentRunner(
      store: store,
      provider: provider,
      modelId: 'scripted-model',
      tools: router,
      approvals: ApprovalPolicy(clock: clock),
      approvalHandler: handler ?? const StaticApprovalHandler.approveAll(),
      clock: clock,
      ids: ids,
      config: config,
      sleep: (_) async {},
    );
  }

  final store = InMemorySessionStore();
  final clock = FakeClock();
  final ids = SequentialIdGenerator();
  final ScriptedProvider provider;
  late final LocalToolRouter router;
  late final AgentRunner runner;

  Future<SessionRecord> newSession() => store.putSession(SessionRecord(
        id: 's1',
        title: defaultSessionTitle,
        createdAt: clock.now(),
        updatedAt: clock.now(),
      ));

  Future<List<AgentEvent>> send(String text, {String? parentId}) async {
    await store.getSession('s1') ?? await newSession();
    return runner.send('s1', [TextPart(text)], parentId: parentId).toList();
  }

  Future<List<Message>> activePath() async {
    final s = await store.getSession('s1');
    return store.path('s1', s!.activeLeafId!);
  }
}

RunFinished finished(List<AgentEvent> events) => events.whereType<RunFinished>().single;

/// Asserts the provider-facing invariant: every tool call on the path is
/// answered by the next message before anything else happens.
void expectPairing(List<Message> path) {
  for (final (i, m) in path.indexed) {
    if (!m.hasToolCalls) continue;
    expect(i + 1, lessThan(path.length), reason: 'tool calls at end of path');
    final next = path[i + 1];
    expect(next.role, Role.tool);
    expect(next.toolResults.map((r) => r.callId).toSet(), m.toolCalls.map((c) => c.id).toSet());
  }
}

void main() {
  test('text reply: streams, persists, titles the session, checkpoints finished', () async {
    final h = Harness([ScriptedTurn.text('Hello there, traveller.')]);
    final events = await h.send('Say hello please');
    expect(events.first, isA<RunStarted>());
    expect(finished(events).outcome, RunOutcome.completed);
    final deltas = events.whereType<ModelStreamed>().map((e) => e.event).whereType<TextDelta>();
    expect(deltas.map((d) => d.text).join(), 'Hello there, traveller.');
    final path = await h.activePath();
    expect(path.map((m) => m.role), [Role.user, Role.assistant]);
    expect(path.last.text, 'Hello there, traveller.');
    expect(path.last.finishReason, 'stop');
    expect((await h.store.getSession('s1'))!.title, 'Say hello please');
    expect((await h.store.getCheckpoint('s1'))!.phase, RunPhase.finished);
    final req = h.provider.requests.single;
    expect(req.systemPrompt, contains('Trust boundary'));
    expect(req.messages.single.text, 'Say hello please');
  });

  test('tool loop: call → result → final answer, result visible to the model', () async {
    final tool = FakeTool('lookup');
    final h = Harness([
      ScriptedTurn.toolCalls([const ToolCall(id: 'c1', name: 'lookup', arguments: {'n': 1})]),
      ScriptedTurn.text('Done.'),
    ], tools: [tool]);
    final events = await h.send('look it up');
    expect(finished(events).outcome, RunOutcome.completed);
    expect(tool.calls, [
      {'n': 1}
    ]);
    final path = await h.activePath();
    expect(path.map((m) => m.role), [Role.user, Role.assistant, Role.tool, Role.assistant]);
    expectPairing(path);
    final second = h.provider.requests[1];
    expect(second.messages.last.toolResults.single.text, 'lookup ok 1');
    expect(second.tools.single.name, 'lookup');
    expect(events.whereType<ToolCallFinished>().single.call.id, 'c1');
  });

  test('parallel calls run concurrently and results keep call order', () async {
    final tool = FakeTool('work', onRun: (args, _) async {
      // Later calls finish first.
      await Future<void>.delayed(Duration(milliseconds: 30 - 10 * (args['n']! as int)));
      return ToolResult.text('r${args['n']}');
    });
    final h = Harness([
      ScriptedTurn.toolCalls([
        for (var i = 0; i < 3; i++) ToolCall(id: 'c$i', name: 'work', arguments: {'n': i}),
      ]),
      ScriptedTurn.text('ok'),
    ], tools: [tool]);
    await h.send('go');
    expect(tool.maxConcurrent, 3);
    final toolMsg = (await h.activePath())[2];
    expect(toolMsg.toolResults.map((r) => r.text), ['r0', 'r1', 'r2']);
  });

  test('parallelism is bounded by maxParallelTools', () async {
    final tool = FakeTool('work');
    final h = Harness([
      ScriptedTurn.toolCalls([for (var i = 0; i < 6; i++) ToolCall(id: 'c$i', name: 'work', arguments: {'n': i})]),
      ScriptedTurn.text('ok'),
    ], tools: [tool], config: const AgentConfig(maxParallelTools: 2));
    await h.send('go');
    expect(tool.calls, hasLength(6));
    expect(tool.maxConcurrent, 2);
  });

  test('destructive tool asks; a denial is reported to the model', () async {
    final tool = FakeTool('delete', annotations: const ToolAnnotations(destructiveHint: true));
    final approvals = RecordingApprovals(UserDecision.deny);
    final h = Harness([
      ScriptedTurn.toolCalls([const ToolCall(id: 'c1', name: 'delete', arguments: {})]),
      ScriptedTurn.text('Understood, not deleting.'),
    ], tools: [tool], handler: approvals);
    final events = await h.send('delete it');
    expect(approvals.asked, ['delete']);
    expect(tool.calls, isEmpty);
    expect(events.whereType<ToolApprovalRequested>().single.requirement.risk, RiskLevel.destructive);
    final result = (await h.activePath())[2].toolResults.single;
    expect(result.isError, isTrue);
    expect(result.text, contains('declined'));
    final audit = await h.store.audit('s1');
    expect(audit.where((a) => a.kind == AuditKind.approval).single.summary, contains('declined'));
  });

  test('read-only closed-world tools auto-run without asking', () async {
    final approvals = RecordingApprovals(UserDecision.deny);
    final h = Harness([
      ScriptedTurn.toolCalls([const ToolCall(id: 'c1', name: 'peek', arguments: {})]),
      ScriptedTurn.text('ok'),
    ], tools: [FakeTool('peek')], handler: approvals);
    await h.send('peek');
    expect(approvals.asked, isEmpty);
  });

  test('invalid arguments and unknown tools become error results, not crashes', () async {
    final h = Harness([
      ScriptedTurn.toolCalls(const [
        ToolCall(id: 'bad', name: 'peek', arguments: {}, argumentsError: 'unterminated string'),
        ToolCall(id: 'ghost', name: 'nope', arguments: {}),
      ]),
      ScriptedTurn.text('sorry'),
    ], tools: [FakeTool('peek')]);
    final events = await h.send('x');
    expect(finished(events).outcome, RunOutcome.completed);
    final results = (await h.activePath())[2].toolResults;
    expect(results[0].text, contains('Invalid arguments'));
    expect(results[1].text, contains('Unknown tool'));
    expect(results.every((r) => r.isError), isTrue);
  });

  test('stop during streaming keeps the partial reply and ends cancelled', () async {
    final h = Harness([ScriptedTurn.text('one two three four five six seven eight nine ten')],
        eventDelay: const Duration(milliseconds: 2));
    await h.newSession();
    final events = <AgentEvent>[];
    final done = Completer<void>();
    h.runner.send('s1', [const TextPart('count')]).listen((e) {
      events.add(e);
      if (e is ModelStreamed && events.whereType<ModelStreamed>().length == 3) h.runner.cancel();
    }, onDone: done.complete);
    await done.future;
    expect(finished(events).outcome, RunOutcome.cancelled);
    final last = (await h.activePath()).last;
    expect(last.role, Role.assistant);
    expect(last.finishReason, 'cancelled');
    expect(last.text, isNotEmpty);
    expect(last.text.length, lessThan(20));
    expect(h.provider.cancelledStreams, 1);
    expect((await h.store.getCheckpoint('s1'))!.phase, RunPhase.cancelled);
    expect(h.runner.isRunning, isFalse);
  });

  test('stop while an approval sheet is open answers every call', () async {
    final handler = HangingApprovals();
    final h = Harness([
      ScriptedTurn.toolCalls(const [
        ToolCall(id: 'a', name: 'delete', arguments: {}),
        ToolCall(id: 'b', name: 'delete', arguments: {}),
      ]),
    ], tools: [FakeTool('delete', annotations: const ToolAnnotations())], handler: handler);
    await h.newSession();
    final future = h.runner.send('s1', [const TextPart('rm')]).toList();
    await handler.asked.future;
    h.runner.cancel();
    final events = await future;
    expect(finished(events).outcome, RunOutcome.cancelled);
    final path = await h.activePath();
    expectPairing(path);
    expect(path.last.toolResults.every((r) => r.isError), isTrue);
  });

  test('stop during tool execution cancels the tool and keeps pairing', () async {
    final started = Completer<void>();
    final tool = FakeTool('slow', onRun: (args, ctx) async {
      started.complete();
      await ctx.cancel.whenCancelled;
      throw const CancelledException();
    });
    final h = Harness([
      ScriptedTurn.toolCalls(const [ToolCall(id: 'c1', name: 'slow', arguments: {})]),
    ], tools: [tool]);
    await h.newSession();
    final future = h.runner.send('s1', [const TextPart('go')]).toList();
    await started.future;
    h.runner.cancel();
    final events = await future;
    expect(finished(events).outcome, RunOutcome.cancelled);
    final path = await h.activePath();
    expectPairing(path);
    expect(path.last.toolResults.single.text, contains('Cancelled'));
  });

  test('retryable provider errors before output are retried', () async {
    final h = Harness([
      ScriptedTurn.error(const ProviderException(ProviderErrorKind.overloaded, 'busy')),
      ScriptedTurn.text('second time lucky'),
    ]);
    final events = await h.send('hi');
    expect(finished(events).outcome, RunOutcome.completed);
    expect(events.whereType<RunNotice>().single.code, 'retrying');
    expect((await h.activePath()).last.text, 'second time lucky');
  });

  test('errors after output fail the run but keep the visible partial', () async {
    final h = Harness([
      ScriptedTurn.error(
        const ProviderException(ProviderErrorKind.network, 'socket closed'),
        before: const [TextDelta('partial ans'), ToolCallStart(index: 0, id: 'c', name: 'peek')],
      ),
    ], tools: [FakeTool('peek')]);
    final events = await h.send('hi');
    expect(finished(events).outcome, RunOutcome.failed);
    final last = (await h.activePath()).last;
    expect(last.text, 'partial ans');
    expect(last.hasToolCalls, isFalse, reason: 'unanswered calls are dropped');
    expect(last.finishReason, 'error');
    expect(h.provider.requests, hasLength(1));
  });

  test('update_plan stores the plan and pins it into the next request', () async {
    final h = Harness([
      ScriptedTurn.toolCalls(const [
        ToolCall(id: 'p', name: 'update_plan', arguments: {
          'task': 'Write the report',
          'items': [
            {'title': 'Outline', 'status': 'completed'},
            {'title': 'Draft', 'status': 'in_progress'},
          ],
        }),
      ]),
      ScriptedTurn.text('Working on the draft.'),
    ], withPlanTool: true);
    final events = await h.send('write a report');
    expect(finished(events).outcome, RunOutcome.completed);
    final plan = await h.store.getPlan('s1');
    expect(plan!.items.map((i) => i.status), [PlanStatus.done, PlanStatus.inProgress]);
    final planResult = h.provider.requests[1].messages.last.toolResults.single.text;
    expect(planResult, contains('[x] Outline'));
    expect(planResult, contains('[~] Draft'));
    expect(h.provider.requests[1].systemPrompt, isNot(contains('Outline')),
        reason: 'plan updates must not rewrite the system prompt');
  });

  test('overflowing context stops with needsUserAction instead of truncating', () async {
    final h = Harness([ScriptedTurn.text('never sent')],
        caps: const ModelCapabilities(contextLength: 600, maxOutputTokens: 100));
    final events = await h.send('word ' * 2000);
    final f = finished(events);
    expect(f.outcome, RunOutcome.needsUserAction);
    expect(f.detail, contains('no longer fits'));
    expect(h.provider.requests, isEmpty);
  });

  test('max steps stops a runaway loop', () async {
    final h = Harness([
      for (var i = 0; i < 3; i++) ScriptedTurn.toolCalls([ToolCall(id: 'c$i', name: 'peek', arguments: const {})]),
    ], tools: [FakeTool('peek')], config: const AgentConfig(maxSteps: 3));
    final events = await h.send('loop');
    expect(finished(events).outcome, RunOutcome.maxSteps);
    expectPairing(await h.activePath());
  });

  test('regenerate and edit create branches without losing history', () async {
    final h = Harness([
      ScriptedTurn.text('first answer'),
      ScriptedTurn.text('second answer'),
      ScriptedTurn.text('edited answer'),
    ]);
    await h.send('question');
    final user = (await h.activePath()).first;
    await h.runner.regenerate('s1', fromMessageId: user.id).toList();
    final replies = await h.store.children('s1', user.id);
    expect(replies.map((m) => m.text), ['first answer', 'second answer']);
    expect((await h.activePath()).last.text, 'second answer');

    await h.runner.edit('s1', user.id, [const TextPart('edited question')]).toList();
    final roots = await h.store.children('s1', null);
    expect(roots.map((m) => m.text), ['question', 'edited question']);
    expect((await h.activePath()).map((m) => m.text), ['edited question', 'edited answer']);
  });

  group('resume after process death', () {
    Future<Harness> crashedMidTools({required ToolAnnotations runningAnnotations}) async {
      final a = FakeTool('a');
      final b = FakeTool('b', annotations: runningAnnotations);
      final c = FakeTool('c');
      final h = Harness([ScriptedTurn.text('all done')], tools: [a, b, c]);
      await h.newSession();
      final t = h.clock.now();
      const calls = [
        ToolCall(id: 'ca', name: 'a', arguments: {}),
        ToolCall(id: 'cb', name: 'b', arguments: {}),
        ToolCall(id: 'cc', name: 'c', arguments: {}),
      ];
      await h.store.putMessage('s1', Message(id: 'u', role: Role.user, content: const [TextPart('go')], createdAt: t));
      await h.store.putMessage('s1', Message(
        id: 'asst',
        parentId: 'u',
        role: Role.assistant,
        content: [for (final c in calls) ToolCallPart(c)],
        createdAt: t,
        finishReason: 'toolCalls',
      ));
      await h.store.putMessage('s1', Message(
        id: 'tools',
        parentId: 'asst',
        role: Role.tool,
        createdAt: t,
        content: const [ToolResultPart(callId: 'ca', toolName: 'a', content: [TextPart('a done')])],
      ));
      await h.store.putCheckpoint(RunCheckpoint(
        sessionId: 's1',
        runId: 'old',
        phase: RunPhase.executingTools,
        step: 1,
        updatedAt: t,
        leafMessageId: 'asst',
        draftMessageId: 'tools',
        pendingCalls: const [
          PendingCall(callId: 'ca', toolName: 'a', status: PendingCallStatus.done),
          PendingCall(callId: 'cb', toolName: 'b', status: PendingCallStatus.running),
          PendingCall(callId: 'cc', toolName: 'c', status: PendingCallStatus.approved),
        ],
      ));
      return h;
    }

    test('non-idempotent interrupted call is not re-run; approved call runs', () async {
      final h = await crashedMidTools(runningAnnotations: const ToolAnnotations());
      final events = await h.runner.resume('s1').toList();
      expect((events.first as RunStarted).resumed, isTrue);
      expect(finished(events).outcome, RunOutcome.completed);
      final b = h.router.lookup('b');
      expect(b, isNotNull);
      final path = await h.activePath();
      expectPairing(path);
      final results = path[2].toolResults;
      expect(results.map((r) => r.callId), ['ca', 'cb', 'cc']);
      expect(results[0].text, 'a done');
      expect(results[1].text, contains('interrupted'));
      expect(results[2].text, 'c ok');
      expect(path.last.text, 'all done');
    });

    test('idempotent interrupted call is re-run', () async {
      final h = await crashedMidTools(runningAnnotations: const ToolAnnotations(idempotentHint: true, destructiveHint: false));
      final events = await h.runner.resume('s1').toList();
      expect(events.whereType<RunNotice>().any((n) => n.code == 'tool_rerun'), isTrue);
      final results = (await h.activePath())[2].toolResults;
      expect(results[1].text, 'b ok');
    });

    test('resume while streaming re-streams into the same draft id', () async {
      final h = Harness([ScriptedTurn.text('fresh reply')]);
      await h.newSession();
      final t = h.clock.now();
      await h.store.putMessage('s1', Message(id: 'u', role: Role.user, content: const [TextPart('hi')], createdAt: t));
      await h.store.putMessage('s1', Message(
          id: 'draft', parentId: 'u', role: Role.assistant, content: const [TextPart('stale par')], createdAt: t));
      await h.store.putCheckpoint(RunCheckpoint(
        sessionId: 's1',
        runId: 'old',
        phase: RunPhase.streamingModel,
        step: 1,
        updatedAt: t,
        leafMessageId: 'u',
        draftMessageId: 'draft',
      ));
      await h.runner.resume('s1').toList();
      final reply = await h.store.getMessage('s1', 'draft');
      expect(reply!.text, 'fresh reply');
      expect(await h.store.children('s1', 'u'), hasLength(1));
    });

    test('nothing to resume after a finished run', () async {
      final h = Harness([ScriptedTurn.text('x')]);
      await h.send('hi');
      final events = await h.runner.resume('s1').toList();
      expect(finished(events).detail, 'nothing to resume');
      expect(h.provider.requests, hasLength(1));
    });
  });

  test('draft is persisted while streaming so a crash loses little', () async {
    final h = Harness([ScriptedTurn.text('a' * 400)], config: const AgentConfig(draftPersistEvery: 10),
        eventDelay: const Duration(milliseconds: 1));
    await h.newSession();
    String? draftText;
    final done = Completer<void>();
    h.runner.send('s1', [const TextPart('go')]).listen((e) async {
      if (e is ModelStreamed && draftText == null) {
        final cp = await h.store.getCheckpoint('s1');
        final d = cp?.draftMessageId == null ? null : await h.store.getMessage('s1', cp!.draftMessageId!);
        if (d != null && d.metadata['draft'] == true) draftText = d.text;
      }
    }, onDone: done.complete);
    await done.future;
    expect(draftText, isNotNull);
    expect(draftText!.length, lessThan(400));
  });

  test('a second concurrent run on the same runner is rejected', () async {
    final h = Harness([ScriptedTurn.text('slow reply text here')], eventDelay: const Duration(milliseconds: 5));
    await h.newSession();
    final first = h.runner.send('s1', [const TextPart('a')]).toList();
    expect(() => h.runner.send('s1', [const TextPart('b')]), throwsStateError);
    await first;
  });

  test('append-only models never see reasoning from an older prefix', () async {
    final h = Harness([
      ScriptedTurn([
        const ReasoningDelta('thinking hard'),
        const ReasoningSignature(signature: 'sig-1'),
        const TextDelta('answer one'),
        const Finish(FinishReason.stop),
      ]),
      ScriptedTurn.text('answer two'),
      ScriptedTurn.text('answer three'),
    ], caps: const ModelCapabilities(contextLength: 32768, historyPolicy: HistoryPolicy.appendOnly));
    await h.send('q1');
    await h.send('q2');
    // Same prefix: the signed reasoning is replayed verbatim.
    final replayed = h.provider.requests[1].messages[1].reasoning.single;
    expect(replayed.signature, 'sig-1');
    // A context rewrite (new overlay) changes the prefix: reasoning is dropped.
    final first = (await h.activePath()).first;
    await h.store.putOverlay('s1', CompactedRange(
      id: 'ov1',
      createdAt: h.clock.now(),
      reason: 'test',
      tokensSaved: 1,
      fromMessageId: first.id,
      toMessageId: first.id,
      strategyId: 'test',
      summary: const CompactionSummary(goal: 'g'),
    ));
    await h.send('q3');
    expect(h.provider.requests[2].messages.expand((m) => m.reasoning), isEmpty);
  });

  test('remote providers record a data-egress audit entry', () async {
    final h = Harness([ScriptedTurn.text('x')]);
    final remote = AgentRunner(
      store: h.store,
      provider: ScriptedProvider([ScriptedTurn.text('remote')],
          info: ProviderInfo(
            id: 'r',
            kind: ProviderKind.openAiCompatible,
            displayName: 'Remote',
            location: ExecutionLocation.remote,
            baseUrl: Uri.parse('https://api.example.com/v1'),
          )),
      modelId: 'm',
      tools: LocalToolRouter(const []),
      approvals: ApprovalPolicy(),
      approvalHandler: const StaticApprovalHandler.approveAll(),
      clock: h.clock,
      ids: h.ids,
    );
    await h.newSession();
    await remote.send('s1', [const TextPart('hi')]).toList();
    final egress = (await h.store.audit('s1')).where((a) => a.kind == AuditKind.dataEgress).single;
    expect(egress.data['host'], 'api.example.com');
  });
}
