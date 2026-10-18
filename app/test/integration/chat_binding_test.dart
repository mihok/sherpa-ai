import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/chat/chat_screen.dart';
import 'package:sherpa/routing/chat_screen_binding.dart';
import 'package:sherpa/state/services.dart';

import '../support/harness.dart';

/// The shell hosts the real chat feature through its one seam
/// (`buildChatScreen`), on phones and in the tablet detail pane.
void main() {
  Harness withRealChat() {
    final h = Harness(
      providers: [openAiConfig()],
      endpoints: {'api.openai.com': const FakeEndpoint(models: ['gpt-a'])},
      defaultModel: const ModelChoice(providerId: 'openai', modelId: 'gpt-a'),
      chat: buildChatScreen,
    );
    return h;
  }

  for (final size in [phone, tablet]) {
    testWidgets('New chat opens the real ChatScreen (${size.width.toInt()}dp)', (tester) async {
      final h = withRealChat();
      setWindow(tester, size);
      await tester.pumpWidget(h.app());
      await tester.pumpAndSettle();
      if (size == phone) {
        await tester.tap(find.byType(FloatingActionButton));
      } else {
        await tester.tap(find.byTooltip('New chat (Ctrl+N)'));
      }
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
