import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:test/test.dart';

import 'helpers.dart';

String encode(List<Message> ms) => jsonEncode([for (final m in ms) m.toJson()]);

void main() {
  final profile = WindowProfile(
    thresholds: const ContextThresholds(prune: 0.05, compact: 0.10, handoff: 0.99),
    keepRecentUserTurns: 2,
    keptTailFraction: 0.9,
  );
  final settings = ContextSettings(profile: profile, keepRecentToolCalls: 1, largeToolResultTokens: 500);

  Conv conversation() {
    final c = Conv()..user('Start the audit. Never email customers.');
    c.toolTurn('c1', 'read_file', {'path': '/w/old.log'}, lines(300));
    c.assistant('Read the old log. ${'analysis ' * 300}');
    c.user('Next file.');
    for (final id in ['c2', 'c3', 'c4']) {
      c.toolTurn(id, 'read_file', {'path': '/w/$id.log'}, lines(120));
    }
    c.assistant('Read three more.');
    c.user('Summarize the findings.');
    return c;
  }

  test('inspect shows exactly what prepare sends, with per-item tokens', () async {
    final c = conversation();
    final m = LadderContextManager(clock: FakeClock());
    final prepared = await m.prepare(req(c.messages, settings: settings));
    expect(prepared.newOverlays.whereType<ToolOutputElided>(), hasLength(3));
    expect(prepared.newOverlays.whereType<CompactedRange>(), hasLength(1));
    final i = m.inspect(req(c.messages, overlays: prepared.newOverlays, settings: settings));
    expect(encode(i.messages), encode(prepared.messages));
    expect(i.prefixKey, prepared.prefixKey);
    expect(i.items.fold(0, (n, x) => n + x.tokens), i.budget.pinnedTokens + i.budget.historyTokens);
    final compaction = prepared.newOverlays.whereType<CompactedRange>().single;
    expect(i.items.first.source, ContextItemSource.summary);
    expect(i.items.first.overlayIds, [compaction.id]);
    final edited = i.items.where((x) => x.source == ContextItemSource.edited).toList();
    expect(edited, isNotEmpty);
    expect(edited.expand((x) => x.overlayIds), everyElement(startsWith('ctx-elide:')));
    expect(i.items.last.source, ContextItemSource.transcript);
  });

  test('a diff per overlay: before/after, tokens, reason, shadowing', () async {
    final c = conversation();
    final m = LadderContextManager(clock: FakeClock());
    final prepared = await m.prepare(req(c.messages, settings: settings));
    final i = m.inspect(req(c.messages, overlays: prepared.newOverlays, settings: settings));
    expect(i.diffs, hasLength(prepared.newOverlays.length));
    final elided = i.diffFor('ctx-elide:m3:c1')!;
    expect(elided.kind, ContextDiffKind.elision);
    expect(elided.before, contains('line 150 of the payload text'));
    expect(elided.after, startsWith('[tool result elided: read_file'));
    expect(elided.tokensBefore, greaterThan(elided.tokensAfter));
    expect(elided.tokensSaved, elided.recordedTokensSaved);
    expect(elided.reason, contains('stale read_file result'));
    final compaction = prepared.newOverlays.whereType<CompactedRange>().single;
    expect(elided.status, OverlayStatus.shadowed, reason: 'its message is inside the compacted range');
    expect(elided.shadowedBy, compaction.id);
    final cd = i.diffFor(compaction.id)!;
    expect(cd.kind, ContextDiffKind.compaction);
    expect(cd.status, OverlayStatus.active);
    expect(cd.messageIds.first, 'm1');
    expect(cd.after, startsWith(CompactionSummary.header));
    expect(cd.tokensBefore, greaterThan(cd.tokensAfter));
    expect(cd.strategyId, 'extractive');
    expect(cd.reason, contains('summarized'));
  });

  test('undo = remove the overlay; dependents of a rolling compaction go with it', () async {
    final c = Conv()..user('Task: refactor. Keep the public API.');
    c.assistant('ok');
    for (var i = 0; i < 3; i++) {
      c.user('Turn $i ${'word ' * 50}');
      c.assistant('ok $i ${'detail ' * 100}');
    }
    final m = LadderContextManager(clock: FakeClock());
    final settings = ContextSettings(profile: compactEverything);
    final first = await m.prepare(req(c.messages, settings: settings));
    final c1 = first.newOverlays.whereType<CompactedRange>().single;
    for (var i = 3; i < 6; i++) {
      c.user('Turn $i ${'word ' * 50}');
      c.assistant('ok $i ${'detail ' * 100}');
    }
    final second = await m.prepare(req(c.messages, overlays: first.newOverlays, settings: settings));
    final c2 = second.newOverlays.whereType<CompactedRange>().single;
    final all = [...first.newOverlays, ...second.newOverlays];
    final i = m.inspect(req(c.messages, overlays: all, settings: settings));
    expect(i.diffFor(c1.id)!.status, OverlayStatus.shadowed);
    expect(i.diffFor(c1.id)!.shadowedBy, c2.id);
    expect(i.diffFor(c1.id)!.dependents, [c2.id]);
    expect(i.undoSet(c1.id), [c1.id, c2.id]);
    expect(i.undoSet(c2.id), [c2.id]);

    // Undo the newer one: the older summary is in effect again.
    final undone = m.inspect(req(c.messages, overlays: first.newOverlays, settings: settings));
    expect(undone.items.first.overlayIds, [c1.id]);
    // Undo both: the verbatim transcript is back.
    final raw = m.inspect(req(c.messages, settings: settings));
    expect(encode(raw.messages), encode(c.messages));
  });

  test('inspect is pure: no model calls, nothing created', () async {
    final provider = ScriptedProvider(const []);
    final m = LadderContextManager(strategy: ModelContextStrategy(provider: provider, modelId: 'x'), clock: FakeClock());
    final c = conversation();
    final i = m.inspect(req(c.messages, settings: settings));
    expect(provider.requests, isEmpty);
    expect(i.diffs, isEmpty);
    expect(i.level, isNot(ContextLevel.healthy), reason: 'reports the level the recorded overlays leave');
  });

  test('overlays for another branch are inactive', () {
    final c = conversation();
    final orphan = ToolOutputElided(
      id: 'x',
      createdAt: DateTime.utc(2026),
      reason: 'other branch',
      tokensSaved: 10,
      messageId: 'not-on-path',
      callId: 'c1',
      stub: 's',
    );
    final i = LadderContextManager(clock: FakeClock()).inspect(req(c.messages, overlays: [orphan]));
    expect(i.diffFor('x')!.status, OverlayStatus.inactive);
    expect(encode(i.messages), encode(c.messages));
  });
}
