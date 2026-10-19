import 'dart:io';

import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/chat/model_picker_sheet.dart';
import 'package:sherpa/features/models/state/local_inference_providers.dart';
import 'package:sherpa/features/models/state/local_model_fit.dart';
import 'package:sherpa/features/models/state/models_providers.dart';
import 'package:sherpa/services/device/device_profile_source.dart';
import 'package:sherpa/services/inference/local_inference.dart';
import 'package:sherpa/services/inference/local_provider_registry.dart';
import 'package:sherpa/state/providers.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_inference/sherpa_inference.dart';
import 'package:sherpa_inference/testing.dart';

import '../../services/inference/support/local_rig.dart';
import 'support/fakes.dart';
import 'support/harness.dart';

void main() {
  late LocalRig rig;

  Future<void> setUpRig(WidgetTester tester, {FakeEngineHost Function()? host}) async {
    await tester.runAsync(() async {
      rig = await LocalRig.create(host: host);
      await rig.add(libraryModel('small', name: 'Small model', sizeBytes: 807694464, installedAt: DateTime.utc(2026, 10, 2)));
      await rig.add(libraryModel('huge', name: 'Huge model', sizeBytes: 9 * gib));
      await rig.local.start();
    });
    addTearDown(() => tester.runAsync(rig.dispose));
  }

  /// Opens the picker from a button; returns the picked choices.
  Future<List<ModelChoice?>> pumpPicker(WidgetTester tester, {bool wired = true, ModelChoice? current}) async {
    tester.view.physicalSize = const Size(420, 1000) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    final inner = FakeProviderRegistry(
      configs: [kCloudConfig],
      providers: {kProviderId: StubRemoteProvider(kCloudConfig)},
    );
    final registry = wired ? LocalProviderRegistry(inner, rig.local) : inner;
    final picked = <ModelChoice?>[];
    final overrides = <Override>[
      providerRegistryProvider.overrideWithValue(registry),
      if (wired) localInferenceProvider.overrideWithValue(rig.local),
      modelLibraryProvider.overrideWithValue(rig.library),
      modelStorageLayoutProvider.overrideWithValue(rig.layout),
      deviceProfileSourceProvider.overrideWithValue(FixedDeviceProfileSource(phone12gb)),
      localModelShapeProvider.overrideWith((ref, path) async => llama1bLikeShape),
    ];
    await tester.pumpWidget(ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: chatTestTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async => picked.add(await ModelPickerSheet.show(context, current: current)),
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

  testWidgets('"On this device" lists library models with their fit; a fitting one is chosen like a remote one',
      (tester) async {
    await setUpRig(tester);
    final picked = await pumpPicker(tester, current: const ModelChoice(providerId: kProviderId, modelId: 'big-cloud'));
    expect(find.text('On this device'), findsOneWidget);
    // The local section's badge says on device, never a host; only the
    // remote section names one.
    expect(find.text('On device'), findsOneWidget);
    expect(find.text('api.example.com'), findsOneWidget);
    expect(find.text('Small model'), findsOneWidget);
    expect(find.text('Huge model'), findsOneWidget);
    expect(find.text('Fits'), findsOneWidget);
    expect(find.text("Won't fit"), findsOneWidget);
    // The remote provider is still there.
    expect(find.text('Test Cloud'), findsOneWidget);
    expect(find.text('big-cloud'), findsOneWidget);

    // Won't fit: disabled, with the reason.
    final huge = find.bySemanticsLabel(RegExp(r'^Huge model\..*Not available'));
    expect(huge, findsOneWidget);
    final hugeRow = find.ancestor(of: find.text('Huge model'), matching: find.byType(InkWell));
    expect(tester.widget<InkWell>(hugeRow.first).onTap, isNull);
    await tester.tap(find.text('Huge model'));
    await tester.pumpAndSettle();
    expect(find.byType(ModelPickerSheet), findsOneWidget, reason: 'a disabled row does not pick');

    await tester.tap(find.text('Small model'));
    await tester.pumpAndSettle();
    expect(picked.single, const ModelChoice(providerId: localProviderId, modelId: 'small'));
  });

  testWidgets('rows are screen-reader buttons: a semantics tap picks, a disabled row offers no tap', (tester) async {
    await setUpRig(tester);
    var picked = await pumpPicker(tester);
    final huge = find.semantics.byLabel(RegExp(r'^Huge model\.')).evaluate().single;
    expect(huge.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
    expect(huge.getSemanticsData().flagsCollection.isButton, isTrue);

    tester.semantics.tap(find.semantics.byLabel(RegExp(r'^Small model\.')));
    await tester.pumpAndSettle();
    expect(picked.single, const ModelChoice(providerId: localProviderId, modelId: 'small'));

    // A remote row (the sheet's own _ModelRow) too.
    picked = await pumpPicker(tester);
    tester.semantics.tap(find.semantics.byLabel(RegExp(r'^big-cloud\.')));
    await tester.pumpAndSettle();
    expect(picked.single, const ModelChoice(providerId: kProviderId, modelId: 'big-cloud'));
  });

  testWidgets('an unavailable engine shows why and disables local models', (tester) async {
    await setUpRig(
      tester,
      host: () => FakeEngineHost()..startError = const EngineUnavailableException('no engine library in this build'),
    );
    final picked = await pumpPicker(tester);
    expect(find.text('On this device'), findsOneWidget);
    expect(find.textContaining('On-device models are unavailable: no engine library in this build'), findsWidgets);
    await tester.tap(find.text('Small model'));
    await tester.pumpAndSettle();
    expect(find.byType(ModelPickerSheet), findsOneWidget);
    // Remote models still work.
    await tester.tap(find.text('big-cloud'));
    await tester.pumpAndSettle();
    expect(picked.single, const ModelChoice(providerId: kProviderId, modelId: 'big-cloud'));
  });

  testWidgets('a crash report from the last run is shown in the section', (tester) async {
    await setUpRig(tester);
    // Simulate a report by restarting over a phase file left "loading".
    await tester.runAsync(() async {
      await rig.local.dispose();
      final f = EngineForensics(_engineDir(rig));
      await f.enter(PhaseRecord(phase: InferencePhase.loading, at: DateTime.utc(2026), modelId: 'small', modelName: 'Small model', nCtx: 8192));
      await f.flush();
    });
    // Built inside runAsync: its file-backed caches chain futures that must
    // not belong to the fake-async zone.
    late final LocalInference again;
    await tester.runAsync(() async {
      again = rig.newService();
      await again.start();
    });
    addTearDown(() => tester.runAsync(again.dispose));
    tester.view.physicalSize = const Size(420, 1000) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        providerRegistryProvider.overrideWithValue(LocalProviderRegistry(FakeProviderRegistry(), again)),
        localInferenceProvider.overrideWithValue(again),
        modelLibraryProvider.overrideWithValue(rig.library),
        modelStorageLayoutProvider.overrideWithValue(rig.layout),
        deviceProfileSourceProvider.overrideWithValue(FixedDeviceProfileSource(phone12gb)),
        localModelShapeProvider.overrideWith((ref, path) async => llama1bLikeShape),
      ],
      child: MaterialApp(theme: chatTestTheme(Brightness.light), home: const Scaffold(body: ModelPickerSheet())),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('Last time: The app was stopped'), findsOneWidget);
    expect(find.textContaining('while loading Small model (8192-token context)'), findsOneWidget);
  });

  testWidgets('without on-device inference wired there is no local section', (tester) async {
    await setUpRig(tester);
    await pumpPicker(tester, wired: false);
    expect(find.text('On this device'), findsNothing);
    expect(find.text('Test Cloud'), findsOneWidget);
  });
}

Directory _engineDir(LocalRig rig) => Directory('${rig.dir.path}/support/engine');
