import 'package:sherpa_core/sherpa_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// L4-style compaction fidelity (R11 §9.9): plant constraints, preferences,
/// paths, handles and completed side effects across 40 turns, force 1, 2 and
/// 4 compactions with the deterministic summarizer, then check what the
/// final summary retained and that no side effect appears twice.
void main() {
  const tools = [
    readFile,
    writeFile,
    ToolDefinition(name: 'send_email', description: 'Send', inputSchema: {'type': 'object'}),
    ToolDefinition(
      name: 'cart_create',
      description: 'Create a cart',
      inputSchema: {'type': 'object'},
      annotations: ToolAnnotations(idempotentHint: false, destructiveHint: false),
    ),
  ];
  final constraints = [for (var k = 0; k < 8; k++) 'You must never modify legacy_$k.py.'];
  final preferences = [for (var k = 0; k < 4; k++) 'I prefer variant $k for naming.'];
  final writes = [for (var k = 0; k < 8; k++) '/proj/out/report_$k.md'];
  final handles = [for (var k = 0; k < 4; k++) 'cart-$k-xyz'];

  /// Appends turn [t] (user message, tool work, answer).
  void turn(Conv c, int t) {
    final said = [
      'Turn $t: continue the migration.',
      if (t % 5 == 0) constraints[t ~/ 5],
      if (t % 10 == 3) preferences[t ~/ 10],
    ].join(' ');
    c.user(said);
    c.toolTurn('r$t', 'read_file', {'path': '/proj/src/module_$t.py'}, lines(30, prefix: 'code $t'));
    if (t % 5 == 2) {
      final k = t ~/ 5;
      c.toolTurn('w$k', 'write_file', {'path': writes[k], 'content': 'report $k'}, 'wrote ${writes[k]}');
    }
    if (t % 10 == 4) {
      final k = t ~/ 10;
      c.toolTurn('cart$k', 'cart_create', {'owner': 'me', 'label': 'cart $k'}, '{"basket_id": "${handles[k]}", "items": []}');
      c.toolTurn('mail$k', 'send_email', {'to': 'team@example.com', 'subject': 'cart $k'}, 'sent');
    }
    c.assistant('Turn $t done. ${'notes ' * 40}');
  }

  Future<(CompactionSummary, List<CompactedRange>, Conv)> run(Set<int> compactAt) async {
    final manager = LadderContextManager(clock: FakeClock());
    final settings = ContextSettings(profile: compactEverything);
    final c = Conv();
    final overlays = <ContextOverlay>[];
    for (var t = 0; t < 40; t++) {
      turn(c, t);
      if (!compactAt.contains(t + 1)) continue;
      // Compact at the boundary before turn t+1's user message.
      c.user('Turn ${t + 1} is next.');
      final outcome = await manager.compactNow(req(c.messages, overlays: overlays, tools: tools, settings: settings, window: 65536));
      expect(outcome.compacted, isTrue, reason: 'compaction before turn ${t + 1}: ${outcome.skippedReason}');
      overlays.add(outcome.overlay!);
    }
    final ranges = overlays.whereType<CompactedRange>().toList();
    return (ranges.last.summary, ranges, c);
  }

  for (final schedule in [
    {40},
    {20, 40},
    {10, 20, 30, 40},
  ]) {
    test('retention after ${schedule.length} compaction(s)', () async {
      final (summary, ranges, conv) = await run(schedule);
      expect(summary.compactionCount, schedule.length);
      expect(ranges.map((r) => r.fromMessageId).toSet(), {'m1'}, reason: 'rolling: every range starts at the root');

      // Constraints and preferences: carried forward deterministically.
      for (final x in constraints) {
        expect(summary.constraints.join('\n'), contains(x), reason: 'constraint lost: $x');
      }
      for (final x in preferences) {
        expect(summary.userPreferences.join('\n'), contains(x), reason: 'preference lost: $x');
      }

      // Handles and written paths.
      final rendered = summary.render();
      for (final h in handles) {
        expect(summary.stateHandles.map((s) => s.value), contains(h), reason: 'handle lost: $h');
      }
      for (final w in writes) {
        expect(rendered, contains(w), reason: 'written path lost: $w');
      }

      // Side effects: every completed write/send exactly once, reads never.
      final ids = summary.sideEffectLedger.map((s) => s.callId).toList();
      expect(ids.toSet(), {
        for (var k = 0; k < 8; k++) 'w$k',
        for (var k = 0; k < 4; k++) ...['cart$k', 'mail$k'],
      });
      expect(ids.length, ids.toSet().length, reason: 'duplicate side effect in the ledger');
      final digests = summary.sideEffectLedger.map((s) => '${s.tool}:${s.argsDigest}').toList();
      expect(digests.length, digests.toSet().length);
      expect(rendered, contains('do not repeat them'));

      // The latest user turn stays verbatim after the summary.
      final p = await LadderContextManager(clock: FakeClock()).prepare(
          req(conv.messages, overlays: ranges, tools: tools, window: 65536));
      expect(p.messages.first.kind, MessageKind.summary);
      expect(p.messages.last.text, 'Turn 40 is next.');
      expectProviderInvariants(p.messages);

      // Summary cost stays bounded however many times it was merged.
      expect(const QuarterCounter().countText(rendered), lessThan(4000));
    });
  }
}
