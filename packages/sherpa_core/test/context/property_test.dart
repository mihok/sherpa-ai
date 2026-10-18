import 'dart:convert';
import 'dart:math';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const _system = 'You are a test assistant.';
const _tools = ['read_file', 'write_file', 'search', 'update_plan', 'send_email'];

String _words(Random r, int n) => [for (var i = 0; i < n; i++) 'w${r.nextInt(1000)}'].join(' ');

String _payload(Random r) => switch (r.nextInt(4)) {
      0 => 'ok',
      1 => [for (var i = 0; i < r.nextInt(200); i++) 'row $i ${_words(r, 6)}'].join('\n'),
      2 => jsonEncode({
          'items': [for (var i = 0; i < r.nextInt(80); i++) {'id': 'id-$i', 'body': _words(r, 10)}],
          'basket_id': 'b-${r.nextInt(99)}',
        }),
      _ => _words(r, r.nextInt(1500)),
    };

/// Appends one random agent step (assistant tool calls + results).
void _toolStep(Conv c, Random r, List<int> callSeq, String key) {
  final n = 1 + r.nextInt(3);
  final calls = [
    for (var i = 0; i < n; i++)
      ToolCall(
        id: 'c${callSeq[0]++}',
        name: _tools[r.nextInt(_tools.length)],
        arguments: {
          'path': '/w/f${r.nextInt(20)}.txt',
          if (r.nextInt(5) == 0) 'content': 'x' * r.nextInt(8000),
        },
      ),
  ];
  c.assistant(r.nextBool() ? '' : 'calling tools', calls: calls, reasoning: r.nextInt(3) == 0 ? 'think' : null, prefixKey: key);
  c.results([
    for (final call in calls)
      ToolResultPart(callId: call.id, toolName: call.name, content: [TextPart(_payload(r))], isError: r.nextInt(8) == 0),
  ], pinned: r.nextInt(20) == 0);
}

List<Message> _conversation(Random r) {
  final c = Conv();
  final key = PassthroughContextManager.prefixKeyOf(_system, const [], const []);
  final calls = [0];
  final turns = 1 + r.nextInt(12);
  for (var t = 0; t < turns; t++) {
    c.user('Turn $t. ${_words(r, r.nextInt(400))}', pinned: r.nextInt(12) == 0);
    for (var s = r.nextInt(4); s > 0; s--) {
      _toolStep(c, r, calls, key);
    }
    final last = t == turns - 1;
    if (!last || r.nextBool()) c.assistant('answer $t ${_words(r, r.nextInt(80))}', reasoning: r.nextInt(3) == 0 ? 'hmm' : null, prefixKey: key);
  }
  if (c.messages.last.role == Role.assistant) c.user('next? ${_words(r, r.nextInt(50))}');
  return c.messages;
}

ContextRequest _request(Random r, List<Message> path, List<ContextOverlay> overlays, {required HistoryPolicy policy, required int window, required int maxOutput, required ContextSettings settings}) =>
    req(path, overlays: overlays, window: window, maxOutput: maxOutput, policy: policy, settings: settings, systemPrompt: _system);

void _expectInvariants(List<Message> path, ContextRequest request, PreparedContext p, String why) {
  expectProviderInvariants(p.messages, reason: why);
  final sent = {for (final m in p.messages) m.id: m};
  for (final m in path.where((m) => m.pinned)) {
    expect(sent[m.id], isNotNull, reason: '$why: pinned ${m.id} dropped');
    expect(jsonEncode(sent[m.id]!.toJson()), jsonEncode(m.toJson()), reason: '$why: pinned ${m.id} changed');
  }
  expect(sent.containsKey(path.last.id), isTrue, reason: '$why: latest message missing');
  if (path.last.role == Role.user) {
    expect(jsonEncode(sent[path.last.id]!.toJson()), jsonEncode(path.last.toJson()), reason: '$why: latest user turn changed');
  }
  if (p.recommendation?.kind != ContextRecommendationKind.hardStop) {
    expect(p.budget.fits, isTrue, reason: '$why: silent overflow');
  }
  if (request.capabilities.historyPolicy == HistoryPolicy.appendOnly) {
    if (path.last.role != Role.user) expect(p.newOverlays, isEmpty, reason: '$why: rewrite mid tool loop');
    for (final m in p.messages.where((m) => m.reasoning.isNotEmpty)) {
      expect(m.metadata['prefixKey'], p.prefixKey, reason: '$why: reasoning from an older prefix replayed');
    }
  }
}

void main() {
  test('random conversations × random budgets: pairing, pinned, no overflow, idempotent', () async {
    final manager = LadderContextManager(clock: FakeClock());
    for (var seed = 0; seed < 200; seed++) {
      final r = Random(seed);
      final path = _conversation(r);
      final policy = r.nextBool() ? HistoryPolicy.appendOnly : HistoryPolicy.mutable;
      final window = [1024, 2048, 4096, 6000, 8192, 16384, 32768][r.nextInt(7)];
      final maxOutput = [128, 256, 512, 1024][r.nextInt(4)];
      final settings = ContextSettings(
        largeToolResultTokens: 100 + r.nextInt(1500),
        largeToolInputTokens: 100 + r.nextInt(1000),
        keepRecentToolCalls: 1 + r.nextInt(4),
        staleAfterTurns: 1 + r.nextInt(3),
      );
      final why = 'seed $seed ($window/$maxOutput ${policy.name}, ${path.length} msgs)';
      final request = _request(r, path, const [], policy: policy, window: window, maxOutput: maxOutput, settings: settings);
      final first = await manager.prepare(request);
      _expectInvariants(path, request, first, why);

      final again = _request(r, path, first.newOverlays, policy: policy, window: window, maxOutput: maxOutput, settings: settings);
      final second = await manager.prepare(again);
      expect(second.newOverlays, isEmpty, reason: '$why: not idempotent');
      expect(second.prefixKey, first.prefixKey, reason: why);
      expect(jsonEncode([for (final m in second.messages) m.toJson()]), jsonEncode([for (final m in first.messages) m.toJson()]),
          reason: '$why: recompute changed the view');
      expect(manager.inspect(again).pairingIssues, isEmpty, reason: why);
    }
  });

  test('simulated sessions: invariants hold on every step with overlays persisted', () async {
    final manager = LadderContextManager(clock: FakeClock());
    for (var seed = 0; seed < 40; seed++) {
      final r = Random(1000 + seed);
      final policy = r.nextBool() ? HistoryPolicy.appendOnly : HistoryPolicy.mutable;
      final window = [2048, 4096, 8192, 16384][r.nextInt(4)];
      final settings = ContextSettings(largeToolResultTokens: 200 + r.nextInt(800));
      final c = Conv();
      final overlays = <ContextOverlay>[];
      final calls = [0];
      var key = PassthroughContextManager.prefixKeyOf(_system, const [], const []);
      var compactions = 0;
      for (var turn = 0; turn < 25; turn++) {
        c.user('Turn $turn. ${_words(r, r.nextInt(300))}', pinned: turn == 0);
        for (var step = 0; step <= r.nextInt(3); step++) {
          final request = _request(r, c.messages, overlays, policy: policy, window: window, maxOutput: 256, settings: settings);
          final p = await manager.prepare(request);
          final why = 'seed $seed turn $turn step $step ($window ${policy.name})';
          _expectInvariants(c.messages, request, p, why);
          overlays.addAll(p.newOverlays);
          compactions += p.newOverlays.whereType<CompactedRange>().length;
          key = p.prefixKey!;
          if (p.recommendation?.kind == ContextRecommendationKind.hardStop) break;
          if (r.nextInt(3) == 0) break;
          _toolStep(c, r, calls, key);
        }
        if (c.messages.last.role != Role.assistant) c.assistant('answer $turn', prefixKey: key);
      }
      // Rolling compaction: at most one summary is ever visible.
      c.user('end');
      final last = await manager.prepare(
          _request(r, c.messages, overlays, policy: policy, window: window, maxOutput: 256, settings: settings));
      expect(last.messages.where((m) => m.kind == MessageKind.summary && m.role == Role.user).length, lessThanOrEqualTo(1));
      if (compactions > 1) {
        final latest = overlays.whereType<CompactedRange>().last.summary;
        expect(latest.compactionCount, greaterThan(1), reason: 'seed $seed: summaries are merged, not nested');
      }
    }
  });
}
