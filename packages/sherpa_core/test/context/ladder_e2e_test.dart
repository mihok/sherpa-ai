import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:test/test.dart';

import 'helpers.dart';

final class ReadFileTool implements LocalTool {
  @override
  ToolDefinition get definition => readFile;

  @override
  Future<ToolResult> run(Map<String, Object?> arguments, ToolExecutionContext context) async =>
      ToolResult.text('contents of ${arguments['path']}\n${lines(130)}');
}

/// Drives the real agent loop through a long conversation on a small window
/// and checks the provider-facing invariants on every request it made.
void main() {
  test('AgentRunner + LadderContextManager: elide → compact → handoff → hard stop', () async {
    const counter = QuarterCounter();
    const caps = ModelCapabilities(contextLength: 8192, maxOutputTokens: 512);
    final store = InMemorySessionStore();
    final clock = FakeClock();
    final provider = ScriptedProvider(const [], capabilitiesValue: caps);
    final runner = AgentRunner(
      store: store,
      provider: provider,
      modelId: 'scripted-model',
      tools: LocalToolRouter([ReadFileTool()]),
      approvals: ApprovalPolicy(clock: clock),
      approvalHandler: const StaticApprovalHandler.approveAll(),
      contextManager: LadderContextManager(clock: clock),
      counter: counter,
      clock: clock,
      ids: SequentialIdGenerator(),
      config: const AgentConfig(contextSettings: ContextSettings(largeToolResultTokens: 400)),
      sleep: (_) async {},
    );
    await store.putSession(SessionRecord(id: 's1', title: 'New chat', createdAt: clock.now(), updatedAt: clock.now()));

    final events = <AgentEvent>[];
    var handoffAt = -1;
    var compactionsAtHandoff = 0;
    for (var i = 0; i < 40 && handoffAt < 0; i++) {
      provider
        ..enqueue(
          ScriptedTurn.toolCalls([
            ToolCall(id: 'call$i', name: 'read_file', arguments: {'path': '/w/f$i.txt'}),
          ]),
        )
        ..enqueue(ScriptedTurn.text('Answer $i: ${'detail ' * 150}'));
      final text = i == 0
          ? 'Audit the files. You must never delete files. ${'context ' * 120}'
          : 'Turn $i: read the next file. ${'context ' * 120}';
      final run = await runner.send('s1', [TextPart(text)]).toList();
      events.addAll(run);
      expect(run.whereType<RunFinished>().single.outcome, RunOutcome.completed, reason: 'turn $i');
      if (run.whereType<RunNotice>().any((n) => n.code == 'handoff_recommended')) {
        handoffAt = i;
        compactionsAtHandoff = (await store.overlays('s1')).whereType<CompactedRange>().length;
      }
    }

    final overlays = await store.overlays('s1');
    final created = events.whereType<ContextPrepared>().expand((e) => e.newOverlays).toList();
    final firstElision = created.indexWhere((o) => o is ToolOutputElided);
    final firstCompaction = created.indexWhere((o) => o is CompactedRange);
    expect(firstElision, greaterThanOrEqualTo(0), reason: 'stage 1 ran');
    expect(firstCompaction, greaterThan(firstElision), reason: 'elision comes before compaction');
    expect(handoffAt, greaterThan(0), reason: 'a handoff was recommended');
    expect(compactionsAtHandoff, greaterThanOrEqualTo(1));
    expect(overlays.length, created.length, reason: 'the runner persisted every new overlay');
    final latest = overlays.whereType<CompactedRange>().last.summary;
    expect(latest.constraints.join(), contains('You must never delete files.'));
    expect(latest.compactionCount, overlays.whereType<CompactedRange>().length);
    final audit = await store.audit('s1');
    expect(audit.where((a) => a.kind == AuditKind.contextAction), hasLength(overlays.length));

    // Every request the model ever saw: paired, within budget, one summary
    // at most and only at the start.
    expect(provider.requests, isNotEmpty);
    for (final (n, r) in provider.requests.indexed) {
      final why = 'request $n';
      expectProviderInvariants(r.messages, reason: why);
      final input =
          counter.countText(r.systemPrompt ?? '') +
          counter.countTools(r.tools) +
          r.messages.fold(0, (s, m) => s + counter.countMessage(m));
      expect(input, lessThanOrEqualTo(8192 - 512), reason: '$why overflows: $input');
      final summaries = [
        for (final (i, m) in r.messages.indexed)
          if (m.kind == MessageKind.summary && m.role == Role.user) i,
      ];
      expect(summaries.length, lessThanOrEqualTo(1), reason: why);
      if (summaries.isNotEmpty) expect(summaries.single, 0, reason: why);
      expect(r.messages.last.role, anyOf(Role.user, Role.tool), reason: why);
    }

    // A message no pruning can absorb: hard stop, nothing sent.
    final sent = provider.requests.length;
    provider.enqueue(ScriptedTurn.text('never'));
    final stop = await runner.send('s1', [TextPart('word ' * 9000)]).toList();
    final finished = stop.whereType<RunFinished>().single;
    expect(finished.outcome, RunOutcome.needsUserAction);
    expect(finished.detail, contains('no longer fits'));
    expect(provider.requests.length, sent, reason: 'never silently overflow');
    expect((await store.getCheckpoint('s1'))!.phase, RunPhase.failed);
  });
}
