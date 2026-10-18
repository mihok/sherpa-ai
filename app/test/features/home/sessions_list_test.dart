import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/home/session_search_field.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../support/harness.dart';

Finder get searchField => find.descendant(of: find.byType(SessionSearchField), matching: find.byType(TextField));

void main() {
  const choice = ModelChoice(providerId: 'openai', modelId: 'gpt-x');

  testWidgets('empty state sells the first chat; New chat creates and opens one', (tester) async {
    final h = Harness(providers: [openAiConfig()], defaultModel: choice);
    await pumpApp(tester, h);
    expect(find.text('Start your first chat'), findsOneWidget);
    expect(find.text('New chats use gpt-x'), findsOneWidget);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    final s = (await h.store.listSessions()).single;
    expect(s.title, defaultSessionTitle);
    expect(s.modelId, 'gpt-x');
    expect(find.text('chat:${s.id}'), findsOneWidget);

    // Back returns to the list, which now shows the chat with its badge.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, defaultSessionTitle), findsOneWidget);
    expect(findBadge('api.openai.com'), findsOneWidget);
    expect(find.text('Just now'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
  });

  testWidgets('swipe left deletes with undo; undo brings it back', (tester) async {
    final h = Harness(providers: [openAiConfig()]);
    final s = await h.addSession('Plan the trip', providerId: 'openai', modelId: 'gpt-x');
    await pumpApp(tester, h);

    await tester.drag(find.text('Plan the trip'), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('Plan the trip'), findsNothing);
    expect(find.text('Chat deleted'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Plan the trip'), findsOneWidget);
    expect(await h.store.getSession(s.id), isNotNull);
  });

  testWidgets('a delete commits when the undo window closes', (tester) async {
    final h = Harness();
    final s = await h.addSession('Scratch');
    await pumpApp(tester, h);

    await tester.drag(find.text('Scratch'), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(await h.store.getSession(s.id), isNotNull, reason: 'not deleted during the undo window');
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(await h.store.getSession(s.id), isNull);
    expect(find.text('Start your first chat'), findsNothing);
    expect(find.text('Connect a model to start'), findsOneWidget);
  });

  testWidgets('swipe right archives; archived chats are one tap away', (tester) async {
    final h = Harness();
    await h.addSession('Old notes');
    await pumpApp(tester, h);

    await tester.drag(find.text('Old notes'), const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(find.text('Old notes'), findsNothing);
    expect(find.text('Chat archived'), findsOneWidget);
    expect((await h.store.listSessions(includeArchived: true)).single.archived, isTrue);

    await tester.tap(find.byTooltip('Show archived chats'));
    await tester.pumpAndSettle();
    expect(find.text('Archived chats'), findsOneWidget);
    expect(find.text('Old notes'), findsOneWidget);
  });

  testWidgets('search filters by title and model, with a designed no-results state', (tester) async {
    final h = Harness();
    await h.addSession('Trip to Lisbon', modelId: 'gpt-x');
    await h.addSession('Fix the parser', modelId: 'qwen3:8b', age: const Duration(days: 2));
    await pumpApp(tester, h);
    expect(find.text('Trip to Lisbon'), findsOneWidget);
    expect(find.text('Fix the parser'), findsOneWidget);

    await tester.enterText(searchField, 'qwen');
    await tester.pumpAndSettle();
    expect(find.text('Trip to Lisbon'), findsNothing);
    expect(find.text('Fix the parser'), findsOneWidget);

    await tester.enterText(searchField, 'zebra');
    await tester.pumpAndSettle();
    expect(find.text('No chats match "zebra"'), findsOneWidget);
    await tester.tap(find.text('Clear search'));
    await tester.pumpAndSettle();
    expect(find.text('Trip to Lisbon'), findsOneWidget);
    expect(find.text('Fix the parser'), findsOneWidget);
  });

  testWidgets('tiles expose archive and delete to screen readers', (tester) async {
    final handle = tester.ensureSemantics();
    final h = Harness();
    await h.addSession('Accessible chat', modelId: 'gpt-x');
    await pumpApp(tester, h);
    final node = tester.getSemantics(find.text('Accessible chat'));
    final actions = node.getSemanticsData().customSemanticsActionIds ?? const [];
    expect(actions, hasLength(2));
    expect(node.label, contains('Accessible chat'));
    expect(node.label, contains('just now'));
    handle.dispose();
  });

  testWidgets('chats renamed elsewhere (e.g. by the agent loop) update live', (tester) async {
    final h = Harness();
    final s = await h.addSession(defaultSessionTitle);
    await pumpApp(tester, h);
    await h.store.putSession(s.copyWith(title: 'Weekend in Porto'));
    await tester.pumpAndSettle();
    expect(find.text('Weekend in Porto'), findsOneWidget);
  });
}
