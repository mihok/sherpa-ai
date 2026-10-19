import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/chat/state/chat_controller.dart';
import 'package:sherpa/features/chat/widgets/model_chip.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';

import '../features/chat/support/fakes.dart';
import '../features/chat/support/harness.dart';
import '../support/a11y_audit.dart';
import 'support/chat_rig.dart';

/// What a screen reader gets from the chat: one announcement per phase of a
/// reply (never its tokens), turns as headings with the message after
/// them, and the approval named by its heading.
void main() {
  /// Every node in the semantics tree, in traversal-ish (tree) order.
  List<SemanticsNode> nodes(WidgetTester tester) {
    final out = <SemanticsNode>[];
    void visit(SemanticsNode n) {
      out.add(n);
      n.visitChildren((c) {
        visit(c);
        return true;
      });
    }

    for (final v in tester.binding.renderViews) {
      final root = v.owner?.semanticsOwner?.rootSemanticsNode;
      if (root != null) visit(root);
    }
    return out;
  }

  /// Labels of the live regions on screen, by node id.
  Map<int, String> liveRegions(WidgetTester tester) => {
        for (final n in nodes(tester))
          if (!n.isMergedIntoParent && n.getSemanticsData().flagsCollection.isLiveRegion) n.id: n.getSemanticsData().label,
      };

  testWidgets('a streaming reply is announced once when it starts and once when it ends, never per token', (tester) async {
    final semantics = tester.ensureSemantics();
    final p = ManualProvider(info: kCloudInfo);
    final h = ChatHarness(provider: p);
    addTearDown(h.dispose);
    await h.createSession();
    await pumpChatFor(tester, h, AuditView.phone1x);
    await streamFrames(tester, frames: 10);
    await typeAndSend(tester, 'Plan three days in Lisbon');

    // What each live region said, frame by frame: a screen reader speaks a
    // live region when its own label changes.
    final said = <int, List<String>>{};
    void record() {
      for (final e in liveRegions(tester).entries) {
        final list = said.putIfAbsent(e.key, () => []);
        if (list.isEmpty || list.last != e.value) list.add(e.value);
      }
    }

    const words = 'Lisbon in May is lovely : warm days , few crowds , and the light on the river at dusk .';
    for (final w in words.split(' ')) {
      p.emit(TextDelta('$w '));
      await tester.pump(const Duration(milliseconds: 16));
      record();
    }
    expect(find.textContaining('warm days', findRichText: true), findsWidgets, reason: 'the reply streamed in');
    await p.finish();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      record();
    }

    final spoken = said.values.expand((l) => l).where((l) => l.isNotEmpty).toList();
    expect(spoken, ['Assistant is responding', 'Response complete'], reason: 'phases only, once each');
    for (final label in liveRegions(tester).values) {
      expect(label, isNot(contains('Lisbon')), reason: 'the reply text is never in a live region');
    }
    semantics.dispose();
  });

  testWidgets('each turn is a heading ("You", "Sherpa") with its actions; the message is read after it', (tester) async {
    final semantics = tester.ensureSemantics();
    final h = ChatHarness();
    addTearDown(h.dispose);
    await h.createSession();
    await h.seedExchange('Will it rain tomorrow?', 'Light rain after 3 pm.');
    await pumpChatFor(tester, h, AuditView.phone1x);
    await streamFrames(tester, frames: 20);

    for (final (speaker, message, action) in [
      ('You', 'Will it rain tomorrow?', 'Copy text'),
      ('Sherpa', 'Light rain after 3 pm.', 'Copy reply'),
    ]) {
      final heading = nodes(tester).singleWhere((n) => n.getSemanticsData().label == speaker);
      final data = heading.getSemanticsData();
      expect((data.headingLevel, data.flagsCollection.isHeader), (2, true), reason: speaker);
      expect(data.hasAction(SemanticsAction.customAction), isTrue, reason: '$speaker carries "$action"');
      // The message is a node of its own below the heading, not merged in
      // (the app bar's title, a heading of its own, may repeat it).
      final text = nodes(tester)
          .where((n) => n.getSemanticsData().label.contains(message) && n.getSemanticsData().headingLevel == 0)
          .toList();
      expect(text, isNotEmpty, reason: message);
      for (final t in text) {
        expect(t.id, isNot(heading.id));
        var a = t.parent;
        while (a != null && a.id != heading.id) {
          a = a.parent;
        }
        expect(a, isNotNull, reason: '"$message" sits under the "$speaker" heading');
      }
    }
    semantics.dispose();
  });

  testWidgets('the approval is named by its heading, read before the risk and the arguments', (tester) async {
    final semantics = tester.ensureSemantics();
    final h = ChatHarness(tools: [writeTool('save_note', title: 'Save note')], turns: [
      ScriptedTurn.toolCalls([const ToolCall(id: 'n1', name: 'save_note', arguments: {'title': 'Lisbon'})]),
    ]);
    addTearDown(h.dispose);
    await h.createSession();
    await pumpChatFor(tester, h, AuditView.phone1x);
    await streamFrames(tester, frames: 10);
    await typeAndSend(tester, 'Save that');
    await streamFrames(tester, frames: 20);
    await tester.pumpAndSettle();

    final all = nodes(tester);
    final heading = all.singleWhere((n) => n.getSemanticsData().label == 'Approval needed. Allow “Save note”?');
    expect(heading.getSemanticsData().headingLevel, 2);
    final risk = all.indexWhere((n) => n.getSemanticsData().label.contains('Can make changes'));
    expect(all.indexOf(heading), lessThan(risk), reason: 'heading first, then what the tool can do');
    ProviderScope.containerOf(tester.element(find.byType(Scaffold).first)).read(chatControllerProvider(kSession).notifier).stop();
    await streamFrames(tester, frames: 20);
    semantics.dispose();
  });

  testWidgets('at large text on a phone the model chip gets its own row, so the title stays visible', (tester) async {
    final h = ChatHarness();
    addTearDown(h.dispose);
    await h.createSession(title: 'Will it rain tomorrow in Lisbon?');
    for (final (view, below) in [(AuditView.phone1x, false), (AuditView.phone2x, true), (AuditView.tablet2x, false)]) {
      await pumpChatFor(tester, h, view);
      await streamFrames(tester, frames: 10);
      final title = tester.getRect(find.text('Will it rain tomorrow in Lisbon?'));
      final chip = tester.getRect(find.byType(ModelChip));
      expect(chip.top >= title.bottom, below, reason: '$view: the chip ${below ? 'is' : 'is not'} below the title');
      expect(title.width, greaterThan(view == AuditView.phone2x ? 140 : 60), reason: '$view: room for the title');
    }
  });
}
