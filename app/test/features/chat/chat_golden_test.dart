@Tags(['golden'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/chat/chat_screen.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';

import 'support/chat_golden_fonts.dart';
import 'support/fakes.dart';
import 'support/harness.dart';
import 'support/pump.dart';

/// Pixel goldens for the chat surface, light and dark.
///
/// Rendered by flutter_test's software Skia with Roboto, Material Icons
/// and a monospace font loaded by [loadChatGoldenFonts], so they are only
/// stable on Linux with the pinned SDK. Regenerate with
/// `flutter test test/features/chat --tags golden --update-goldens`.
///
/// They use the chat test theme (support/harness.dart), not the app theme,
/// so the shell's palette work can't churn them.
void main() {
  var fontsReady = false;
  setUpAll(() async => fontsReady = await loadChatGoldenFonts());

  late ChatHarness h;
  tearDown(() => h.dispose());

  /// A finished turn with reasoning and a tool call, ready to continue.
  Future<void> seedConversation() async {
    final t = h.clock.now();
    await h.store.putMessage(
      kSession,
      Message(id: 'u1', role: Role.user, content: const [TextPart('Will it rain in Lisbon tomorrow?')], createdAt: t),
    );
    await h.store.putMessage(
      kSession,
      Message(
        id: 'a1',
        parentId: 'u1',
        role: Role.assistant,
        createdAt: t.add(const Duration(seconds: 1)),
        providerId: kProviderId,
        modelId: kModelId,
        finishReason: 'toolCalls',
        metadata: const {'reasoningMs': 12000},
        content: const [
          ReasoningPart(text: 'The user wants tomorrow\'s forecast for Lisbon. I should call the weather tool.'),
          TextPart('Let me check the forecast.'),
          ToolCallPart(ToolCall(id: 'w1', name: 'weather', arguments: {'city': 'Lisbon', 'day': 'tomorrow'})),
        ],
      ),
    );
    await h.store.putMessage(
      kSession,
      Message(
        id: 't1',
        parentId: 'a1',
        role: Role.tool,
        createdAt: t.add(const Duration(seconds: 2)),
        content: const [
          ToolResultPart(
            callId: 'w1',
            toolName: 'weather',
            content: [TextPart('Light rain after 15:00, 18 °C, wind 12 km/h')],
            durationMs: 840,
          ),
        ],
      ),
    );
    await h.store.putMessage(
      kSession,
      Message(
        id: 'a2',
        parentId: 't1',
        role: Role.assistant,
        createdAt: t.add(const Duration(seconds: 3)),
        providerId: kProviderId,
        modelId: kModelId,
        finishReason: 'stop',
        content: const [
          TextPart('Yes, light rain is likely after 3 pm, around 18 °C. Take a light jacket if you are out in the afternoon.'),
        ],
      ),
    );
    final s = await h.store.getSession(kSession);
    await h.store.putSession(s!.copyWith(activeLeafId: 'a2', title: 'Lisbon weather'));
    h.clock.advance(const Duration(minutes: 1));
  }

  Future<void> settle(WidgetTester tester, [int frames = 20]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
  }

  for (final brightness in Brightness.values) {
    final name = brightness.name;

    testWidgets('conversation with reasoning, tool card and approval ($name)', (tester) async {
      if (!fontsReady) return;
      h = ChatHarness(
        tools: [
          FakeTool('weather', title: 'Weather'),
          writeTool('save_note', title: 'Save note'),
        ],
        turns: [
          ScriptedTurn.toolCalls([
            const ToolCall(
              id: 'n1',
              name: 'save_note',
              arguments: {'title': 'Lisbon', 'text': 'Light rain after 3 pm. Take a jacket.'},
            ),
          ]),
        ],
      );
      await h.createSession();
      await seedConversation();
      await pumpChatScreen(tester, h, brightness: brightness, size: const Size(720, 1180));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Weather'));
      await tester.pumpAndSettle();
      await send(tester, 'Save that to my notes');
      await settle(tester);
      FocusManager.instance.primaryFocus?.unfocus();
      await settle(tester, 30);
      expect(find.text('Allow “Save note”?'), findsOneWidget);
      await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/chat_conversation_$name.png'));
      h.controller.stop();
      await settle(tester);
    }, skip: !Platform.isLinux);

    testWidgets('streaming reply on a phone ($name)', (tester) async {
      if (!fontsReady) return;
      final p = ManualProvider();
      h = ChatHarness(provider: p, tools: [FakeTool('maps', title: 'Maps')]);
      await h.createSession();
      await h.seedExchange('Hi! Can you help me plan trips?', 'Of course. Where are you headed?');
      await pumpChatScreen(tester, h, brightness: brightness, size: const Size(390, 844));
      await tester.pumpAndSettle();
      await send(tester, 'Plan a relaxed day in Porto');
      await settle(tester, 5);
      p.emit(const ReasoningDelta('A relaxed pace: riverside morning, bookshop, tram, sunset viewpoint.'));
      await settle(tester, 2);
      h.clock.advance(const Duration(seconds: 4));
      p.emitAll(const [
        TextDelta('Here is an easy-going day in Porto.\n\n'),
        TextDelta('**Morning.** Start at the Ribeira waterfront and walk across the Dom Luís I bridge '),
        TextDelta('to the Gaia side for the view.\n\n**Late morning.** Livraria Lello, '),
        ToolCallStart(index: 0, id: 'm1', name: 'maps'),
        ToolCallArgsDelta(index: 0, fragment: '{"query": "Livraria Lello opening'),
      ]);
      FocusManager.instance.primaryFocus?.unfocus();
      await settle(tester, 30);
      expect(find.byTooltip('Stop (Esc)'), findsOneWidget);
      await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/chat_streaming_$name.png'));
      h.controller.stop();
      await settle(tester);
    }, skip: !Platform.isLinux);
  }
}
