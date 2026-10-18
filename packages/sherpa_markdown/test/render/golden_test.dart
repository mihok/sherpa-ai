// Pixel goldens with real fonts (see test/flutter_test_config.dart).
// Linux only: font rasterization differs across hosts. Regenerate with
//   flutter test --no-pub --update-goldens test/render/golden_test.dart
@Tags(['golden'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_markdown/sherpa_markdown.dart';

import '../support/harness.dart';
import '../support/sample_document.dart';

const _goldenKey = ValueKey('golden');

/// A long streaming reply caught mid-sentence: earlier blocks frozen (the
/// code is highlighted), the open tail rendered tentatively (bold already
/// bold, the half-received link styled but pending).
const _streamingSnapshot = '''
## Live tail

A frozen paragraph with *emphasis* and `code`.

```python
def greet(name):
    return f"hi {name}"
```

| Model | Size |
|-------|-----:|
| Qwen3 | 0.6B |

The model is still typing **bold text with [a link](https://exam''';

Future<void> _pumpGolden(
  WidgetTester tester,
  String text, {
  required Brightness brightness,
  bool streaming = false,
}) async {
  setSurface(tester, 400, 1900);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      themeAnimationDuration: Duration.zero,
      theme: ThemeData(
        brightness: brightness,
        colorSchemeSeed: const Color(0xFF3A6EA5),
      ),
      home: Builder(
        builder: (context) => Align(
          alignment: Alignment.topCenter,
          child: RepaintBoundary(
            key: _goldenKey,
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SelectionArea(
                  child: StreamingMarkdown(text: text, streaming: streaming),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  expect(tester.takeException(), isNull);
}

void main() {
  final skip = !Platform.isLinux;

  testWidgets('sample document, light', skip: skip, (tester) async {
    await _pumpGolden(tester, sampleDocument, brightness: Brightness.light);
    await expectLater(
      find.byKey(_goldenKey),
      matchesGoldenFile('goldens/sample_light.png'),
    );
  });

  testWidgets('sample document, dark', skip: skip, (tester) async {
    await _pumpGolden(tester, sampleDocument, brightness: Brightness.dark);
    await expectLater(
      find.byKey(_goldenKey),
      matchesGoldenFile('goldens/sample_dark.png'),
    );
  });

  testWidgets('mid-stream snapshot, light', skip: skip, (tester) async {
    await _pumpGolden(
      tester,
      _streamingSnapshot,
      brightness: Brightness.light,
      streaming: true,
    );
    await expectLater(
      find.byKey(_goldenKey),
      matchesGoldenFile('goldens/streaming_light.png'),
    );
  });
}
