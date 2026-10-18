import 'dart:convert';
import 'dart:io';

import 'package:sherpa_hub/sherpa_hub.dart';
import 'package:test/test.dart';

/// Golden test over the R08 §14 corpus: 128 live repo/file names.
///
/// `fixtures/r08_corpus.md` is the verbatim table; the expectations in
/// `fixtures/r08_corpus_expected.json` are normalized from its columns (the
/// normalization rules are in that file's "about").
final class _Row {
  _Row(this.n, this.repo, this.file, this.branch);

  final int n;
  final String repo;
  final String? file;
  final String? branch;
}

List<_Row> _corpus() {
  final rows = <_Row>[];
  for (final line in File('test/fixtures/r08_corpus.md').readAsLinesSync()) {
    final m = RegExp(r'^\| (\d+) \| ([^|]+) \| ([^|]+) \|').firstMatch(line);
    if (m == null) continue;
    final col = m.group(3)!.trim();
    rows.add(_Row(
      int.parse(m.group(1)!),
      m.group(2)!.trim(),
      col == 'repo' || col.startsWith('branch') ? null : col,
      col.startsWith('branch') ? RegExp('`([^`]+)`').firstMatch(col)!.group(1) : null,
    ));
  }
  return rows;
}

void main() {
  final rows = _corpus();
  final expected = {
    for (final r in ((jsonDecode(File('test/fixtures/r08_corpus_expected.json').readAsStringSync()) as Map)['rows'] as List))
      ((r as Map)['n'] as int): r.cast<String, Object?>(),
  };

  test('corpus fixture is complete: 128 rows, one expectation each', () {
    expect(rows, hasLength(128));
    expect(rows.map((r) => r.n), List.generate(128, (i) => i + 1));
    expect(expected.keys.toSet(), rows.map((r) => r.n).toSet());
  });

  for (final row in rows) {
    final e = expected[row.n]!;
    final label = '#${row.n} ${row.repo} ${row.file ?? row.branch ?? '(repo)'}';
    test(label, () {
      final p = parseModelName(row.repo, fileName: row.file, revision: row.branch);
      String? s(String k) => e[k] as String?;

      expect(p.format.name, s('fmt'), reason: 'format');
      expect(p.family?.value, s('fam'), reason: 'family');
      expect(p.namePrefix?.value, s('pre'), reason: 'prefix');
      expect(p.baseFamily?.value, s('base'), reason: 'base family');
      expect(p.teacher?.value, s('teach'), reason: 'teacher');
      expect(p.version?.raw, s('ver'), reason: 'version');
      expect(p.build?.value, s('build'), reason: 'build');
      expect(p.size?.value.label, s('size'), reason: 'size');
      expect(p.tier?.value, s('tier'), reason: 'tier');
      expect(p.activeParams?.value.label, s('act'), reason: 'active params');
      expect(p.contextHint?.value, e['ctx'], reason: 'context hint');
      expect(p.variants.map((v) => v.value.name).toList(), (e['var'] as List?)?.cast<String>() ?? const <String>[],
          reason: 'variants');
      expect(p.qualifiers, (e['qual'] as List?)?.cast<String>() ?? const <String>[], reason: 'qualifiers');
      expect(p.deviceTarget, s('dev'), reason: 'device target');

      final role = p.draftKind == null ? p.role.value.name : '${p.role.value.name}(${p.draftKind!.name})';
      expect(role, s('role') ?? 'model', reason: 'role');

      final shard = p.shard?.value;
      final shardText = shard == null ? null : '${shard.index}/${shard.count}${shard.byteSplit ? 'b' : ''}';
      expect(shardText, s('shard'), reason: 'shard');

      expect(p.flags.map((f) => f.name).toSet(), ((e['flags'] as List?)?.cast<String>() ?? const <String>[]).toSet(),
          reason: 'flags');

      final q = p.quant?.value;
      final scheme = s('sch');
      if (s('q') == null && scheme == null) {
        expect(q, isNull, reason: 'no quant in the name');
      } else {
        expect(q, isNotNull, reason: 'quant');
        if (s('q') != null) {
          expect(q!.scheme, QuantScheme.ggml);
          expect(q.label, s('q'), reason: 'quant label');
          expect(q.ggufType?.id, s('qb'), reason: 'llama.cpp file type');
          expect(q.dynamic, e['dyn'] ?? false, reason: 'dynamic');
          expect(q.imatrix, e['im'] ?? false, reason: 'imatrix');
          expect(q.embedOutputQ8, e['emb'] ?? false, reason: 'Q8_0 embed/output');
          expect(q.bpwIsLowerBound, e['lb'] ?? false, reason: 'bpw lower bound');
          expect(q.approximateBase, e['approx'] ?? false, reason: 'approximate base');
          expect(q.custom, e['custom'] ?? false, reason: 'custom label');
          if (e['bits'] != null) expect(q.bits, e['bits'], reason: 'bits');
        } else {
          expect(q!.scheme.name, scheme, reason: 'scheme');
          expect(q.bits, e['bits'], reason: 'bits');
          expect(q.groupSize, e['gs'], reason: 'group size');
          expect(q.headBits, e['hb'], reason: 'head bits');
          expect(q.mixed, e['mixed'] ?? false, reason: 'mixed');
        }
        final bpw = e['bpw'] as num?;
        if (bpw == null) {
          expect(q.bpw, isNull, reason: 'bpw must come from file bytes');
        } else {
          expect(q.bpw, closeTo(bpw, (e['tol'] as num?) ?? 0.01), reason: 'bpw');
        }
        final typ = e['typ'] as num?;
        if (typ != null) expect(q.ggufType?.typicalFileBpw, closeTo(typ, 0.1), reason: 'typical file bpw');
      }

      final src = (e['src'] as Map?)?.cast<String, String>() ?? const {};
      if (src['fam'] != null) expect(p.family?.source.name, src['fam'], reason: 'family source');
      if (src['size'] != null) expect(p.size?.source.name, src['size'], reason: 'size source');
      if (src['q'] != null) expect(p.quant?.source.name, src['q'], reason: 'quant source');

      // Every decoded field carries a tooltip.
      for (final d in <Decoded<Object>?>[
        p.family, p.namePrefix, p.baseFamily, p.teacher, p.version, p.build, p.size, p.tier, p.activeParams,
        p.contextHint, p.quant, p.shard, p.role, ...p.variants,
      ]) {
        if (d != null) expect(d.explanation, isNotEmpty, reason: 'tooltip for ${d.raw}');
      }
    });
  }

  test('pass rate summary', () {
    var ok = 0;
    for (final row in rows) {
      final e = expected[row.n]!;
      final p = parseModelName(row.repo, fileName: row.file, revision: row.branch);
      if (p.format.name == e['fmt'] && p.family?.value == e['fam'] && p.size?.value.label == e['size']) ok++;
    }
    expect(ok, rows.length);
  });
}
