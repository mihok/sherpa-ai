import 'dart:async';
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/mcp/input/server_content.dart';
import 'package:sherpa/features/mcp/widgets/mcp_widgets.dart' show McpStatusPill;
import 'package:sherpa/features/models/state/directory_controller.dart';
import 'package:sherpa/features/models/widgets/model_card.dart';
import 'package:sherpa/routing/routes.dart';
import 'package:sherpa/services/downloads/downloads.dart';
import 'package:sherpa_core/sherpa_core.dart' show ApprovalResponse, ApprovalScope, UserDecision;
import 'package:sherpa_hub/sherpa_hub.dart' show FileRole, ModelFormat;

import '../features/mcp/support/input_rig.dart' show InputRig, formRequest, inputContext;
import '../features/mcp/support/mcp_rig.dart';
import '../features/models/support/models_rig.dart';
import '../features/models/support/sample_jobs.dart';
import '../support/harness.dart';

/// What screen readers hear, screen by screen: headings that say how long
/// their list is, live regions for status changes (and only at
/// milestones), labelled progress, single-node cards that keep their tap.
void main() {
  SemanticsData heading(WidgetTester tester, String title) => tester.getSemantics(find.text(title)).getSemanticsData();

  /// The live region over [inside] (a widget in it), as announced.
  SemanticsData liveOver(WidgetTester tester, Finder inside) {
    final region = find.ancestor(
      of: inside,
      matching: find.byWidgetPredicate((w) => w is Semantics && (w.properties.liveRegion ?? false)),
    );
    expect(region, findsWidgets, reason: 'a live region announces this');
    return tester.getSemantics(region.first).getSemanticsData();
  }

  testWidgets('the library heading says how many models it lists', (tester) async {
    final handle = tester.ensureSemantics();
    final rig = await ModelsRig.create(tester);
    await tester.runAsync(() async {
      for (final id in ['a', 'b']) {
        final rel = '$id/$id.gguf';
        final f = File(rig.manager.layout.libraryPath(rel));
        await f.parent.create(recursive: true);
        await f.writeAsBytes(fillBytes(64));
        await rig.library.add(LibraryModel(
          id: id,
          source: LibrarySource.hub,
          displayName: 'Model $id',
          format: ModelFormat.gguf,
          files: [LibraryFile(path: rel, role: FileRole.model, sizeBytes: 64)],
          loadPath: rel,
          installedAt: DateTime.utc(2026, 10, 1),
        ));
      }
    });
    await rig.pump(tester, location: Routes.models);
    final h = heading(tester, 'On this phone');
    expect((h.headingLevel, h.value), (2, '2 models'));
    handle.dispose();
  });

  testWidgets('download sections say how many; each download announces its phase and 25 % steps', (tester) async {
    final handle = tester.ensureSemantics();
    final rig = await ModelsRig.create(tester)..staticJobs = sampleJobs();
    await rig.pump(tester, location: Routes.downloads);
    expect(heading(tester, 'In progress').value, '2 downloads');
    expect(heading(tester, 'Needs attention').value, '1 download');
    // 1.2 of 2.3 GB is 52 %: announced as the 50 % milestone.
    expect(liveOver(tester, find.text('Downloading').first).label, 'Llama 3.2 1B: downloading, 50%');
    expect(liveOver(tester, find.text('Waiting for Wi-Fi')).label, 'Qwen 3 8B: waiting for Wi-Fi');
    expect(
      find.byWidgetPredicate((w) => w is LinearProgressIndicator && w.semanticsLabel == 'Download progress'),
      findsWidgets,
      reason: 'the bar itself is labelled, with its percentage as value',
    );
    handle.dispose();
  });

  testWidgets('directory results count only the cards as list items', (tester) async {
    final rig = await ModelsRig.create(tester);
    await rig.pump(tester, location: Routes.modelBrowse);
    final container = ProviderScope.containerOf(tester.element(find.byType(ModelCard).first));
    final items = container.read(directoryControllerProvider).items;
    expect(items, isNotEmpty);
    expect(tester.widget<CustomScrollView>(find.byType(CustomScrollView)).semanticChildCount, items.length);
  });

  testWidgets('a model card is one button that keeps its tap', (tester) async {
    final handle = tester.ensureSemantics();
    final rig = await ModelsRig.create(tester);
    await rig.pump(tester, location: Routes.modelBrowse);
    final node = tester.getSemantics(find.byType(ModelCard).first).getSemanticsData();
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.hasAction(SemanticsAction.tap), isTrue);
    expect(node.label, startsWith('Llama 3.2 1B by bartowski. Family Llama 3.2.'));
    handle.dispose();
  });

  testWidgets('tool server sections count their servers; a server announces its status', (tester) async {
    final handle = tester.ensureSemantics();
    final rig = await McpRig.create(tester, remote: exampleServers());
    await rig.pump(tester, location: Routes.tools);
    expect(heading(tester, 'Your servers').value, 'none yet');
    await rig.addRemote(tester);
    expect(heading(tester, 'Your servers').value, '1 server');
    await goTo(tester, Routes.toolServer('example_tools'));
    expect(liveOver(tester, find.byType(McpStatusPill)).label, contains('Status: '));
    handle.dispose();
  });

  testWidgets('remembered approvals: same name as the Settings row, and a counted heading', (tester) async {
    final handle = tester.ensureSemantics();
    final rig = await McpRig.create(tester, remote: exampleServers());
    await rig.addRemote(tester, trusted: true);
    rig.runtime.policy.recordFor(
      rig.runtime.router.lookup('memory__save_note')!,
      's1',
      const ApprovalResponse(UserDecision.approve, scope: ApprovalScope.always),
    );
    await rig.pump(tester, location: Routes.tools);
    await tapText(tester, 'Remembered approvals');
    expect(find.text('Remembered approvals'), findsOneWidget, reason: 'the page title');
    expect(heading(tester, 'Allowed without asking').value, '1 tool');
    handle.dispose();
  });

  testWidgets('a registry search says how many servers came back', (tester) async {
    final handle = tester.ensureSemantics();
    final rig = await McpRig.create(tester, registryHttp: registryMock([]));
    await rig.pump(tester, location: Routes.toolRegistry);
    await rig.settle(tester);
    expect(liveOver(tester, find.text('2 servers')).label, '2 servers');
    handle.dispose();
  });

  testWidgets('onboarding announces each step and labels its progress bar', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpApp(tester, Harness(onboarded: false));
    await tapText(tester, 'Get started');
    expect(liveOver(tester, find.text('Step 1 of 3')).label, 'Step 1 of 3');
    expect(
      find.byWidgetPredicate((w) => w is LinearProgressIndicator && w.semanticsLabel == 'Setup progress, step 1 of 3'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('input sheets whose title follows their stage announce it', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpApp(tester, Harness());
    final page = tester.element(find.byType(Scaffold).last);
    unawaited(showModalBottomSheet<void>(
      context: page,
      builder: (_) => const InputRequesterHeader(
        serverName: 'Example tools',
        trusted: true,
        title: 'Writing an answer…',
        announceTitle: true,
      ),
    ));
    await tester.pumpAndSettle();
    final node = liveOver(tester, find.text('Writing an answer…'));
    expect(node.flagsCollection.isLiveRegion, isTrue);
    expect(tester.getSemantics(find.text('Writing an answer…')).getSemanticsData().headingLevel, 2);
    handle.dispose();
  });

  testWidgets('dialog titles are headings', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpApp(tester, Harness(providers: [openAiConfig()], keys: {'provider/openai/api_key': 'sk-x'}));
    await goTo(tester, Routes.providers);
    await tester.tap(find.byTooltip('More for OpenAI'));
    await tester.pumpAndSettle();
    await tapText(tester, 'Remove');
    expect(heading(tester, 'Remove OpenAI?').headingLevel, 2);
    handle.dispose();
  });

  testWidgets('Settings › Keep working in the background is one labelled switch', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpApp(tester, Harness(), size: const Size(360, 740), textScale: 2);
    await goTo(tester, Routes.settings);
    final tile = find.text('Keep working in the background');
    await tester.scrollUntilVisible(tile, 200, scrollable: find.byType(Scrollable).first);
    final node = tester.getSemantics(tile).getSemanticsData();
    expect(node.label, startsWith('Keep working in the background'));
    expect(node.flagsCollection.isToggled, isNot(Tristate.none), reason: 'a switch, on or off');
    expect(node.hasAction(SemanticsAction.tap), isTrue);
    expect(tester.getSize(find.ancestor(of: tile, matching: find.byType(SwitchListTile))).height,
        greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  group('focus order', () {
    List<String> order(WidgetTester tester) =>
        [for (final n in tester.semantics.simulatedAccessibilityTraversal()) n.getSemanticsData().label];

    int at(List<String> labels, String label) {
      final i = labels.indexWhere((l) => l.contains(label));
      expect(i, isNot(-1), reason: '"$label" in $labels');
      return i;
    }

    testWidgets('a form sheet: title, who asks, the form, then the answers', (tester) async {
      final handle = tester.ensureSemantics();
      final rig = await InputRig.create(tester);
      await rig.pumpApp(tester);
      unawaited(rig.handler.elicit(
        formRequest({'name': {'type': 'string', 'title': 'Your name'}}, message: 'Tell us about you'),
        inputContext(),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      final labels = order(tester);
      expect(labels, contains('A tool server needs your input'), reason: 'the heading is only the title');
      final title = at(labels, 'A tool server needs your input');
      final asker = at(labels, 'Asked by');
      final field = at(labels, 'Your name');
      final cancel = at(labels, 'Cancel');
      final send = at(labels, 'Send to Example tools');
      expect([title, asker, field, cancel, send], orderedEquals([...[title, asker, field, cancel, send]]..sort()));
      await tester.pump(const Duration(minutes: 6));
      await tester.pumpAndSettle();
      handle.dispose();
    });

    testWidgets('a dialog: title, what happens, then Cancel before the destructive action', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpApp(tester, Harness(providers: [openAiConfig()], keys: {'provider/openai/api_key': 'sk-x'}));
      await goTo(tester, Routes.providers);
      await tester.tap(find.byTooltip('More for OpenAI'));
      await tester.pumpAndSettle();
      await tapText(tester, 'Remove');
      final labels = order(tester);
      final title = at(labels, 'Remove OpenAI?');
      final body = at(labels, 'Its key is deleted');
      final cancel = at(labels, 'Cancel');
      final remove = labels.lastIndexOf('Remove');
      expect(title < body && body < cancel && cancel < remove, isTrue, reason: '$labels');
      handle.dispose();
    });
  });
}
