import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:test/test.dart';

/// M4 review fixes: the side-effect ledger only trusts trusted annotations,
/// an imported handoff taints its session, and approval grants can be
/// persisted and revoked one by one.
void main() {
  final clock = FakeClock();

  group('side-effect ledger', () {
    const claimsReadOnly = ToolAnnotations(readOnlyHint: true, openWorldHint: false);
    const untrustedFetch = ToolDefinition(
      name: 'web__fetch',
      description: 'fetch',
      inputSchema: {'type': 'object'},
      annotations: claimsReadOnly,
      source: ToolSource(ToolSourceKind.mcp, serverId: 'web'),
    );
    const builtinRead = ToolDefinition(
      name: 'read_file',
      description: 'read',
      inputSchema: {'type': 'object'},
      annotations: claimsReadOnly,
    );

    List<Message> calls() => [
          Message(
            id: 'a1',
            role: Role.assistant,
            createdAt: clock.now(),
            content: const [
              ToolCallPart(ToolCall(id: 'c1', name: 'web__fetch', arguments: {'url': 'https://example.com'})),
              ToolCallPart(ToolCall(id: 'c2', name: 'read_file', arguments: {'path': 'a.txt'})),
            ],
          ),
          Message(
            id: 't1',
            parentId: 'a1',
            role: Role.tool,
            createdAt: clock.now(),
            content: const [
              ToolResultPart(callId: 'c1', toolName: 'web__fetch', content: [TextPart('page')]),
              ToolResultPart(callId: 'c2', toolName: 'read_file', content: [TextPart('file')]),
            ],
          ),
        ];

    test("an untrusted server's readOnlyHint does not keep its call out of the ledger", () {
      final h = SummaryComposer.harvest(CompactionInput(messages: calls(), tools: const [untrustedFetch, builtinRead]));
      expect(h.sideEffects.map((s) => s.callId), ['c1'], reason: 'built-in read-only stays out; the MCP claim counts as a write');
      expect(h.sideEffects.single.server, 'web');
    });

    test('the approval policy decides which servers are trusted', () {
      final trusting = ApprovalPolicy(clock: clock, trustedServers: {'web'});
      final h = SummaryComposer.harvest(CompactionInput(
        messages: calls(),
        tools: const [untrustedFetch, builtinRead],
        annotationsFor: trusting.annotationsFor,
      ));
      expect(h.sideEffects, isEmpty, reason: 'trusted read-only hints are honoured');

      final strict = ApprovalPolicy(clock: clock);
      final h2 = SummaryComposer.harvest(CompactionInput(
        messages: calls(),
        tools: const [untrustedFetch, builtinRead],
        annotationsFor: strict.annotationsFor,
      ));
      expect(h2.sideEffects.map((s) => s.callId), ['c1']);
    });

    test('LadderContextManager forwards annotationsFor to compaction', () {
      final policy = ApprovalPolicy(clock: clock);
      final m = LadderContextManager(annotationsFor: policy.annotationsFor);
      expect(m.annotationsFor, isNotNull);
      expect(m.annotationsFor!(untrustedFetch).isReadOnly, isFalse);
    });
  });

  group('imported handoff', () {
    const source = HandoffSource(
      appVersion: '0.1.0',
      providerKind: 'anthropic',
      modelId: 'm',
      location: ExecutionLocation.remote,
    );
    HandoffBundle bundle({List<TaintRecord> taint = const []}) => HandoffBundle(
          createdAt: DateTime.utc(2026, 10, 18),
          source: source,
          task: 'Finish the report',
          summary: CompactionSummary(goal: 'report', taint: taint),
        );

    final ids = SequentialIdGenerator();

    Future<(InMemorySessionStore, SessionRecord)> start(HandoffBundle b, {bool trustedSource = false}) async {
      final store = InMemorySessionStore();
      final s = await startSessionFromHandoff(
        store: store,
        bundle: b,
        sessionId: 's',
        ids: ids,
        clock: clock,
        trustedSource: trustedSource,
        nonce: 'abcdef0123456789',
      );
      return (store, s);
    }

    Future<Message> seed(InMemorySessionStore store, SessionRecord s) async =>
        (await store.path('s', s.activeLeafId!)).firstWhere((m) => m.kind == MessageKind.handoff);

    test('the seed of an imported bundle is flagged untrusted', () async {
      final (store, s) = await start(bundle());
      expect((await seed(store, s)).metadata[UntrustedData.messageMetadataKey], isTrue);
    });

    test("the user's own untainted session is not flagged; a tainted one is", () async {
      final (store, s) = await start(bundle(), trustedSource: true);
      expect((await seed(store, s)).metadata.containsKey(UntrustedData.messageMetadataKey), isFalse);
      final (store2, s2) = await start(
        bundle(taint: const [TaintRecord(source: 'mcp:web/fetch', firstMessageId: 'm1')]),
        trustedSource: true,
      );
      expect((await seed(store2, s2)).metadata[UntrustedData.messageMetadataKey], isTrue);
    });

    test('a run in a session seeded from an import asks before acting', () async {
      final (store, _) = await start(bundle());
      final email = _Tool('mail__send', const ToolAnnotations(destructiveHint: false, openWorldHint: true));
      final policy = ApprovalPolicy(clock: clock, trustedServers: {'mail'});
      policy.record('mail__send', 's', const ApprovalResponse(UserDecision.approve, scope: ApprovalScope.session));
      final handler = _Recorder();
      final runner = AgentRunner(
        store: store,
        provider: ScriptedProvider([
          ScriptedTurn.toolCalls(const [ToolCall(id: 'c1', name: 'mail__send', arguments: {'to': 'a@example.com'})]),
          ScriptedTurn.text('ok'),
        ]),
        modelId: 'm',
        tools: LocalToolRouter([email]),
        approvals: policy,
        approvalHandler: handler,
        clock: clock,
        ids: ids,
        sleep: (_) async {},
      );
      final events = await runner.send('s', const [TextPart('go on')]).toList();
      expect(handler.asked, ['mail__send'], reason: 'the session grant does not cover a tainted session');
      expect(email.runs, 0);
      expect(events.whereType<RunNotice>().map((n) => n.code), contains('untrusted_content'));
    });
  });

  group('approval grants', () {
    const tool = ToolDefinition(
      name: 'mail__send',
      description: '',
      inputSchema: {},
      annotations: ToolAnnotations(destructiveHint: false),
      source: ToolSource(ToolSourceKind.mcp, serverId: 'mail'),
      definitionHash: 'h1',
    );

    test('every change reports the new list, which round-trips through JSON', () {
      final seen = <List<ApprovalGrant>>[];
      final policy = ApprovalPolicy(clock: clock, trustedServers: {'mail'}, onGrantsChanged: seen.add);
      policy.recordFor(tool, 's', const ApprovalResponse(UserDecision.approve, scope: ApprovalScope.always));
      policy.recordFor(tool, 's', const ApprovalResponse(UserDecision.approve));
      expect(seen, hasLength(1), reason: 'a one-off answer records nothing');
      final restored = ApprovalPolicy(
        clock: clock,
        trustedServers: {'mail'},
        grants: [for (final g in seen.last) ApprovalGrant.fromJson(g.toJson())],
      );
      expect(restored.evaluate(tool, 'other'), isA<AutoApprove>());
      expect(restored.grants.single.definitionHash, 'h1');
    });

    test('grants are revoked one at a time, and expired ones pruned', () {
      final changes = <int>[];
      final policy = ApprovalPolicy(clock: clock, trustedServers: {'mail'}, onGrantsChanged: (g) => changes.add(g.length));
      policy.recordFor(tool, 's1', const ApprovalResponse(UserDecision.approve, scope: ApprovalScope.session));
      policy.recordFor(
        tool,
        's2',
        const ApprovalResponse(UserDecision.approve, scope: ApprovalScope.session, expiresIn: Duration(minutes: 5)),
      );
      policy.revokeGrant(policy.grants.first);
      expect(policy.grants.single.sessionId, 's2');
      expect(policy.pruneExpired(), 0);
      clock.advance(const Duration(minutes: 6));
      expect(policy.pruneExpired(), 1);
      expect(policy.grants, isEmpty);
      expect(changes, [1, 2, 1, 0]);
    });
  });
}

final class _Tool implements LocalTool {
  _Tool(this.name, this.annotations);
  final String name;
  final ToolAnnotations annotations;
  int runs = 0;

  @override
  ToolDefinition get definition => ToolDefinition(
        name: name,
        description: name,
        inputSchema: const {'type': 'object'},
        annotations: annotations,
        source: const ToolSource(ToolSourceKind.mcp, serverId: 'mail'),
      );

  @override
  Future<ToolResult> run(Map<String, Object?> arguments, ToolExecutionContext context) async {
    runs++;
    return ToolResult.text('sent');
  }
}

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
    asked.add(call.name);
    return const ApprovalResponse(UserDecision.deny);
  }
}
