import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/context/handoff/handoff_import_screen.dart';
import 'package:sherpa/features/context/handoff/handoff_screen.dart';
import 'package:sherpa/features/context/inspector_screen.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../support/harness.dart' as shell;
import 'support/context_harness.dart';

/// Where the context tools are reached from: the chat's overflow menu and
/// context ring, and the home screen's overflow.
void main() {
  late ContextHarness h;
  tearDown(() => h.dispose());

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('More'));
    await settle(tester);
  }

  testWidgets('the chat overflow offers context details, Compact now (with undo) and Hand off…', (tester) async {
    h = ContextHarness();
    await h.seedConversation(turns: 4, resultLines: 20);
    await pumpContext(tester, h, location: '/chat/$kSession', realChat: true);
    await openMenu(tester);
    expect(find.text('Context details'), findsOneWidget);
    expect(find.text('Hand off…'), findsOneWidget);
    await tester.tap(find.text('Compact now'));
    await settle(tester);
    expect((await h.store.overlays(kSession)).single, isA<CompactedRange>());
    expect(find.textContaining('Summarized earlier messages, freed'), findsOneWidget);
    await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
    await settle(tester);
    expect(await h.store.overlays(kSession), isEmpty);

    await openMenu(tester);
    await tester.tap(find.text('Hand off…'));
    await settle(tester);
    expect(find.byType(HandoffScreen), findsOneWidget);
  });

  testWidgets('the context ring sheet says what changed last and opens the inspector', (tester) async {
    h = ContextHarness();
    await h.seedConversation(turns: 4, resultLines: 20);
    final chat = await h.open();
    await chat.compactNow();
    await pumpContext(tester, h, location: '/chat/$kSession', realChat: true);
    await tester.tap(find.bySemanticsLabel(RegExp('^Context ')));
    await settle(tester);
    expect(find.text('Last change: Earlier messages were summarized'), findsOneWidget);
    expect(find.textContaining('Compacted on request'), findsOneWidget);
    await tester.tap(find.text('See what the model sees'));
    await settle(tester);
    expect(find.byType(ContextInspectorScreen), findsOneWidget);
  });

  testWidgets('Compact now is disabled while there is nothing to compact', (tester) async {
    h = ContextHarness();
    await h.createSession();
    await pumpContext(tester, h, location: '/chat/$kSession', realChat: true);
    await openMenu(tester);
    final item = tester.widget<PopupMenuItem<Object?>>(
      find.ancestor(of: find.text('Compact now'), matching: find.byWidgetPredicate((w) => w is PopupMenuItem)),
    );
    expect(item.enabled, isFalse);
  });

  testWidgets('the home overflow opens Import handoff', (tester) async {
    h = ContextHarness();
    final app = shell.Harness();
    await shell.pumpApp(tester, app);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import handoff…'));
    await tester.pumpAndSettle();
    expect(find.byType(HandoffImportScreen), findsOneWidget);
  });
}
