// Micro-benchmark: stream 4,000 tokens into the parser one at a time and
// check that the per-token cost stays flat as the document grows (i.e. the
// total is linear, not quadratic). Run alone for stable numbers:
//   flutter test --no-pub test/parse/benchmark_test.dart
@Tags(['benchmark'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_markdown/parse.dart';

import '../support/sample_document.dart';

const _tokenCount = 4000;

/// Model-like tokens: up to 6 non-space characters with their leading
/// whitespace (newlines included), roughly 4 characters on average.
List<String> _tokens() {
  final buffer = StringBuffer();
  var part = 0;
  final tokens = <String>[];
  final pattern = RegExp(r'\s*\S{1,6}');
  while (tokens.length < _tokenCount) {
    buffer
      ..write(
        sampleDocument.replaceFirst('# Streaming Markdown', '# Part ${part++}'),
      )
      ..write('\n');
    tokens
      ..clear()
      ..addAll(pattern.allMatches(buffer.toString()).map((m) => m[0]!));
  }
  return tokens.sublist(0, _tokenCount);
}

int _percentile(List<int> sorted, double p) =>
    sorted[((sorted.length - 1) * p).round()];

void main() {
  test('4,000 tokens appended one at a time stay linear', () {
    final tokens = _tokens();
    final prefixes = <String>[];
    final b = StringBuffer();
    for (final t in tokens) {
      b.write(t);
      prefixes.add(b.toString());
    }

    // Warm up the JIT on a different parser so the measured run is steady.
    final warm = IncrementalMarkdownParser();
    for (final p in prefixes.take(1500)) {
      warm.update(p);
    }

    // Three identical runs; each step's minimum filters out GC pauses and
    // CPU contention (flutter test runs suites in parallel), leaving the
    // parser's own cost. The raw first run is printed too.
    const runs = 3;
    late IncrementalMarkdownParser parser;
    final raw = <int>[];
    final micros = List<int>.filled(_tokenCount, 1 << 30);
    final watch = Stopwatch();
    for (var run = 0; run < runs; run++) {
      parser = IncrementalMarkdownParser();
      for (var i = 0; i < _tokenCount; i++) {
        watch
          ..reset()
          ..start();
        parser.update(prefixes[i]);
        watch.stop();
        final us = watch.elapsedMicroseconds;
        if (run == 0) raw.add(us);
        if (us < micros[i]) micros[i] = us;
      }
    }
    parser.update(prefixes.last, complete: true);

    final total = micros.fold<int>(0, (a, b) => a + b);
    final rawTotal = raw.fold<int>(0, (a, b) => a + b);
    final sorted = [...micros]..sort();
    final rawSorted = [...raw]..sort();
    final quarter = _tokenCount ~/ 4;
    double mean(Iterable<int> xs) =>
        xs.fold<int>(0, (a, b) => a + b) / xs.length;
    final firstQuarter = mean(micros.take(quarter));
    final lastQuarter = mean(micros.skip(_tokenCount - quarter));

    // For contrast: what re-parsing the whole text on every token costs.
    final scratch = Stopwatch()..start();
    IncrementalMarkdownParser().update(prefixes.last);
    scratch.stop();

    // ignore: avoid_print
    print(
      'sherpa_markdown benchmark: $_tokenCount tokens, '
      '${prefixes.last.length} chars, ${parser.blocks.length} blocks, '
      '${parser.parseCount} block parses\n'
      '  per-step min of $runs runs: total ${(total / 1000).toStringAsFixed(1)} ms, '
      'mean ${(total / _tokenCount).toStringAsFixed(1)} µs/token, '
      'p50 ${_percentile(sorted, .5)} µs, p95 ${_percentile(sorted, .95)} µs, '
      'p99 ${_percentile(sorted, .99)} µs, max ${sorted.last} µs\n'
      '  raw first run: total ${(rawTotal / 1000).toStringAsFixed(1)} ms, '
      'p99 ${_percentile(rawSorted, .99)} µs, max ${rawSorted.last} µs\n'
      '  first quarter mean ${firstQuarter.toStringAsFixed(1)} µs, '
      'last quarter mean ${lastQuarter.toStringAsFixed(1)} µs\n'
      '  one full re-parse of the final text: ${scratch.elapsedMicroseconds} µs '
      '(×$_tokenCount tokens ≈ quadratic baseline)',
    );

    // No single token may cost more than a few milliseconds…
    expect(sorted.last, lessThan(5000), reason: 'max step µs');
    expect(_percentile(sorted, .99), lessThan(1500), reason: 'p99 step µs');
    // …and the per-token cost must not grow with the document: the last
    // quarter (≈12 KB in) costs about what the first quarter did.
    expect(lastQuarter, lessThan(firstQuarter * 3 + 50));
  });
}
