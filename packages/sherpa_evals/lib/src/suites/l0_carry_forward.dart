/// L0 constraint carry-forward across repeated rolling compaction.
library;

import 'package:sherpa_core/sherpa_core.dart';

import '../data.dart';
import '../report.dart';
import '../runtime/conv.dart';

final class CarryTotals {
  int planted = 0;
  int retained = 0;
  int duplicates = 0;
}

const List<ToolDefinition> carryTools = [
  ToolDefinition(
    name: 'read_file',
    description: 'Read a file',
    inputSchema: {'type': 'object'},
    annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: false),
  ),
  ToolDefinition(
    name: 'write_file',
    description: 'Write a file',
    inputSchema: {'type': 'object'},
    annotations: ToolAnnotations(destructiveHint: true),
  ),
];

Future<(List<CaseResult>, CarryTotals)> runCarryForward({String? only}) async {
  final t = CarryTotals();
  if (only != null && !'carry_forward'.contains(only) && !only.startsWith('carry')) return (<CaseResult>[], t);
  final d = loadData('l0/carry_forward.json');
  final turns = d['turns']! as int;
  final compactBefore = {...(d['compactBefore']! as List).cast<int>()};
  final constraints = objectList(d['constraints']);
  final preferences = objectList(d['preferences']);
  final writes = objectList(d['writes']);
  final manager = LadderContextManager(clock: FakeClock());
  final settings = ContextSettings(profile: compactEverything);
  final c = Conv();
  final overlays = <ContextOverlay>[];
  final problems = <String>[];
  for (var turn = 0; turn <= turns; turn++) {
    if (compactBefore.contains(turn)) {
      c.user('Turn $turn is next.');
      final outcome = await manager.compactNow(contextRequest(c.messages, overlays: overlays, tools: carryTools, settings: settings));
      if (outcome.overlay == null) {
        problems.add('compaction before turn $turn skipped: ${outcome.skippedReason}');
      } else {
        overlays.add(outcome.overlay!);
      }
    }
    if (turn == turns) break;
    final said = [
      'Turn $turn: continue the refactor.',
      for (final x in constraints) if (x['turn'] == turn) x['text']! as String,
      for (final x in preferences) if (x['turn'] == turn) x['text']! as String,
    ].join(' ');
    c.user(said);
    c.toolTurn('r$turn', 'read_file', {'path': '/proj/src/module_$turn.py'}, filler(20, prefix: 'code $turn'));
    for (final w in writes.where((w) => w['turn'] == turn)) {
      c.toolTurn('w$turn', 'write_file', {'path': w['path'], 'content': 'report'}, 'wrote ${w['path']}');
    }
    c.assistant('Turn $turn done. ${'notes ' * 30}');
  }
  final ranges = overlays.whereType<CompactedRange>().toList();
  if (ranges.isEmpty) {
    problems.add('nothing was compacted');
  } else {
    final s = ranges.last.summary;
    final kept = [...s.constraints, ...s.userPreferences].join('\n');
    for (final x in [...constraints, ...preferences]) {
      t.planted++;
      if (kept.contains(x['text']! as String)) {
        t.retained++;
      } else {
        problems.add('lost: ${x['text']}');
      }
    }
    final ids = [for (final e in s.sideEffectLedger) e.callId];
    t.duplicates = ids.length - ids.toSet().length;
    if (t.duplicates > 0) problems.add('${t.duplicates} duplicate ledger entries');
    final rendered = s.render();
    for (final w in writes) {
      if (!rendered.contains(w['path']! as String)) {
        problems.add('written path lost: ${w['path']}');
      }
    }
    if (s.compactionCount != ranges.length) problems.add('compactionCount ${s.compactionCount} != ${ranges.length}');
  }
  return (
    [
      CaseResult(
        id: 'carry_forward.extractive',
        group: 'carry_forward',
        pass: problems.isEmpty,
        detail: problems.isEmpty ? '${t.retained}/${t.planted} kept over ${ranges.length} compactions' : problems.join('; '),
      ),
    ],
    t,
  );
}
