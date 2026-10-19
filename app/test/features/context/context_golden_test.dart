@Tags(['golden'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../support/golden_fonts.dart';
import '../chat/support/chat_golden_fonts.dart';
import 'support/context_harness.dart';

/// Pixel goldens for the context inspector and the handoff review at phone
/// size, light and dark, in the app's real theme.
///
/// Roboto and Material Icons come from flutter_test_config.dart; monospace
/// (raw payloads) from the chat goldens' font loader. Stable only on Linux
/// with the pinned SDK. Regenerate with
/// `flutter test test/features/context --tags golden --update-goldens`.
void main() {
  var mono = false;
  setUpAll(() async => mono = await loadChatGoldenFonts());
  bool ready() => goldenFontsLoaded && mono;

  late ContextHarness h;
  tearDown(() => h.dispose());

  for (final brightness in Brightness.values) {
    final name = brightness.name;

    testWidgets('inspector after a long run ($name)', (tester) async {
      if (!ready()) return;
      h = ContextHarness(turns: [textTurn('All quiet this week.')]);
      await h.seedConversation(turns: 9);
      final chat = await h.open();
      await chat.send('Summarize what changed this week.');
      h.clock.advance(const Duration(minutes: 3));
      await pumpContext(tester, h, location: '/chat/$kSession/context', brightness: brightness);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/inspector_$name.png'));
    });

    testWidgets('inspector items and changes ($name)', (tester) async {
      if (!ready()) return;
      h = ContextHarness(turns: [textTurn('All quiet this week.')]);
      await h.seedConversation(turns: 9);
      final chat = await h.open();
      await chat.send('Summarize what changed this week.');
      h.clock.advance(const Duration(minutes: 3));
      await pumpContext(tester, h, location: '/chat/$kSession/context', brightness: brightness);
      await tester.scrollUntilVisible(
        find.text('In the next request'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
      await settle(tester);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/inspector_items_$name.png'));
    });

    testWidgets('handoff review ($name)', (tester) async {
      if (!ready()) return;
      h = ContextHarness();
      await h.seedConversation(turns: 3, resultLines: 10);
      await h.open();
      await pumpContext(tester, h, location: '/chat/$kSession/handoff', brightness: brightness);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/handoff_review_$name.png'));
    });
  }
}
