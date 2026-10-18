import 'package:flutter/rendering.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_markdown/sherpa_markdown.dart';

import '../support/harness.dart';
import '../support/span_helpers.dart';

void main() {
  testWidgets('headings carry semantics heading levels', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpMarkdown(tester, '# One\n\n## Two\n\n###### Six');
    for (final (label, level) in [('One', 1), ('Two', 2), ('Six', 6)]) {
      final node = tester.getSemantics(find.text(label));
      expect(node.getSemanticsData().headingLevel, level, reason: label);
    }
    final one = spanContaining(tester, 'One').style;
    final body = spanContaining(tester, 'Six').style;
    expect(one.fontSize!, greaterThan(body.fontSize!));
    semantics.dispose();
  });

  testWidgets('inline styles: strong, em, strike, code, link', (tester) async {
    await pumpMarkdown(
      tester,
      'a **strong** *em* ~~gone~~ `code` [link](https://x.io)',
    );
    expect(spanContaining(tester, 'strong').style.fontWeight, FontWeight.w700);
    expect(spanContaining(tester, 'em').style.fontStyle, FontStyle.italic);
    expect(
      spanContaining(tester, 'gone').style.decoration!.contains(TextDecoration.lineThrough),
      isTrue,
    );
    final code = spanContaining(tester, 'code').style;
    expect(code.fontFamily, 'monospace');
    expect(code.backgroundColor, isNotNull);
    final link = spanContaining(tester, 'link');
    expect(link.style.decoration!.contains(TextDecoration.underline), isTrue);
    expect(link.span.recognizer, isNotNull);
  });

  testWidgets('paragraph soft breaks and hard breaks become line breaks', (tester) async {
    await pumpMarkdown(tester, 'one\ntwo  \nthree');
    final text = tester.widget<RichText>(find.byType(RichText).first).text.toPlainText();
    expect(text, 'one\ntwo\nthree');
  });

  testWidgets('code block: language label, copy button, horizontal scroll', (tester) async {
    await pumpMarkdown(tester, '```dart\nvoid main() {}\n```');
    expect(find.text('dart'), findsOneWidget);
    expect(find.byIcon(Icons.content_copy_rounded), findsOneWidget);
    final scroll = tester.widget<SingleChildScrollView>(
      find
          .ancestor(
            of: find.textContaining('void main()', findRichText: true),
            matching: find.byType(SingleChildScrollView),
          )
          .first,
    );
    expect(scroll.scrollDirection, Axis.horizontal);
    // Highlighted: the keyword has its own colour.
    final keyword = spanContaining(tester, 'void');
    final plainColor = MarkdownColors.of(tester).onSurface;
    expect(keyword.style.color, isNot(plainColor));
  });

  testWidgets('table: header styling, alignment, horizontal scroll', (tester) async {
    await pumpMarkdown(tester, '| L | C | R |\n|:--|:-:|--:|\n| a | b | c |');
    final table = tester.widget<Table>(find.byType(Table));
    expect(table.children, hasLength(2));
    expect(table.children.first.decoration, isA<BoxDecoration>());
    expect(spanContaining(tester, 'L').style.fontWeight, FontWeight.w600);
    final aligns = [
      for (final s in ['a', 'b', 'c'])
        tester.widget<RichText>(find.text(s, findRichText: true)).textAlign,
    ];
    expect(aligns, [TextAlign.start, TextAlign.center, TextAlign.end]);
    final scroll = tester.widget<SingleChildScrollView>(
      find.ancestor(of: find.byType(Table), matching: find.byType(SingleChildScrollView)).first,
    );
    expect(scroll.scrollDirection, Axis.horizontal);
  });

  testWidgets('block quote has a leading bar and dimmed text', (tester) async {
    await pumpMarkdown(tester, '> quoted\n\nplain');
    final box = tester.widget<DecoratedBox>(
      find.ancestor(of: find.text('quoted'), matching: find.byType(DecoratedBox)).first,
    );
    final border = (box.decoration as BoxDecoration).border! as BorderDirectional;
    expect(border.start.width, 3);
    expect(
      spanContaining(tester, 'quoted').style.color,
      isNot(spanContaining(tester, 'plain').style.color),
    );
  });

  testWidgets('lists: bullets by depth, numbers from start, tasks', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpMarkdown(
      tester,
      '- a\n  - b\n    - c\n\n7. seven\n8. eight\n\n- [x] done\n- [ ] todo',
    );
    expect(find.text('•'), findsOneWidget);
    expect(find.text('◦'), findsOneWidget);
    expect(find.text('–'), findsOneWidget);
    expect(find.text('7.'), findsOneWidget);
    expect(find.text('8.'), findsOneWidget);
    expect(find.byIcon(Icons.check_box_rounded), findsOneWidget);
    expect(find.byIcon(Icons.check_box_outline_blank_rounded), findsOneWidget);
    // The checked state merges into the list item, which reads
    // "checked, done" — no separate checkbox control.
    expect(
      tester.getSemantics(find.text('done')),
      containsSemantics(hasCheckedState: true, isChecked: true),
    );
    expect(
      tester.getSemantics(find.text('todo')),
      containsSemantics(hasCheckedState: true, isChecked: false),
    );
    semantics.dispose();
  });

  testWidgets('thematic break renders a divider', (tester) async {
    await pumpMarkdown(tester, 'a\n\n---\n\nb');
    expect(find.byType(Divider), findsOneWidget);
  });

  testWidgets('math: block and inline render with flutter_math_fork', (tester) async {
    await pumpMarkdown(tester, r'$$\frac{1}{2}$$' '\n\ninline \$x^2\$ here');
    expect(find.byType(Math), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('math parse errors fall back to raw TeX in monospace', (tester) async {
    await pumpMarkdown(tester, r'$$\frac{1}{$$');
    expect(find.text(r'\frac{1}{'), findsOneWidget);
    final raw = tester.widget<Text>(find.text(r'\frac{1}{'));
    expect(raw.style!.fontFamily, 'monospace');
  });

  testWidgets('a streaming (unclosed) math block shows raw TeX', (tester) async {
    await pumpMarkdown(tester, '\$\$\n\\int_0^1 x', streaming: true);
    expect(find.byType(Math), findsNothing);
    expect(find.text(r'\int_0^1 x'), findsOneWidget);
  });

  testWidgets('HTML is shown as text, never interpreted', (tester) async {
    await pumpMarkdown(tester, '<div><b>bold?</b><img src="https://x.io/p.png"></div>');
    expect(find.textContaining('<div><b>bold?</b>'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('dark theme changes code and text colours', (tester) async {
    await pumpMarkdown(tester, 'text\n\n```\ncode\n```');
    final lightText = spanContaining(tester, 'text').style.color;
    final lightBox = _codeBackground(tester);
    await pumpMarkdown(tester, 'text\n\n```\ncode\n```', brightness: Brightness.dark);
    expect(spanContaining(tester, 'text').style.color, isNot(lightText));
    expect(_codeBackground(tester), isNot(lightBox));
  });

  testWidgets('host style overrides apply', (tester) async {
    await pumpMarkdown(
      tester,
      '[l](https://x.io) and `c`',
      style: const SherpaMarkdownStyle(
        body: TextStyle(fontSize: 20),
        linkColor: Color(0xFFFF0000),
      ),
    );
    expect(spanContaining(tester, 'l').style.color, const Color(0xFFFF0000));
    expect(spanContaining(tester, 'and').style.fontSize, 20);
  });
}

Color _codeBackground(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(
    find.ancestor(of: find.text('code'), matching: find.byType(DecoratedBox)).first,
  );
  return (box.decoration as BoxDecoration).color!;
}

/// Colours of the ambient test theme.
abstract final class MarkdownColors {
  static ColorScheme of(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(StreamingMarkdown))).colorScheme;
}
