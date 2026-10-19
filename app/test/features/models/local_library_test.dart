import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/models/model_library_screen.dart';
import 'package:sherpa/features/models/models_bootstrap.dart';
import 'package:sherpa/features/models/state/local_inference_providers.dart';
import 'package:sherpa/features/models/state/local_model_choice.dart';
import 'package:sherpa/features/models/state/models_providers.dart';
import 'package:sherpa/state/observable_session_store.dart';
import 'package:sherpa/state/providers.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';
import 'package:sherpa_inference/testing.dart';

import '../../services/inference/support/local_rig.dart';
import '../chat/support/harness.dart' show chatTestTheme;

void main() {
  late LocalRig rig;
  late ObservableSessionStore store;

  Future<void> setUpRig(WidgetTester tester, {FakeEngineHost Function()? host, bool crashed = false}) async {
    await tester.runAsync(() async {
      rig = await LocalRig.create(host: host);
      await rig.add(libraryModel('m1', name: 'Qwen3 0.6B'));
      if (crashed) {
        final f = EngineForensics(Directory('${rig.dir.path}/support/engine'));
        await f.enter(PhaseRecord(
            phase: InferencePhase.generating, at: DateTime.utc(2026), modelId: 'm1', modelName: 'Qwen3 0.6B', nCtx: 8192));
        await f.flush();
      }
      await rig.local.start();
    });
    store = ObservableSessionStore(InMemorySessionStore());
    addTearDown(() => tester.runAsync(rig.dispose));
  }

  Future<GoRouter> pumpLibrary(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 1200) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const ModelLibraryScreen()),
      GoRoute(path: '/chat/:id', builder: (_, s) => Scaffold(body: Text('chat:${s.pathParameters['id']}'))),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sessionStoreProvider.overrideWithValue(store),
        preferencesProvider.overrideWithValue(_NoPrefs()),
        localInferenceProvider.overrideWithValue(rig.local),
        modelRecordStoreProvider.overrideWithValue(rig.records),
        modelStorageLayoutProvider.overrideWithValue(rig.layout),
        modelLibraryProvider.overrideWithValue(rig.library),
        libraryModelsProvider.overrideWith((ref) async* {
          yield rig.library.models;
          yield* rig.library.changes;
        }),
        downloadJobsProvider.overrideWith((ref) => Stream.value(const [])),
        useLocalModelInChatProvider.overrideWith((ref) => (context, choice) => openChatOnModel(ref, context, choice)),
      ],
      child: MaterialApp.router(theme: chatTestTheme(Brightness.light), routerConfig: router),
    ));
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('the crash report shows as a banner until dismissed', (tester) async {
    await setUpRig(tester, crashed: true);
    await pumpLibrary(tester);
    expect(find.text('The on-device engine stopped last time'), findsOneWidget);
    expect(find.textContaining('while generating a reply with Qwen3 0.6B (8192-token context)'), findsOneWidget);
    expect(find.textContaining('shorter context'), findsOneWidget);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('The on-device engine stopped last time'), findsNothing);
    expect(rig.local.status.crashReport, isNull);
  });

  testWidgets('an unavailable engine is explained and "Use in chat" is disabled', (tester) async {
    await setUpRig(tester, host: () => FakeEngineHost()..startError = const EngineUnavailableException('no engine in this build'));
    await pumpLibrary(tester);
    expect(find.text("On-device chat isn't available"), findsOneWidget);
    expect(find.textContaining('no engine in this build'), findsOneWidget);
    final button = tester.widget<ButtonStyleButton>(find.ancestor(of: find.text('Use in chat'), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)));
    expect(button.onPressed, isNull);
  });

  testWidgets('"Use in chat" opens a chat on that model, reusing an empty one', (tester) async {
    await setUpRig(tester);
    final router = await pumpLibrary(tester);
    expect(find.text("On-device chat isn't available"), findsNothing);
    await tester.runAsync(() async {
      await tester.tap(find.text('Use in chat'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    final sessions = await store.listSessions();
    expect(sessions.single.providerId, localProviderId);
    expect(sessions.single.modelId, 'm1');
    expect(find.text('chat:${sessions.single.id}'), findsOneWidget);
    expect(rig.library.byId('m1')!.lastUsedAt, isNotNull);

    // Back to the library, again: the still-empty chat is reused.
    router.go('/');
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Use in chat'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(await store.listSessions(), hasLength(1));
    expect(find.text('chat:${sessions.single.id}'), findsOneWidget);
  });
}

final class _NoPrefs implements PreferencesStore {
  @override
  ModelChoice? get defaultModel => null;

  @override
  Future<void> setDefaultModel(ModelChoice? choice) async {}

  @override
  bool get onboardingComplete => true;

  @override
  Future<void> setOnboardingComplete(bool value) async {}

  @override
  Stream<void> get changes => const Stream.empty();
}
