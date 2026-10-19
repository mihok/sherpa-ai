import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/design/motion.dart';
import 'package:sherpa/design/theme.dart';
import 'package:sherpa/design/tokens.dart';
import 'package:sherpa/design/typography.dart';
import 'package:sherpa/design/widgets/a11y.dart';
import 'package:sherpa/design/widgets/section_header.dart';
import 'package:sherpa/design/widgets/state_views.dart';
import 'package:sherpa/features/models/widgets/download_announcement.dart';
import 'package:sherpa/services/downloads/downloads.dart';

/// The design system's accessibility pieces (M6).
void main() {
  Future<void> pump(WidgetTester tester, Widget child, {double textScale = 1}) => tester.pumpWidget(MaterialApp(
        theme: SherpaTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData().copyWith(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(body: child),
        ),
      ));

  group('Heading', () {
    testWidgets('is a heading on both platforms: headingLevel (announced) and header', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, const Heading(level: 3, child: Text('Models')));
      final data = tester.getSemantics(find.text('Models')).getSemanticsData();
      expect(data.headingLevel, 3);
      expect(data.flagsCollection.isHeader, isTrue);
      handle.dispose();
    });

    testWidgets("SectionHeader speaks its list's length after the title", (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, const SectionHeader('In progress', count: '2 downloads'));
      final data = tester.getSemantics(find.text('In progress')).getSemanticsData();
      expect(data.label, 'In progress');
      expect(data.value, '2 downloads');
      expect(data.headingLevel, 2);
      expect(find.text('2 downloads'), findsNothing, reason: 'spoken only; the list shows it');
      handle.dispose();
    });

    testWidgets("StateView's title is a heading", (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, const EmptyState(title: 'No downloads'));
      expect(tester.getSemantics(find.text('No downloads')).getSemanticsData().headingLevel, 2);
      handle.dispose();
    });
  });

  group('LiveAnnouncement', () {
    SemanticsData live(WidgetTester tester) => tester.getSemantics(find.byType(LiveAnnouncement)).getSemanticsData();

    testWidgets('its own label is the announcement; the detail stays readable in its own node', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, const LiveAnnouncement(message: 'Llama: downloading, 25%', child: Text('312 of 1249 MB')));
      expect(live(tester).label, 'Llama: downloading, 25%');
      expect(live(tester).flagsCollection.isLiveRegion, isTrue);
      expect(tester.getSemantics(find.text('312 of 1249 MB')).label, '312 of 1249 MB',
          reason: 'not merged into the live region, so byte counts never re-announce');
      handle.dispose();
    });

    testWidgets('a download re-announces at 25 % steps only, not with every byte', (tester) async {
      final handle = tester.ensureSemantics();
      final labels = <String>[];
      for (final p in [0.01, 0.10, 0.24, 0.26, 0.40, 0.51, 0.99, 1.0]) {
        await pump(
          tester,
          LiveAnnouncement(
            message: downloadAnnouncement('Llama', JobPhase.downloading, progress: p),
            child: Text('${(p * 1249).round()} of 1249 MB'),
          ),
        );
        labels.add(live(tester).label);
      }
      expect(labels.toSet().toList(), [
        'Llama: downloading, 0%',
        'Llama: downloading, 25%',
        'Llama: downloading, 50%',
        'Llama: downloading, 75%',
        'Llama: downloading, 100%',
      ]);
      handle.dispose();
    });

    test('every phase has its own announcement', () {
      final said = {for (final p in JobPhase.values) downloadAnnouncement('M', p, progress: 0.5)};
      expect(said, hasLength(JobPhase.values.length));
    });

    test('progressMilestone', () {
      expect([null, double.nan, -1.0, 0.0, 0.249, 0.25, 0.7, 1.0, 2.0].map(progressMilestone), [0, 0, 0, 0, 0, 25, 50, 100, 100]);
      expect(progressMilestone(0.33, step: 10), 30);
    });
  });

  group('motion', () {
    test('framework animations take no time under reduced motion', () {
      expect(const MotionTokens().style, isNull, reason: "the widget's own default");
      expect(const MotionTokens(reduced: true).style, AnimationStyle.noAnimation);
      expect(const MotionTokens(reduced: true).tabs, Duration.zero);
      expect(const MotionTokens().tabs, greaterThan(Duration.zero));
    });

    testWidgets('MotionPageRoute is instant under reduced motion and animates otherwise', (tester) async {
      Future<bool> running({required bool disable}) async {
        await tester.pumpWidget(MaterialApp(
          theme: SherpaTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: disable),
            child: MotionScope(child: child!),
          ),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(MotionPageRoute<void>(builder: (_) => const Text('page'))),
              child: const Text('open'),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        final r = tester.hasRunningAnimations;
        await tester.pumpAndSettle();
        expect(find.text('page'), findsOneWidget);
        return r;
      }

      expect(await running(disable: false), isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(await running(disable: true), isFalse);
    });
  });

  testWidgets('scaledMaxLines gives names room only at large text sizes', (tester) async {
    late int normal;
    late int large;
    await pump(tester, Builder(builder: (c) => Text('${normal = scaledMaxLines(c)}')));
    await pump(tester, Builder(builder: (c) => Text('${large = scaledMaxLines(c)}')), textScale: 2);
    expect((normal, large), (1, 3));
  });
}
