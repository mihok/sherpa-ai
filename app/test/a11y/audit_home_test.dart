import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/chat/chat_screen.dart';
import 'package:sherpa/routing/chat_screen_binding.dart';
import 'package:sherpa/routing/routes.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa/state/ui_preferences.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../support/a11y_audit.dart';
import '../support/harness.dart';

/// M6 audit of home and the shell: the chats list on phones, the rail with
/// the sessions pane and a chat beside it on tablets, its empty, first-run,
/// no-results and archived states, a chat's actions, and the offline
/// banner (see [auditScreen]).
// Where textContrastGuideline is skipped (the exact check still runs; see
// auditScreen), and what it misread there.
const _small = '12 px text beside a badge at 1×: an anti-aliasing shade is the most frequent "dark" pixel';

void main() {
  /// Chats from today back to last month, on a configured provider, one
  /// without a model and one whose provider was removed.
  Future<Harness> seeded(AuditView view, {bool chats = true, bool providers = true, bool realChat = false}) async {
    final h = Harness(
      providers: providers ? [openAiConfig()] : const [],
      keys: providers ? {'provider/openai/api_key': 'sk-x'} : const {},
      endpoints: {'api.openai.com': const FakeEndpoint(models: ['gpt-a'])},
      defaultModel: providers ? const ModelChoice(providerId: 'openai', modelId: 'gpt-a') : null,
      ui: UiSettings(themeMode: view.themeMode),
      chat: realChat ? buildChatScreen : FakeChatScreen.new,
    );
    if (chats) {
      await h.addSession('Plan three days in Lisbon', providerId: 'openai', modelId: 'gpt-a');
      await h.addSession('Fix the flaky upload test', providerId: 'openai', modelId: 'gpt-a', age: const Duration(hours: 3));
      await h.addSession('Draft a note to the landlord', age: const Duration(days: 1));
      await h.addSession('Compare two phone plans', providerId: 'gone', modelId: 'x', age: const Duration(days: 9));
      await h.addSession('Summer reading list', providerId: 'openai', modelId: 'gpt-a', age: const Duration(days: 40));
    }
    return h;
  }

  Future<Harness> open(WidgetTester tester, AuditView view, {bool chats = true, bool providers = true, bool realChat = false}) async {
    final h = await seeded(view, chats: chats, providers: providers, realChat: realChat);
    await pumpApp(tester, h, size: view.size, textScale: view.textScale);
    return h;
  }

  auditScreen('home: chats', (tester, view) async => open(tester, view));
  auditScreen('home: nothing set up', (tester, view) async => open(tester, view, chats: false, providers: false));
  auditScreen('home: first chat', (tester, view) async => open(tester, view, chats: false),
      pixelContrastSkip: {AuditView.tablet1x}, contrastNote: _small);

  auditScreen('home: search, nothing matches', (tester, view) async {
    await open(tester, view);
    await tester.enterText(find.byType(TextField), 'tides');
    await tester.pumpAndSettle();
    expect(find.text('No chats match "tides"'), findsOneWidget);
  });

  auditScreen('home: archived, none', (tester, view) async {
    await open(tester, view, chats: false);
    await tester.tap(find.byTooltip('Show archived chats'));
    await tester.pumpAndSettle();
    expect(find.text('No archived chats'), findsOneWidget);
  });

  auditScreen("home: a chat's actions", (tester, view) async {
    await open(tester, view);
    await tester.longPress(find.text('Plan three days in Lisbon'));
    await tester.pumpAndSettle();
    expect(find.text('Archive'), findsOneWidget);
  });

  auditScreen('home: a chat open', (tester, view) async {
    final h = await seeded(view, realChat: true);
    final s = await h.addSession('Will it rain tomorrow?', providerId: 'openai', modelId: 'gpt-a');
    final user = Message(
      id: 'u1',
      role: Role.user,
      content: const [TextPart('Will it rain in Lisbon tomorrow?')],
      createdAt: h.clock.now(),
    );
    final reply = Message(
      id: 'a1',
      parentId: 'u1',
      role: Role.assistant,
      content: const [TextPart('Light rain is likely after 3 pm, around 18 °C.')],
      createdAt: h.clock.now(),
      providerId: 'openai',
      modelId: 'gpt-a',
      finishReason: 'stop',
    );
    await h.store.putMessage(s.id, user);
    await h.store.putMessage(s.id, reply);
    await h.store.putSession(s.copyWith(activeLeafId: 'a1'));
    await pumpApp(tester, h, size: view.size, textScale: view.textScale);
    await goTo(tester, Routes.chat(s.id));
    expect(find.byType(ChatScreen), findsOneWidget);
  });

  auditScreen('shell: offline', (tester, view) async {
    final h = await open(tester, view);
    h.connectivity.add([ConnectivityResult.none]);
    await tester.pumpAndSettle();
    expect(find.text("You're offline · remote models are unavailable"), findsOneWidget);
  });

  auditScreen('shell: settings from the rail', (tester, view) async {
    await open(tester, view);
    await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.byIcon(Icons.settings_outlined)));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsOneWidget, reason: 'Settings is the selected destination');
  }, views: const [AuditView.tablet1x, AuditView.tablet2x]);

  // Medium windows (600–839 dp, a small tablet or an unfolded phone): the
  // rail beside one pane, which the phone and large tablet views never show.
  const medium = [AuditView('medium 1x', Size(720, 1000)), AuditView('medium 2x', Size(720, 1000), textScale: 2)];
  auditScreen('shell: rail and one pane', (tester, view) async {
    await open(tester, view);
    expect(find.byType(NavigationRail), findsOneWidget);
  }, views: medium);
}
