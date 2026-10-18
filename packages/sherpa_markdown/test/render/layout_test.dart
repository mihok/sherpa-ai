import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_markdown/sherpa_markdown.dart';

import '../support/harness.dart';
import '../support/sample_document.dart';

void main() {
  testWidgets('no overflow at 2.0 text scale on a 320-wide surface', (tester) async {
    setSurface(tester, 320, 640);
    await pumpMarkdown(tester, sampleDocument, textScale: 2.0);
    expect(tester.takeException(), isNull);
    // The document is far taller than the viewport; scroll through it so
    // every block is laid out and painted at least once.
    for (var i = 0; i < 40; i++) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('streaming every prefix at 2.0 text scale never overflows', (tester) async {
    setSurface(tester, 320, 2000);
    const doc = '| Column one | Column two |\n|---|---|\n| a long cell value here | b |\n\n'
        '- [ ] a task with a really long description that wraps\n'
        '```bash\necho "a very long command line that must scroll horizontally"\n```\n'
        '![img](https://images.example.net/with/a/very/long/path/name.png)';
    for (var i = 1; i <= doc.length; i += 3) {
      await pumpMarkdown(tester, doc.substring(0, i), streaming: true, textScale: 2.0);
      expect(tester.takeException(), isNull, reason: 'prefix $i');
    }
  });

  testWidgets('long words and URLs wrap inside the width', (tester) async {
    setSurface(tester, 320, 800);
    final word = 'x' * 300;
    await pumpMarkdown(tester, '$word https://example.com/${'a' * 200}', textScale: 2.0);
    expect(tester.takeException(), isNull);
    final size = tester.getSize(find.byType(StreamingMarkdown));
    expect(size.width, lessThanOrEqualTo(320 - 32));
  });

  testWidgets('text scaling reaches every text widget', (tester) async {
    await pumpMarkdown(tester, '# H\n\npara\n\n- item\n\n| t |\n|---|\n| c |', textScale: 1.7);
    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      expect(rich.textScaler, const TextScaler.linear(1.7));
    }
  });
}
