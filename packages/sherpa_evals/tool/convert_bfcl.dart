/// Converts a deterministic subset of BFCL v4 (Berkeley Function Calling
/// Leaderboard, Apache-2.0) into `data/l2/bfcl_subset.json`.
///
///     dart run tool/convert_bfcl.dart <dir with BFCL_v4_*.json and ans_BFCL_v4_*.json>
///
/// Source: github.com/ShishirPatil/gorilla, berkeley-function-call-leaderboard/
/// bfcl_eval/data (questions) and data/possible_answer (ground truth).
/// Every [_stride]th entry of each category is taken, so a re-run on the
/// same files reproduces the subset.
///
/// Conversion: BFCL's Python-flavoured types become JSON Schema
/// (`dict` → object, `float` → number, `tuple` → array, `any` → untyped),
/// and dots in function names become underscores (as BFCL does for
/// OpenAI-style function calling); `bfclName` keeps the original for
/// scoring.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const Map<String, (String file, String? answers, int take, int stride)> _categories = {
  'simple': ('BFCL_v4_simple_python.json', 'ans_BFCL_v4_simple_python.json', 20, 20),
  'multiple': ('BFCL_v4_multiple.json', 'ans_BFCL_v4_multiple.json', 10, 20),
  'parallel': ('BFCL_v4_parallel.json', 'ans_BFCL_v4_parallel.json', 10, 20),
  'irrelevance': ('BFCL_v4_irrelevance.json', null, 10, 24),
};

List<Map<String, Object?>> _jsonl(String path) => [
      for (final line in File(path).readAsLinesSync())
        if (line.trim().isNotEmpty) (jsonDecode(line) as Map).cast<String, Object?>(),
    ];

String sanitizeName(String name) => name.replaceAll('.', '_');

Object? _schema(Object? s) {
  if (s is! Map) return s;
  final out = <String, Object?>{};
  for (final e in s.entries) {
    final k = e.key as String;
    final v = e.value;
    switch (k) {
      case 'type':
        final t = switch (v) {
          'dict' => 'object',
          'float' => 'number',
          'tuple' => 'array',
          'any' => null,
          _ => v,
        };
        if (t != null) out['type'] = t;
      case 'properties':
        out['properties'] = {for (final p in (v! as Map).entries) p.key: _schema(p.value)};
      case 'items':
        out['items'] = _schema(v);
      default:
        out[k] = v;
    }
  }
  return out;
}

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/convert_bfcl.dart <bfcl data dir>');
    exitCode = 2;
    return;
  }
  final dir = args.single;
  final cases = <Map<String, Object?>>[];
  for (final c in _categories.entries) {
    final (file, answers, take, stride) = c.value;
    final qs = _jsonl(p.join(dir, file));
    final gt = answers == null ? <String, Object?>{} : {for (final a in _jsonl(p.join(dir, answers))) a['id']! as String: a['ground_truth']};
    for (var i = 0; i < qs.length && cases.where((x) => x['category'] == c.key).length < take; i += stride) {
      final q = qs[i];
      final turns = (q['question']! as List).cast<List<Object?>>();
      cases.add({
        'id': q['id'],
        'category': c.key,
        'messages': turns.first,
        'functions': [
          for (final f in (q['function']! as List).cast<Map<String, Object?>>())
            {
              'name': sanitizeName(f['name']! as String),
              'bfclName': f['name'],
              'description': f['description'],
              'parameters': _schema(f['parameters']),
            },
        ],
        if (answers != null) 'ground_truth': gt[q['id']],
      });
    }
  }
  final out = {
    'schema': 'sherpa.eval.l2-bfcl/1',
    'source': 'BFCL v4 (gorilla berkeley-function-call-leaderboard bfcl_eval/data), Apache License 2.0; '
        'converted by tool/convert_bfcl.dart (every Nth entry: simple 20/20, multiple 10/20, parallel 10/20, irrelevance 10/24).',
    'cases': cases,
  };
  final path = p.join(p.dirname(p.dirname(Platform.script.toFilePath())), 'data', 'l2', 'bfcl_subset.json');
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('${const JsonEncoder.withIndent(' ').convert(out)}\n');
  stdout.writeln('wrote ${cases.length} cases to $path');
}
