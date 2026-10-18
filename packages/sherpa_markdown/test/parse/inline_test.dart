import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_markdown/parse.dart';

import '../support/parse_helpers.dart';

/// Inlines of the open (streaming) paragraph for [text].
List<MdInline> streamingInlines(String text) {
  final blocks = IncrementalMarkdownParser().update(text);
  if (blocks.isEmpty) return const [];
  final node = blocks.last.node;
  return node is MdParagraph ? node.inlines : throw StateError('$node');
}

void main() {
  group('emphasis', () {
    test('em, strong, both, strikethrough', () {
      expect(inlinesOf('*a* _b_ **c** __d__ ***e*** ~~f~~'), const [
        MdEmphasis([MdText('a')]),
        MdText(' '),
        MdEmphasis([MdText('b')]),
        MdText(' '),
        MdStrong([MdText('c')]),
        MdText(' '),
        MdStrong([MdText('d')]),
        MdText(' '),
        MdEmphasis([
          MdStrong([MdText('e')]),
        ]),
        MdText(' '),
        MdStrikethrough([MdText('f')]),
      ]);
    });

    test('intraword underscores and spaced asterisks stay literal', () {
      expect(inlinesOf('snake_case_name and 2 * 3 * 4'), const [
        MdText('snake_case_name and 2 * 3 * 4'),
      ]);
    });

    test('a single tilde means "approximately", not strikethrough', () {
      expect(inlinesOf('~5 min to ~10 min'), const [
        MdText('~5 min to ~10 min'),
      ]);
    });
  });

  group('code spans', () {
    test('single and double backticks', () {
      expect(inlinesOf('`a` and `` b`c ``'), const [
        MdInlineCode('a'),
        MdText(' and '),
        MdInlineCode('b`c'),
      ]);
    });

    test('markup inside code is literal', () {
      expect(inlinesOf(r'`**x** $y$`'), const [MdInlineCode(r'**x** $y$')]);
    });
  });

  group('links and images', () {
    test('inline link with title', () {
      expect(inlinesOf('[docs](https://a.com/x "T")'), const [
        MdLink(href: 'https://a.com/x', title: 'T', children: [MdText('docs')]),
      ]);
    });

    test('autolinks: angle brackets, bare URLs, www, email', () {
      final links = inlinesOf(
        '<https://a.com> https://b.org/p_q www.c.net <me@d.io>',
      ).whereType<MdLink>().map((l) => l.href);
      expect(links, [
        'https://a.com',
        'https://b.org/p_q',
        'http://www.c.net',
        'mailto:me@d.io',
      ]);
    });

    test('images keep src and alt', () {
      expect(inlinesOf('![a cat](https://x.io/c.png)'), const [
        MdImage(src: 'https://x.io/c.png', alt: 'a cat'),
      ]);
    });

    test(
      'reference-style links stay literal (no definitions across blocks)',
      () {
        expect(plain(inlinesOf('[text][ref]')), '[text][ref]');
      },
    );
  });

  group('inline math', () {
    test(r'$…$ and \(…\)', () {
      expect(inlinesOf(r'$x^2$ and \(y\)'), const [
        MdInlineMath('x^2'),
        MdText(' and '),
        MdInlineMath('y'),
      ]);
    });

    test('currency is not math', () {
      for (final text in [
        r'It costs $5 and $10.',
        r'$5-$10 per month',
        r'$5, $10, and $15',
        r'US$5 or US$10',
        r'$ 5 $',
      ]) {
        expect(
          inlinesOf(text).whereType<MdInlineMath>(),
          isEmpty,
          reason: text,
        );
      }
    });

    test('only the first dollar after the opener can close it', () {
      expect(inlinesOf(r'costs $5. Then $x$ wins'), const [
        MdText(r'costs $5. Then '),
        MdInlineMath('x'),
        MdText(' wins'),
      ]);
    });

    test(r'escaped \$ is literal; $$…$$ inline is display math', () {
      expect(inlinesOf(r'\$x\$'), const [MdText(r'$x$')]);
      expect(inlinesOf(r'a $$\sum$$ b'), const [
        MdText('a '),
        MdInlineMath(r'\sum', display: true),
        MdText(' b'),
      ]);
    });
  });

  group('breaks, entities, HTML', () {
    test('hard breaks: two spaces and backslash', () {
      expect(inlinesOf('a  \nb\\\nc'), const [
        MdText('a'),
        MdLineBreak(),
        MdText('b'),
        MdLineBreak(),
        MdText('c'),
      ]);
    });

    test('entities decode; inline HTML stays literal text', () {
      expect(inlinesOf('a &amp; <b>bold</b> <img src=x onerror=y>'), const [
        MdText('a & <b>bold</b> <img src=x onerror=y>'),
      ]);
    });
  });

  group('streaming repairs (open block only)', () {
    test('unclosed emphasis renders as emphasis from the first character', () {
      expect(streamingInlines('Hi **bol'), const [
        MdText('Hi '),
        MdStrong([MdText('bol')]),
      ]);
      expect(streamingInlines('*it'), const [
        MdEmphasis([MdText('it')]),
      ]);
      expect(streamingInlines('_it'), const [
        MdEmphasis([MdText('it')]),
      ]);
      expect(streamingInlines('~~gone'), const [
        MdStrikethrough([MdText('gone')]),
      ]);
      expect(streamingInlines('**bold *both'), const [
        MdStrong([
          MdText('bold '),
          MdEmphasis([MdText('both')]),
        ]),
      ]);
    });

    test('a dangling opener is hidden, not shown as asterisks', () {
      expect(streamingInlines('Hello **'), const [MdText('Hello')]);
      expect(streamingInlines('Hello `'), const [MdText('Hello')]);
      expect(streamingInlines('Hello ~~'), const [MdText('Hello')]);
    });

    test('closers already present are not duplicated', () {
      expect(streamingInlines('**done**'), const [
        MdStrong([MdText('done')]),
      ]);
    });

    test('unclosed code span is code; emphasis outside it still closes', () {
      expect(streamingInlines('run `npm i'), const [
        MdText('run '),
        MdInlineCode('npm i'),
      ]);
      expect(streamingInlines('**see `x'), const [
        MdStrong([MdText('see '), MdInlineCode('x')]),
      ]);
    });

    test('a link whose URL is streaming is pending (styled, not tappable)', () {
      expect(streamingInlines('See [docs](https://a.co'), const [
        MdText('See '),
        MdLink(href: null, children: [MdText('docs')]),
      ]);
      expect(streamingInlines('See [docs'), const [MdText('See docs')]);
      expect(streamingInlines('See [docs]'), const [MdText('See docs')]);
      expect(streamingInlines('x[0'), const [MdText('x[0')]);
    });

    test('images: hidden until the URL starts, then a pending image', () {
      expect(streamingInlines('![a cat'), isEmpty);
      expect(streamingInlines('![a cat](https://x'), const [
        MdImage(src: null, alt: 'a cat'),
      ]);
    });

    test('a bare URL at the very end is not tappable yet', () {
      final inlines = streamingInlines('go https://example.com/a');
      expect(
        inlines.last,
        isA<MdLink>().having((l) => l.pending, 'pending', isTrue),
      );
      final trailing = streamingInlines('go https://example.com/a_');
      expect(trailing.whereType<MdLink>().single.pending, isTrue);
      final done = streamingInlines('go https://example.com/a now');
      expect(done.whereType<MdLink>().single.href, 'https://example.com/a');
    });

    test('an odd trailing backslash is hidden', () {
      expect(streamingInlines(r'a \'), const [MdText('a')]);
    });

    test('literal constructs are unaffected', () {
      expect(streamingInlines('2 * 3 = 6'), const [MdText('2 * 3 = 6')]);
      expect(streamingInlines('my_var_name'), const [MdText('my_var_name')]);
      expect(streamingInlines(r'costs $5'), const [MdText(r'costs $5')]);
    });

    test('complete text is parsed exactly, without repairs', () {
      expect(inlinesOf('Hi **bol'), const [MdText('Hi **bol')]);
      expect(inlinesOf('[docs](https://a'), const [MdText('[docs](https://a')]);
    });

    test('headings and table cells being typed are repaired too', () {
      final heading = IncrementalMarkdownParser().update('# **Bo').single.node;
      expect(
        heading,
        const MdHeading(1, [
          MdStrong([MdText('Bo')]),
        ]),
      );
      final table =
          IncrementalMarkdownParser()
                  .update('| a | b |\n|---|---|\n| 1 | **tw')
                  .single
                  .node
              as MdTable;
      expect(table.rows.single[1], const [
        MdStrong([MdText('tw')]),
      ]);
    });
  });
}
