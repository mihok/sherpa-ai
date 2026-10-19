import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/app.dart';
import 'package:sherpa/bootstrap.dart' show noRetry;
import 'package:sherpa/features/models/state/platform_models_providers.dart';
import 'package:sherpa/features/onboarding/starter_model.dart';
import 'package:sherpa/services/inference/on_device_ids.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_hub/sherpa_hub.dart';
import 'package:sherpa_hub/testing.dart';
import 'package:sherpa_litert/sherpa_litert.dart' show GeminiNanoProvider;

import '../../services/inference/support/platform_rig.dart';
import '../../support/harness.dart';
import '../models/support/models_rig.dart';

/// Polls [test] in real time (inside `runAsync`).
Future<void> until(bool Function() test, {Duration timeout = const Duration(seconds: 10), String? what}) async {
  final deadline = DateTime.now().add(timeout);
  while (!test()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('timed out waiting for ${what ?? 'condition'}');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Lets real IO run and the UI rebuild until [test] holds.
Future<void> settleUntil(WidgetTester tester, bool Function() test, {String? what}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!test()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('timed out waiting for ${what ?? 'condition'}');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  group('pickStarterModel', () {
    final big = fixtureDetails(llama1b, llama1bFiles);

    test("the first starter repo whose recommended variant fits; repos that can't be read are skipped", () async {
      final catalog = FixtureModelCatalog(entries: const [], detailsById: {llama1b: big});
      final pick = await pickStarterModel(
        catalog: catalog,
        shapes: FakeShapeSource({llama1b: llama1bShape}),
        device: phone12,
      );
      expect(pick.details.id, llama1b);
      expect(pick.row.recommended, isTrue);
      expect(pick.row.label, 'Q8_0', reason: "the Hub directory's recommended variant");
      expect(pick.row.kind.name, 'fits');
    });

    test('a recommended variant over the size cap moves on; nothing that fits says why', () async {
      final catalog = FixtureModelCatalog(entries: const [], detailsById: {llama1b: big});
      await expectLater(
        pickStarterModel(
          catalog: catalog,
          shapes: FakeShapeSource({llama1b: llama1bShape}),
          device: phone12,
          maxDownloadBytes: 100 << 20,
        ),
        throwsA(isA<StarterUnavailable>().having((e) => e.reason, 'reason', contains('fits'))),
      );
      await expectLater(
        pickStarterModel(catalog: FixtureModelCatalog(entries: const []), shapes: FakeShapeSource({}), device: phone12),
        throwsA(isA<StarterUnavailable>().having((e) => e.reason, 'reason', contains("Couldn't pick"))),
      );
    });
  });

  testWidgets('on-device path: a recommended small model that fits downloads and the first chat opens on it',
      (tester) async {
    final rig = await ModelsRig.create(tester, onboarded: false, details: <String, CatalogModelDetails>{});
    // The catalog lists exactly what the fake Hub serves (sizes and hashes).
    rig.catalog.detailsById[llama1b] = fixtureDetails(llama1b, [for (final f in rig.hub.files.values) f.listing]);
    await rig.pump(tester);

    await tapText(tester, 'Get started');
    expect(find.text('Run a model on this phone'), findsOneWidget);
    expect(find.text('Local models (download)'), findsNothing, reason: 'the "coming next" teaser is gone');
    expect(find.text('OpenAI'), findsOneWidget, reason: 'the remote path stays');

    await tapText(tester, 'Run a model on this phone');
    await settleUntil(tester, () => find.text('Finding a model that fits this phone…').evaluate().isEmpty, what: 'the pick');
    expect(find.text('Step 2 of 2'), findsOneWidget);
    expect(find.text('Recommended for this phone'), findsOneWidget);
    expect(find.textContaining('Llama'), findsWidgets);
    expect(find.textContaining('Q8_0'), findsOneWidget);
    expect(find.text('Fits'), findsOneWidget);

    await tester.tap(find.textContaining('and start'));
    await settleUntil(tester, () => rig.library.models.isNotEmpty, what: 'installed');
    await settleUntil(tester, () => rig.app.prefs.onboardingComplete, what: 'onboarding done');
    await settleUntil(tester, () => find.textContaining('chat:').evaluate().isNotEmpty, what: 'the chat');
    expect(rig.library.models, hasLength(1), reason: '${rig.library.models.map((m) => m.variantId)}');
    final model = rig.library.models.single;
    expect(model.format, ModelFormat.gguf);
    expect(model.variantId, contains('Q8_0'));
    final session = (await rig.app.store.listSessions()).single;
    expect((session.providerId, session.modelId), (localProviderId, model.id));
    expect(rig.app.prefs.defaultModel, ModelChoice(providerId: localProviderId, modelId: model.id));
    expect(find.text('chat:${session.id}'), findsOneWidget);
  });

  testWidgets('the on-device step offers the system model when it is ready', (tester) async {
    final rig = await ModelsRig.create(tester, onboarded: false, details: <String, CatalogModelDetails>{});
    late PlatformRig platform;
    await tester.runAsync(() async => platform = await PlatformRig.create(platform: DevicePlatform.android));
    addTearDown(() => tester.runAsync(platform.dispose));
    setWindow(tester, phone);
    await tester.pumpWidget(ProviderScope(
      overrides: [...rig.overrides, platformModelProvidersProvider.overrideWithValue(platform.providers)],
      retry: noRetry,
      child: const SherpaApp(),
    ));
    await tester.pumpAndSettle();
    await tapText(tester, 'Get started');
    await tapText(tester, 'Run a model on this phone');
    await settleUntil(tester, () => find.text('Finding a model that fits this phone…').evaluate().isEmpty, what: 'the pick');

    expect(find.text('Built into this phone'), findsOneWidget);
    expect(find.text('On screen only'), findsOneWidget);
    expect(find.text(kForegroundOnlyExplanation), findsOneWidget);
    expect(find.textContaining("Couldn't pick a model"), findsOneWidget, reason: 'no starter fixture: says so, keeps going');
    await tester.tap(find.text('Use Gemini Nano'));
    await settleUntil(tester, () => rig.app.prefs.onboardingComplete, what: 'onboarding done');
    await settleUntil(tester, () => find.textContaining('chat:').evaluate().isNotEmpty, what: 'the chat');
    final session = (await rig.app.store.listSessions()).single;
    expect((session.providerId, session.modelId), (geminiNanoProviderId, GeminiNanoProvider.modelId));
    expect(find.text('chat:${session.id}'), findsOneWidget);
  });

  testWidgets('back from the on-device step returns to the choices; the remote path still works', (tester) async {
    final rig = await ModelsRig.create(tester, onboarded: false, details: <String, CatalogModelDetails>{});
    await rig.pump(tester);
    await tapText(tester, 'Get started');
    await tapText(tester, 'Run a model on this phone');
    await settleUntil(tester, () => find.text('Finding a model that fits this phone…').evaluate().isEmpty, what: 'the pick');
    await tapText(tester, 'Use a cloud model or my own server instead');
    expect(find.text('Where should your models run?'), findsOneWidget);
    await tapText(tester, 'Run a model on this phone');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Where should your models run?'), findsOneWidget);
    await tapText(tester, 'OpenAI');
    expect(find.text('Connect OpenAI'), findsOneWidget);
  });
}
