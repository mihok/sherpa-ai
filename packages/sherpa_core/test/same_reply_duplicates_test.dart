import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:test/test.dart';

/// A tool with configurable hints and source that counts its runs.
final class _Tool implements LocalTool {
  _Tool(this.name, {this.annotations = const ToolAnnotations(), this.source = ToolSource.builtin});

  final String name;
  final ToolAnnotations annotations;
  final ToolSource source;
  final List<Map<String, Object?>> runs = [];

  @override
  ToolDefinition get definition => ToolDefinition(
        name: name,
        description: 'test tool $name',
        inputSchema: const {'type': 'object'},
        annotations: annotations,
        source: source,
      );

  @override
  Future<ToolResult> run(Map<String, Object?> arguments, ToolExecutionContext context) async {
    runs.add(arguments);
    return ToolResult.text('{"note_id": "note_${runs.length}", "title": "${arguments['title'] ?? ''}"}');
  }
}

/// [LocalToolRouter] plus a `call_tool` proxy (as MCP's deferred mode):
/// `call_tool(name, arguments)` resolves to and runs its target.
final class _ProxyRouter implements ToolRouter {
  _ProxyRouter(List<LocalTool> tools) : _inner = LocalToolRouter(tools);

  final LocalToolRouter _inner;

  static const ToolDefinition proxy = ToolDefinition(
    name: 'call_tool',
    description: 'Run a tool found by tool_search.',
    inputSchema: {'type': 'object'},
    annotations: ToolAnnotations(readOnlyHint: false, destructiveHint: true),
  );

  ToolCall _target(ToolCall c) => ToolCall(
        id: c.id,
        name: c.arguments['name']! as String,
        arguments: (c.arguments['arguments']! as Map).cast<String, Object?>(),
      );

  @override
  Future<List<ToolDefinition>> toolsForTurn({
    required String sessionId,
    String? query,
    int? schemaTokenBudget,
    ToolSelectionHints? hints,
  }) async =>
      [...await _inner.toolsForTurn(sessionId: sessionId), proxy];

  @override
  ToolDefinition? lookup(String name) => name == proxy.name ? proxy : _inner.lookup(name);

  @override
  ResolvedToolCall? resolve(ToolCall call, {required String sessionId}) {
    if (call.name != proxy.name) return _inner.resolve(call, sessionId: sessionId);
    final t = _target(call);
    return ResolvedToolCall(call: t, tool: _inner.lookup(t.name));
  }

  @override
  Future<ToolResult> execute(ToolCall call, ToolExecutionContext context) =>
      _inner.execute(call.name == proxy.name ? _target(call) : call, context);
}

final class _Approvals implements ApprovalHandler {
  final List<String> asked = [];

  @override
  Future<ApprovalResponse> requestApproval({
    required String sessionId,
    required ToolCall call,
    required ToolDefinition? tool,
    required NeedsConfirmation requirement,
    required CancellationToken cancel,
  }) async {
    asked.add('${call.id}:${call.name}');
    return const ApprovalResponse(UserDecision.approve);
  }
}

final class _Run {
  _Run(List<ToolCall> calls, List<LocalTool> tools, {Set<String> trusted = const {}})
      : provider = ScriptedProvider([ScriptedTurn.toolCalls(calls), ScriptedTurn.text('Done.')]) {
    runner = AgentRunner(
      store: store,
      provider: provider,
      modelId: 'scripted',
      tools: _ProxyRouter(tools),
      approvals: ApprovalPolicy(clock: clock, trustedServers: trusted),
      approvalHandler: approvals,
      clock: clock,
      ids: SequentialIdGenerator(),
      sleep: (_) async {},
    );
  }

  final store = InMemorySessionStore();
  final clock = FakeClock();
  final approvals = _Approvals();
  final ScriptedProvider provider;
  late final AgentRunner runner;
  late final List<AgentEvent> events;

  Future<List<Message>> go() async {
    await store.putSession(SessionRecord(id: 's1', title: defaultSessionTitle, createdAt: clock.now(), updatedAt: clock.now()));
    events = await runner.send('s1', const [TextPart('Make a note')]).toList();
    final leaf = (await store.getSession('s1'))!.activeLeafId!;
    return store.path('s1', leaf);
  }

  Map<String, ToolResultPart> results(List<Message> path) => {
        for (final m in path)
          for (final r in m.toolResults) r.callId: r,
      };
}

void main() {
  const note = {'title': 'Groceries', 'body': 'milk, eggs'};
  const write = ToolAnnotations(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false);

  test('identical non-idempotent calls in one reply run once; the duplicate is answered, pairing stays valid', () async {
    final tool = _Tool('create_note', annotations: write);
    final r = _Run([
      const ToolCall(id: 'c1', name: 'create_note', arguments: note),
      // Same arguments in another key order: the same call.
      const ToolCall(id: 'c2', name: 'create_note', arguments: {'body': 'milk, eggs', 'title': 'Groceries'}),
    ], [tool]);
    final path = await r.go();
    expect(finishedOutcome(r.events), RunOutcome.completed);
    expect(tool.runs, hasLength(1));
    final results = r.results(path);
    expect(results.keys, ['c1', 'c2'], reason: 'every call is answered, in order');
    expect(results['c1']!.isError, isFalse);
    final dup = results['c2']!;
    // Not an error: the action is done (by c1). Told "error", a small model
    // runs the call a third time.
    expect(dup.isError, isFalse);
    expect(dup.text, startsWith('Duplicate of call c1, not run'));
    expect(dup.text, contains('call c1 already did it'));
    expect(dup.meta[SummaryComposer.metaNotRun], isTrue);
    expect(r.approvals.asked, ['c1:create_note'], reason: 'one approval sheet, for the call that runs');
    expect(r.events.whereType<RunNotice>().map((n) => n.code), contains('tool_call_duplicate'));
    expect(r.events.whereType<ToolCallStarted>().map((e) => e.call.id), ['c1']);
    final audit = await r.store.audit('s1');
    expect(audit.map((a) => a.summary), contains('skipped duplicate create_note'));

    // The summary ledger lists the action once: the duplicate never ran.
    final h = SummaryComposer.harvest(CompactionInput(messages: path, toolLookup: (n) => tool.definition));
    expect(h.sideEffects.map((e) => e.callId), ['c1']);
  });

  test('a proxied call and a direct call to the same target with the same arguments are one call', () async {
    final tool = _Tool('create_note', annotations: write);
    final r = _Run([
      const ToolCall(id: 'c1', name: 'call_tool', arguments: {'name': 'create_note', 'arguments': note}),
      const ToolCall(id: 'c2', name: 'create_note', arguments: note),
    ], [tool]);
    final path = await r.go();
    expect(tool.runs, hasLength(1));
    expect(r.results(path)['c2']!.text, startsWith('Duplicate of call c1'));
  });

  test('different arguments, or read-only / trusted idempotent tools, are not deduplicated', () async {
    final create = _Tool('create_note', annotations: write);
    final search = _Tool('search_notes', annotations: const ToolAnnotations(readOnlyHint: true, openWorldHint: false));
    final put = _Tool('put_note', annotations: const ToolAnnotations(readOnlyHint: false, idempotentHint: true, destructiveHint: false));
    final r = _Run([
      const ToolCall(id: 'c1', name: 'create_note', arguments: note),
      const ToolCall(id: 'c2', name: 'create_note', arguments: {'title': 'Groceries', 'body': 'milk, eggs, bread'}),
      const ToolCall(id: 'c3', name: 'search_notes', arguments: {'query': 'x'}),
      const ToolCall(id: 'c4', name: 'search_notes', arguments: {'query': 'x'}),
      const ToolCall(id: 'c5', name: 'put_note', arguments: {'id': 'n1'}),
      const ToolCall(id: 'c6', name: 'put_note', arguments: {'id': 'n1'}),
    ], [create, search, put]);
    final path = await r.go();
    expect(create.runs, hasLength(2));
    expect(search.runs, hasLength(2));
    expect(put.runs, hasLength(2));
    expect(r.results(path).values.where((x) => x.isError), isEmpty);
    expect(r.events.whereType<RunNotice>().map((n) => n.code), isNot(contains('tool_call_duplicate')));
  });

  test('an untrusted server cannot opt out by declaring its tool idempotent', () async {
    final tool = _Tool(
      'shop__place_order',
      annotations: const ToolAnnotations(readOnlyHint: false, idempotentHint: true, destructiveHint: false),
      source: const ToolSource(ToolSourceKind.mcp, serverId: 'shop'),
    );
    final untrusted = _Run([
      const ToolCall(id: 'c1', name: 'shop__place_order', arguments: {'basket': 'b1'}),
      const ToolCall(id: 'c2', name: 'shop__place_order', arguments: {'basket': 'b1'}),
    ], [tool]);
    await untrusted.go();
    expect(tool.runs, hasLength(1));

    tool.runs.clear();
    final trusted = _Run([
      const ToolCall(id: 'c1', name: 'shop__place_order', arguments: {'basket': 'b1'}),
      const ToolCall(id: 'c2', name: 'shop__place_order', arguments: {'basket': 'b1'}),
    ], [tool], trusted: {'shop'});
    await trusted.go();
    expect(tool.runs, hasLength(2), reason: 'a trusted idempotent hint makes the repeat harmless');
  });

  test('a duplicate of a declined call is not asked about again', () async {
    final tool = _Tool('create_note', annotations: write);
    final store = InMemorySessionStore();
    final clock = FakeClock();
    final asked = <String>[];
    final runner = AgentRunner(
      store: store,
      provider: ScriptedProvider([
        ScriptedTurn.toolCalls(const [
          ToolCall(id: 'c1', name: 'create_note', arguments: note),
          ToolCall(id: 'c2', name: 'create_note', arguments: note),
        ]),
        ScriptedTurn.text('OK.'),
      ]),
      modelId: 'scripted',
      tools: _ProxyRouter([tool]),
      approvals: ApprovalPolicy(clock: clock),
      approvalHandler: _Deny(asked),
      clock: clock,
      ids: SequentialIdGenerator(),
      sleep: (_) async {},
    );
    await store.putSession(SessionRecord(id: 's1', title: defaultSessionTitle, createdAt: clock.now(), updatedAt: clock.now()));
    await runner.send('s1', const [TextPart('go')]).toList();
    expect(tool.runs, isEmpty);
    expect(asked, ['c1']);
    final path = await store.path('s1', (await store.getSession('s1'))!.activeLeafId!);
    final results = {for (final m in path) for (final x in m.toolResults) x.callId: x};
    expect(results['c1']!.text, startsWith('The user declined'));
    expect(results['c2']!.text, startsWith('Duplicate of call c1'));
    expect(results['c2']!.isError, isTrue, reason: 'the original did not happen');
    expect(results['c2']!.text, isNot(contains('already did it')));
  });

  test('resume: an original answered before the process died still claims its duplicate', () async {
    // The process died after c1's decision was durable and before c2 was
    // answered: c2 must not take c1's place and run (or prompt).
    final tool = _Tool('create_note', annotations: write);
    final store = InMemorySessionStore();
    final clock = FakeClock();
    final asked = <String>[];
    final at = clock.now();
    await store.putSession(SessionRecord(id: 's1', title: 't', createdAt: at, updatedAt: at, activeLeafId: 'a1'));
    await store.putMessage('s1', Message(id: 'u1', role: Role.user, content: const [TextPart('go')], createdAt: at));
    await store.putMessage(
      's1',
      Message(
        id: 'a1',
        parentId: 'u1',
        role: Role.assistant,
        createdAt: at,
        finishReason: 'toolCalls',
        content: const [
          ToolCallPart(ToolCall(id: 'c1', name: 'create_note', arguments: note)),
          ToolCallPart(ToolCall(id: 'c2', name: 'create_note', arguments: note)),
        ],
      ),
    );
    await store.putMessage(
      's1',
      Message(
        id: 't1',
        parentId: 'a1',
        role: Role.tool,
        createdAt: at,
        content: const [
          ToolResultPart(callId: 'c1', toolName: 'create_note', content: [TextPart('The user declined this tool call.')], isError: true),
        ],
      ),
    );
    await store.putCheckpoint(RunCheckpoint(
      sessionId: 's1',
      runId: 'r1',
      phase: RunPhase.awaitingApproval,
      step: 1,
      updatedAt: at,
      leafMessageId: 'a1',
      draftMessageId: 't1',
      pendingCalls: const [
        PendingCall(callId: 'c1', toolName: 'create_note', status: PendingCallStatus.denied),
        PendingCall(callId: 'c2', toolName: 'create_note', status: PendingCallStatus.pending),
      ],
    ));
    final runner = AgentRunner(
      store: store,
      provider: ScriptedProvider([ScriptedTurn.text('OK.')]),
      modelId: 'scripted',
      tools: _ProxyRouter([tool]),
      approvals: ApprovalPolicy(clock: clock),
      approvalHandler: _Deny(asked),
      clock: clock,
      ids: SequentialIdGenerator(),
      sleep: (_) async {},
    );
    await runner.resume('s1').toList();
    expect(tool.runs, isEmpty);
    expect(asked, isEmpty);
    final results = {for (final x in (await store.getMessage('s1', 't1'))!.toolResults) x.callId: x};
    expect(results['c2']!.text, startsWith('Duplicate of call c1'));
    expect(results['c2']!.isError, isTrue);
  });
}

final class _Deny implements ApprovalHandler {
  _Deny(this.asked);

  final List<String> asked;

  @override
  Future<ApprovalResponse> requestApproval({
    required String sessionId,
    required ToolCall call,
    required ToolDefinition? tool,
    required NeedsConfirmation requirement,
    required CancellationToken cancel,
  }) async {
    asked.add(call.id);
    return const ApprovalResponse(UserDecision.deny);
  }
}

RunOutcome? finishedOutcome(List<AgentEvent> events) => events.whereType<RunFinished>().lastOrNull?.outcome;
