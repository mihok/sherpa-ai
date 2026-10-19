import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/chat/model_picker_sheet.dart';
import 'package:sherpa/features/models/model_library_screen.dart';
import 'package:sherpa/features/models/models_bootstrap.dart' show openChatOnModel;
import 'package:sherpa/features/models/state/local_inference_providers.dart';
import 'package:sherpa/features/models/state/local_model_choice.dart';
import 'package:sherpa/features/models/state/local_model_fit.dart';
import 'package:sherpa/features/models/state/models_providers.dart';
import 'package:sherpa/features/models/state/platform_models_providers.dart';
import 'package:sherpa/services/device/device_profile_source.dart';
import 'package:sherpa/services/inference/on_device_ids.dart';
import 'package:sherpa/state/observable_session_store.dart';
import 'package:sherpa/state/providers.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart' show DevicePlatform, DeviceProfile;
import 'package:sherpa_litert/sherpa_litert.dart';

import '../../services/inference/support/local_rig.dart' show gib, libraryModel, llama1bLikeShape;
import '../../services/inference/support/platform_rig.dart';
import '../chat/support/harness.dart' show chatTestTheme;
import 'state_test_prefs.dart';

const _android12 = DeviceProfile(platform: DevicePlatform.android, totalRamBytes: 12 * gib, availableRamBytes: 7 * gib);

void main() {
  late PlatformRig rig;
  late ObservableSessionStore store;

  Future<void> setUpAndroid(WidgetTester tester, {NanoStatusMsg? nano}) async {
    await tester.runAsync(() async {
      rig = await PlatformRig.create(platform: DevicePlatform.android);
      if (nano != null) rig.litert.nano = nano;
      await rig.addLiteRt('g1', name: 'Gemma 3 1B');
      await rig.addMlx('q3', name: 'Qwen3 MLX');
      await rig.local.add(libraryModel('m1', name: 'Qwen3 GGUF'));
      await rig.local.local.start();
    });
    store = ObservableSessionStore(InMemorySessionStore());
    addTearDown(() => tester.runAsync(rig.dispose));
  }

  List<Override> overrides() => [
        sessionStoreProvider.overrideWithValue(store),
        preferencesProvider.overrideWithValue(NoPrefs()),
        localInferenceProvider.overrideWithValue(rig.local.local),
        platformModelProvidersProvider.overrideWithValue(rig.providers),
        providerRegistryProvider.overrideWithValue(rig.registry),
        modelRecordStoreProvider.overrideWithValue(rig.local.records),
        modelStorageLayoutProvider.overrideWithValue(rig.layout),
        modelLibraryProvider.overrideWithValue(rig.local.library),
        deviceProfileSourceProvider.overrideWithValue(FixedDeviceProfileSource(_android12)),
        libraryModelsProvider.overrideWith((ref) async* {
          yield rig.local.library.models;
          yield* rig.local.library.changes;
        }),
        downloadJobsProvider.overrideWith((ref) => Stream.value(const [])),
        useLocalModelInChatProvider.overrideWith((ref) => (context, choice) => openChatOnModel(ref, context, choice)),
        localModelShapeProvider.overrideWith((ref, path) async => llama1bLikeShape),
      ];

  Future<void> pumpLibrary(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 2400) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const ModelLibraryScreen()),
      GoRoute(path: '/chat/:id', builder: (_, s) => Scaffold(body: Text('chat:${s.pathParameters['id']}'))),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(),
      child: MaterialApp.router(theme: chatTestTheme(Brightness.light), routerConfig: router),
    ));
    await tester.pumpAndSettle();
  }

  ButtonStyleButton useButtonIn(WidgetTester tester, String modelName) {
    final tile = find.ancestor(of: find.text(modelName), matching: find.byType(LibraryModelTile));
    return tester.widget<ButtonStyleButton>(find
        .ancestor(
          of: find.descendant(of: tile, matching: find.text('Use in chat')),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        )
        .first);
  }

  group('library', () {
    testWidgets('each engine says whether it can run the model here, and why not', (tester) async {
      await setUpAndroid(tester);
      await pumpLibrary(tester);
      expect(find.text('LiteRT-LM: Runs on GPU (falls back to CPU).'), findsOneWidget);
      expect(find.text('MLX: MLX models run on iPhone and iPad only.'), findsOneWidget);
      expect(useButtonIn(tester, 'Gemma 3 1B').onPressed, isNotNull);
      expect(useButtonIn(tester, 'Qwen3 MLX').onPressed, isNull, reason: 'MLX on Android stays blocked');
      expect(useButtonIn(tester, 'Qwen3 GGUF').onPressed, isNotNull);
    });

    testWidgets('"Use in chat" on a LiteRT model opens a chat on litert_lm', (tester) async {
      await setUpAndroid(tester);
      await pumpLibrary(tester);
      final tile = find.ancestor(of: find.text('Gemma 3 1B'), matching: find.byType(LibraryModelTile));
      await tester.runAsync(() async {
        await tester.tap(find.descendant(of: tile, matching: find.text('Use in chat')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      final s = (await store.listSessions()).single;
      expect((s.providerId, s.modelId), (liteRtProviderId, 'g1'));
      expect(find.text('chat:${s.id}'), findsOneWidget);
    });

    testWidgets('System models: Gemini Nano downloads with progress, then can be used; foreground only is explained',
        (tester) async {
      await setUpAndroid(tester, nano: NanoStatusMsg(featureStatus: NanoFeatureStatus.downloadable));
      final release = Completer<void>();
      rig.litert.scripts.add((s) async {
        s.batch([LiteRtEvent(kind: EventKind.downloadStarted, value: 1000 << 20)]);
        s.batch([LiteRtEvent(kind: EventKind.downloadProgress, value: 250 << 20)]);
        await release.future;
        rig.litert.nano = NanoStatusMsg(featureStatus: NanoFeatureStatus.available, baseModelName: 'nano-v3');
        s.batch([LiteRtEvent(kind: EventKind.downloadCompleted)]);
      });
      await pumpLibrary(tester);
      expect(find.text('System models'), findsOneWidget);
      expect(find.text('Gemini Nano'), findsOneWidget);
      expect(find.text('Not downloaded'), findsOneWidget);
      expect(find.text(kForegroundOnlyExplanation), findsOneWidget);
      expect(find.text('Gemini Nano is supported on this device and can be downloaded.'), findsOneWidget);
      expect(find.text('Apple Intelligence'), findsNothing, reason: 'Android has no Apple model');

      await tester.tap(find.text('Download Gemini Nano'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(find.text('Downloading'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
          find.byWidgetPredicate((w) => w is LinearProgressIndicator && w.semanticsLabel == 'Downloading Gemini Nano'));
      expect(bar.value, 0.25);
      expect(find.textContaining('of 1000 MB'), findsOneWidget);

      release.complete();
      await tester.pumpAndSettle();
      expect(find.text('Ready'), findsOneWidget);
      expect(find.text('Gemini Nano (nano-v3) is ready.'), findsOneWidget);
      final card = find.byKey(const ValueKey('system-model-$geminiNanoProviderId'));
      await tester.runAsync(() async {
        await tester.tap(find.descendant(of: card, matching: find.text('Use in chat')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      final s = (await store.listSessions()).single;
      expect((s.providerId, s.modelId), (geminiNanoProviderId, GeminiNanoProvider.modelId));
    });

    testWidgets('an unsupported system model explains itself and offers nothing', (tester) async {
      await setUpAndroid(tester,
          nano: NanoStatusMsg(
              featureStatus: 0, error: ErrorMsg(source: 'nano', code: NanoErrorCode.featureNotFound, message: 'x')));
      await pumpLibrary(tester);
      expect(find.text('Unavailable'), findsOneWidget);
      expect(find.textContaining('unlocked bootloader'), findsOneWidget);
      expect(find.text('Download Gemini Nano'), findsNothing);
      expect(find.text(kForegroundOnlyExplanation), findsNothing);
    });
  });

  group('picker', () {
    Future<List<ModelChoice?>> pumpPicker(WidgetTester tester) async {
      tester.view.physicalSize = const Size(420, 1600) * tester.view.devicePixelRatio;
      addTearDown(tester.view.resetPhysicalSize);
      final picked = <ModelChoice?>[];
      await tester.pumpWidget(ProviderScope(
        overrides: overrides(),
        child: MaterialApp(
          theme: chatTestTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () async => picked.add(await ModelPickerSheet.show(context)),
                  child: const Text('Pick'),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Pick'));
      await tester.pumpAndSettle();
      return picked;
    }

    testWidgets('lists LiteRT and GGUF models with their engine, MLX blocked, and Gemini Nano as on screen only',
        (tester) async {
      await setUpAndroid(tester);
      final picked = await pumpPicker(tester);
      expect(find.text('Gemma 3 1B'), findsOneWidget);
      expect(find.textContaining('LiteRT · '), findsOneWidget);
      expect(find.text('Runs on GPU (falls back to CPU).'), findsOneWidget);
      expect(find.text('MLX models run on iPhone and iPad only.'), findsOneWidget);
      expect(find.text('Gemini Nano (nano-v3)'), findsOneWidget);
      expect(find.text('On screen only'), findsOneWidget);
      expect(find.text('Pauses when you leave Sherpa; continues when you come back.'), findsOneWidget);
      final nanoRow = find.byKey(const ValueKey('system-model-$geminiNanoProviderId'));
      expect(tester.getSemantics(nanoRow).label, contains('Only while Sherpa is on screen'));

      await tester.tap(find.text('Gemma 3 1B'));
      await tester.pumpAndSettle();
      expect(picked.single, const ModelChoice(providerId: liteRtProviderId, modelId: 'g1'));

      await tester.tap(find.text('Pick'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Qwen3 MLX'));
      await tester.pumpAndSettle();
      expect(find.text('Choose a model'), findsOneWidget, reason: 'a blocked row does nothing');
      await tester.tap(find.text('Gemini Nano (nano-v3)'));
      await tester.pumpAndSettle();
      expect(picked.last, const ModelChoice(providerId: geminiNanoProviderId, modelId: GeminiNanoProvider.modelId));
    });
  });
}
