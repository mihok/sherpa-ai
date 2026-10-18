import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_markdown/parse.dart';

import '../support/parse_helpers.dart';
import '../support/sample_document.dart';

/// Edge cases for the streaming split: blocks that interrupt each other
/// without blank lines, lazy lines, containers, tabs, unclosed constructs.
const trickyDocument = '''
Intro paragraph
continues here
# Heading right after
Setext para
===
- list
lazy line
- second

  indented para in item
    continuation

* other bullet list
1. one
1) paren list
> quote
lazy quote
>> nested
> ```
> fenced in quote
> ```
after quote
| h1 | h2 |
|----|----|
| a | b |
row without pipes
<div>
html
</div>

<!-- comment
spanning -->
\$\$
a
\$\$
\\[
b
\\]

\ttab indented code

- [ ] task
- [x] done

Trailing **bold and [link](https://example.com/x
~~~
unclosed tilde fence''';

final documents = <String, String>{
  'sample': sampleDocument,
  'tricky': trickyDocument,
  'tricky CRLF': trickyDocument.replaceAll('\n', '\r\n'),
};

void main() {
  group('streaming equivalence', () {
    for (final MapEntry(key: name, value: doc) in documents.entries) {
      final once = IncrementalMarkdownParser.parse(doc);
      final onceStreaming = IncrementalMarkdownParser().update(doc);

      test('$name: char by char == parsed at once', () {
        final parser = stream(doc, charByChar());
        expect(parser.blocks, onceStreaming);
        expect(parser.update(doc, complete: true), once);
      });

      test('$name: random chunk sizes == parsed at once', () {
        for (var seed = 1; seed <= 12; seed++) {
          final parser = stream(doc, randomChunks(seed, maxChunk: seed * 8));
          expect(parser.blocks, onceStreaming, reason: 'seed $seed');
          expect(parser.update(doc, complete: true), once, reason: 'seed $seed');
        }
      });

      test('$name: every prefix equals a fresh parse of that prefix', () {
        final incremental = IncrementalMarkdownParser();
        for (var i = 1; i <= doc.length; i++) {
          final prefix = doc.substring(0, i);
          expect(
            incremental.update(prefix),
            IncrementalMarkdownParser().update(prefix),
            reason: 'prefix of length $i ends with ${_tail(prefix)}',
          );
        }
      });

      test('$name: a frozen block never changes once frozen', () {
        final frozen = <String, MdBlock>{};
        var previousFrozen = 0;
        stream(
          doc,
          charByChar(),
          onUpdate: (parser, blocks) {
            final count = blocks.takeWhile((b) => b.frozen).length;
            // Frozen blocks form a prefix that never shrinks while appending.
            expect(count, greaterThanOrEqualTo(previousFrozen));
            expect(blocks.skip(count).where((b) => b.frozen), isEmpty);
            previousFrozen = count;
            for (final b in blocks.take(count)) {
              final seen = frozen.putIfAbsent(b.id, () => b);
              expect(identical(seen, b), isTrue, reason: '${b.id} was replaced');
            }
          },
        );
        expect(frozen, isNotEmpty);
      });
    }
  });

  group('caching (parse counter)', () {
    test('frozen blocks are never re-parsed', () {
      var previous = const <MdBlock>[];
      var previousCount = 0;
      stream(
        sampleDocument,
        charByChar(),
        onUpdate: (parser, blocks) {
          final frozenBefore = previous.takeWhile((b) => b.frozen).length;
          final parsed = parser.parseCount - previousCount;
          // Only blocks after the previously frozen prefix may be parsed.
          expect(parsed, lessThanOrEqualTo(blocks.length - frozenBefore));
          previous = blocks;
          previousCount = parser.parseCount;
        },
      );
    });

    test('cost of a token does not depend on how many blocks are frozen', () {
      final history = List.generate(500, (i) => 'Paragraph $i with **bold**.').join('\n\n');
      final parser = IncrementalMarkdownParser()..update('$history\n\n');
      expect(parser.blocks, hasLength(500));
      expect(parser.blocks.every((b) => b.frozen), isTrue);
      const tail = 'A new paragraph streams in';
      for (var i = 1; i <= tail.length; i++) {
        final before = parser.parseCount;
        parser.update('$history\n\n${tail.substring(0, i)}');
        expect(parser.parseCount - before, lessThanOrEqualTo(1));
      }
    });

    test('total parses stay linear in updates + blocks', () {
      final doc = List.generate(200, (i) => 'Block $i *x*').join('\n\n');
      final parser = stream(doc, charByChar());
      expect(parser.parseCount, lessThanOrEqualTo(doc.length + 200));
    });

    test('an unchanged open block keeps its instance', () {
      final parser = IncrementalMarkdownParser();
      final first = parser.update('para\n# Hea');
      final second = parser.update('para\n# Head');
      expect(first.first.frozen, isFalse);
      expect(identical(first.first, second.first), isTrue);
    });
  });

  group('hold-back of ambiguous partial lines', () {
    for (final (text, visible) in [
      ('Para\n-', 'Para'),
      ('Para\n1', 'Para'),
      ('Para\n--', 'Para'),
      ('Para\n`', 'Para'),
      ('Para\n```', 'Para'),
      ('Para\n|:-', 'Para'),
      ('Para\n- [', 'Para'),
      ('Para\n\$\$', 'Para'),
      ('Para\n> ', 'Para'),
    ]) {
      test('"${text.replaceAll('\n', r'\n')}" shows only "$visible"', () {
        final blocks = IncrementalMarkdownParser().update(text);
        expect(blocks, hasLength(1));
        expect(blocks.single.node, MdParagraph([MdText(visible)]));
        // Complete text shows everything.
        expect(
          IncrementalMarkdownParser.parse(text).map((b) => b.source).join('|'),
          isNot(visible),
        );
      });
    }

    test('a setext underline is never mistaken for a list while partial', () {
      final p = IncrementalMarkdownParser();
      expect(p.update('Title\n-').single.node, isA<MdParagraph>());
      expect(p.update('Title\n---').single.node, isA<MdParagraph>());
      expect(p.update('Title\n---\n').single.node, const MdHeading(2, [MdText('Title')]));
    });
  });

  group('completion and replacement', () {
    test('complete: true freezes the last block; ids are stable', () {
      final p = IncrementalMarkdownParser();
      final open = p.update('# T\n\nlast');
      expect(open.last.frozen, isFalse);
      final done = p.update('# T\n\nlast', complete: true);
      expect(done.every((b) => b.frozen), isTrue);
      expect(done.map((b) => b.id), open.map((b) => b.id));
    });

    test('appending after completion re-opens only provisional blocks', () {
      final p = IncrementalMarkdownParser();
      final done = p.update('# T\n\nlast', complete: true);
      final more = p.update('# T\n\nlast and more');
      expect(identical(more.first, done.first), isTrue);
      expect(more.last.frozen, isFalse);
      expect(more.last.id, done.last.id);
      expect(more.last.node, const MdParagraph([MdText('last and more')]));
    });

    test('replacing earlier text re-parses from the change with fresh ids', () {
      final p = IncrementalMarkdownParser();
      final before = p.update('# Keep\n\nold paragraph\n\nmore\n\n');
      final after = p.update('# Keep\n\nnew paragraph\n\n');
      expect(identical(after.first, before.first), isTrue);
      expect(after[1].node, const MdParagraph([MdText('new paragraph')]));
      expect(after[1].id, isNot(before[1].id));
      expect(after, hasLength(2));
      // And it still matches a fresh parse (ignoring ids).
      expect(
        after.map((b) => b.node),
        IncrementalMarkdownParser().update('# Keep\n\nnew paragraph\n\n').map((b) => b.node),
      );
    });

    test('shrinking to empty and regrowing works', () {
      final p = IncrementalMarkdownParser()..update('# A\n\nB\n\n');
      expect(p.update(''), isEmpty);
      final regrown = p.update('# C\n\n');
      expect(regrown.single.node, const MdHeading(1, [MdText('C')]));
    });

    test('an edit inside the open tail keeps frozen blocks', () {
      final p = IncrementalMarkdownParser();
      final a = p.update('# A\n\nHello wor');
      final b = p.update('# A\n\nHello there');
      expect(identical(a.first, b.first), isTrue);
      expect(b.last.node, const MdParagraph([MdText('Hello there')]));
    });
  });
}

String _tail(String s) {
  final t = s.length > 30 ? s.substring(s.length - 30) : s;
  return '"${t.replaceAll('\n', r'\n').replaceAll('\r', r'\r')}"';
}
