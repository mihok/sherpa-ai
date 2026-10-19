// Frame-timing benchmark (docs/research/12-mobile-ux-ci.md §3.7–3.8).
//
// Five scenarios, each traced under its own report key so the driver
// (test_driver/perf_driver.dart) writes one
// build/<scenario>.r<N>.timeline_summary.json per scenario and repetition:
//
//   stream_4k_tokens_markdown  StreamingMarkdown alone, ~4K tokens at 60 Hz
//   chat_stream_long_reply     the chat screen streaming a long reply with
//                              code and tables from the scripted model
//   chat_scroll_long_transcript flinging through a 60-exchange transcript
//   model_picker_open          opening, scrolling and closing the picker
//   context_inspector          opening and scrolling "What the model sees"
//
// The app is the real one from bootstrap(inMemory: true) with a scripted
// "remote" model (support/bench_app.dart). On a device:
//
//   bench/app/run_frame_bench.sh -d <device id> -c <device class> [-n runs] [-r repeats]
//
// which runs `flutter drive --profile` and gates the medians with
// tools/perf_gate.dart. On the host,
// `flutter test -d flutter-tester integration_test/frame_bench_test.dart`
// runs every scenario once (a smoke test of the flows; debug-mode numbers).
//
// --dart-define=SHERPA_BENCH_REPEAT=3 repeats each scenario in-process;
// --dart-define=SHERPA_BENCH_ONLY=a,b runs only the named scenarios;
// --dart-define=SHERPA_BENCH_SUMMARY_DIR=build/bench-host (host runs)
// writes the timeline summaries without a driver.
import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/chat/model_picker_sheet.dart';
import 'package:sherpa/features/chat/widgets/model_chip.dart';
import 'package:sherpa/features/chat/widgets/transcript.dart';
import 'package:sherpa/features/context/inspector_screen.dart';
import 'package:sherpa/routing/router.dart';
import 'package:sherpa/routing/routes.dart';
import 'package:sherpa_core/testing.dart';
import 'package:sherpa_markdown/sherpa_markdown.dart';

import 'support/bench_app.dart';

const int repeat = int.fromEnvironment('SHERPA_BENCH_REPEAT', defaultValue: 1);
const String only = String.fromEnvironment('SHERPA_BENCH_ONLY');

/// Host runs only: where to write the timeline summaries (there is no
/// driver to do it). Empty on devices: the driver writes them.
const String summaryDir = String.fromEnvironment('SHERPA_BENCH_SUMMARY_DIR');

/// Scenario ids; also the `scenario` of the result and baseline files.
abstract final class Scenario {
  static const markdown = 'stream_4k_tokens_markdown';
  static const stream = 'chat_stream_long_reply';
  static const scroll = 'chat_scroll_long_transcript';
  static const picker = 'model_picker_open';
  static const inspector = 'context_inspector';

  static const all = [markdown, stream, scroll, picker, inspector];
}

/// `<scenario>.r<n>`: the driver writes `build/<key>.timeline_summary.json`.
String reportKey(String scenario, int run) => '$scenario.r$run';

bool selected(String scenario) => only.isEmpty || only.split(',').map((s) => s.trim()).contains(scenario);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Every frame the app asks for is drawn, as on a phone; pumps only wait.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  if (summaryDir.isNotEmpty) {
    tearDownAll(() async {
      for (final f in await writeTimelineSummaries(binding.reportData, summaryDir)) {
        debugPrint('frame bench: wrote $f');
      }
    });
  }

  void scenario(String id, Future<void> Function(WidgetTester tester) body) {
    testWidgets(id, (tester) async {
      debugPrint('frame bench: $id x$repeat');
      await body(tester);
    }, skip: !selected(id));
  }

  scenario(Scenario.markdown, (tester) async {
    final text = ValueNotifier<String>('');
    addTearDown(text.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ValueListenableBuilder<String>(
            valueListenable: text,
            builder: (context, t, _) => StreamingMarkdown(text: t, streaming: true),
          ),
        ),
      ),
    ));
    final reply = benchReply(sections: 12);
    for (var r = 1; r <= repeat; r++) {
      text.value = '';
      await tester.pump();
      await traced(binding, reportKey(Scenario.markdown, r), () async {
        for (var i = 0; i < reply.length; i += 4) {
          text.value = reply.substring(0, min(reply.length, i + 4));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await tester.pump(const Duration(milliseconds: 200));
      });
    }
  });

  scenario(Scenario.stream, (tester) async {
    final app = await BenchApp.start(
      tester,
      turns: [for (var r = 0; r < repeat; r++) ScriptedTurn.text(benchReply(sections: 8, seed: r))],
    );
    for (var r = 1; r <= repeat; r++) {
      final id = await app.newChat(id: 'stream-$r', title: 'Streaming $r');
      await app.go(Routes.chat(id));
      final controller = app.controller(id);
      final asked = app.model.requests.length;
      await traced(binding, reportKey(Scenario.stream, r), () async {
        unawaited(controller.send('Walk me through the context ladder, with code and a table.'));
        await app.pumpUntil(
          () => app.model.requests.length > asked && !app.chat(id).isRunActive && app.chat(id).lastOutcome != null,
          what: 'the reply to finish streaming',
        );
        await app.pumpFor(const Duration(milliseconds: 500));
      });
      expect(app.chat(id).error, isNull);
      // The last section of the reply is on screen (the view followed it).
      expect(find.textContaining('Step ${8 * (r - 1) + 7}:', findRichText: true), findsWidgets);
    }
  });

  scenario(Scenario.scroll, (tester) async {
    final app = await BenchApp.start(tester);
    final id = await app.seedTranscript(exchanges: 60);
    await app.go(Routes.chat(id));
    final list = find.descendant(of: find.byType(ChatTranscript), matching: find.byType(Scrollable)).first;
    expect(list, findsOneWidget);
    double offset() => tester.state<ScrollableState>(list).position.pixels;
    for (var r = 1; r <= repeat; r++) {
      final start = offset();
      var furthest = start;
      await traced(binding, reportKey(Scenario.scroll, r), () async {
        // Up through the history (older messages build as they appear),
        // then back down to the newest.
        for (final dy in [for (var i = 0; i < 6; i++) 500.0, for (var i = 0; i < 6; i++) -500.0]) {
          await tester.fling(list, Offset(0, dy), 2400);
          await app.pumpFor(const Duration(milliseconds: 700));
          if ((offset() - start).abs() > (furthest - start).abs()) furthest = offset();
        }
      });
      expect((furthest - start).abs(), greaterThan(2000), reason: 'the transcript scrolled through its history');
    }
  });

  scenario(Scenario.picker, (tester) async {
    final app = await BenchApp.start(tester);
    final id = await app.newChat(id: 'picker');
    await app.go(Routes.chat(id));
    Future<void> openPicker() async {
      await tester.tap(find.byType(ModelChip));
      await app.pumpFor(const Duration(milliseconds: 700));
      expect(find.byType(ModelPickerSheet), findsOneWidget);
    }

    Future<void> closePicker() async {
      Navigator.of(tester.element(find.byType(ModelPickerSheet))).pop();
      await app.pumpFor(const Duration(milliseconds: 500));
    }

    // Warm-up: the first open starts (or fails to start) the on-device
    // engine; that is start-up work, not the picker's frames.
    await openPicker();
    await waitForEngine(app);
    await closePicker();
    for (var r = 1; r <= repeat; r++) {
      await traced(binding, reportKey(Scenario.picker, r), () async {
        for (var i = 0; i < 4; i++) {
          await openPicker();
          expect(
            find.descendant(of: find.byType(ModelPickerSheet), matching: find.text('Bench large')),
            findsOneWidget,
            reason: "the bench provider's models are listed",
          );
          await tester.fling(find.byType(ModelPickerSheet), const Offset(0, -400), 1600);
          await app.pumpFor(const Duration(milliseconds: 600));
          await closePicker();
        }
      });
    }
  });

  scenario(Scenario.inspector, (tester) async {
    final app = await BenchApp.start(tester);
    final id = await app.seedTranscript(exchanges: 60);
    await app.go(Routes.chat(id));
    for (var r = 1; r <= repeat; r++) {
      await traced(binding, reportKey(Scenario.inspector, r), () async {
        for (var i = 0; i < 3; i++) {
          await app.push(Routes.chatContext(id));
          await app.pumpFor(const Duration(milliseconds: 900));
          expect(find.byType(ContextInspectorScreen), findsOneWidget);
          expect(find.text("Couldn't read this chat's context"), findsNothing);
          final list = find.descendant(of: find.byType(ContextInspectorScreen), matching: find.byType(Scrollable)).first;
          await tester.fling(list, const Offset(0, -600), 2000);
          await app.pumpFor(const Duration(milliseconds: 700));
          app.container.read(routerProvider).pop();
          await app.pumpFor(const Duration(milliseconds: 600));
        }
      });
    }
  });

  test('every scenario has a report key the run script knows', () {
    expect(Scenario.all.toSet(), hasLength(5));
    expect(reportKey(Scenario.stream, 2), 'chat_stream_long_reply.r2');
  });
}
