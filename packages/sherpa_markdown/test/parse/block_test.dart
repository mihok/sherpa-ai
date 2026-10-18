import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_markdown/parse.dart';

import '../support/parse_helpers.dart';

void main() {
  group('headings', () {
    test('ATX levels 1-6 with closing sequence stripped', () {
      for (var level = 1; level <= 6; level++) {
        expect(
          nodeOf('${'#' * level} Title ${'#' * 3}'),
          MdHeading(level, const [MdText('Title')]),
        );
      }
    });

    test('seven hashes or no space is a paragraph', () {
      expect(nodeOf('####### seven'), isA<MdParagraph>());
      expect(nodeOf('#hashtag'), isA<MdParagraph>());
    });

    test('setext headings, including multi-line content', () {
      expect(nodeOf('Title\n====='), const MdHeading(1, [MdText('Title')]));
      expect(nodeOf('Sub\n---'), const MdHeading(2, [MdText('Sub')]));
      expect(
        nodeOf('two\nlines\n==='),
        const MdHeading(1, [MdText('two\nlines')]),
      );
    });

    test('a spaced dash line after a paragraph is a break, not setext', () {
      expect(nodesOf('para\n- - -'), const [
        MdParagraph([MdText('para')]),
        MdThematicBreak(),
      ]);
    });
  });

  group('paragraphs', () {
    test('soft breaks are kept, blank lines separate', () {
      expect(nodesOf('a\nb\n\nc'), const [
        MdParagraph([MdText('a\nb')]),
        MdParagraph([MdText('c')]),
      ]);
    });

    test('leading indentation of continuation lines is dropped', () {
      expect(inlinesOf('a\n      b'), const [MdText('a\nb')]);
    });
  });

  group('fenced code', () {
    test('backtick fence with info string', () {
      expect(
        nodeOf('```dart title="x"\nvoid main() {}\n```'),
        const MdCodeBlock(
          'void main() {}',
          language: 'dart',
          info: 'dart title="x"',
          complete: true,
        ),
      );
    });

    test('tilde fence, longer closing fence, inner shorter fence', () {
      expect(
        nodeOf('~~~~\n```\nnot closed\n~~~\n~~~~~~'),
        const MdCodeBlock('```\nnot closed\n~~~', complete: true),
      );
    });

    test('indented fence strips its indentation from content', () {
      expect(
        nodeOf('  ```\n  a\n    b\n  ```'),
        const MdCodeBlock('a\n  b', complete: true),
      );
    });

    test('pandoc-style info braces', () {
      final node = nodeOf('```{.python}\nx\n```') as MdCodeBlock;
      expect(node.language, 'python');
    });

    test(
      'an unclosed fence is an open, incomplete code block while streaming',
      () {
        final blocks = IncrementalMarkdownParser().update('```py\nprint(1)\n');
        expect(blocks.single.frozen, isFalse);
        expect(
          blocks.single.node,
          const MdCodeBlock(
            'print(1)',
            language: 'py',
            info: 'py',
            complete: false,
          ),
        );
      },
    );

    test('end of input closes an unclosed fence when complete', () {
      expect(nodeOf('```\ncode'), const MdCodeBlock('code', complete: true));
    });

    test('backtick info containing a backtick is not a fence', () {
      expect(nodeOf('``` a`b'), isA<MdParagraph>());
    });

    test('the language label waits for the info string to finish', () {
      final p = IncrementalMarkdownParser();
      final partial = p.update('```pyth').single.node as MdCodeBlock;
      expect(partial.language, isNull);
      final full = p.update('```python\n').single.node as MdCodeBlock;
      expect(full.language, 'python');
    });
  });

  group('indented code', () {
    test('four spaces, blank lines inside, trailing blanks dropped', () {
      expect(nodesOf('    a\n\n    b\n\n\npara'), const [
        MdCodeBlock('a\n\nb', complete: true),
        MdParagraph([MdText('para')]),
      ]);
    });

    test('cannot interrupt a paragraph', () {
      expect(inlinesOf('para\n    not code'), const [MdText('para\nnot code')]);
    });
  });

  group('block quotes', () {
    test('quote with lazy continuation and a following paragraph', () {
      expect(nodesOf('> one\ntwo\n> three\n\nafter'), const [
        MdQuote([
          MdParagraph([MdText('one\ntwo\nthree')]),
        ]),
        MdParagraph([MdText('after')]),
      ]);
    });

    test('nested quotes and lists inside quotes', () {
      expect(
        nodeOf('> outer\n>> inner\n> - item'),
        const MdQuote([
          MdParagraph([MdText('outer')]),
          MdQuote([
            MdParagraph([MdText('inner')]),
          ]),
          MdList(
            ordered: false,
            tight: true,
            items: [
              MdListItem([
                MdParagraph([MdText('item')]),
              ]),
            ],
          ),
        ]),
      );
    });

    test('no lazy continuation into a fence inside the quote', () {
      expect(nodesOf('> ```\n> code\nafter'), const [
        MdQuote([MdCodeBlock('code', complete: true)]),
        MdParagraph([MdText('after')]),
      ]);
    });

    test('a blank line ends the quote', () {
      expect(nodesOf('> a\n\n> b'), hasLength(2));
    });
  });

  group('lists', () {
    MdList list(String text) => nodeOf(text) as MdList;

    test('unordered with -, *, +; changing bullet starts a new list', () {
      expect(nodesOf('- a\n- b\n* c\n+ d'), hasLength(3));
      expect(list('- a\n- b').items, hasLength(2));
    });

    test('ordered list keeps its start number', () {
      final l = list('3. three\n4. four');
      expect(l.ordered, isTrue);
      expect(l.start, 3);
    });

    test('only "1." may interrupt a paragraph', () {
      expect(nodesOf('In\n2015. A year'), hasLength(1));
      expect(nodesOf('Steps:\n1. first'), [isA<MdParagraph>(), isA<MdList>()]);
      expect(nodesOf('Items:\n- first'), hasLength(2));
    });

    test('nesting by content indentation', () {
      final l = list('- a\n  - b\n    1. c\n- d');
      expect(l.items, hasLength(2));
      final nested = l.items.first.children[1] as MdList;
      final deeper = nested.items.single.children[1] as MdList;
      expect(deeper.ordered, isTrue);
      expect(
        deeper.items.single.children.single,
        const MdParagraph([MdText('c')]),
      );
    });

    test('tight vs loose', () {
      expect(list('- a\n- b').tight, isTrue);
      expect(list('- a\n\n- b').tight, isFalse);
      expect(list('- a\n\n  second paragraph').tight, isFalse);
      // A blank line inside a nested list does not loosen the outer one.
      expect(list('- a\n  - b\n\n  - c\n- d').tight, isTrue);
    });

    test('continues across blank lines when indented or another item', () {
      final l = list('1. one\n\n   more of one\n\n2. two');
      expect(l.items, hasLength(2));
      expect(l.items.first.children, hasLength(2));
    });

    test('ends at an unindented line after a blank line', () {
      expect(nodesOf('- a\n\nafter'), [isA<MdList>(), isA<MdParagraph>()]);
    });

    test('lazy continuation of an item paragraph', () {
      expect(
        list('- a\nb').items.single.children.single,
        const MdParagraph([MdText('a\nb')]),
      );
    });

    test('task items', () {
      final l = list('- [ ] open\n- [x] done\n- [X] also\n- [ ]not task');
      expect([for (final i in l.items) i.checked], [false, true, true, null]);
      expect(
        l.items.first.children.single,
        const MdParagraph([MdText('open')]),
      );
    });

    test('fenced code with blank lines inside an item', () {
      final l = list('- x\n\n  ```\n  a\n\n  b\n  ```\n- y');
      expect(l.items, hasLength(2));
      expect(
        l.items.first.children[1],
        const MdCodeBlock('a\n\nb', complete: true),
      );
    });

    test('a thematic break ends the list', () {
      expect(nodesOf('- a\n* * *'), [isA<MdList>(), isA<MdThematicBreak>()]);
    });
  });

  group('tables', () {
    test('alignment, header and body', () {
      expect(
        nodeOf('| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |'),
        const MdTable(
          alignments: [MdAlign.left, MdAlign.center, MdAlign.right],
          header: [
            [MdText('a')],
            [MdText('b')],
            [MdText('c')],
          ],
          rows: [
            [
              [MdText('1')],
              [MdText('2')],
              [MdText('3')],
            ],
          ],
        ),
      );
    });

    test('rows are normalized to the column count; pipes can be escaped', () {
      final t = nodeOf('a | b\n--|--\n1\n1 | 2 | 3\nx \\| y | z') as MdTable;
      expect(t.rows.map((r) => r.length), everyElement(2));
      expect(t.rows[0][1], isEmpty);
      expect(t.rows[2][0], const [MdText('x | y')]);
    });

    test('a table can interrupt a paragraph and ends at a blank line', () {
      expect(nodesOf('Intro:\n| a |\n|---|\n| 1 |\n\nafter'), [
        isA<MdParagraph>(),
        isA<MdTable>(),
        isA<MdParagraph>(),
      ]);
    });

    test('mismatched delimiter cell count is not a table', () {
      expect(nodeOf('| a | b |\n|---|'), isA<MdParagraph>());
    });

    test('a header row before its delimiter row previews as a table', () {
      final p = IncrementalMarkdownParser();
      final preview = p.update('| Model | Size |\n').single;
      expect(
        preview.node,
        isA<MdTable>().having((t) => t.tentative, 'tentative', isTrue),
      );
      expect((preview.node as MdTable).header, const [
        [MdText('Model')],
        [MdText('Size')],
      ]);
      // The delimiter row is held back while partial…
      expect(p.update('| Model | Size |\n|---|-').single.id, preview.id);
      // …and once complete the same block becomes a real table.
      final real = p.update('| Model | Size |\n|---|---|\n').single;
      expect(real.id, preview.id);
      expect((real.node as MdTable).tentative, isFalse);
    });

    test('a pipe row is only a paragraph in complete text', () {
      expect(nodeOf('| not a table'), isA<MdParagraph>());
    });
  });

  group('thematic breaks', () {
    test('***, ---, ___ with spaces', () {
      expect(
        nodesOf('***\n\n- - -\n\n_ _ _'),
        List.filled(3, const MdThematicBreak()),
      );
    });
  });

  group('math blocks', () {
    test(r'$$ fenced, single-line and \[ \] blocks', () {
      expect(nodesOf('\$\$\nx^2\n\$\$\n\n\$\$ y \$\$\n\n\\[\nz\n\\]'), const [
        MdMathBlock('x^2', complete: true),
        MdMathBlock('y', complete: true),
        MdMathBlock('z', complete: true),
      ]);
    });

    test('closing delimiter at the end of a content line', () {
      expect(
        nodeOf('\$\$\na +\nb \$\$'),
        const MdMathBlock('a +\nb', complete: true),
      );
    });

    test('streams as incomplete raw TeX until closed', () {
      final block = IncrementalMarkdownParser()
          .update('\$\$\n\\frac{a}{')
          .single;
      expect(block.node, const MdMathBlock(r'\frac{a}{', complete: false));
      expect(block.frozen, isFalse);
    });

    test(r'an unclosed $$ in complete text is a paragraph', () {
      expect(nodesOf('\$\$\nnot math'), [isA<MdParagraph>()]);
    });

    test(r'$$ with trailing text is inline display math', () {
      expect(inlinesOf(r'$$x$$ is nice'), const [
        MdInlineMath('x', display: true),
        MdText(' is nice'),
      ]);
      expect(nodeOf(r'$$5 million'), isA<MdParagraph>());
    });
  });

  group('HTML blocks', () {
    test('rendered as plain text, never parsed as markup', () {
      expect(nodesOf('<div>\n*hi*\n</div>\n\nafter'), const [
        MdHtmlBlock('<div>\n*hi*\n</div>'),
        MdParagraph([MdText('after')]),
      ]);
      expect(nodeOf('<!-- c -->'), const MdHtmlBlock('<!-- c -->'));
      expect(
        nodeOf('<script>\nalert(1)\n</script>'),
        const MdHtmlBlock('<script>\nalert(1)\n</script>'),
      );
    });

    test('type 7 (any tag) cannot interrupt a paragraph', () {
      expect(nodesOf('text\n<custom-tag>'), [isA<MdParagraph>()]);
    });
  });

  group('block ids and offsets', () {
    test('ids are positional, offsets cover the source', () {
      const text = '# A\n\npara\n\n- x';
      final blocks = IncrementalMarkdownParser.parse(text);
      expect(blocks.map((b) => b.id), ['b0', 'b1', 'b2']);
      for (final b in blocks) {
        expect(text.substring(b.start, b.end), b.source);
      }
      expect(blocks.map((b) => b.kind), [
        MdBlockKind.heading,
        MdBlockKind.paragraph,
        MdBlockKind.list,
      ]);
    });

    test('CRLF input parses like LF input', () {
      const lf = '# A\n\n- x\n- y\n\n```\ncode\n```\n';
      final a = nodesOf(lf);
      final b = nodesOf(lf.replaceAll('\n', '\r\n'));
      expect(b, a);
    });
  });
}
