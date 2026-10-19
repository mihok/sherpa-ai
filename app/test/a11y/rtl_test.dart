import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/bootstrap.dart' show noRetry;
import 'package:sherpa/design/motion.dart';
import 'package:sherpa/design/theme.dart';
import 'package:sherpa/features/context/widgets/budget_overview.dart';
import 'package:sherpa/routing/router.dart';
import 'package:sherpa/routing/routes.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../features/models/support/models_rig.dart';
import '../features/models/support/sample_jobs.dart';
import '../support/a11y_audit.dart';

/// Right-to-left layout. The app ships English only, so RTL is forced
/// below the app's own Directionality ([rtlBuilder]); padding, alignment,
/// borders and the context level bar must follow it (start/end, never
/// left/right).
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
}
