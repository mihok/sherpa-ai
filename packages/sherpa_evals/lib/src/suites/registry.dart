/// The suites, in run order. L5 (prompt injection) is deferred: see the
/// package README.
library;

import 'l0.dart';
import 'l1_parsers.dart';
import 'l2_bfcl.dart';
import 'l3_state.dart';
import 'l4_compaction.dart';
import 'suite.dart';

final List<EvalSuite> allSuites = [
  const L0Suite(),
  const L1ParserSuite(),
  const L2BfclSuite(),
  const L3Suite(),
  const L4Suite(),
];

/// `all`, one id, or a comma list (case-insensitive).
List<EvalSuite> selectSuites(String spec) {
  if (spec.trim().toLowerCase() == 'all') return allSuites;
  final want = [for (final s in spec.split(',')) s.trim().toUpperCase()];
  final out = <EvalSuite>[];
  for (final w in want) {
    final s = allSuites.where((x) => x.id == w).firstOrNull;
    if (s == null) throw ArgumentError('unknown suite "$w" (have ${allSuites.map((s) => s.id).join(', ')})');
    out.add(s);
  }
  return out;
}
