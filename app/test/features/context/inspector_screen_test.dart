import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/context/handoff/handoff_screen.dart';
import 'package:sherpa/features/context/widgets/item_views.dart';
import 'package:sherpa/features/context/widgets/overlay_views.dart';
import 'package:sherpa_core/sherpa_core.dart';

import 'support/context_harness.dart';

void main() {
  late ContextHarness h;
  tearDown(() => h.dispose());

  /// A 9-turn chat whose last run made the ladder elide and compact.
  Future<void> longRun(WidgetTester tester) async {
    h = ContextHarness(turns: [textTurn('All quiet this week.')]);
    await h.seedConversation(turns: 9);
    final chat = await h.open();
    await chat.send('Summarize what changed this week.');
  }

  Future<void> scrollTo(WidgetTester tester, Finder f) async {
    await tester.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);
    await tester.pump();
  }

  testWidgets('shows the budget, every item and every change of a real run', (tester) async {
    await longRun(tester);
    final overlays = await h.store.overlays(kSession);
    expect(overlays.whereType<CompactedRange>(), hasLength(1));
    expect(overlays.whereType<ToolOutputElided>(), isNotEmpty);

    await pumpContext(tester, h, location: '/chat/$kSession/context');
    expect(find.text('What the model sees'), findsWidgets);
    expect(find.textContaining('% used'), findsOneWidget);
    expect(find.text('Estimated'), findsOneWidget);
    expect(find.text('Earlier messages are summarized'), findsOneWidget);
    expect(find.text('System prompt'), findsWidgets);
    expect(find.text('Tool definitions'), findsWidgets);

    // The summary leads the view, marked as compacted.
    await scrollTo(tester, find.text('Summary of earlier messages'));
    expect(find.text('Compacted'), findsWidgets);
    // Every item of the inspection has a tile.
    final snap = (await h.chat.inspectContext())!;
    await scrollTo(tester, find.textContaining('All quiet this week.'));
    expect(find.byType(ContextItemTile), findsWidgets);
    expect(snap.inspection.items.length, 8);

    // Every overlay has a card with its reason.
    await scrollTo(tester, find.text('Changes to the context'));
    await scrollTo(tester, find.textContaining('summarized 32 earlier messages'));
    expect(find.text('In effect'), findsOneWidget);
    // The elisions inside the summary are grouped, collapsed.
    await scrollTo(tester, find.text('6 older changes inside a summary'));
    expect(find.text('Inside a later summary'), findsNothing);
    await tester.tap(find.text('6 older changes inside a summary'));
    await settle(tester);
    await scrollTo(tester, find.text('Inside a later summary').last);
    expect(find.text('Shortened a read_file tool result'), findsWidgets);
    expect(find.byType(OverlayCard), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a summary opens with tool-derived items marked untrusted', (tester) async {
    await longRun(tester);
    await pumpContext(tester, h, location: '/chat/$kSession/context');
    await scrollTo(tester, find.text('Summary of earlier messages'));
    await tester.tap(find.text('Summary of earlier messages'));
    await settle(tester);
    expect(find.text('Constraints (still apply)'), findsOneWidget);
    expect(find.text('Never email customers.'), findsWidgets);
    expect(find.text('From you'), findsWidgets);
    expect(find.textContaining('Untrusted · from the read_file tool'), findsWidgets);
    expect(find.text('Collected from tool output: untrusted'), findsOneWidget);
    expect(find.text('Exact text sent to the model'), findsOneWidget);
  });

  testWidgets('Compact now summarizes, persists the overlay and offers undo', (tester) async {
    h = ContextHarness();
    await h.seedConversation(turns: 4, resultLines: 20);
    await h.open();
    await pumpContext(tester, h, location: '/chat/$kSession/context');
    expect(find.text('Nothing has been shortened or summarized. The model sees this conversation word for word.'),
        findsNothing, reason: 'below the fold');
    await tester.tap(find.text('Compact now'));
    await settle(tester);
    final stored = await h.store.overlays(kSession);
    expect(stored.single, isA<CompactedRange>());
    expect(find.textContaining('Summarized earlier messages'), findsOneWidget);
    expect(find.widgetWithText(SnackBarAction, 'Undo'), findsOneWidget);
  });

  testWidgets('undo asks first, then puts the original back', (tester) async {
    h = ContextHarness();
    await h.seedConversation(turns: 4, resultLines: 20);
    final chat = await h.open();
    final overlayId = (await chat.compactNow())!.overlay!.id;
    await pumpContext(tester, h, location: '/chat/$kSession/context');
    await scrollTo(tester, find.widgetWithText(TextButton, 'Undo'));
    await tester.tap(find.widgetWithText(TextButton, 'Undo'));
    await settle(tester);
    expect(find.text('Undo this summary?'), findsOneWidget);
    expect(find.textContaining('Your transcript was never changed'), findsOneWidget);

    // Cancel keeps it.
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(await h.store.overlays(kSession), hasLength(1));

    await tester.tap(find.widgetWithText(TextButton, 'Undo'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Undo'));
    await settle(tester);
    expect(await h.store.overlays(kSession), isEmpty);
    expect(overlayId, startsWith('ctx-compact:'));
    expect(find.textContaining('The original is back in context'), findsOneWidget);
  });

  testWidgets('undoing a summary that a later one merged explains and undoes both', (tester) async {
    h = ContextHarness();
    await h.seedConversation(turns: 4, resultLines: 20);
    final chat = await h.open();
    await chat.compactNow();
    for (var n = 5; n <= 8; n++) {
      await h.addTurn(n, resultLines: 20);
    }
    await chat.compactNow();
    await pumpContext(tester, h, location: '/chat/$kSession/context');
    // The older summary is the one inside the newer one.
    await scrollTo(tester, find.text('1 older change inside a summary'));
    await tester.tap(find.text('1 older change inside a summary'));
    await settle(tester);
    await scrollTo(tester, find.text('Inside a later summary'));
    final card = find.ancestor(of: find.text('Inside a later summary'), matching: find.byType(OverlayCard));
    await tester.tap(find.descendant(of: card, matching: find.widgetWithText(TextButton, 'Undo')));
    await settle(tester);
    expect(find.text('A later summary was built on this one, so it is undone too:'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Undo 2 changes'));
    await settle(tester);
    expect(await h.store.overlays(kSession), isEmpty);
    expect(find.text('Undid 2 changes.'), findsOneWidget);
  });

  testWidgets('a nearly full chat shows the handoff advice with its three ways out', (tester) async {
    h = ContextHarness();
    {
      await h.createSession();
      // One huge message: nothing to elide, no earlier turn to summarize.
      await h.store.putMessage(
        kSession,
        Message(id: 'big', role: Role.user, content: [TextPart(lines(270))], createdAt: h.clock.now()),
      );
      final s = (await h.store.getSession(kSession))!;
      await h.store.putSession(s.copyWith(activeLeafId: 'big'));
      await h.open();
    }
    await pumpContext(tester, h, location: '/chat/$kSession/context');
    expect(find.text('Consider continuing in a new chat'), findsOneWidget);
    expect(find.text('Hand off…'), findsOneWidget);
    expect(find.text('Compact'), findsOneWidget);
    expect(find.text('Switch model'), findsOneWidget);
    await tester.tap(find.text('Hand off…'));
    await settle(tester);
    expect(find.byType(HandoffScreen), findsOneWidget);
  });

  testWidgets('accessible: labels, 48dp targets, and no overflow at 2x text', (tester) async {
    await longRun(tester);
    final semantics = tester.ensureSemantics();
    await pumpContext(tester, h, location: '/chat/$kSession/context', textScale: 2.0);
    expect(tester.takeException(), isNull);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await scrollTo(tester, find.text('Summary of earlier messages'));
    expect(
      find.bySemanticsLabel(RegExp(r'^Summary of earlier messages, [\d,]+ tokens, pinned, compacted')),
      findsOneWidget,
    );
    semantics.dispose();
  });
}
