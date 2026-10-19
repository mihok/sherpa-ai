import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/bootstrap.dart' show noRetry;
import 'package:sherpa/design/motion.dart';
import 'package:sherpa/design/theme.dart';
import 'package:sherpa/features/chat/widgets/composer.dart';
import 'package:sherpa/features/chat/widgets/user_message.dart';
import 'package:sherpa/features/context/widgets/budget_overview.dart';
import 'package:sherpa/routing/router.dart';
import 'package:sherpa/routing/routes.dart';
import 'package:sherpa/shell/app_shell.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../features/chat/support/fakes.dart';
import '../features/chat/support/harness.dart';
import '../features/models/support/models_rig.dart';
import '../features/models/support/sample_jobs.dart';
import '../support/a11y_audit.dart';
import '../support/harness.dart';
import 'support/chat_rig.dart';

/// Right-to-left layout. The app ships English only, so RTL is forced
/// below the app's own Directionality ([rtlBuilder]); padding, alignment,
/// borders, the context level bar, the chat and the shell must follow it
/// (start/end, never left/right).
void main() {
  /// The real router and services in a `MaterialApp` whose pages are RTL.
  Future<void> pumpRtl(WidgetTester tester, ModelsRig rig, String location) async {
    const view = AuditView.phoneRtl;
    setAuditWindow(tester, view);
    await tester.pumpWidget(ProviderScope(
      overrides: rig.overrides,
      retry: noRetry,
      child: Consumer(
        builder: (context, ref, _) => MaterialApp.router(
          theme: SherpaTheme.light(),
          routerConfig: ref.watch(routerProvider),
          builder: rtlBuilder(view, (context, child) => MotionScope(child: child!)),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final router = ProviderScope.containerOf(tester.element(find.byType(Navigator).first)).read(routerProvider);
    router.go(location);
    await tester.pumpAndSettle();
  }

  for (final location in [Routes.settings, Routes.privacy, Routes.models, Routes.modelBrowse, Routes.downloads, Routes.huggingFace]) {
    testWidgets('lays out right to left without overflow and meets the guidelines: $location', (tester) async {
      final semantics = tester.ensureSemantics();
      final rig = await ModelsRig.create(tester);
      if (location == Routes.downloads) rig.staticJobs = sampleJobs();
      await pumpRtl(tester, rig, location);
      // Layout is what RTL changes; colours are the same as LTR (audited
      // there), and the exact contrast check still runs.
      await expectAudit(tester, view: AuditView.phoneRtl, textContrast: false);
      semantics.dispose();
    });
  }

  testWidgets("a download's title starts at the right edge, its buttons sit at the left", (tester) async {
    final rig = await ModelsRig.create(tester)..staticJobs = sampleJobs();
    await pumpRtl(tester, rig, Routes.downloads);
    final name = find.text('Llama 3.2 1B').first;
    final title = tester.getRect(name);
    final pause = tester.getRect(find.byTooltip('Pause').first);
    expect(pause.center.dx, lessThan(title.center.dx));
    // The tile's start padding (16 dp) is on the right in RTL.
    final tile = tester.getRect(find.ancestor(of: name, matching: find.byType(DecoratedBox)).first);
    expect(tile.right - title.right, moreOrLessEquals(16, epsilon: 0.5));
  });

  testWidgets('the context level bar fills from the right in RTL', (tester) async {
    Future<RenderObject> bar(TextDirection d) async {
      await tester.pumpWidget(MaterialApp(
        theme: SherpaTheme.light(),
        home: Directionality(
          textDirection: d,
          child: const Center(
            child: SizedBox(
              width: 300,
              child: LevelBar(
                ratio: 0.4,
                level: ContextLevel.healthy,
                thresholds: ContextThresholds(),
              ),
            ),
          ),
        ),
      ));
      return tester.renderObject(find.descendant(of: find.byType(LevelBar), matching: find.byType(CustomPaint)));
    }

    expect(await bar(TextDirection.rtl), paints..save()..translate(x: 300, y: 0)..scale(x: -1, y: 1));
    expect(await bar(TextDirection.ltr), isNot(paints..scale(x: -1, y: 1)));
  });

  // ---- chat, home and the shell ---------------------------------------

  testWidgets("the chat mirrors: the user's bubble at the trailing (left) edge, replies from the right", (tester) async {
    final semantics = tester.ensureSemantics();
    final h = ChatHarness(tools: [FakeTool('weather', title: 'Weather'), FakeTool('calendar', title: 'Calendar')]);
    addTearDown(h.dispose);
    await h.createSession();
    await seedToolConversation(h);
    await pumpChatFor(tester, h, AuditView.phoneRtl);
    await streamFrames(tester, frames: 20);
    await tester.pumpAndSettle();
    await expectAudit(tester, view: AuditView.phoneRtl, textContrast: false);

    final list = tester.state<ScrollableState>(find.byType(Scrollable).first);
    list.position.jumpTo(list.position.minScrollExtent);
    await tester.pumpAndSettle();
    final width = AuditView.phoneRtl.size.width;
    final bubble = tester.getRect(find.byType(UserBubble).first);
    expect(bubble.left, lessThan(24), reason: 'at the end edge, which is the left in RTL');
    expect(bubble.right, lessThan(width - 40), reason: 'not stretched to the start edge');
    final reply = tester.getRect(find.textContaining('Let me check', findRichText: true).first);
    expect(reply.right, greaterThan(width - 24), reason: 'replies start at the right edge');

    // The composer: Attach at the start (right), Send at the end (left).
    final attach = tester.getRect(find.byKey(const ValueKey('composer-attach')));
    final send = tester.getRect(find.descendant(of: find.byType(ChatComposer), matching: find.byTooltip('Send')));
    expect(attach.center.dx, greaterThan(send.center.dx));
    semantics.dispose();
  });

  /// The real router, shell and home over [Harness], right to left.
  Future<Harness> pumpHomeRtl(WidgetTester tester, AuditView view) async {
    final h = Harness(
      providers: [openAiConfig()],
      endpoints: {'api.openai.com': const FakeEndpoint(models: ['gpt-a'])},
      defaultModel: const ModelChoice(providerId: 'openai', modelId: 'gpt-a'),
    );
    await h.addSession('Plan three days in Lisbon', providerId: 'openai', modelId: 'gpt-a');
    await h.addSession('Draft a note to the landlord', age: const Duration(days: 2));
    setAuditWindow(tester, view);
    await tester.pumpWidget(ProviderScope(
      overrides: h.overrides,
      retry: noRetry,
      child: Consumer(
        builder: (context, ref, _) => MaterialApp.router(
          theme: SherpaTheme.light(),
          routerConfig: ref.watch(routerProvider),
          builder: rtlBuilder(view, (context, child) => MotionScope(child: child!)),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return h;
  }

  testWidgets('home lays out right to left; swiping a chat towards the end reveals Archive at the start edge', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpHomeRtl(tester, AuditView.phoneRtl);
    await expectAudit(tester, view: AuditView.phoneRtl, textContrast: false);
    final tile = find.text('Plan three days in Lisbon');
    // Towards the end edge (leftwards in RTL), part of the way.
    await tester.drag(tile, const Offset(-120, 0));
    await tester.pump();
    final archive = tester.getRect(find.text('Archive'));
    expect(archive.center.dx, greaterThan(AuditView.phoneRtl.size.width / 2), reason: 'revealed at the right (start) edge');
    await tester.pumpAndSettle();
    semantics.dispose();
  });

  for (final rtl in [false, true]) {
    testWidgets('the rail sits at the start edge and the panes keep the outer side insets (${rtl ? 'RTL' : 'LTR'})', (tester) async {
      const view = AuditView('tablet 1x', AuditView.tabletSize);
      final h = Harness(providers: [openAiConfig()]);
      setAuditWindow(tester, view);
      // A landscape notch on each side.
      tester.view.padding = const FakeViewPadding(left: 40, right: 40);
      tester.view.viewPadding = const FakeViewPadding(left: 40, right: 40);
      await tester.pumpWidget(ProviderScope(
        overrides: h.overrides,
        retry: noRetry,
        child: Consumer(
          builder: (context, ref, _) => MaterialApp.router(
            theme: SherpaTheme.light(),
            routerConfig: ref.watch(routerProvider),
            builder: rtlBuilder(
              AuditView(view.name, view.size, rtl: rtl),
              (context, child) => MotionScope(child: child!),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final rail = tester.getRect(find.byType(NavigationRail));
      expect(rail.width, AppShell.railWidth);
      // The notch is on the rail's outer side only.
      expect(rtl ? view.size.width - rail.right : rail.left, 40, reason: 'the rail keeps the inset at the screen edge');
      final pane = MediaQuery.paddingOf(tester.element(find.text('Pick a chat, or start a new one')));
      expect((pane.left, pane.right), rtl ? (40.0, 0.0) : (0.0, 40.0), reason: 'the detail pane keeps only its outer inset');
    });
  }
}
