import 'dart:convert';
import 'dart:typed_data';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:test/test.dart';

T roundTrip<T>(T value, Map<String, Object?> Function(T) toJson, T Function(JsonMap) fromJson) {
  final encoded = jsonEncode(toJson(value));
  return fromJson((jsonDecode(encoded) as Map).cast<String, Object?>());
}

void main() {
  group('Message JSON', () {
    test('round-trips every content part type', () {
      final msg = Message(
        id: 'm1',
        parentId: 'm0',
        role: Role.assistant,
        createdAt: DateTime.utc(2026, 10, 18, 12),
        pinned: true,
        usage: const Usage(inputTokens: 5, outputTokens: 7, cacheReadTokens: 2),
        content: [
          const TextPart('hello'),
          ImagePart(mimeType: 'image/png', data: Uint8List.fromList([1, 2, 3])),
          AudioPart(mimeType: 'audio/wav', uri: Uri.parse('file:///tmp/a.wav')),
          const ResourceLinkPart(uri: 'file:///x', name: 'x', size: 10),
          const EmbeddedResourcePart(uri: 'mem://a', text: 'body'),
          const ReasoningPart(text: 'think', signature: 'sig', providerId: 'anthropic'),
          const ToolCallPart(ToolCall(id: 'c1', name: 'search', arguments: {'q': 'dart'})),
          const ToolResultPart(
            callId: 'c1',
            toolName: 'search',
            content: [TextPart('result')],
            structured: {'hits': 3},
            isError: true,
            uiResourceUri: 'ui://search/view',
          ),
          const UiResourcePart(resourceUri: 'ui://a', serverId: 's1'),
        ],
      );
      final back = roundTrip(msg, (m) => m.toJson(), Message.fromJson);
      expect(jsonEncode(back.toJson()), jsonEncode(msg.toJson()));
      expect(back.toolCalls.single.arguments['q'], 'dart');
      expect((back.content[1] as ImagePart).data, [1, 2, 3]);
      expect(back.toolResults.single.structured, {'hits': 3});
    });

    test('unknown part types are preserved verbatim', () {
      final j = {
        'id': 'm',
        'role': 'user',
        'createdAt': '2026-01-01T00:00:00.000Z',
        'content': [
          {'type': 'hologram', 'x': 1},
        ],
      };
      final m = Message.fromJson(j);
      expect(m.content.single, isA<UnknownPart>());
      expect(m.toJson()['content'], j['content']);
    });
  });

  test('ToolDefinition round-trips annotations and source', () {
    const t = ToolDefinition(
      name: 'gh__create_issue',
      originalName: 'create_issue',
      description: 'Create',
      inputSchema: {'type': 'object'},
      annotations: ToolAnnotations(destructiveHint: false, openWorldHint: true),
      source: ToolSource(ToolSourceKind.mcp, serverId: 'gh'),
      modelVisible: false,
    );
    final back = roundTrip(t, (x) => x.toJson(), ToolDefinition.fromJson);
    expect(back.wireName, 'create_issue');
    expect(back.annotations.isDestructive, isFalse);
    expect(back.source.serverId, 'gh');
    expect(back.modelVisible, isFalse);
  });

  test('annotation defaults follow the MCP spec', () {
    const a = ToolAnnotations();
    expect(a.isReadOnly, isFalse);
    expect(a.isDestructive, isTrue);
    expect(a.isIdempotent, isFalse);
    expect(a.isOpenWorld, isTrue);
    expect(const ToolAnnotations(readOnlyHint: true).isDestructive, isFalse);
  });

  test('overlays round-trip', () {
    final overlays = <ContextOverlay>[
      ToolOutputElided(
        id: 'o1',
        createdAt: DateTime.utc(2026),
        reason: 'stale',
        tokensSaved: 100,
        messageId: 'm',
        callId: 'c',
        stub: '[elided]',
      ),
      CompactedRange(
        id: 'o2',
        createdAt: DateTime.utc(2026),
        reason: '80%',
        tokensSaved: 5000,
        fromMessageId: 'a',
        toMessageId: 'b',
        strategyId: 'llm',
        summary: const CompactionSummary(goal: 'ship', decisions: ['flutter']),
      ),
    ];
    for (final o in overlays) {
      final back = roundTrip(o, (x) => x.toJson(), ContextOverlay.fromJson);
      expect(jsonEncode(back.toJson()), jsonEncode(o.toJson()));
    }
  });

  test('checkpoint and plan round-trip', () {
    final cp = RunCheckpoint(
      sessionId: 's',
      runId: 'r',
      phase: RunPhase.executingTools,
      step: 3,
      updatedAt: DateTime.utc(2026),
      pendingCalls: const [PendingCall(callId: 'c', toolName: 't', status: PendingCallStatus.running)],
    );
    expect(jsonEncode(roundTrip(cp, (x) => x.toJson(), RunCheckpoint.fromJson).toJson()),
        jsonEncode(cp.toJson()));
    final plan = Plan(
      task: 'do it',
      updatedAt: DateTime.utc(2026),
      items: const [PlanItem(id: '1', title: 'a', status: PlanStatus.inProgress)],
    );
    expect(roundTrip(plan, (x) => x.toJson(), Plan.fromJson).render(), plan.render());
  });

  group('ContextBudget', () {
    test('levels follow thresholds', () {
      ContextBudget b(int history) => ContextBudget(
            limit: 1100,
            outputReserve: 100,
            safetyMargin: 0,
            systemTokens: 0,
            toolTokens: 0,
            pinnedTokens: 0,
            historyTokens: history,
            exact: true,
          );
      const t = ContextThresholds();
      expect(b(100).levelFor(t), ContextLevel.healthy);
      expect(b(600).levelFor(t), ContextLevel.pruning);
      expect(b(800).levelFor(t), ContextLevel.compacting);
      expect(b(920).levelFor(t), ContextLevel.handoff);
      expect(b(1001).levelFor(t), ContextLevel.overflow);
      expect(b(1001).fits, isFalse);
    });
  });

  group('HeuristicTokenCounter', () {
    test('counts dense scripts per character', () {
      final c = HeuristicTokenCounter();
      expect(c.countText(''), 0);
      expect(c.countText('日本語'), 4);
      expect(c.countText('hello world'), greaterThan(2));
    });

    test('calibration moves toward observed ratio and stays bounded', () {
      final c = HeuristicTokenCounter(family: 'qwen');
      final before = c.charsPerToken;
      c.calibrate(estimated: 100, actual: 200);
      expect(c.charsPerToken, lessThan(before));
      for (var i = 0; i < 50; i++) {
        c.calibrate(estimated: 1, actual: 1000);
      }
      expect(c.charsPerToken, 2.0);
    });
  });

  group('CancellationToken', () {
    test('cancelling a parent cancels children', () async {
      final root = CancellationToken();
      final child = root.child();
      final grandchild = child.child();
      root.cancel('stop');
      expect(child.isCancelled, isTrue);
      expect(grandchild.reason, 'stop');
      expect(await grandchild.whenCancelled, 'stop');
      expect(grandchild.throwIfCancelled, throwsA(isA<CancelledException>()));
    });

    test('child of a cancelled parent starts cancelled', () {
      final root = CancellationToken()..cancel();
      expect(root.child().isCancelled, isTrue);
    });
  });

  group('ApprovalPolicy', () {
    final clock = FakeClock();
    const readOnlyMcp = ToolDefinition(
      name: 'fs__read',
      description: '',
      inputSchema: {},
      annotations: ToolAnnotations(readOnlyHint: true),
      source: ToolSource(ToolSourceKind.mcp, serverId: 'fs'),
    );
    const destructive = ToolDefinition(
      name: 'fs__delete',
      description: '',
      inputSchema: {},
      source: ToolSource(ToolSourceKind.mcp, serverId: 'fs'),
    );

    test('untrusted read-only open-world tools still need confirmation', () {
      final p = ApprovalPolicy(clock: clock);
      expect(p.evaluate(readOnlyMcp, 's'), isA<NeedsConfirmation>());
      p.trustServer('fs');
      expect(p.evaluate(readOnlyMcp, 's'), isA<AutoApprove>());
    });

    test('destructive tools need confirmation; grants honour scope and expiry', () {
      final p = ApprovalPolicy(clock: clock, trustedServers: {'fs'});
      final r = p.evaluate(destructive, 's1');
      expect(r, isA<NeedsConfirmation>());
      expect((r as NeedsConfirmation).risk, RiskLevel.destructive);
      p.record('fs__delete', 's1',
          const ApprovalResponse(UserDecision.approve, scope: ApprovalScope.session, expiresIn: Duration(hours: 1)));
      expect(p.evaluate(destructive, 's1'), isA<AutoApprove>());
      expect(p.evaluate(destructive, 's2'), isA<NeedsConfirmation>());
      clock.advance(const Duration(hours: 2));
      expect(p.evaluate(destructive, 's1'), isA<NeedsConfirmation>());
    });
  });
}
