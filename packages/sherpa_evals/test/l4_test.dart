import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_evals/src/data.dart';
import 'package:sherpa_evals/src/suites/l4_compaction.dart';
import 'package:test/test.dart';

L4Session _session(String id) =>
    L4Session(objectList(loadData('l4/sessions.json')['sessions']).firstWhere((s) => s['id'] == id));

void main() {
  test('sessions are 40–80 turns with every plant kind', () {
    for (final j in objectList(loadData('l4/sessions.json')['sessions'])) {
      final s = L4Session(j);
      expect(s.turns, inInclusiveRange(40, 80));
      expect({for (final p in s.plants) p.kind}, containsAll(['constraint', 'preference', 'note', 'event', 'write', 'append', 'read']));
      expect({for (final p in s.plants) p.turn}, hasLength(s.plants.length), reason: 'one plant per turn');
      expect(s.compactBefore(4), hasLength(4));
    }
  });

  test('control (no compaction): everything retained, no duplicates, handles attributable', () async {
    final r = await runL4Session(_session('household_40'), compactions: 0);
    expect(r.problems, isEmpty);
    expect(r.duplicated, 0);
    for (final f in l4Fields) {
      expect(r.retention[f]!.$1, r.retention[f]!.$2, reason: f);
    }
    expect(r.handleProbesOk, 2);
    expect(r.handleLookups, 0);
  });

  test('extractive compaction carries constraints and preferences through 4 rounds', () async {
    final r = await runL4Session(_session('household_80'), compactions: 4, variant: L4Variant.directApp);
    expect(r.compacted, 4);
    expect(r.retention['constraints']!.$1, r.retention['constraints']!.$2);
    expect(r.retention['preferences']!.$1, r.retention['preferences']!.$2);
    expect(r.duplicated, 0, reason: 'with annotationsFor wired, reads stay out of the ledger: ${r.duplicates}');
    expect(r.ledgerReadOnly, 0);
  });

  test('the checklist probe is a real probe: it redoes what it cannot see', () async {
    // A summarizer that loses the side-effect ledger (the weakness L4 found
    // in the 40-entry eviction): every completed action folded into the
    // summary is invisible, and the faithful agent redoes each one.
    final s = _session('household_80');
    final r = await runL4Session(s, compactions: 2, variant: L4Variant.directApp, strategy: const _DropLedger());
    expect(r.effectsEvicted, greaterThan(0), reason: 'completed writes in neither the ledger nor the kept tail');
    expect(r.duplicated, r.effectsEvicted, reason: 'each invisible write is redone once');
    expect(r.duplicatedNonIdempotent, greaterThan(0));
    expect(l4KnownIssue(r), isNull);
  });

  for (final v in [L4Variant.deferredLookupOnly, L4Variant.directLookupOnly]) {
    test('without a trust-aware view (${v.name}), declared reads are folded, never in place of a write', () async {
      final r = await runL4Session(_session('household_80'), compactions: 4, variant: v);
      expect(r.ledgerReadOnly, greaterThan(0), reason: 'untrusted read-only hints keep reads in the ledger');
      expect(r.ledgerFolded, greaterThan(0), reason: 'over the 40-entry cap, reads are folded per tool');
      expect(r.effectsEvicted, 0);
      expect(r.duplicated, 0, reason: '${r.duplicates}');
      expect(r.ledgerUnnamed, 0);
    });
  }

  test('deferred tools: ledger lines, taint and handles name the tool that ran, not call_tool', () async {
    for (final v in [L4Variant.deferred, L4Variant.deferredLookupOnly]) {
      ModelRequest? probe;
      final r = await runL4Session(_session('household_40'), compactions: 1, variant: v, onProbe: (p) => probe = p);
      final lines = probe!.messages.firstWhere((m) => m.kind == MessageKind.summary).text.split('\n');
      // The harness-attributed lines: ledger, handles, taint. (In-process
      // servers are on-device sources: `tool:<name>` taint.)
      final attributed = [
        for (final l in lines)
          if (l.contains('→ done') || l.contains('_id = ') || l.startsWith('Untrusted sources')) l,
      ];
      expect(attributed.join('\n'), contains('tool:files__write_file'), reason: v.name);
      expect(attributed.join('\n'), contains('(notes__create_note)'), reason: '${v.name}: handles attributed to the target');
      expect(attributed.where((l) => l.contains('call_tool') || l.contains('sherpa.tools')), isEmpty, reason: v.name);
      expect(r.ledgerEntries, greaterThan(0), reason: v.name);
      expect(r.ledgerUnnamed, 0, reason: v.name);
      expect(r.strictEffects.$1, r.strictEffects.$2, reason: '${v.name}: every action on a line with its tool and key argument');
      expect(r.duplicated, 0, reason: v.name);
    }
  });

  test('handles keep what they identify: no handle probe needs a search after compaction', () async {
    final r = await runL4Session(_session('household_80'), compactions: 2, variant: L4Variant.deferred);
    expect(r.handleProbesOk, r.handleProbes);
    expect(r.handleLookups, 0);
  });

  test('every known-issue case id names a real run', () {
    final sessions = {for (final j in objectList(loadData('l4/sessions.json')['sessions'])) j['id']};
    for (final id in l4KnownIssues.keys) {
      final parts = id.split('.');
      expect(L4Variant.values.map((v) => v.name), contains(parts[0]), reason: id);
      expect(sessions, contains(parts[1]), reason: id);
      expect(l4CompactionCounts.map((n) => 'c$n'), contains(parts[2]), reason: id);
    }
  });
}

/// The extractive summarizer with the side-effect ledger left out.
final class _DropLedger implements ContextStrategy {
  const _DropLedger();

  @override
  String get id => 'extractive-without-ledger';

  @override
  Future<CompactionSummary> summarize(CompactionInput input, {CancellationToken? cancel}) async =>
      (await const ExtractiveContextStrategy().summarize(input, cancel: cancel)).copyWith(sideEffectLedger: const []);
}
