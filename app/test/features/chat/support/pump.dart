import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/chat/chat_screen.dart';

import 'harness.dart';

/// Pumps [ChatScreen] for [kSession] inside a GoRouter so `context.push`
/// works; pushed routes render a page naming the location.
Future<GoRouter> pumpChatScreen(
  WidgetTester tester,
  ChatHarness h, {
  Brightness brightness = Brightness.light,
  Size size = const Size(400, 800),
  double textScale = 1.0,
  bool reducedMotion = false,
}) async {
  tester.view.physicalSize = size * tester.view.devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
  final router = GoRouter(
    initialLocation: '/chat/$kSession',
    routes: [
      GoRoute(
        path: '/chat/:id',
        builder: (_, s) => ChatScreen(sessionId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/settings/providers/:rest',
        builder: (_, s) => Scaffold(body: Text('route:${s.uri.path}')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MediaQuery(
        data: MediaQueryData.fromView(tester.view).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reducedMotion,
        ),
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: chatTestTheme(Brightness.light, reducedMotion: reducedMotion),
          darkTheme: chatTestTheme(Brightness.dark, reducedMotion: reducedMotion),
          themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
          routerConfig: router,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return router;
}
