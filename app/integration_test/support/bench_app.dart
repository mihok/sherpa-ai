// Shared harness for the frame-timing benchmark (frame_bench_test.dart):
// the real app from `bootstrap(inMemory: true)`, with the model providers
// swapped for a scripted one, chats seeded straight into the session store,
// and helpers that wait in real time (integration tests run on a live
// binding, so frames come from the engine, not from fake time).
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_driver/flutter_driver.dart' as driver;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa/app.dart';
import 'package:sherpa/bootstrap.dart';
import 'package:sherpa/features/chat/state/chat_controller.dart';
import 'package:sherpa/features/chat/state/chat_dependencies.dart' show chatRunnerExtrasProvider;
import 'package:sherpa/features/chat/state/chat_view_state.dart';
import 'package:sherpa/features/models/models_bootstrap.dart';
import 'package:sherpa/features/models/state/local_inference_providers.dart';
import 'package:sherpa/routing/router.dart';
import 'package:sherpa/services/inference/local_inference.dart';
import 'package:sherpa/state/in_memory/in_memory_preferences_store.dart';
import 'package:sherpa/state/observable_session_store.dart';
import 'package:sherpa/state/providers.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

/// The provider every bench chat talks to (a scripted "remote" model).
const String kBenchProviderId = 'bench';
const String kBenchModelId = 'bench-large';

/// Extra providers so the model picker has a realistic amount to lay out.
const int kPickerProviders = 4;
const int kModelsPerProvider = 12;

/// The registry the bench app uses: [kBenchProviderId] resolves to [model];
/// the others only list models (the picker never calls them).
final class BenchRegistry implements ProviderRegistry {
  BenchRegistry(this.model);

  final ScriptedProvider model;

  @override
  late final List<ProviderConfig> configs = [
    ProviderConfig(
      id: kBenchProviderId,
      flavor: ApiFlavor.openAiChat,
      displayName: 'Bench Cloud',
      baseUrl: Uri.parse('https://bench.example.com/v1'),
      defaultModelId: kBenchModelId,
    ),
    for (var i = 1; i < kPickerProviders; i++)
      ProviderConfig(
        id: 'picker$i',
        flavor: i.isEven ? ApiFlavor.anthropic : ApiFlavor.openAiResponses,
        displayName: 'Provider $i',
        baseUrl: Uri.parse('https://provider$i.example.com/v1'),
      ),
  ];

  @override
  Stream<List<ProviderConfig>> get changes => const Stream.empty();

  @override
  Future<ProviderConfig> add(ProviderConfig config, {String? apiKey}) => throw UnsupportedError('bench registry is fixed');

  @override
  Future<ProviderConfig> update(ProviderConfig config, {String? apiKey, bool clearApiKey = false}) =>
      throw UnsupportedError('bench registry is fixed');

  @override
  Future<void> remove(String providerId) => throw UnsupportedError('bench registry is fixed');

  @override
  Future<bool> hasApiKey(String providerId) async => true;

  @override
  Future<ModelProvider> resolve(String providerId) async {
    if (providerId == kBenchProviderId) return model;
    throw StateError('Unknown provider "$providerId"');
  }

  @override
  Future<List<ModelDescriptor>> models(String providerId, {bool refresh = false}) async => [
        for (var m = 0; m < kModelsPerProvider; m++)
          ModelDescriptor(
            id: m == 0 && providerId == kBenchProviderId ? kBenchModelId : '$providerId-model-$m',
            providerId: providerId,
            displayName: m == 0 && providerId == kBenchProviderId ? 'Bench large' : 'Model $m of $providerId',
            capabilities: ModelCapabilities(contextLength: 32768 << (m % 3), vision: m.isEven),
          ),
      ];

  @override
  Future<EndpointStatus> probe(String providerId) async => EndpointStatus.ok;
}

/// A long assistant reply: headings, prose with inline code and links,
/// nested lists, fenced code and tables (what makes markdown layout slow).
String benchReply({int sections = 10, int seed = 0}) {
  final b = StringBuffer();
  for (var i = 0; i < sections; i++) {
    final n = seed * sections + i;
    b
      ..writeln('## Step $n: ${i.isEven ? 'prune' : 'compact'} the context')
      ..writeln()
      ..writeln('The **context ladder** first elides stale tool output, then compacts at a legal cut point '
          '(`keepRecentUserTurns = 3`). See [the notes](https://example.org/notes/$n) and the '
          '_side-effect ledger_ before you retry a tool that is not idempotent.')
      ..writeln()
      ..writeln('- elide old results\n- clear large inputs\n  - keep call/result pairing\n  - keep the last 3 calls\n'
          '1. compact\n2. hand off')
      ..writeln()
      ..writeln('```dart\nfinal prepared = await manager.prepare(request);\n'
          'if (prepared.budget.ratio > 0.8) {\n  await compactor.run(prepared, keep: 3);\n}\n'
          'print(prepared.budget.ratio.toStringAsFixed(2));\n```')
      ..writeln()
      ..writeln('| stage | trigger | keeps |\n|---|---:|---|\n| prune | 0.60 | recent 3 |\n'
          '| compact | 0.80 | summary + tail |\n| handoff | 0.92 | bundle |')
      ..writeln();
  }
  return b.toString();
}

/// The running bench app.
final class BenchApp {
  BenchApp._(this.tester, this.store, this.model);

  final WidgetTester tester;
  final ObservableSessionStore store;
  final ScriptedProvider model;

  ProviderContainer get container => ProviderScope.containerOf(tester.element(find.byType(SherpaApp)));

  /// Boots the in-memory app (onboarding done, the bench model as the
  /// default) with [turns] scripted for the bench model, each event
  /// [eventDelay] apart, and pumps it until the home screen settles.
  static Future<BenchApp> start(
    WidgetTester tester, {
    List<ScriptedTurn> turns = const [],
    Duration eventDelay = const Duration(milliseconds: 8),
  }) async {
    // A desktop host (`flutter test -d flutter-tester`) may have no system
    // D-Bus for connectivity_plus; phones always answer.
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) ConnectivityPlatform.instance = _HostConnectivity();
    // bootstrap() installs the app's error handlers; the test framework's
    // must stay in place so a rendering error still fails the run.
    final flutterOnError = FlutterError.onError;
    final platformOnError = PlatformDispatcher.instance.onError;
    final base = await bootstrap(inMemory: true);
    FlutterError.onError = flutterOnError;
    PlatformDispatcher.instance.onError = platformOnError;

    final model = ScriptedProvider(
      turns,
      eventDelay: eventDelay,
      capabilitiesValue: const ModelCapabilities(contextLength: 131072, maxOutputTokens: 8192),
      info: ProviderInfo(
        id: kBenchProviderId,
        kind: ProviderKind.fake,
        displayName: 'Bench Cloud',
        location: ExecutionLocation.remote,
        baseUrl: Uri.parse('https://bench.example.com/v1'),
      ),
    );
    final store = ObservableSessionStore(InMemorySessionStore());
    final dir = await Directory.systemTemp.createTemp('sherpa_bench_');
    // On-device inference stays wired (the picker shows its section) but
    // the engine does not start on its own in the middle of a measurement.
    final local = await localInferenceOverrides(
      registry: BenchRegistry(model),
      config: LocalInferenceConfig(
        supportDirectory: p.join(dir.path, 'support'),
        cacheDirectory: p.join(dir.path, 'caches'),
        autoStart: false,
        observeAppLifecycle: false,
      ),
    );
    final replaced = <Override>[
      ...local,
      sessionStoreProvider.overrideWithValue(store),
      preferencesProvider.overrideWithValue(InMemoryPreferencesStore(
        defaultModel: const ModelChoice(providerId: kBenchProviderId, modelId: kBenchModelId),
        onboardingComplete: true,
      )),
    ];
    final origins = {for (final o in replaced) o.origin};
    final overrides = [
      for (final o in base)
        if (!origins.contains(o.origin)) o,
      ...replaced,
    ];
    assert(overrides.any((o) => o.origin == chatRunnerExtrasProvider));
    assert(overrides.any((o) => o.origin == localInferenceConfigProvider));

    await tester.pumpWidget(ProviderScope(overrides: overrides, retry: noRetry, child: const SherpaApp()));
    final app = BenchApp._(tester, store, model);
    await app.settle();
    return app;
  }

  /// Pumps frames for [d] of real time.
  Future<void> pumpFor(Duration d) async {
    final end = DateTime.now().add(d);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// Pumps until [done] holds; fails after [timeout].
  Future<void> pumpUntil(bool Function() done, {Duration timeout = const Duration(seconds: 90), String? what}) async {
    final end = DateTime.now().add(timeout);
    while (!done()) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for ${what ?? 'the condition'}');
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// Lets the app go idle: animations finish, the router settles.
  Future<void> settle() => pumpFor(const Duration(milliseconds: 600));

  Future<void> go(String location) async {
    container.read(routerProvider).go(location);
    await settle();
  }

  Future<void> push(String location) async {
    unawaited(container.read(routerProvider).push(location));
    await settle();
  }

  ChatViewState chat(String sessionId) => container.read(chatControllerProvider(sessionId));

  ChatController controller(String sessionId) => container.read(chatControllerProvider(sessionId).notifier);

  /// An empty chat on the bench model.
  Future<String> newChat({String id = 'bench-chat', String title = 'Bench chat'}) async {
    final now = DateTime.now().toUtc();
    await store.putSession(SessionRecord(
      id: id,
      title: title,
      createdAt: now,
      updatedAt: now,
      providerId: kBenchProviderId,
      modelId: kBenchModelId,
    ));
    return id;
  }

  /// A chat with [exchanges] finished question/answer pairs on the active
  /// branch (every fifth answer also calls a tool), as if read from disk.
  Future<String> seedTranscript({String id = 'bench-long', int exchanges = 60}) async {
    final start = DateTime.now().toUtc().subtract(Duration(minutes: exchanges * 2));
    final session = SessionRecord(
      id: id,
      title: 'A long chat about context budgets',
      createdAt: start,
      updatedAt: start,
      providerId: kBenchProviderId,
      modelId: kBenchModelId,
    );
    await store.putSession(session);
    var at = start;
    String? parent;
    var n = 0;
    String nextId() => 'm${n++}';
    Future<void> put(Role role, List<ContentPart> content, {String? finish}) async {
      final m = Message(
        id: nextId(),
        parentId: parent,
        role: role,
        content: content,
        createdAt: at,
        providerId: role == Role.assistant ? kBenchProviderId : null,
        modelId: role == Role.assistant ? kBenchModelId : null,
        finishReason: finish,
        usage: role == Role.assistant ? const Usage(inputTokens: 1200, outputTokens: 600) : null,
      );
      await store.putMessage(id, m);
      parent = m.id;
      at = at.add(const Duration(seconds: 20));
    }

    for (var i = 0; i < exchanges; i++) {
      await put(Role.user, [TextPart('Question $i: how should the agent handle a context that is ${60 + i % 30}% full?')]);
      if (i % 5 == 4) {
        final call = ToolCall(id: 'call$i', name: 'update_plan', arguments: {'step': i, 'note': 'Checked the budget'});
        await put(Role.assistant, [const TextPart('Let me record that in the plan.'), ToolCallPart(call)], finish: 'tool_calls');
        await put(Role.tool, [
          ToolResultPart(callId: call.id, toolName: call.name, content: [TextPart('Plan updated: step $i done.')]),
        ]);
      }
      await put(Role.assistant, [TextPart(benchReply(sections: 2, seed: i))], finish: 'stop');
    }
    await store.putSession(session.copyWith(updatedAt: at, activeLeafId: parent));
    return id;
  }
}

/// Always online, never changes (host runs only).
final class _HostConnectivity extends ConnectivityPlatform {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => const [ConnectivityResult.wifi];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => const Stream.empty();
}

/// Whether a VM service is there to record a timeline (`flutter drive`, or
/// `flutter test` with `--enable-vmservice`); plain `flutter test` on the
/// host has none.
Future<bool> timelineAvailable() async {
  if (kIsWeb) return false;
  final info = await developer.Service.getInfo();
  return info.serverUri != null;
}

/// What `TimelineSummary` reads: `Frame` build events (Dart), raster and
/// vsync events (Embedder) and collections (GC). Recording `all` streams
/// overflows the VM's ring buffer within a second or two (API and compiler
/// events), so a long scenario would keep only its last frames.
const List<String> kTimelineStreams = ['Dart', 'Embedder', 'GC'];

/// Runs [action] inside `traceAction` under [reportKey] when a timeline
/// can be recorded, else just runs it (a host smoke run of the scenario).
Future<void> traced(IntegrationTestWidgetsFlutterBinding binding, String reportKey, Future<void> Function() action) async {
  if (!await timelineAvailable()) {
    debugPrint('frame bench: no VM service, running "$reportKey" without a timeline');
    await action();
    return;
  }
  await binding.traceAction(action, reportKey: reportKey, streams: kTimelineStreams);
}

/// Waits until the engine status the picker started is final (never a
/// measurement of the engine's own start-up).
Future<void> waitForEngine(BenchApp app) => app.pumpUntil(
      () {
        final s = app.container.read(localInferenceProvider)?.status.state;
        return s == null || s == LocalEngineState.ready || s == LocalEngineState.unavailable || s == LocalEngineState.idle;
      },
      timeout: const Duration(seconds: 30),
      what: 'the on-device engine to settle',
    );

/// Writes `<dir>/<key>.timeline_summary.json` for every traced action in
/// [reportData], the way test_driver/perf_driver.dart does after
/// `flutter drive`. For host runs (`--dart-define=SHERPA_BENCH_SUMMARY_DIR=…`),
/// which have a VM service but no driver: the numbers are debug-mode
/// flutter_tester numbers, good for checking the pipeline, not as a baseline.
Future<List<String>> writeTimelineSummaries(Map<String, dynamic>? reportData, String dir) async {
  final out = <String>[];
  for (final e in (reportData ?? const <String, dynamic>{}).entries) {
    final timeline = driver.Timeline.fromJson((e.value as Map).cast<String, dynamic>());
    await driver.TimelineSummary.summarize(timeline)
        .writeTimelineToFile(e.key, destinationDirectory: dir, pretty: true, includeSummary: true);
    out.add(p.join(dir, '${e.key}.timeline_summary.json'));
  }
  return out;
}
