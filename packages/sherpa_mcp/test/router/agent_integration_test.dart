import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:test/test.dart';

final class _Recorder implements ApprovalHandler {
  final List<String> asked = [];

  @override
  Future<ApprovalResponse> requestApproval({
    required String sessionId,
    required ToolCall call,
    required ToolDefinition? tool,
    required NeedsConfirmation requirement,
    required CancellationToken cancel,
  }) async {
    asked.add('${call.name}:${tool?.name}');
    return const ApprovalResponse(UserDecision.approve, scope: ApprovalScope.session);
  }
}

void main() {
  test('AgentRunner drives a namespaced on-device tool and call_tool through the MCP layer', () async {
    final clock = FakeClock(DateTime.utc(2026, 10, 19, 9));
    final store = InMemorySessionStore();
    await store.putSession(SessionRecord(id: 's', title: defaultSessionTitle, createdAt: clock.now(), updatedAt: clock.now()));
    final kv = InMemoryNoteStorage();
    final onDevice = OnDeviceServers()
      ..register(memoryMcpServer(MemoryNotes(store: kv, clock: clock, ids: SequentialIdGenerator())),
          id: 'memory', name: 'Memory')
      ..register(
        deviceMcpServer(
          clock: clock,
          provider: const StaticDeviceFactsProvider(DeviceFacts(
            appName: 'Sherpa',
            appVersion: '0.4.0',
            platform: 'ios',
            locale: 'en-GB',
            timeZone: 'Europe/London',
            timeZoneOffset: Duration(hours: 1),
          )),
        ),
        id: 'device',
        name: 'Device',
      );
    final policy = ApprovalPolicy(clock: clock);
    final manager = McpServerManager(
      servers: onDevice.configs,
      transportFactory: onDevice.transportFor,
      options: const McpClientOptions(timeouts: McpTimeouts(inProcessProbe: Duration(milliseconds: 500))),
      onTrustChanged: (id, trusted) => trusted ? policy.trustServer(id) : policy.untrustServer(id),
    );
    manager.trustedServerIds.forEach(policy.trustServer);
    // 5 MCP tools + update_plan against a budget of 4 (+1 reserved for the
    // plan tool): the session goes deferred.
    final router = McpToolRouter(
      manager: manager,
      clock: clock,
      defaultBudget: const ToolBudget(maxTools: 5, maxSchemaTokens: 100000, reservedSlots: 1),
      alwaysOn: {'memory__save_note'},
      onGrantsInvalidated: policy.revoke,
    );
    final recorder = _Recorder();
    final provider = ScriptedProvider([
      ScriptedTurn.toolCalls(const [
        ToolCall(id: 'c1', name: 'memory__save_note', arguments: {'text': 'The user likes green tea.', 'tags': ['prefs']}),
      ]),
      ScriptedTurn.toolCalls(const [
        ToolCall(id: 'c2', name: 'call_tool', arguments: {'name': 'device__device_info', 'arguments': <String, Object?>{}}),
      ]),
      ScriptedTurn.text('Noted. It is 10:00 in London.'),
    ]);
    final runner = AgentRunner(
      store: store,
      provider: provider,
      modelId: 'scripted-model',
      tools: CompositeToolRouter([
        LocalToolRouter([UpdatePlanTool(store: store, clock: clock)]),
        router,
      ]),
      approvals: policy,
      approvalHandler: McpApprovalHandler(inner: recorder, router: router, policy: policy),
      clock: clock,
      ids: SequentialIdGenerator(),
      sleep: (_) async {},
    );

    final events = await runner.send('s', const [TextPart('Remember that I like green tea, then tell me the time.')]).toList();

    expect(events.whereType<RunFinished>().single.outcome, RunOutcome.completed);
    expect(provider.requests, hasLength(3));
    final lists = [for (final r in provider.requests) [for (final t in r.tools) t.name]];
    // Core: always-on save_note + current_time ranked from the user's query;
    // the long tail (device_info, search/delete notes) is behind the proxies.
    expect(lists.first, ['update_plan', 'memory__save_note', 'device__current_time', 'tool_search', 'call_tool']);
    expect({for (final l in lists) l.join(',')}, hasLength(1), reason: 'the tool list never changes within the segment');
    expect(
      {for (final r in provider.requests) canonicalJson([for (final t in r.tools) t.toJson()])},
      hasLength(1),
      reason: 'byte-identical definitions (prompt / KV cache prefix)',
    );

    // Approvals: save_note (moderate, not read-only) asked once; the proxied
    // read-only device_info on the trusted server was auto-approved on the
    // TARGET, and nothing was ever granted to "call_tool".
    expect(recorder.asked, ['memory__save_note:memory__save_note']);
    expect(policy.grants.map((g) => g.toolName), ['memory__save_note']);

    final results = [
      for (final m in await store.path('s', (await store.getSession('s'))!.activeLeafId!))
        ...m.toolResults,
    ];
    expect(results.map((r) => r.toolName), ['memory__save_note', 'call_tool']);
    expect(results.first.text, 'Saved note note_1.');
    expect(results.last.text, allOf(contains('app: Sherpa 0.4.0'), contains('timeZone: Europe/London')));
    expect(kv.data.keys, ['memory/note/note_1']);
    expect(events.whereType<RunNotice>().map((n) => n.code), contains('untrusted_content'),
        reason: 'on-device tool output counts as untrusted data');
    expect(router.recentTools('s'), ['device__device_info', 'memory__save_note']);
    // The next segment carries the proxied tool into the core (sticky).
    router.resetSegment('s');
    final next = [for (final t in await router.toolsForTurn(sessionId: 's')) t.name];
    expect(next, containsAll(['device__device_info', 'memory__save_note', 'call_tool']));

    await router.dispose();
    await manager.dispose();
    await onDevice.close();
  });

  test('a proxied destructive call asks the user about the TARGET, and a denial reaches the model', () async {
    final clock = FakeClock();
    final store = InMemorySessionStore();
    await store.putSession(SessionRecord(id: 's', title: defaultSessionTitle, createdAt: clock.now(), updatedAt: clock.now()));
    final kv = InMemoryNoteStorage();
    final notes = MemoryNotes(store: kv, clock: clock, ids: SequentialIdGenerator());
    await notes.save(text: 'keep me');
    final onDevice = OnDeviceServers()..register(memoryMcpServer(notes), id: 'memory', name: 'Memory');
    final policy = ApprovalPolicy(clock: clock, trustedServers: {'memory'});
    final manager = McpServerManager(servers: onDevice.configs, transportFactory: onDevice.transportFor);
    final router = McpToolRouter(manager: manager, clock: clock, defaultBudget: const ToolBudget(maxTools: 2, maxSchemaTokens: 100000));
    final asked = <String>[];
    final runner = AgentRunner(
      store: store,
      provider: ScriptedProvider([
        ScriptedTurn.toolCalls(const [
          ToolCall(id: 'c1', name: 'call_tool', arguments: {
            'name': 'memory__delete_note',
            'arguments': {'id': 'note_1'},
          }),
        ]),
        ScriptedTurn.text('ok'),
      ]),
      modelId: 'm',
      tools: router,
      approvals: policy,
      approvalHandler: McpApprovalHandler(
        inner: _Deny(asked),
        router: router,
        policy: policy,
      ),
      clock: clock,
      ids: SequentialIdGenerator(),
      sleep: (_) async {},
    );
    await runner.send('s', const [TextPart('delete my note')]).toList();
    expect(asked, ['memory__delete_note']);
    expect(kv.data, hasLength(1), reason: 'denied, so not deleted');
    await router.dispose();
    await manager.dispose();
    await onDevice.close();
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
    asked.add(tool!.name);
    expect(requirement.risk, RiskLevel.destructive);
    return const ApprovalResponse(UserDecision.deny);
  }
}
