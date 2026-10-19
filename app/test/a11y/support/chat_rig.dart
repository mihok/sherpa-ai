import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/design/motion.dart';
import 'package:sherpa/design/theme.dart';
import 'package:sherpa/features/chat/chat_screen.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../features/chat/support/harness.dart';
import '../../support/a11y_audit.dart';

/// The chat screen for [view] over [h]'s container, with the app's own
/// theme ([SherpaTheme], not the chat tests' seeded one, so contrast is the
/// shipped palette's), [MotionScope] and, for [AuditView.rtl], a forced
/// right-to-left [Directionality]. Other routes render a page naming them.
Future<GoRouter> pumpChatFor(WidgetTester tester, ChatHarness h, AuditView view) async {
  setAuditWindow(tester, view);
  final router = GoRouter(
    initialLocation: '/chat/$kSession',
    routes: [
      GoRoute(path: '/chat/:id', builder: (_, s) => ChatScreen(sessionId: s.pathParameters['id']!)),
    ],
    errorBuilder: (_, s) => Scaffold(body: Text('route:${s.uri.path}')),
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: SherpaTheme.light(),
        darkTheme: SherpaTheme.dark(),
        themeMode: view.themeMode,
        routerConfig: router,
        builder: rtlBuilder(view, (context, child) => MotionScope(child: child ?? const SizedBox.shrink())),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return router;
}

/// Advances fake time in small steps so scripted events stream through.
Future<void> streamFrames(WidgetTester tester, {int frames = 30}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Types [text] into the composer and taps Send.
Future<void> typeAndSend(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).last, text);
  await tester.pump();
  await tester.tap(find.byTooltip('Send'));
  await tester.pump();
}

/// A finished exchange that called tools: one call on its own (expanded
/// to show its arguments and result), then a group of three.
Future<void> seedToolConversation(ChatHarness h) async {
  final t = h.clock.now();
  Message msg(String id, String? parent, Role role, List<ContentPart> content, {String? finish, JsonMap meta = const {}}) =>
      Message(
        id: id,
        parentId: parent,
        role: role,
        content: content,
        createdAt: t,
        providerId: role == Role.assistant ? kProviderId : null,
        modelId: role == Role.assistant ? kModelId : null,
        finishReason: finish,
        metadata: meta,
      );
  ToolResultPart result(String id, String name, String text, int ms) =>
      ToolResultPart(callId: id, toolName: name, content: [TextPart(text)], durationMs: ms);
  final messages = [
    msg('u1', null, Role.user, const [TextPart('Will it rain in Lisbon tomorrow, and what is on my calendar?')]),
    msg('a1', 'u1', Role.assistant, const [
      ReasoningPart(text: 'Check the forecast first, then the calendar and the notes.'),
      TextPart('Let me check the forecast.'),
      ToolCallPart(ToolCall(id: 'w1', name: 'weather', arguments: {'city': 'Lisbon', 'day': 'tomorrow'})),
    ], finish: 'toolCalls', meta: const {'reasoningMs': 4000}),
    msg('t1', 'a1', Role.tool, [result('w1', 'weather', 'Light rain after 15:00, 18 °C, wind 12 km/h', 840)]),
    msg('a2', 't1', Role.assistant, const [
      TextPart('Now your calendar and notes.'),
      ToolCallPart(ToolCall(id: 'c1', name: 'calendar', arguments: {'day': 'tomorrow'})),
      ToolCallPart(ToolCall(id: 'n1', name: 'notes', arguments: {'query': 'Lisbon'})),
      ToolCallPart(ToolCall(id: 'm1', name: 'maps', arguments: {'from': 'Hotel', 'to': 'Belém'})),
    ], finish: 'toolCalls'),
    msg('t2', 'a2', Role.tool, [
      result('c1', 'calendar', '10:00 Tram 28 tour', 120),
      result('n1', 'notes', 'Pastéis de Belém before noon', 90),
      result('m1', 'maps', '25 min by tram 15E', 300),
    ]),
    msg('a3', 't2', Role.assistant, const [
      TextPart('Light rain is likely after 3 pm. Your tram tour is at 10, and Belém is 25 minutes away by tram 15E.'),
    ], finish: 'stop'),
  ];
  for (final m in messages) {
    await h.store.putMessage(kSession, m);
  }
  final s = await h.store.getSession(kSession);
  await h.store.putSession(s!.copyWith(activeLeafId: 'a3', title: 'Lisbon tomorrow'));
}
