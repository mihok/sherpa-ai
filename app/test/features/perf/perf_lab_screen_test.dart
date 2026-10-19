import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/design/contrast.dart';
import 'package:sherpa/design/theme.dart';
import 'package:sherpa/design/tokens.dart';
import 'package:sherpa/features/models/model_library_screen.dart';
import 'package:sherpa/features/models/state/local_inference_providers.dart';
import 'package:sherpa/features/models/state/models_providers.dart';
import 'package:sherpa/features/perf/perf_lab_screen.dart';
import 'package:sherpa/features/perf/state/perf_models.dart';
import 'package:sherpa/features/perf/state/perf_providers.dart';
import 'package:sherpa/features/perf/widgets/bench_tab.dart';
import 'package:sherpa/features/perf/widgets/compare_tab.dart';
import 'package:sherpa/features/perf/widgets/overview_tab.dart';
import 'package:sherpa/routing/routes.dart';
import 'package:sherpa/state/providers.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';
import 'package:sherpa_inference/testing.dart';

import 'support/perf_rig.dart';

Map<int, ({double pp, double tg})> get _byThreads => {
      1: (pp: 60, tg: 6),
      2: (pp: 100, tg: 10),
      3: (pp: 140, tg: 14),
      4: (pp: 200, tg: 20),
    };

const _fourThreads = SessionConfig(nThreads: 4, nThreadsBatch: 4);

void main() {
  Future<PerfRig> rigFor(
    WidgetTester tester, {
    FakeEngineHost? host,
    FakeMemoryMonitor? memory,
    bool start = true,
  }) async {
    late PerfRig rig;
    await tester.runAsync(() async {
      rig = await PerfRig.create(
        host: host ?? FakeEngineHost(bench: scriptedBench(_byThreads)),
        memory: memory,
        sessionDefaults: _fourThreads,
      );
      if (start) {
        await rig.addModelAndStart();
      } else {
        await rig.library.add(libraryModel('m1'));
        await rig.local.start();
      }
    });
    addTearDown(() => tester.runAsync(rig.dispose));
    return rig;
  }

  List<Override> overrides(PerfRig rig) => [
        localInferenceProvider.overrideWithValue(rig.local),
        memoryMonitorProvider.overrideWithValue(rig.memory),
        clockProvider.overrideWithValue(rig.clock),
        perfLabProvider.overrideWithValue(rig.lab),
        perfMonitorIntervalProvider.overrideWithValue(null),
        localLibraryModelsProvider.overrideWith((ref) async* {
          yield rig.library.models;
          yield* rig.library.changes;
        }),
      ];

  Widget withScale(double scale, Widget child) => Builder(
        builder: (context) =>
            MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child),
      );

  /// Alternates real time (file IO of the lifecycle's forensics) with
  /// frames and fake-zone microtasks until [condition] holds.
  Future<void> waitFor(WidgetTester tester, bool Function() condition, {int tries = 500}) async {
    for (var i = 0; i < tries && !condition(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 4)));
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue, reason: 'condition not met in time');
    // Let trailing file writes (forensics phases) land, so nothing is left
    // pending in the fake zone when the rig is disposed.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 4)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// Keeps the memory checks of [configs] alive until they are known.
  Future<void> waitForFits(WidgetTester tester, ProviderContainer c, List<LabConfig> configs) async {
    final subs = [for (final x in configs) c.listen(perfFitProvider(('m1', x)), (_, _) {})];
    await waitFor(tester, () => configs.every((x) => c.read(perfFitProvider(('m1', x))).hasValue));
    for (final s in subs) {
      s.close();
    }
  }

  Future<ProviderContainer> pumpLab(WidgetTester tester, PerfRig rig,
      {Size size = const Size(420, 1400), double scale = 1, Widget home = const PerfLabScreen(modelId: 'm1')}) async {
    tester.view.physicalSize = size * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(rig),
      child: MaterialApp(
        theme: SherpaTheme.light(),
        home: withScale(scale, home),
      ),
    ));
    final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
    await waitFor(tester, () => container.read(perfOverviewProvider('m1')).hasValue || container.read(perfOverviewProvider('m1')).hasError);
    return container;
  }

  PerfLabController controller(ProviderContainer c) => c.read(perfLabControllerProvider('m1').notifier);
  PerfLabState labState(ProviderContainer c) => c.read(perfLabControllerProvider('m1'));

  /// Frames plus real-zone microtask turns: futures completed during the
  /// rig's real-time setup resume their awaiters only when the real event
  /// loop runs.
  Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> openTab(WidgetTester tester, String name) async {
    await tester.tap(find.widgetWithText(Tab, name));
    await settle(tester);
  }

  Future<void> tapReal(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pump();
    await tester.tap(f);
    await tester.pump();
  }

  testWidgets('the overview shows the device, the engine, the tuned settings and the memory estimate', (tester) async {
    final rig = await rigFor(tester, memory: FakeMemoryMonitor(memoryState(availableMib: 4096, footprintMib: 300)));
    await pumpLab(tester, rig);

    expect(find.text('Performance: Qwen3 0.6B'), findsOneWidget);
    expect(find.text('Google Tensor G3'), findsOneWidget);
    expect(find.text('Google Pixel 8a'), findsOneWidget);
    expect(find.text('4 of 9'), findsOneWidget);
    expect(find.text('CPU · KleidiAI'), findsOneWidget);
    expect(find.text('fake 1.0'), findsOneWidget);
    expect(find.text('82%'), findsOneWidget);
    expect(find.text('Not tuned yet'), findsOneWidget);
    expect(find.text('Re-run autotune'), findsOneWidget);
    expect(find.textContaining('No on-device reply yet'), findsOneWidget);
    expect(find.text('Estimate'), findsOneWidget);
    expect(find.text('Budget'), findsOneWidget);
    expect(find.text('Fits'), findsOneWidget);
  });

  testWidgets('the live monitor shows the last reply’s numbers', (tester) async {
    final rig = await rigFor(tester);
    await tester.runAsync(() => replyText(rig.local.provider, 'm1', 'hello'));
    await pumpLab(tester, rig);
    expect(find.textContaining('Last reply'), findsOneWidget);
    expect(find.text('50 ms'), findsOneWidget);
    expect(find.text('100 tok/s'), findsOneWidget);
    expect(find.text('20.0 tok/s'), findsOneWidget);
  });

  testWidgets('a benchmark shows its result and the history as a chart and a table', (tester) async {
    final handle = tester.ensureSemantics();
    final rig = await rigFor(tester);
    rig.memory.emit(memoryState(thermal: ThermalLevel.fair));
    final c = await pumpLab(tester, rig);
    await openTab(tester, 'Benchmark');
    expect(find.textContaining('No runs yet'), findsOneWidget);

    controller(c).setBenchSpec(const BenchSpec(promptTokens: 128, genTokens: 32, reps: 3));
    await tester.pump();
    await tapReal(tester, find.text('Run benchmark'));
    await waitFor(tester, () => labState(c).job == null && labState(c).lastRun != null);

    expect(find.text('Latest result'), findsOneWidget);
    expect(find.text('200 tok/s'), findsWidgets);
    expect(find.text('20.0 tok/s'), findsWidgets);
    expect(find.text('690 ms'), findsWidgets);
    expect(find.text('620 MB'), findsOneWidget);
    expect(find.text('+120 MB during the run'), findsOneWidget);
    expect(find.text('Before and after: Warm'), findsOneWidget);
    expect(find.semantics.byLabel(RegExp(r'^Run 1 of 1, .*20\.0 tokens per second')), findsOne);

    await tapReal(tester, find.text('Run benchmark'));
    await waitFor(tester, () => labState(c).job == null && labState(c).history.length == 2);
    expect(find.semantics.byLabel(RegExp(r'^Run 2 of 2')), findsOne);
    expect(find.bySemanticsLabel(RegExp(r'^Decode over the last 2 runs')), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Prefill'));
    await tester.pump();
    expect(find.semantics.byLabel(RegExp(r'^Run 2 of 2, .*200 tokens per second')), findsOne);

    await tester.ensureVisible(find.text('Show table'));
    await tester.tap(find.text('Show table'));
    await tester.pump();
    expect(find.bySemanticsLabel(RegExp(r'^Run on .*Prefill 200 tokens per second, decode 20\.0 tokens per second')),
        findsNWidgets(2));
    expect(find.text('Show chart'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('cancel stops a running benchmark, and a reply pauses it', (tester) async {
    final fake = FakeEngineHost(bench: scriptedBench(_byThreads), eventDelay: const Duration(milliseconds: 15));
    final rig = await rigFor(tester, host: fake);
    final c = await pumpLab(tester, rig);
    await openTab(tester, 'Benchmark');
    rig.host.holdBenches();

    await tapReal(tester, find.text('Run benchmark'));
    await waitFor(tester, () => rig.host.benchesStarted == 1 && labState(c).job?.phase == LabJobPhase.running);
    expect(find.text('Benchmark in progress'), findsOneWidget);
    final run = tester.widget<ButtonStyleButton>(find.ancestor(of: find.text('Run benchmark'), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)));
    expect(run.onPressed, isNull, reason: 'one job at a time');

    // A chat reply takes the engine: the bench is preempted and waits.
    var replied = false;
    unawaited(replyText(rig.local.provider, 'm1', 'hello').then((_) => replied = true));
    await waitFor(tester, () => labState(c).job?.phase == LabJobPhase.paused);
    expect(find.textContaining('Paused: a chat reply needed the engine'), findsOneWidget);
    await waitFor(tester, () => replied && rig.host.benchesStarted == 2);

    await tapReal(tester, find.text('Cancel'));
    await waitFor(tester, () => labState(c).job == null);
    expect(find.text('Benchmark cancelled.'), findsOneWidget);
    expect(find.text('Latest result'), findsNothing);
    expect(rig.host.benchesCancelled, 2);
  });

  testWidgets('A/B with a clear winner: apply pins it, reset returns to auto', (tester) async {
    final handle = tester.ensureSemantics();
    final rig = await rigFor(tester, host: FakeEngineHost(bench: scriptedBench(_byThreads, noise: [0, 0.02, -0.02, 0.01])));
    final c = await pumpLab(tester, rig);
    await openTab(tester, 'Compare');
    expect(find.text('Setting A'), findsOneWidget);
    expect(find.text('Setting B'), findsOneWidget);

    controller(c)
      ..setA(const LabConfig(nThreads: 2))
      ..setB(const LabConfig(nThreads: 4))
      ..setAbSpec(const BenchSpec.comparison(reps: 3));
    await waitForFits(tester, c, const [LabConfig(nThreads: 2), LabConfig(nThreads: 4)]);
    expect(find.textContaining('Fits: about'), findsNWidgets(2));

    await tapReal(tester, find.text('Run comparison'));
    await waitFor(tester, () => labState(c).job == null && labState(c).ab != null);
    expect(find.text('B is faster'), findsOneWidget);
    expect(find.textContaining('less time per agent turn'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Decode: A median 10\.0 tok/s.*B median 20\.4 tok/s.*B better by')), findsOneWidget);
    expect([for (final b in rig.fake.benches) b.nThreads], [2, 4, 2, 4, 2, 4]);

    await tapReal(tester, find.text('Apply B'));
    await waitFor(tester, () => !labState(c).applying && labState(c).message != null);
    expect(find.textContaining('Chats use it from the next message'), findsOneWidget,
        reason: 'applied at once, even before autotune has run');
    final tuner = rig.local.lifecycle!.autotuner!;
    final saved = await tester.runAsync(() => tuner.overrides('m1'));
    expect(saved!.nThreads, 4);

    await waitFor(tester, () => c.read(perfOverviewProvider('m1')).value?.hasOverrides ?? false);
    await tapReal(tester, find.text('Reset to auto'));
    await waitFor(tester, () => !labState(c).applying && labState(c).message?.text == 'Back to automatic settings.');
    expect(find.text('Back to automatic settings.'), findsOneWidget);
    expect((await tester.runAsync(() => tuner.overrides('m1')))!.isEmpty, isTrue);
    handle.dispose();
  });

  testWidgets('A/B within noise names no winner and offers nothing to apply', (tester) async {
    final rig = await rigFor(
      tester,
      host: FakeEngineHost(
          bench: scriptedBench({2: (pp: 100, tg: 10), 4: (pp: 100, tg: 10)}, noise: [0, 0.03, -0.03, 0.01, -0.01])),
    );
    final c = await pumpLab(tester, rig);
    await openTab(tester, 'Compare');
    controller(c)
      ..setA(const LabConfig(nThreads: 2))
      ..setB(const LabConfig(nThreads: 4))
      ..setAbSpec(const BenchSpec.comparison(reps: 5));
    await waitForFits(tester, c, const [LabConfig(nThreads: 2), LabConfig(nThreads: 4)]);
    await tapReal(tester, find.text('Run comparison'));
    await waitFor(tester, () => labState(c).job == null && labState(c).ab != null);

    expect(find.text('No clear winner'), findsOneWidget);
    expect(find.textContaining('within run-to-run noise'), findsOneWidget);
    expect(find.text('Within noise'), findsNWidgets(4));
    final apply = tester.widget<ButtonStyleButton>(
        find.ancestor(of: find.text('Apply winner'), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)));
    expect(apply.onPressed, isNull);
  });

  testWidgets('a config that would not fit memory is refused before it runs', (tester) async {
    // 1600 MB available: admission picks q8_0 at 8192 tokens; B (f16) needs
    // 1326 MB of a 1072 MB budget.
    final rig = await rigFor(tester, memory: FakeMemoryMonitor(memoryState(availableMib: 1600)));
    final c = await pumpLab(tester, rig);
    await openTab(tester, 'Compare');
    final o = c.read(perfOverviewProvider('m1')).value!;
    await waitForFits(tester, c, [CompareTab.defaultA(o), CompareTab.defaultB(o)]);
    expect(CompareTab.defaultA(o).kv, KvType.q8_0);
    expect(CompareTab.defaultB(o).kv, KvType.f16);
    expect(find.textContaining('Won’t fit: it needs about 1326 MB at a 8192-token context'), findsOneWidget);
    final run = tester.widget<ButtonStyleButton>(
        find.ancestor(of: find.text('Run comparison'), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)));
    expect(run.onPressed, isNull);
    expect(rig.fake.benches, isEmpty);
  });

  testWidgets('autotune shows progress and can be cancelled', (tester) async {
    final rig = await rigFor(tester);
    final c = await pumpLab(tester, rig);
    rig.host.holdBenches();
    await tapReal(tester, find.text('Re-run autotune'));
    await waitFor(tester, () => rig.host.benchesStarted == 1);
    expect(find.text('Autotune in progress'), findsOneWidget);
    // The lifecycle's own progress report.
    await waitFor(tester, () => labState(c).job?.detail != null);
    expect(labState(c).job!.detail, 'Checked 0 of 10');
    await tapReal(tester, find.text('Cancel'));
    await waitFor(tester, () => labState(c).job == null);
    expect(find.textContaining('Autotune cancelled'), findsOneWidget);

    rig.host.releaseBenches();
    await tapReal(tester, find.text('Re-run autotune'));
    await waitFor(tester, () => labState(c).job == null && labState(c).message != null);
    expect(find.textContaining('Tuned:'), findsOneWidget);
    await waitFor(tester, () => c.read(perfOverviewProvider('m1')).value?.profile != null);
    expect(find.text('Measured'), findsOneWidget);
    expect(find.text('Measured speed'), findsOneWidget);
  });

  testWidgets('an unavailable engine is shown with its reason', (tester) async {
    final rig = await rigFor(
      tester,
      host: FakeEngineHost()..startError = const EngineUnavailableException('no engine in this build'),
      start: false,
    );
    tester.view.physicalSize = const Size(420, 900) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(rig),
      child: MaterialApp(theme: SherpaTheme.light(), home: const PerfLabScreen(modelId: 'm1')),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('The on-device engine isn’t available'), findsOneWidget);
    expect(find.textContaining('no engine in this build'), findsOneWidget);
    expect(find.byType(TabBar), findsNothing);
  });

  testWidgets('"Performance" on a library model opens its lab', (tester) async {
    final rig = await rigFor(tester);
    tester.view.physicalSize = const Size(420, 1400) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const ModelLibraryScreen()),
      GoRoute(path: '/settings/models/performance/:id', builder: (_, s) => PerfLabScreen(modelId: s.pathParameters['id']!)),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...overrides(rig),
        modelRecordStoreProvider.overrideWithValue(rig.records),
        modelStorageLayoutProvider.overrideWithValue(rig.layout),
        modelLibraryProvider.overrideWithValue(rig.library),
        libraryModelsProvider.overrideWith((ref) async* {
          yield rig.library.models;
          yield* rig.library.changes;
        }),
        downloadJobsProvider.overrideWith((ref) => Stream.value(const [])),
      ],
      child: MaterialApp.router(theme: SherpaTheme.light(), routerConfig: router),
    ));
    await tester.pump();
    await tester.pump();
    expect(Routes.modelPerformance('m1'), '/settings/models/performance/m1');
    await tester.tap(find.text('Performance'));
    await waitFor(tester, () => router.state.uri.path == '/settings/models/performance/m1');
    expect(find.text('Performance: Qwen3 0.6B'), findsOneWidget);
  });

  group('accessibility', () {
    Future<(PerfRig, ProviderContainer)> populated(WidgetTester tester,
        {double scale = 1, Size size = const Size(360, 740), Widget home = const PerfLabScreen(modelId: 'm1')}) async {
      final rig = await rigFor(tester, host: FakeEngineHost(bench: scriptedBench(_byThreads, noise: [0, 0.02, -0.02, 0.01])));
      await tester.runAsync(() async {
        await replyText(rig.local.provider, 'm1', 'hello');
        await rig.lab.bench('m1', const BenchSpec(reps: 1));
        await rig.lab.bench('m1', const BenchSpec(reps: 1));
      });
      final c = await pumpLab(tester, rig, size: size, scale: scale, home: home);
      controller(c)
        ..setA(const LabConfig(nThreads: 2))
        ..setB(const LabConfig(nThreads: 4, kv: KvType.q8_0, speculative: SpeculativeChoice.ngram))
        ..setAbSpec(const BenchSpec.comparison(reps: 3));
      final r = await tester.runAsync(() => rig.lab.compare('m1', const LabConfig(nThreads: 2), const LabConfig(nThreads: 4),
          spec: const BenchSpec.comparison(reps: 3)));
      // Show a finished comparison without running it through the UI again.
      c.read(perfLabControllerProvider('m1').notifier).state = labState(c).copyWith(ab: r);
      await waitForFits(tester, c, [
        const LabConfig(nThreads: 2),
        const LabConfig(nThreads: 4, kv: KvType.q8_0, speculative: SpeculativeChoice.ngram),
      ]);
      return (rig, c);
    }

    for (final tab in ['Overview', 'Benchmark', 'Compare']) {
      testWidgets('text scale 2.0 on a small phone without overflow: $tab', (tester) async {
        await populated(tester, scale: 2);
        if (tab != 'Overview') await openTab(tester, tab);
        final list = find.byType(ListView).hitTestable().first;
        for (var i = 0; i < 12; i++) {
          await tester.drag(list, const Offset(0, -500), warnIfMissed: false);
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(tester.takeException(), isNull);
      });

      testWidgets('tap targets and labels: $tab', (tester) async {
        final handle = tester.ensureSemantics();
        // Each tab's content on its own, everything on screen at once.
        await populated(tester, size: const Size(800, 2400), home: _TabOnly(tab));
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        handle.dispose();
      });
    }

    // textContrastGuideline samples pixels and takes the most frequent
    // "dark" color, which for 12 px text is often an anti-aliasing shade
    // (it failed notes whose real contrast is ~7:1). The lab's text colors
    // are checked exactly instead: every foreground it uses, on every
    // surface it puts text on, in both themes.
    for (final brightness in Brightness.values) {
      test('text colors meet 4.5:1 on the lab’s surfaces (${brightness.name})', () {
        final theme = brightness == Brightness.light ? SherpaTheme.light() : SherpaTheme.dark();
        final s = theme.colorScheme;
        final t = theme.extension<SherpaTokens>()!;
        final fgs = {
          'onSurface': s.onSurface,
          'onSurfaceVariant': s.onSurfaceVariant,
          'success': t.semantic.success,
          'warning': t.semantic.warning,
          'danger': t.semantic.danger,
          'primary': s.primary,
        };
        for (final bg in {'surface': s.surface, 'surfaceContainerLow': s.surfaceContainerLow}.entries) {
          for (final fg in fgs.entries) {
            expect(contrastRatio(fg.value, bg.value), greaterThanOrEqualTo(4.5), reason: '${fg.key} on ${bg.key}');
          }
        }
      });
    }

    testWidgets('the history chart is described for screen readers and has a table view', (tester) async {
      final handle = tester.ensureSemantics();
      await populated(tester, size: const Size(420, 2400));
      await openTab(tester, 'Benchmark');
      expect(find.bySemanticsLabel(RegExp(r'^Decode over the last 2 runs, oldest first: lowest .* latest')), findsOneWidget);
      expect(find.semantics.byLabel(RegExp(r'^Run 1 of 2')), findsOne);
      expect(find.semantics.byLabel(RegExp(r'^Run 2 of 2')), findsOne);
      handle.dispose();
    });

    testWidgets('at large text sizes the history opens as a table', (tester) async {
      final handle = tester.ensureSemantics();
      await populated(tester, scale: 2, size: const Size(360, 2400));
      await openTab(tester, 'Benchmark');
      expect(find.text('Show chart'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Run on ')), findsNWidgets(2));
      handle.dispose();
    });
  });
}

/// One tab of the lab without the TabBarView around it.
class _TabOnly extends ConsumerWidget {
  const _TabOnly(this.tab);

  final String tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final o = ref.watch(perfOverviewProvider('m1')).value;
    ref.watch(perfLabControllerProvider('m1'));
    return Scaffold(
      appBar: AppBar(title: const Text('Performance')),
      body: o == null
          ? const SizedBox.shrink()
          : switch (tab) {
              'Benchmark' => BenchTab(overview: o),
              'Compare' => CompareTab(overview: o),
              _ => OverviewTab(overview: o),
            },
    );
  }
}
