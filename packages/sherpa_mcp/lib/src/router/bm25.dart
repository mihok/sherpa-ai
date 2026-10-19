/// Lexical tool retrieval (R11 §(c), §9.5).
library;

import 'dart:math' as math;

import 'package:meta/meta.dart';

/// One searchable document: weighted fields of free text.
@immutable
final class Bm25Document {
  const Bm25Document({required this.id, required this.fields});

  final String id;

  /// Text per field name; weights come from [Bm25Index.fieldWeights].
  final Map<String, String> fields;
}

/// A scored hit.
@immutable
final class Bm25Hit {
  const Bm25Hit(this.id, this.score);

  final String id;
  final double score;

  @override
  String toString() => 'Bm25Hit($id, ${score.toStringAsFixed(3)})';
}

/// Okapi BM25 with per-field weights (BM25F-lite: a field's term
/// frequencies are multiplied by its weight before saturation).
///
/// Why BM25 and why here: small local models cannot pick from dozens of
/// tools, so retrieval happens outside the model before each segment and
/// behind `tool_search` (RAG-MCP: 43% vs 14% selection accuracy; R11 §(c)).
/// BM25 needs no model download, is deterministic (ties break by insertion
/// order, so the same catalog always ranks the same) and handles the
/// snake/camel-case vocabulary of tool names once [tokenize] splits it.
/// An embedding ranker can be fused on top ([ToolEmbedder] in the router).
final class Bm25Index {
  Bm25Index(
    Iterable<Bm25Document> documents, {
    this.fieldWeights = const {'name': 3, 'params': 2, 'description': 1},
    this.k1 = 1.2,
    this.b = 0.75,
  }) {
    for (final d in documents) {
      final tf = <String, double>{};
      var length = 0.0;
      for (final f in d.fields.entries) {
        final w = (fieldWeights[f.key] ?? 1).toDouble();
        for (final t in tokenize(f.value)) {
          tf[t] = (tf[t] ?? 0) + w;
          length += w;
        }
      }
      _docs.add(_Doc(d.id, tf, length));
      for (final t in tf.keys) {
        _df[t] = (_df[t] ?? 0) + 1;
      }
    }
    _avgLength = _docs.isEmpty ? 0 : _docs.fold<double>(0, (s, d) => s + d.length) / _docs.length;
  }

  final Map<String, num> fieldWeights;
  final double k1;
  final double b;
  final List<_Doc> _docs = [];
  final Map<String, int> _df = {};
  double _avgLength = 0;

  int get length => _docs.length;

  /// Hits with a positive score, best first, at most [limit]. [filter]
  /// restricts the candidates (e.g. per-session enablement).
  List<Bm25Hit> search(String query, {int limit = 10, bool Function(String id)? filter}) {
    final terms = tokenize(query).toSet();
    if (terms.isEmpty || _docs.isEmpty) return const [];
    final n = _docs.length;
    final hits = <(int, Bm25Hit)>[];
    for (final (i, d) in _docs.indexed) {
      if (filter != null && !filter(d.id)) continue;
      var score = 0.0;
      for (final t in terms) {
        final f = d.tf[t];
        if (f == null) continue;
        final df = _df[t]!;
        final idf = math.log(1 + (n - df + 0.5) / (df + 0.5));
        final norm = _avgLength == 0 ? 1 : (1 - b + b * d.length / _avgLength);
        score += idf * (f * (k1 + 1)) / (f + k1 * norm);
      }
      if (score > 0) hits.add((i, Bm25Hit(d.id, score)));
    }
    hits.sort((x, y) {
      final c = y.$2.score.compareTo(x.$2.score);
      return c != 0 ? c : x.$1.compareTo(y.$1);
    });
    return [for (final h in hits.take(limit)) h.$2];
  }

  static const Set<String> _stop = {
    'a', 'an', 'and', 'are', 'as', 'at', 'be', 'by', 'can', 'do', 'for', 'from', 'how', 'i', 'in', 'into', //
    'is', 'it', 'its', 'me', 'my', 'of', 'on', 'or', 'please', 'should', 'so', 'some', 'that', 'the', 'this',
    'to', 'use', 'using', 'want', 'was', 'what', 'when', 'which', 'will', 'with', 'you', 'your',
  };

  static final RegExp _camel = RegExp(r'(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])');
  static final RegExp _split = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

  /// Lower-cased terms: splits on non-alphanumerics and camelCase,
  /// drops stop words and applies a tiny suffix stemmer (plural `s`/`es`,
  /// `ing`, `ed`) so "issues"/"issue" and "searching"/"search" meet.
  static List<String> tokenize(String text) {
    final out = <String>[];
    for (final raw in text.replaceAll(_camel, ' ').split(_split)) {
      if (raw.isEmpty) continue;
      final w = raw.toLowerCase();
      if (_stop.contains(w)) continue;
      out.add(stem(w));
    }
    return out;
  }

  static String stem(String w) {
    if (w.length > 5 && w.endsWith('ing')) return w.substring(0, w.length - 3);
    if (w.length > 4 && w.endsWith('ies')) return '${w.substring(0, w.length - 3)}y';
    if (w.length > 4 && w.endsWith('ed')) return w.substring(0, w.length - 2);
    if (w.length > 4 && (w.endsWith('ches') || w.endsWith('shes') || w.endsWith('sses') || w.endsWith('xes'))) {
      return w.substring(0, w.length - 2);
    }
    if (w.length > 3 && w.endsWith('s') && !w.endsWith('ss') && !w.endsWith('us')) return w.substring(0, w.length - 1);
    return w;
  }
}

final class _Doc {
  _Doc(this.id, this.tf, this.length);

  final String id;
  final Map<String, double> tf;
  final double length;
}

/// Reciprocal-rank fusion of several rankings (Cormack et al.): robust to
/// incomparable score scales, which is why BM25 and cosine similarity are
/// fused this way rather than by adding scores.
List<String> reciprocalRankFusion(List<List<String>> rankings, {int k = 60}) {
  final score = <String, double>{};
  final firstSeen = <String, int>{};
  var order = 0;
  for (final r in rankings) {
    for (final (i, id) in r.indexed) {
      score[id] = (score[id] ?? 0) + 1 / (k + i + 1);
      firstSeen.putIfAbsent(id, () => order++);
    }
  }
  final ids = score.keys.toList()
    ..sort((a, b) {
      final c = score[b]!.compareTo(score[a]!);
      return c != 0 ? c : firstSeen[a]!.compareTo(firstSeen[b]!);
    });
  return ids;
}

/// Cosine similarity; 0 for empty or mismatched vectors.
double cosineSimilarity(List<double> a, List<double> b) {
  if (a.isEmpty || a.length != b.length) return 0;
  var dot = 0.0;
  var na = 0.0;
  var nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return na == 0 || nb == 0 ? 0 : dot / (math.sqrt(na) * math.sqrt(nb));
}
