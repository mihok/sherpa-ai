/// The router hooks the agent loop uses: call resolution (proxies such as
/// MCP's `call_tool`), model-size hints, hygiene-bound grants, visibility,
/// result attribution and idempotency keys.
library;

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:test/test.dart';

const _proxySource = ToolSource(ToolSourceKind.mcp, serverId: 'proxy.local');
const _serverSource = ToolSource(ToolSourceKind.mcp, serverId: 'srv');

/// A router with one dispatch proxy, `call_tool`, in front of real tools,
/// like sherpa_mcp's McpToolRouter.
final class _ProxyRouter implements ToolRouter {
  _ProxyRouter(this.targets);

  final Map<String, ToolDefinition> targets;
  final List<(ToolCall, ToolExecutionContext)> executed = [];
  final List<ToolSelectionHints?> hints = [];

  static const ToolDefinition proxy = ToolDefinition(
    name: 'call_tool',
    description: 'Run a tool by name.',
    inputSchema: {'type': 'object'},
    source: _proxySource,
  );

  @override
  Future<List<ToolDefinition>> toolsForTurn({
    required String sessionId,
    String? query,
    int? schemaTokenBudget,
    ToolSelectionHints? hints,
  }) async {
    this.hints.add(hints);
    return [proxy];
  }

  @override
  ToolDefinition? lookup(String name) => name == 'call_tool' ? proxy : targets[name];

  @override
  ResolvedToolCall? resolve(ToolCall call, {required String sessionId}) {
    if (call.name != 'call_tool') {
      final t = targets[call.name];
      return t == null ? null : ResolvedToolCall(call: call, tool: t);
    }
    final raw = call.arguments['name'];
    if (raw is! String) return ResolvedToolCall(call: call, tool: proxy, refusal: 'call_tool needs "name".');
    final exact = targets[raw];
    final fuzzy = exact == null ? targets[raw.toLowerCase()] : null;
    final target = exact ?? fuzzy;
    if (target == null) return ResolvedToolCall(call: call, tool: proxy, refusal: 'There is no tool named "$raw".');
    return ResolvedToolCall(
      call: ToolCall(id: call.id, name: target.name, arguments: (call.arguments['arguments'] as Map?)?.cast() ?? const {}),
      tool: target,
      correctedName: fuzzy != null,
    );
  }

  @override
  Future<ToolResult> execute(ToolCall call, ToolExecutionContext context) async {
    executed.add((call, context));
    final target = call.name == 'call_tool' ? call.arguments['name'] : call.name;
    return ToolResult(content: [TextPart('ran $target')], meta: const {'server/own': 1, ToolResultPart.metaServerId: 'forged'});
  }
}

final class _Recorder implements ApprovalHandler {
  _Recorder(this.decision, {this.scope = ApprovalScope.once});

  final UserDecision decision;
  final ApprovalScope scope;
  final List<(ToolCall, ToolDefinition?, NeedsConfirmation)> asked = [];

  @override
  Future<ApprovalResponse> requestApproval({
    required String sessionId,
    required ToolCall call,
    required ToolDefinition? tool,
    required NeedsConfirmation requirement,
    required CancellationToken cancel,
  }) async {
    asked.add((call, tool, requirement));
    return ApprovalResponse(decision, scope: scope);
  }
}

final clock = FakeClock();

const _write = ToolDefinition(
  name: 'srv__write',
  description: 'write',
  inputSchema: {'type': 'object'},
  annotations: ToolAnnotations(destructiveHint: false, openWorldHint: false),
  source: _serverSource,
);
const _read = ToolDefinition(
  name: 'srv__read',
  description: 'read',
  inputSchema: {'type': 'object'},
  annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: false, idempotentHint: true),
  source: _serverSource,
  uiResourceUri: 'ui://srv/read',
);

Future<(InMemorySessionStore, List<AgentEvent>)> _run(
  ToolRouter router,
  List<ToolCall> calls, {
  required ApprovalHandler handler,
  required ApprovalPolicy policy,
  ScriptedProvider? provider,
}) async {
  final store = InMemorySessionStore();
  await store.putSession(SessionRecord(id: 's1', title: defaultSessionTitle, createdAt: clock.now(), updatedAt: clock.now()));
  final runner = AgentRunner(
    store: store,
    provider: provider ?? ScriptedProvider([ScriptedTurn.toolCalls(calls), ScriptedTurn.text('done')]),
    modelId: 'm',
    tools: router,
    approvals: policy,
    approvalHandler: handler,
    clock: clock,
    ids: SequentialIdGenerator(),
    sleep: (_) async {},
  );
  final events = await runner.send('s1', const [TextPart('go')]).toList();
  return (store, events);
}

Future<List<ToolResultPart>> _results(InMemorySessionStore store) async =>
    [for (final m in await store.path('s1', (await store.getSession('s1'))!.activeLeafId!)) ...m.toolResults];

void main() {
  group('ToolRouter.resolve', () {
    test('a proxied call is gated, asked about and granted as its target, never the proxy', () async {
      final router = _ProxyRouter({'srv__write': _write});
      final policy = ApprovalPolicy(clock: clock, trustedServers: {'srv'});
      final handler = _Recorder(UserDecision.approve, scope: ApprovalScope.session);
      final (store, events) = await _run(router, const [
        ToolCall(id: 'c1', name: 'call_tool', arguments: {'name': 'srv__write', 'arguments': {'x': 1}}),
      ], handler: handler, policy: policy);
      final (call, tool, requirement) = handler.asked.single;
      expect(call.name, 'srv__write');
      expect(call.arguments, {'x': 1});
      expect(tool!.name, 'srv__write');
      expect(requirement.risk, RiskLevel.moderate, reason: 'the target\'s risk, not the destructive proxy\'s');
      expect(events.whereType<ToolApprovalRequested>().single.call.name, 'srv__write');
      expect(policy.grants.map((g) => g.toolName), ['srv__write']);
      expect(router.executed.single.$1.name, 'call_tool', reason: 'the router still gets the model\'s call');
      final result = (await _results(store)).single;
      expect(result.toolName, 'call_tool', reason: 'pairs with the call in the transcript');
      expect(result.meta[ToolResultPart.metaServerId], 'srv', reason: 'attribution is the harness\'s');
      expect(result.meta[ToolResultPart.metaTool], 'srv__write');
      expect(result.meta['server/own'], 1);
      final audit = await store.audit('s1');
      expect(audit.where((a) => a.kind == AuditKind.toolCall).single.data, containsPair('via', 'call_tool'));
    });

    test('a refusal is answered without asking or running', () async {
      final router = _ProxyRouter({'srv__write': _write});
      final handler = _Recorder(UserDecision.approve);
      final (store, _) = await _run(router, const [
        ToolCall(id: 'c1', name: 'call_tool', arguments: {'name': 'nope'}),
      ], handler: handler, policy: ApprovalPolicy(clock: clock));
      expect(handler.asked, isEmpty);
      expect(router.executed, isEmpty);
      final result = (await _results(store)).single;
      expect(result.isError, isTrue);
      expect(result.text, 'There is no tool named "nope".');
    });

    test('a corrected name to a non-read-only target asks once, even with a grant', () async {
      final router = _ProxyRouter({'srv__write': _write});
      final policy = ApprovalPolicy(clock: clock, trustedServers: {'srv'})
        ..record('srv__write', 's1', const ApprovalResponse(UserDecision.approve, scope: ApprovalScope.always));
      final handler = _Recorder(UserDecision.approve, scope: ApprovalScope.always);
      await _run(router, const [
        ToolCall(id: 'c1', name: 'call_tool', arguments: {'name': 'SRV__WRITE'}),
      ], handler: handler, policy: policy);
      expect(handler.asked.single.$3.oneOffOnly, isTrue);
      expect(handler.asked.single.$3.reason, contains('slightly different name'));
      expect(policy.grants, hasLength(1), reason: 'the one-off answer adds no grant');
    });

    test('the resume re-run decision uses the target', () async {
      final router = _ProxyRouter({'srv__read': _read});
      final store = InMemorySessionStore();
      final t = clock.now();
      await store.putSession(SessionRecord(id: 's1', title: 't', createdAt: t, updatedAt: t));
      await store.putMessage('s1', Message(id: 'u', role: Role.user, content: const [TextPart('go')], createdAt: t));
      await store.putMessage(
        's1',
        Message(
          id: 'asst',
          parentId: 'u',
          role: Role.assistant,
          createdAt: t,
          finishReason: 'toolCalls',
          content: const [
            ToolCallPart(ToolCall(id: 'call_0', name: 'call_tool', arguments: {'name': 'srv__read'})),
          ],
        ),
      );
      await store.putCheckpoint(RunCheckpoint(
        sessionId: 's1',
        runId: 'old',
        phase: RunPhase.executingTools,
        step: 1,
        updatedAt: t,
        leafMessageId: 'asst',
        draftMessageId: 'tools',
        pendingCalls: const [PendingCall(callId: 'call_0', toolName: 'call_tool', status: PendingCallStatus.running)],
      ));
      final runner = AgentRunner(
        store: store,
        provider: ScriptedProvider([ScriptedTurn.text('done')]),
        modelId: 'm',
        tools: router,
        approvals: ApprovalPolicy(clock: clock, trustedServers: {'srv'}),
        approvalHandler: _Recorder(UserDecision.deny),
        clock: clock,
        ids: SequentialIdGenerator(),
        sleep: (_) async {},
      );
      await runner.resume('s1').toList();
      expect(router.executed, hasLength(1), reason: 'the trusted idempotent target re-runs (the proxy itself is not)');
      expect(router.executed.single.$2.idempotencyKey, 'asst:call_0', reason: 'the same key as the interrupted run');
    });

    test('CompositeToolRouter delegates to the owner; LocalToolRouter resolves to itself', () {
      final proxy = _ProxyRouter({'srv__write': _write});
      final local = LocalToolRouter([UpdatePlanTool(store: InMemorySessionStore(), clock: clock)]);
      final composite = CompositeToolRouter([local, proxy]);
      const plan = ToolCall(id: 'p', name: 'update_plan', arguments: {});
      expect(composite.resolve(plan, sessionId: 's')!.call, same(plan));
      expect(composite.resolve(plan, sessionId: 's')!.tool!.name, 'update_plan');
      final r = composite.resolve(
        const ToolCall(id: 'c', name: 'call_tool', arguments: {'name': 'srv__write'}),
        sessionId: 's',
      )!;
      expect(r.call.name, 'srv__write');
      expect(composite.resolve(const ToolCall(id: 'x', name: 'ghost', arguments: {}), sessionId: 's'), isNull);
    });
  });

  test('tool selection hints: the runner describes the model; CompositeToolRouter counts reserved tools', () async {
    final proxy = _ProxyRouter(const {});
    final store = InMemorySessionStore();
    final router = CompositeToolRouter([
      LocalToolRouter([UpdatePlanTool(store: store, clock: clock)]),
      proxy,
    ]);
    await store.putSession(SessionRecord(id: 's1', title: 't', createdAt: clock.now(), updatedAt: clock.now()));
    await AgentRunner(
      store: store,
      provider: ScriptedProvider(
        [ScriptedTurn.text('hi')],
        capabilitiesValue: const ModelCapabilities(contextLength: 8192, parameterCount: 1700000000),
      ),
      modelId: 'm',
      tools: router,
      approvals: ApprovalPolicy(clock: clock),
      approvalHandler: _Recorder(UserDecision.deny),
      clock: clock,
      ids: SequentialIdGenerator(),
    ).send('s1', const [TextPart('hi')]).toList();
    final h = proxy.hints.single!;
    expect(h.onDevice, isTrue, reason: 'the scripted provider runs on the device');
    expect(h.parameterBillions, closeTo(1.7, 1e-9));
    expect(h.reservedTools, 1, reason: 'update_plan was collected first');
  });

  group('hygiene and definition-bound grants', () {
    const flagged = ToolDefinition(
      name: 'srv__read',
      description: 'read',
      inputSchema: {},
      annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: false),
      source: _serverSource,
      requiresConfirmation: true,
      definitionHash: 'h1',
    );

    test('requiresConfirmation asks even for a trusted read-only tool, unless that exact definition was granted', () {
      final policy = ApprovalPolicy(clock: clock, trustedServers: {'srv'});
      expect(policy.evaluate(flagged, 's'), isA<NeedsConfirmation>());
      policy.recordFor(flagged, 's', const ApprovalResponse(UserDecision.approve, scope: ApprovalScope.session));
      expect(policy.grants.single.definitionHash, 'h1');
      expect(policy.evaluate(flagged, 's'), isA<AutoApprove>());
      const changed = ToolDefinition(
        name: 'srv__read',
        description: 'read (changed)',
        inputSchema: {},
        annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: false),
        source: _serverSource,
        requiresConfirmation: true,
        definitionHash: 'h2',
      );
      expect(policy.evaluate(changed, 's'), isA<NeedsConfirmation>(), reason: 'a changed definition voids the grant');
      const unhashed = ToolDefinition(
        name: 'srv__read',
        description: 'read',
        inputSchema: {},
        source: _serverSource,
        requiresConfirmation: true,
      );
      expect(ApprovalPolicy(clock: clock, trustedServers: {'srv'}).evaluate(unhashed, 's'), isA<NeedsConfirmation>());
    });

    test('a grant is bound to the definition hash; persisted grants without one do not cover hashed tools', () {
      final now = clock.now();
      final hashed = ApprovalGrant(toolName: 't', scope: ApprovalScope.always, grantedAt: now, definitionHash: 'abc');
      final back = ApprovalGrant.fromJson(hashed.toJson());
      expect(back.definitionHash, 'abc');
      expect(back.covers('t', 's', now, definitionHash: 'abc'), isTrue);
      expect(back.covers('t', 's', now, definitionHash: 'xyz'), isFalse);
      final legacy = ApprovalGrant.fromJson(const {'toolName': 't', 'scope': 'always', 'grantedAt': '2026-01-01T00:00:00.000Z'});
      expect(legacy.covers('t', 's', now), isTrue);
      expect(legacy.covers('t', 's', now, definitionHash: 'abc'), isFalse);
      const def = ToolDefinition(name: 'x', description: '', inputSchema: {}, requiresConfirmation: true, definitionHash: 'abc');
      final json = ToolDefinition.fromJson(def.toJson());
      expect(json.requiresConfirmation, isTrue);
      expect(json.definitionHash, 'abc');
    });
  });

  test('a call to a tool the model may not see is refused before gating', () async {
    final router = _ProxyRouter({
      'srv__app_only': const ToolDefinition(
        name: 'srv__app_only',
        description: '',
        inputSchema: {},
        source: _serverSource,
        modelVisible: false,
      ),
    });
    final handler = _Recorder(UserDecision.approve);
    final (store, _) = await _run(router, const [
      ToolCall(id: 'c1', name: 'call_tool', arguments: {'name': 'srv__app_only'}),
    ], handler: handler, policy: ApprovalPolicy(clock: clock));
    expect(handler.asked, isEmpty);
    expect(router.executed, isEmpty);
    expect((await _results(store)).single.text, contains('not available to the model'));
  });

  test('ToolResultPart.meta round-trips; the idempotency key is <assistantMessageId>:<callId>', () async {
    const part = ToolResultPart(callId: 'c', toolName: 't', content: [TextPart('x')], meta: {'a': 1});
    expect(ToolResultPart.fromJson(part.toJson()).meta, {'a': 1});
    expect(const ToolResultPart(callId: 'c', toolName: 't', content: []).toJson().containsKey('meta'), isFalse);

    final router = _ProxyRouter({'srv__read': _read});
    final (store, _) = await _run(router, const [
      ToolCall(id: 'call_0', name: 'srv__read', arguments: {}),
    ], handler: _Recorder(UserDecision.deny), policy: ApprovalPolicy(clock: clock, trustedServers: {'srv'}));
    final path = await store.path('s1', (await store.getSession('s1'))!.activeLeafId!);
    final assistant = path.firstWhere((m) => m.hasToolCalls);
    expect(router.executed.single.$2.idempotencyKey, '${assistant.id}:call_0');
    final result = path.expand((m) => m.toolResults).single;
    expect(result.uiResourceUri, 'ui://srv/read');
    expect(result.meta.containsKey(ToolResultPart.metaTool), isFalse, reason: 'not proxied');
  });
}
