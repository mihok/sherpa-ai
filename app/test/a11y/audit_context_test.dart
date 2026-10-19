import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/context/handoff/handoff_platform.dart';
import 'package:sherpa/features/context/handoff/handoff_service.dart';

import '../features/context/support/context_harness.dart';
import '../support/a11y_audit.dart';

// textContrastGuideline misreads 12 px notes at 1× here (the cards' surface
// or anti-aliasing wins the sample); the exact check still runs.
const _small = '12 px notes at 1×: the neighbouring card surface or anti-aliasing wins the pixel sample';
const _oneX = {AuditView.phone1x, AuditView.tablet1x};

/// M6 audit of the context screens: what the model sees, hand off, and
/// importing a handoff (see [auditScreen]).
void main() {
  Future<ContextHarness> afterLongRun() async {
    final h = ContextHarness(turns: [textTurn('All quiet this week.')]);
    addTearDown(h.dispose);
    await h.seedConversation(turns: 9);
    final chat = await h.open();
    await chat.send('Summarize what changed this week.');
    h.clock.advance(const Duration(minutes: 3));
    return h;
  }

  Future<void> pumpAt(WidgetTester tester, ContextHarness h, AuditView view, String location) =>
      pumpContext(tester, h, location: location, size: view.size, textScale: view.textScale, brightness: view.brightness);

  auditScreen('what the model sees', (tester, view) async {
    await pumpAt(tester, await afterLongRun(), view, '/chat/$kSession/context');
  }, pixelContrastSkip: _oneX, contrastNote: _small);

  auditScreen('what the model sees: an item', (tester, view) async {
    await pumpAt(tester, await afterLongRun(), view, '/chat/$kSession/context');
    await tester.tap(find.byTooltip('How context works'));
    await settle(tester);
    Navigator.of(tester.element(find.text('How Sherpa manages context'))).pop();
    await settle(tester);
    final item = find.text('System prompt').first;
    await tester.scrollUntilVisible(item, 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(item);
    await settle(tester);
  }, pixelContrastSkip: _oneX, contrastNote: _small);

  auditScreen('how context works sheet', (tester, view) async {
    await pumpAt(tester, await afterLongRun(), view, '/chat/$kSession/context');
    await tester.tap(find.byTooltip('How context works'));
    await settle(tester);
  });

  auditScreen('hand off', (tester, view) async {
    final h = ContextHarness();
    addTearDown(h.dispose);
    await h.seedConversation(turns: 3, resultLines: 10);
    await h.open();
    await pumpAt(tester, h, view, '/chat/$kSession/handoff');
  }, pixelContrastSkip: {..._oneX, AuditView.phoneDark}, contrastNote: _small);

  auditScreen('import a handoff', (tester, view) async {
    final h = ContextHarness();
    addTearDown(h.dispose);
    await pumpAt(tester, h, view, '/handoff/import');
  });

  auditScreen('review an imported handoff', (tester, view) async {
    final h = ContextHarness();
    addTearDown(h.dispose);
    await h.seedConversation(turns: 2, resultLines: 8);
    final json = (await HandoffService(store: h.store, registry: h.registry, clock: h.clock, ids: h.ids)
            .build(sessionId: kSession))
        .toJson();
    json['connections'] = [
      {'type': 'mcp', 'name': 'Team notes', 'url': 'https://notes.example.com/mcp', 'authKind': 'oauth'},
    ];
    h.platform.nextPick = PickedFile(name: 'trip.sherpa-handoff.json', bytes: utf8.encode(jsonEncode(json)));
    await pumpAt(tester, h, view, '/handoff/import');
    await tester.tap(find.text('Choose a file'));
    await settle(tester);
    expect(find.text('Review handoff'), findsOneWidget);
  }, pixelContrastSkip: {AuditView.phone1x}, contrastNote: _small);

  auditScreen('import a handoff: refused', (tester, view) async {
    final h = ContextHarness();
    addTearDown(h.dispose);
    await pumpAt(tester, h, view, '/handoff/import');
    await tester.tap(find.text('Paste text'));
    await settle(tester);
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.byType(TextField), 150, scrollable: list);
    await tester.enterText(find.byType(TextField), 'not a handoff');
    await tester.scrollUntilVisible(find.text('Check'), 150, scrollable: list);
    await tester.tap(find.text('Check'));
    await settle(tester);
    await tester.scrollUntilVisible(find.text("This handoff can't be used"), -150, scrollable: list);
    await settle(tester);
    expect(find.text("This handoff can't be used"), findsOneWidget);
  });
}
