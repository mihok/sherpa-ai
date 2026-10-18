import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:test/test.dart';

void main() {
  Future<(InMemorySessionStore, AgentRunner, ScriptedProvider)> setup(List<ScriptedTurn> turns, List<LocalTool> tools) async {
    final store = InMemorySessionStore();
    final clock = FakeClock();
    await store.putSession(SessionRecord(id: 's', title: defaultSessionTitle, createdAt: clock.now(), updatedAt: clock.now()));
    final provider = ScriptedProvider(turns);
    final runner = AgentRunner(
      store: store,
      provider: provider,
      modelId: 'm',
      tools: LocalToolRouter(tools),
      approvals: ApprovalPolicy(clock: clock),
      approvalHandler: const StaticApprovalHandler.approveAll(),
      clock: clock,
      ids: SequentialIdGenerator(),
      sleep: (_) async {},
    );
    return (store, runner, provider);
  }

  test('a refused turn never executes the tool calls it streamed', () async {
    final (store, runner, provider) = await setup([
      ScriptedTurn(const [
        ToolCallStart(index: 0, id: 'c1', name: 'noop'),
        ToolCallComplete(index: 0, call: ToolCall(id: 'c1', name: 'noop', arguments: {})),
        Finish(FinishReason.refusal),
      ]),
    ], [_NoopTool()]);
    final events = await runner.send('s', const [TextPart('do it')]).toList();
    expect(events.whereType<ToolCallStarted>(), isEmpty);
    expect(events.whereType<RunFinished>().single.outcome, RunOutcome.completed);
    final leaf = (await store.getSession('s'))!.activeLeafId!;
    final reply = await store.getMessage('s', leaf);
    expect(reply!.hasToolCalls, isFalse);
    expect(reply.finishReason, 'refusal');
  });

  test('thinking after a redacted block starts a new reasoning part', () async {
    final (store, runner, _) = await setup([
      ScriptedTurn(const [
        ReasoningSignature(redactedData: 'opaque'),
        ReasoningDelta('visible thought'),
        ReasoningSignature(signature: 'sig'),
        TextDelta('answer'),
        Finish(FinishReason.stop),
      ]),
    ], const []);
    await runner.send('s', const [TextPart('q')]).toList();
    final leaf = (await store.getSession('s'))!.activeLeafId!;
    final parts = (await store.getMessage('s', leaf))!.reasoning;
    expect(parts, hasLength(2));
    expect(parts[0].redactedData, 'opaque');
    expect(parts[0].text, isEmpty);
    expect(parts[1].text, 'visible thought');
    expect(parts[1].signature, 'sig');
  });

  test('child tokens detach from their parent', () {
    final root = CancellationToken();
    final children = [for (var i = 0; i < 100; i++) root.child()];
    for (final c in children) {
      c.detach();
    }
    root.cancel();
    expect(children.every((c) => !c.isCancelled), isTrue, reason: 'detached children are unlinked');
  });

  test('in-memory store enforces sessions and idempotent, chronological audit', () async {
    final store = InMemorySessionStore();
    final t = DateTime.utc(2026);
    expect(() => store.putMessage('nope', Message(id: 'm', role: Role.user, content: const [], createdAt: t)),
        throwsStateError);
    await store.putSession(SessionRecord(id: 's', title: 'x', createdAt: t, updatedAt: t));
    AuditEntry e(String id, int minute) =>
        AuditEntry(id: id, sessionId: 's', at: t.add(Duration(minutes: minute)), kind: AuditKind.toolCall, summary: id);
    await store.appendAudit(e('b', 2));
    await store.appendAudit(e('a', 1));
    await store.appendAudit(e('a', 1));
    await store.appendAudit(e('c', 2));
    expect((await store.audit('s')).map((x) => x.id), ['a', 'b', 'c']);
    expect((await store.audit('s', limit: 2)).map((x) => x.id), ['b', 'c']);
  });
}

final class _NoopTool implements LocalTool {
  @override
  ToolDefinition get definition => const ToolDefinition(
        name: 'noop',
        description: 'does nothing',
        inputSchema: {'type': 'object'},
        annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: false),
      );

  @override
  Future<ToolResult> run(Map<String, Object?> arguments, ToolExecutionContext context) async =>
      ToolResult.text('ran');
}
