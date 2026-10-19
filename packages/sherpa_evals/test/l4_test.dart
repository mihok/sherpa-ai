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
    final r = await runL4Session(_session('household_80'), compactions: 4, variant: L4Variant.directPolicy);
    expect(r.compacted, 4);
    expect(r.retention['constraints']!.$1, r.retention['constraints']!.$2);
    expect(r.retention['preferences']!.$1, r.retention['preferences']!.$2);
    expect(r.duplicated, 0, reason: 'with annotationsFor wired, reads stay out of the ledger: ${r.duplicates}');
    expect(r.ledgerReadOnly, 0);
  });

  test('the checklist probe is a real probe: it redoes what it cannot see', () async {
    // household_80 with 2 compactions and the app wiring is a documented
    // known issue (data/l4/known_issues.json). If this starts passing, the
    // weakness was fixed: remove the entries and flip this expectation.
    final s = _session('household_80');
    final r = await runL4Session(s, compactions: 2, variant: L4Variant.directApp);
    expect(l4KnownIssue(r), isNotNull);
    expect(r.ledgerReadOnly, greaterThan(0), reason: 'read-only MCP calls ledgered as side effects');
    expect(r.effectsEvicted, greaterThan(0), reason: 'the 40-entry cap evicted completed writes');
    expect(r.duplicated, r.effectsEvicted, reason: 'each evicted write is redone once');
    expect(r.duplicatedNonIdempotent, greaterThan(0));
  });

  test('deferred tools: ledger lines name call_tool, not the tool that ran', () async {
    final r = await runL4Session(_session('household_40'), compactions: 1, variant: L4Variant.deferred);
    expect(r.ledgerUnnamed, greaterThan(0));
    expect(r.duplicated, 0, reason: 'short sessions stay under the ledger cap');
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
