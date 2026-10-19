import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const _write = ToolAnnotations(readOnlyHint: false, destructiveHint: false, openWorldHint: false);
const _read = ToolAnnotations(readOnlyHint: true, openWorldHint: false);

ToolDefinition _mcp(String server, String name, ToolAnnotations a) => ToolDefinition(
      name: '${server}__$name',
      originalName: name,
      description: name,
      inputSchema: const {'type': 'object'},
      annotations: a,
      source: ToolSource(ToolSourceKind.mcp, serverId: server),
    );

const _callTool = ToolDefinition(
  name: 'call_tool',
  description: 'proxy',
  inputSchema: {'type': 'object'},
  annotations: ToolAnnotations(readOnlyHint: false, destructiveHint: true),
);

final _defs = {
  for (final d in [
    _mcp('files', 'write_file', _write),
    _mcp('files', 'read_file', _read),
    _mcp('notes', 'create_note', _write),
    _callTool,
  ])
    d.name: d,
};

/// Trusts every server (what `ApprovalPolicy.annotationsFor` returns for
/// trusted servers).
ToolAnnotations _trustAll(ToolDefinition d) => d.annotations;

extension on Conv {
  /// A call made through `call_tool`, answered as the agent loop does:
  /// the result names the proxy, its meta the tool that ran.
  void proxied(String id, String target, Map<String, Object?> args, String result, {String? server}) {
    assistant('', calls: [ToolCall(id: id, name: 'call_tool', arguments: {'name': target, 'arguments': args})]);
    results([
      ToolResultPart(
        callId: id,
        toolName: 'call_tool',
        content: [TextPart(result)],
        meta: {ToolResultPart.metaTool: target, ToolResultPart.metaServerId: ?server},
      ),
    ]);
  }
}

SideEffectRecord _rec(int i, {String tool = 'files__write_file', bool read = false}) => SideEffectRecord(
      callId: 'c$i',
      tool: tool,
      server: 'files',
      argsDigest: Digest.args({'path': '/w/$i.txt'}),
      outcome: SideEffectOutcome.ok,
      argsPreview: '{"path":"/w/$i.txt"}',
      keyArgs: ['path="/w/$i.txt"'],
      declaredReadOnly: read,
    );

void main() {
  group('proxied calls are judged and ledgered as their target', () {
    final longContent = 'Lorem ipsum dolor sit amet, ' * 12;

    SummaryHarvest harvest({ToolAnnotations Function(ToolDefinition)? annotationsFor}) {
      final c = Conv()..user('save it');
      c.proxied('c1', 'files__write_file', {'content': longContent, 'path': '/home/ana/notes/plan.md'}, 'ok', server: 'files');
      c.proxied('c2', 'files__read_file', {'path': '/home/ana/notes/plan.md'}, 'text', server: 'files');
      c.proxied('c3', 'notes__create_note', {'title': 'Groceries', 'body': 'milk'}, '{"note_id": "note_ab12", "title": "Groceries"}');
      return SummaryComposer.harvest(CompactionInput(messages: c.messages, toolLookup: (n) => _defs[n], annotationsFor: annotationsFor));
    }

    test('the ledger names the tool that ran, its server, and digests its own arguments', () {
      final h = harvest(annotationsFor: _trustAll);
      expect(h.sideEffects.map((e) => e.callId), ['c1', 'c3'], reason: 'the trusted read is not a side effect');
      final w = h.sideEffects.first;
      expect(w.tool, 'files__write_file');
      expect(w.server, 'files');
      expect(w.argsDigest, Digest.args({'content': longContent, 'path': '/home/ana/notes/plan.md'}));
      // Key argument first, long values clipped one by one.
      expect(w.argsPreview, startsWith('{"path":"/home/ana/notes/plan.md","content":"Lorem ipsum'));
      expect(w.argsPreview!.length, lessThanOrEqualTo(160));
      expect(w.keyArgs, ['path="/home/ana/notes/plan.md"']);
      expect(h.sideEffects.last.server, 'notes', reason: 'from the target definition when the meta has none');
    });

    test('taint and handles are attributed to the target, not call_tool', () {
      final h = harvest(annotationsFor: _trustAll);
      expect(h.taint.map((t) => t.source), containsAll(['mcp:files/files__write_file', 'mcp:notes/notes__create_note']));
      expect(h.taint.map((t) => t.source).where((s) => s.contains('call_tool')), isEmpty);
      final handle = h.stateHandles.single;
      expect(handle.tool, 'notes__create_note');
      expect(handle.label, 'Groceries');
    });

    test('without a trust-aware view, a declared read stays in the ledger, marked as such', () {
      final h = harvest();
      expect(h.sideEffects.map((e) => e.callId), ['c1', 'c2', 'c3']);
      expect(h.sideEffects[1].tool, 'files__read_file');
      expect(h.sideEffects[1].declaredReadOnly, isTrue);
      expect(h.sideEffects.first.declaredReadOnly, isFalse);
    });

    test('the extractive strategy tags tool key facts and failures with the tool that ran', () async {
      final c = Conv()..user('save it');
      c.proxied('c1', 'files__write_file', {'path': '/p.md'}, 'Wrote 12 bytes to /p.md', server: 'files');
      c.assistant('', calls: const [ToolCall(id: 'c2', name: 'call_tool', arguments: {'name': 'notes__create_note'})]);
      c.results(const [
        ToolResultPart(
          callId: 'c2',
          toolName: 'call_tool',
          content: [TextPart('quota exceeded')],
          isError: true,
          meta: {ToolResultPart.metaTool: 'notes__create_note'},
        ),
      ]);
      c.toolTurn('c3', 'files__read_file', {'path': '/p.md'}, 'plain call');
      final s = await const ExtractiveContextStrategy()
          .summarize(CompactionInput(messages: c.messages, toolLookup: (n) => _defs[n], annotationsFor: _trustAll));
      expect(s.keyFacts, contains('[tool:files__write_file] Wrote 12 bytes to /p.md'));
      expect(s.keyFacts, contains('[tool:files__read_file] plain call'));
      expect(s.failedApproaches, contains('[tool:notes__create_note] notes__create_note failed: quota exceeded'));
      expect([...s.keyFacts, ...s.failedApproaches].where((f) => f.contains('call_tool')), isEmpty);
    });

    test('the rendered line names the tool and its key argument before anything is clipped', () {
      final s = CompactionSummary(goal: 'g', sideEffectLedger: harvest(annotationsFor: _trustAll).sideEffects);
      final line = s.render().split('\n').firstWhere((l) => l.contains('(call c1,'));
      expect(line, startsWith('- files__write_file {"path":"/home/ana/notes/plan.md"'));
      expect(line, contains(' on files → done'));
    });

    test('calls answered without running are not side effects; an interrupted one is', () {
      final c = Conv()..user('go');
      c.assistant('', calls: const [
        ToolCall(id: 'd1', name: 'notes__create_note', arguments: {'title': 'A'}),
        ToolCall(id: 'd2', name: 'notes__create_note', arguments: {'title': 'A'}),
        ToolCall(id: 'd3', name: 'notes__create_note', arguments: {'title': 'B'}),
      ]);
      c.results(const [
        ToolResultPart(callId: 'd1', toolName: 'notes__create_note', content: [TextPart('{"note_id":"n1"}')]),
        ToolResultPart(
          callId: 'd2',
          toolName: 'notes__create_note',
          content: [TextPart('Duplicate of call d1, not run.')],
          isError: true,
          meta: {SummaryComposer.metaNotRun: true},
        ),
        ToolResultPart(
          callId: 'd3',
          toolName: 'notes__create_note',
          content: [TextPart('The app was interrupted while "notes__create_note" was running, so its outcome is unknown.')],
          isError: true,
        ),
      ]);
      final h = SummaryComposer.harvest(CompactionInput(messages: c.messages, toolLookup: (n) => _defs[n]));
      expect(h.sideEffects.map((e) => '${e.callId}:${e.outcome.name}'), ['d1:ok', 'd3:error']);
    });
  });

  group('the ledger cap never drops a completed write', () {
    test('declared reads are folded per tool first; every write stays a line of its own', () {
      final ledger = [
        for (var i = 0; i < 60; i++) i.isEven ? _rec(i) : _rec(i, tool: 'files__read_file', read: true),
      ];
      final capped = CompactionSummary.capLedger(ledger);
      expect(capped.length, lessThanOrEqualTo(CompactionSummary.maxLedger));
      final writes = [for (final e in capped) if (!e.declaredReadOnly) e];
      expect(writes.map((e) => e.callId), [for (var i = 0; i < 60; i += 2) 'c$i']);
      expect(writes.every((e) => !e.isAggregate), isTrue);
      final reads = capped.where((e) => e.declaredReadOnly).toList();
      expect(reads.fold(0, (n, e) => n + e.count), 30, reason: 'folded, not dropped, while there is room');
      final text = CompactionSummary(goal: 'g', sideEffectLedger: capped).render();
      expect(text, contains('files__read_file ×'));
      expect(text, contains('(declared read-only)'));
    });

    test('reads are dropped before any write is folded', () {
      final ledger = [
        for (var i = 0; i < 40; i++) _rec(i),
        for (var i = 40; i < 50; i++) _rec(i, tool: 'files__read_file', read: true),
      ];
      final capped = CompactionSummary.capLedger(ledger);
      expect(capped, hasLength(40));
      expect(capped.map((e) => e.callId), [for (var i = 0; i < 40; i++) 'c$i']);
    });

    test('too many writes: the oldest are folded per tool with their key arguments and ids', () {
      final ledger = [
        for (var i = 0; i < 70; i++) _rec(i, tool: i % 3 == 0 ? 'notes__create_note' : 'files__write_file'),
      ];
      final capped = CompactionSummary.capLedger(ledger);
      expect(capped.length, lessThanOrEqualTo(CompactionSummary.maxLedger));
      final ids = [for (final e in capped) ...e.allCallIds];
      expect(ids.toSet(), {for (var i = 0; i < 70; i++) 'c$i'}, reason: 'nothing completed vanishes');
      expect(capped.fold(0, (n, e) => n + e.count), 70);
      final aggregates = capped.where((e) => e.isAggregate).toList();
      expect(aggregates.map((e) => e.tool).toSet(), {'notes__create_note', 'files__write_file'});
      expect(capped.last.callId, 'c69', reason: 'the newest stay individual, in order');
      final text = CompactionSummary(goal: 'g', sideEffectLedger: capped).render();
      final notes = text.split('\n').firstWhere((l) => l.startsWith('- notes__create_note ×'));
      expect(notes, contains('→ done: path="/w/0.txt"; path="/w/3.txt"'));
      expect(notes, contains('calls, c0 … '));
    });

    test('more distinct tools than the cap: the oldest become one "earlier actions" line', () {
      final ledger = [for (var i = 0; i < 50; i++) _rec(i, tool: 'tool_$i')];
      final capped = CompactionSummary.capLedger(ledger);
      expect(capped.length, lessThanOrEqualTo(CompactionSummary.maxLedger));
      expect(capped.first.tool, 'earlier actions');
      expect(capped.first.keyArgs, contains('tool_0 ×1'));
      expect(capped.fold(0, (n, e) => n + e.count), 50);
    });

    test('rolling merges keep aggregates, and never ledger an aggregated call twice', () async {
      const strategy = ExtractiveContextStrategy();
      CompactionSummary? prev;
      final c = Conv()..user('go');
      for (var round = 0; round < 3; round++) {
        final turn = Conv()..user('round $round');
        for (var i = 0; i < 25; i++) {
          turn.toolTurn('r${round}c$i', 'notes__create_note', {'title': 'Note $round.$i'}, '{"note_id": "n$round$i"}');
        }
        c.messages.addAll(turn.messages);
        prev = await strategy.summarize(CompactionInput(messages: turn.messages, previousSummary: prev, toolLookup: (n) => _defs[n]));
      }
      final ledger = prev!.sideEffectLedger;
      expect(ledger.length, lessThanOrEqualTo(CompactionSummary.maxLedger));
      expect(ledger.fold(0, (n, e) => n + e.count), 75);
      // The same range again (a retried compaction) adds nothing.
      final again = await strategy.summarize(CompactionInput(messages: c.messages, previousSummary: prev, toolLookup: (n) => _defs[n]));
      expect(again.sideEffectLedger.fold(0, (n, e) => n + e.count), 75);
      final ids = [for (final e in again.sideEffectLedger) ...e.allCallIds];
      expect(ids.length, ids.toSet().length);
      expect(again.render(), contains('title="Note 0.0"'));
    });

    test('aggregates and labels round-trip through JSON, and survive the handoff scrubber shape', () {
      final capped = CompactionSummary.capLedger([for (var i = 0; i < 45; i++) _rec(i)]);
      final s = CompactionSummary(
        goal: 'g',
        sideEffectLedger: capped,
        stateHandles: const [StateHandle(key: 'note_id', value: 'note_ab12', tool: 'notes__create_note', label: 'Groceries')],
      );
      final back = CompactionSummary.fromJson((jsonDecode(jsonEncode(s.toJson())) as Map).cast<String, Object?>());
      expect(jsonEncode(back.toJson()), jsonEncode(s.toJson()));
      expect(back.sideEffectLedger.first.isAggregate, isTrue);
      // A reader that only keeps the original fields (e.g. an older app)
      // still renders a line that says what was done.
      final a = back.sideEffectLedger.first;
      final plain = SideEffectRecord(
        callId: a.callId,
        tool: a.tool,
        argsDigest: a.argsDigest,
        outcome: a.outcome,
        argsPreview: a.argsPreview,
      );
      expect(CompactionSummary(goal: 'g', sideEffectLedger: [plain]).render(), contains('files__write_file ×6: path="/w/0.txt"'));
    });
  });

  group('state handles keep what they identify', () {
    test('label from the result, else from the creating call; rendered next to the handle', () {
      final c = Conv()..user('go');
      c.toolTurn('c1', 'notes__create_note', {'title': 'Groceries'}, '{"note_id": "note_ab12", "title": "Groceries"}');
      c.toolTurn('c2', 'shop__new_basket', {'name': 'Weekly shop'}, '{"basket_id": "b-7", "items": []}');
      c.toolTurn(
        'c3',
        'notes__search_notes',
        {'query': 'trip'},
        '{"notes": [{"note_id": "note_cd34", "title": "Trip", "folder_id": "f1"}, {"note_id": "note_ef56", "title": "Trip 2"}]}',
      );
      c.toolTurn('c4', 'notes__update_note', {'note_id': 'note_ab12', 'append': 'x'}, '{"note_id": "note_ab12"}');
      final h = SummaryComposer.harvest(CompactionInput(messages: c.messages));
      final byValue = {for (final s in h.stateHandles) s.value: s};
      expect(byValue['note_ab12']!.label, 'Groceries', reason: 'an unlabelled newer sighting keeps the older label');
      expect(byValue['note_ab12']!.tool, 'notes__update_note');
      expect(byValue['b-7']!.label, 'Weekly shop');
      expect(byValue['note_cd34']!.label, 'Trip');
      expect(byValue['note_ef56']!.label, 'Trip 2');
      expect(byValue['f1']!.label, isNull, reason: 'only the object\'s own (first) id takes its title');
      final text = CompactionSummary(goal: 'g', stateHandles: h.stateHandles).render();
      expect(text, contains('- note_id = note_ab12 for "Groceries" (notes__update_note)'));
      expect(text, contains('- basket_id = b-7 for "Weekly shop" (shop__new_basket)'));
    });

    test('labels merge across compactions', () {
      final prev = SummaryComposer.compose(
        CompactionInput(messages: (Conv()..toolTurn('c1', 'mk', {'title': 'Plan'}, '{"plan_id": "p1"}')).messages),
        const CompactionSummary(goal: 'g'),
      );
      final next = SummaryComposer.compose(
        CompactionInput(messages: (Conv()..toolTurn('c2', 'touch', const {}, '{"plan_id": "p1"}')).messages, previousSummary: prev),
        const CompactionSummary(goal: 'g'),
      );
      expect(next.stateHandles.single.label, 'Plan');
      expect(next.stateHandles.single.tool, 'touch');
    });
  });
}
