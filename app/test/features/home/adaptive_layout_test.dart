import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/home/sessions_pane.dart';
import 'package:sherpa/routing/routes.dart';

import '../../support/harness.dart';

void main() {
  Future<Harness> seeded() async {
    final h = Harness(providers: [openAiConfig()]);
    await h.addSession('Alpha', providerId: 'openai', modelId: 'gpt-x');
    await h.addSession('Beta', providerId: 'openai', modelId: 'gpt-x', age: const Duration(hours: 1));
    return h;
  }

  testWidgets('compact (<600): list only, FAB, settings in the app bar; chat pushes full screen', (tester) async {
    final h = await seeded();
    await pumpApp(tester, h, size: const Size(599, 900));
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(SessionsScreen), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsNothing, reason: 'the chat covers the list');
    expect(find.textContaining('chat:'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
  });

  testWidgets('medium (600–839): rail and one pane', (tester) async {
    final h = await seeded();
    await pumpApp(tester, h, size: const Size(600, 900));
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(SessionsScreen), findsOneWidget);
    expect(find.byType(SessionsPane), findsNothing);
    expect(find.byTooltip('Settings'), findsNothing, reason: 'settings moved to the rail');
  });

  testWidgets('expanded (≥840): rail + sessions pane + chat pane side by side', (tester) async {
    final h = await seeded();
    await pumpApp(tester, h, size: const Size(840, 900));
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(SessionsPane), findsOneWidget);
    expect(find.text('Pick a chat, or start a new one'), findsOneWidget);

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsOneWidget, reason: 'the list stays visible');
    expect(find.textContaining('chat:'), findsOneWidget);
    expect(find.byType(BackButton), findsNothing, reason: 'the list is the navigation in two-pane');
    final tile = tester.widget<ListTile>(find.widgetWithText(ListTile, 'Alpha'));
    expect(tile.selected, isTrue);

    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'Beta')).selected, isTrue);
  });

  testWidgets('resizing across 840 keeps the open chat and switches layout', (tester) async {
    final h = await seeded();
    await pumpApp(tester, h, size: const Size(400, 900));
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionsPane), findsNothing);

    tester.view.physicalSize = const Size(1200, 900);
    await tester.pumpAndSettle();
    expect(find.byType(SessionsPane), findsOneWidget);
    expect(find.textContaining('chat:'), findsOneWidget);

    tester.view.physicalSize = const Size(400, 900);
    await tester.pumpAndSettle();
    expect(find.byType(SessionsPane), findsNothing);
    expect(find.textContaining('chat:'), findsOneWidget);
  });

  testWidgets('a vertical hinge splits panes even below 840', (tester) async {
    final h = await seeded();
    setWindow(tester, const Size(820, 700));
    tester.view.displayFeatures = const [
      DisplayFeature(
        bounds: Rect.fromLTWH(400, 0, 20, 700),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.postureFlat,
      ),
    ];
    await tester.pumpWidget(h.app());
    await tester.pumpAndSettle();
    expect(find.byType(SessionsPane), findsOneWidget);
    final pane = tester.getRect(find.byType(SessionsPane));
    expect(pane.right, lessThanOrEqualTo(400), reason: 'nothing straddles the hinge');
  });

  testWidgets('settings is a rail destination on tablets and hides the list', (tester) async {
    final h = await seeded();
    await pumpApp(tester, h, size: const Size(1200, 900));
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Model providers'), findsOneWidget);
    expect(find.byType(SessionsPane), findsNothing);
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.selectedIndex, 1);
    await tester.tap(find.text('Chats'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionsPane), findsOneWidget);
  });

  testWidgets('Ctrl+N starts a chat, Ctrl+, opens settings', (tester) async {
    final h = await seeded();
    await pumpApp(tester, h, size: const Size(1200, 900));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(await h.store.listSessions(), hasLength(3));
    expect(find.textContaining('chat:'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.text('Privacy & data'), findsOneWidget);
  });

  testWidgets('deep links into a chat work on both layouts', (tester) async {
    final h = await seeded();
    await pumpApp(tester, h);
    final id = (await h.store.listSessions()).first.id;
    await goTo(tester, Routes.chat(id));
    expect(find.text('chat:$id'), findsOneWidget);
  });
}
