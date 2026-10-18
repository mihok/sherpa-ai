import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// A leaf text span found in the widget tree, with its inherited style.
typedef FoundSpan = ({TextSpan span, TextStyle style, RichText owner});

/// Every leaf [TextSpan] under [finder] (default: whole tree), with styles
/// merged from their ancestors the way the text engine sees them.
List<FoundSpan> leafSpans(WidgetTester tester, [Finder? finder]) {
  final out = <FoundSpan>[];
  final widgets = tester.widgetList<RichText>(
    find.descendant(
      of: finder ?? find.byType(MaterialApp),
      matching: find.byType(RichText),
    ),
  );
  for (final rich in widgets) {
    void visit(InlineSpan span, TextStyle inherited) {
      final style = inherited.merge(span.style);
      if (span is TextSpan) {
        if (span.text != null && span.text!.isNotEmpty) {
          out.add((span: span, style: style, owner: rich));
        }
        for (final child in span.children ?? const <InlineSpan>[]) {
          visit(child, style);
        }
      }
    }

    visit(rich.text, const TextStyle());
  }
  return out;
}

/// The first leaf span whose text contains [fragment].
FoundSpan spanContaining(WidgetTester tester, String fragment) =>
    leafSpans(tester).firstWhere(
      (s) => s.span.text!.contains(fragment),
      orElse: () => throw StateError('no span contains "$fragment"'),
    );
