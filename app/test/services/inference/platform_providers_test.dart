import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/features/models/state/local_model_choice.dart';
import 'package:sherpa/services/inference/local_model_provider.dart';
import 'package:sherpa/services/inference/on_device_ids.dart';
import 'package:sherpa/services/inference/platform_model_specs.dart';
import 'package:sherpa/services/inference/platform_models.dart';
import 'package:sherpa/services/inference/runner_extras.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_apple_ml/sherpa_apple_ml.dart';
import 'package:sherpa_apple_ml/testing.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart' show DevicePlatform, ModelFormat;
import 'package:sherpa_litert/sherpa_litert.dart';
import 'package:sherpa_litert/testing.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import 'support/local_rig.dart';
import 'support/platform_rig.dart';

ModelRequest _ask(String model, String text, {String session = 's1'}) => ModelRequest(
      modelId: model,
      messages: [Message(id: 'u1', role: Role.user, content: [TextPart(text)], createdAt: DateTime.utc(2026))],
      cache: CacheHints(sessionId: session),
    );

Future<({List<ModelEvent> events, Object? error})> _collect(Stream<ModelEvent> s) async {
  final events = <ModelEvent>[];
  try {
    await for (final e in s) {
      events.add(e);
    }
    return (events: events, error: null);
  } on Object catch (e) {
    return (events: events, error: e);
  }
}

void main() {
  late PlatformRig rig;

  tearDown(() => rig.dispose());

  group('provider ids', () {
    setUp(() async => rig = await PlatformRig.create());

    test('every on-device id is reserved, on every platform', () async {
      for (final id in [localProviderId, ...platformProviderIds]) {
        final c = ProviderConfig(id: id, flavor: ApiFlavor.openAiChat, displayName: 'Mine', baseUrl: Uri.parse('https://x.example/v1'));
        expect(() => rig.registry.add(c), throwsStateError, reason: id);
        expect(() => rig.registry.update(c), throwsStateError, reason: id);
        expect(await rig.registry.hasApiKey(id), isFalse);
        await rig.registry.remove(id); // a no-op, never an error
      }
      expect(rig.registry.configs, isEmpty);
      expect(isOnDeviceProviderId('openai'), isFalse);
      expect(isForegroundOnlyProvider(geminiNanoProviderId), isTrue);
      expect(isForegroundOnlyProvider(appleFmProviderId), isFalse);
    });

    test('library routing: GGUF → local, MLX → mlx, LiteRT → litert_lm', () {
      expect(libraryProviderIdFor(ModelFormat.gguf), localProviderId);
      expect(libraryProviderIdFor(ModelFormat.mlx), mlxProviderId);
      expect(libraryProviderIdFor(ModelFormat.litert), liteRtProviderId);
      expect(libraryProviderIdFor(ModelFormat.onnx), isNull);
      expect(localModelChoice(libraryModel('g')), const ModelChoice(providerId: localProviderId, modelId: 'g'));
      expect(localModelChoice(libraryModel('m', format: ModelFormat.mlx)), const ModelChoice(providerId: mlxProviderId, modelId: 'm'));
      expect(localModelChoice(libraryModel('l', format: ModelFormat.litert)), const ModelChoice(providerId: liteRtProviderId, modelId: 'l'));
      expect(isLibraryModelFor(libraryModel('m', format: ModelFormat.mlx), mlxProviderId), isTrue);
      expect(isLibraryModelFor(libraryModel('m', format: ModelFormat.mlx), localProviderId), isFalse);
    });
  });

  group('iOS', () {
    setUp(() async => rig = await PlatformRig.create(platform: DevicePlatform.ios));

    test('mlx and apple_fm resolve; litert_lm and gemini_nano are unavailable with the reason', () async {
      final mlx = await rig.registry.resolve(mlxProviderId);
      expect(mlx, isA<OnDeviceEngineView>());
      expect((mlx as OnDeviceEngineView).inner, isA<MlxProvider>());
      expect(mlx.info.location, ExecutionLocation.onDevice);
      expect(await rig.registry.resolve(appleFmProviderId), isA<AppleFoundationModelsProvider>());

      final lm = await rig.registry.resolve(liteRtProviderId);
      expect(lm, isA<UnavailableOnDeviceProvider>());
      final r = await _collect(lm.stream(_ask('x', 'hi')));
      expect(r.error, isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.unsupported));
      expect((r.error! as ProviderException).message, 'LiteRT-LM models run on Android only.');
      expect(await rig.registry.models(liteRtProviderId), isEmpty);
      expect(await rig.registry.models(geminiNanoProviderId), isEmpty);
      expect(await rig.registry.probe(geminiNanoProviderId), EndpointStatus.error);
      expect(rig.providers.createdLiteRt, isNull, reason: 'never built off Android');
    });

    test('models(mlx) lists the library MLX models only; GGUF stays with local', () async {
      await rig.addMlx('q3');
      await rig.local.add(libraryModel('gguf1'));
      final mlx = await rig.registry.models(mlxProviderId);
      expect(mlx.map((m) => m.id), ['q3']);
      expect(mlx.single.providerId, mlxProviderId);
      expect(mlx.single.displayName, 'Qwen3 0.6B (MLX)');
      expect((await rig.registry.models(localProviderId)).map((m) => m.id), ['gguf1']);
    });

    test('the library stays in sync: added and deleted MLX models', () async {
      await rig.registry.models(mlxProviderId); // builds the provider
      final changes = <void>[];
      final sub = rig.registry.changes.listen(changes.add);
      addTearDown(sub.cancel);
      final m = await rig.addMlx('q3');
      await until(() => changes.isNotEmpty);
      expect(rig.providers.createdMlx!.models.map((s) => s.id), ['q3']);
      expect(rig.providers.createdMlx!.models.single.directory, rig.absolute(m));
      await rig.local.library.delete('q3');
      await until(() => rig.providers.createdMlx!.models.isEmpty);
    });

    test('a library MLX model chats through the fake Swift side', () async {
      await rig.addMlx('q3');
      rig.apple.onGenerate = (g) {
        g.text('Hello from MLX');
        g.info();
        g.finish();
      };
      final p = await rig.registry.resolve(mlxProviderId);
      final r = await _collect(p.stream(_ask('q3', 'hi')));
      expect(r.error, isNull);
      expect(r.events.whereType<TextDelta>().map((e) => e.text).join(), 'Hello from MLX');
      expect(rig.apple.loads.single.modelId, 'q3');
    });

    test('apple_fm lists the system model while available or downloadable, not when unsupported', () async {
      expect((await rig.registry.models(appleFmProviderId)).single.id, AppleFoundationModelsProvider.systemModelId);
      expect(await rig.registry.probe(appleFmProviderId), EndpointStatus.ok);

      rig.apple.fm = AmFmAvailability(
          available: false, reason: AmFmUnavailableReason.appleIntelligenceNotEnabled, localeSupported: true);
      // A fresh provider (the status is cached for a while).
      final other = await PlatformRig.create(apple: rig.apple);
      addTearDown(other.dispose);
      final listed = await other.registry.models(appleFmProviderId);
      expect(listed, hasLength(1), reason: 'downloadable: listed, with the reason as description');
      expect(listed.single.description, contains('Turn on Apple Intelligence'));
      expect(await other.registry.probe(appleFmProviderId), EndpointStatus.error);

      rig.apple.fm = AmFmAvailability(available: false, reason: AmFmUnavailableReason.deviceNotEligible, localeSupported: true);
      final third = await PlatformRig.create(apple: rig.apple);
      addTearDown(third.dispose);
      expect(await third.registry.models(appleFmProviderId), isEmpty);
    });
  });

  group('Android', () {
    setUp(() async => rig = await PlatformRig.create(platform: DevicePlatform.android));

    test('litert_lm and gemini_nano resolve; mlx and apple_fm are unavailable', () async {
      final lm = await rig.registry.resolve(liteRtProviderId);
      expect((lm as OnDeviceEngineView).inner, isA<LiteRtLmProvider>());
      expect(await rig.registry.resolve(geminiNanoProviderId), isA<GeminiNanoProvider>());
      final mlx = await rig.registry.resolve(mlxProviderId);
      expect(mlx, isA<UnavailableOnDeviceProvider>());
      expect(mlx.info.displayName, 'On this device (MLX)');
      expect(await rig.registry.models(mlxProviderId), isEmpty);
      expect(await rig.registry.models(appleFmProviderId), isEmpty);
      expect(rig.providers.createdMlx, isNull);
      expect(rig.apple.loads, isEmpty);
    });

    test('models(litert_lm) lists LiteRT library models; MLX ones stay blocked here', () async {
      await rig.addLiteRt('g1');
      await rig.addMlx('q3');
      expect((await rig.registry.models(liteRtProviderId)).map((m) => m.id), ['g1']);
      expect(await rig.registry.models(mlxProviderId), isEmpty);
      final registered = rig.providers.createdLiteRt!.models.single;
      expect(registered.path, rig.absolute(rig.local.library.byId('g1')!));
      expect(registered.vision, isFalse);
    });

    test('gemini_nano is listed when available or downloadable, never while downloading or unsupported', () async {
      expect((await rig.registry.models(geminiNanoProviderId)).single.id, GeminiNanoProvider.modelId);
      rig.litert.nano = NanoStatusMsg(featureStatus: NanoFeatureStatus.downloadable);
      expect(await rig.registry.models(geminiNanoProviderId), hasLength(1));
      rig.litert.nano = NanoStatusMsg(featureStatus: NanoFeatureStatus.downloading);
      expect(await rig.registry.models(geminiNanoProviderId), isEmpty);
      rig.litert.nano = NanoStatusMsg(featureStatus: NanoFeatureStatus.unavailable);
      expect(await rig.registry.models(geminiNanoProviderId), isEmpty);
    });

    test('a LiteRT model streams through the fake Kotlin side', () async {
      await rig.addLiteRt('g1');
      rig.litert.scripts.add((s) {
        s.text('Hi from LiteRT');
        s.done();
      });
      final r = await _collect((await rig.registry.resolve(liteRtProviderId)).stream(_ask('g1', 'hi')));
      expect(r.error, isNull);
      expect(r.events.whereType<TextDelta>().map((e) => e.text).join(), 'Hi from LiteRT');
    });
  });

  test('elsewhere (desktop, host tests) every platform provider is unavailable', () async {
    rig = await PlatformRig.create(platform: DevicePlatform.other);
    for (final id in platformProviderIds) {
      expect(await rig.registry.resolve(id), isA<UnavailableOnDeviceProvider>(), reason: id);
      expect(await rig.registry.models(id), isEmpty);
      expect((await rig.providers.systemStatus(id)).state, EngineAvailabilityState.unsupported);
    }
  });

  group('availability', () {
    test('MLX: complete → available, incomplete → downloadable, on Android → unsupported', () async {
      rig = await PlatformRig.create(platform: DevicePlatform.ios);
      final ok = await rig.addMlx('ok');
      final partial = await rig.addMlx('partial', complete: false);
      final a = (await rig.providers.modelAvailability(ok))!;
      expect(a.state, EngineAvailabilityState.available);
      expect(a.details['contextLength'], isNotNull);
      final b = (await rig.providers.modelAvailability(partial))!;
      expect(b.state, EngineAvailabilityState.downloadable);
      expect(b.reason, contains('missing'));
      expect(await rig.providers.modelAvailability(libraryModel('gguf')), isNull, reason: "llama.cpp's own status applies");

      rig.apple.platform = FakeAppleMlBackend.iosDevice(simulator: true);
      expect((await rig.providers.modelAvailability(ok))!.reason, contains('Simulator'));

      final android = await PlatformRig.create(platform: DevicePlatform.android);
      addTearDown(android.dispose);
      final elsewhere = (await android.providers.modelAvailability(await android.addMlx('q')))!;
      expect(elsewhere.state, EngineAvailabilityState.unsupported);
      expect(elsewhere.reason, 'MLX models run on iPhone and iPad only.');
    });

    test('LiteRT: the backend plan, a missing file, an NPU file for another chip', () async {
      rig = await PlatformRig.create(platform: DevicePlatform.android);
      final g = await rig.addLiteRt('g1');
      final ok = (await rig.providers.modelAvailability(g))!;
      expect(ok.isAvailable, isTrue);
      expect(ok.reason, 'Runs on GPU (falls back to CPU).');

      final npu = await rig.addLiteRt('npu',
          info: FakeLiteRtBackend.modelInfo(backends: const ['npu'], npuBrand: 'qualcomm', socName: 'SM8750'));
      final wrong = (await rig.providers.modelAvailability(npu))!;
      expect(wrong.state, EngineAvailabilityState.unsupported);
      expect(wrong.code, 'wrong_soc');

      rig.litert.models.remove(rig.absolute(g));
      final missing = (await rig.providers.modelAvailability(g))!;
      expect(missing.code, 'file_missing');

      final ios = await PlatformRig.create(platform: DevicePlatform.ios);
      addTearDown(ios.dispose);
      expect((await ios.providers.modelAvailability(await ios.addLiteRt('x')))!.reason, 'LiteRT-LM models run on Android only.');
    });

    test('system models: Apple Intelligence off is downloadable; Gemini Nano states map one to one', () async {
      rig = await PlatformRig.create(platform: DevicePlatform.ios);
      expect((await rig.providers.systemStatus(appleFmProviderId)).isAvailable, isTrue);
      rig.apple.fm = AmFmAvailability(
          available: false, reason: AmFmUnavailableReason.appleIntelligenceNotEnabled, localeSupported: true);
      final off = await rig.providers.systemStatus(appleFmProviderId);
      expect(off.state, EngineAvailabilityState.downloadable);
      expect(off.code, 'appleIntelligenceNotEnabled');
      expect((await rig.providers.systemStatus(geminiNanoProviderId)).reason, 'Gemini Nano runs on Android only.');

      final android = await PlatformRig.create(platform: DevicePlatform.android);
      addTearDown(android.dispose);
      Future<EngineAvailability> nano(NanoStatusMsg s) {
        android.litert.nano = s;
        return android.providers.systemStatus(geminiNanoProviderId);
      }

      expect((await nano(NanoStatusMsg(featureStatus: NanoFeatureStatus.available))).state, EngineAvailabilityState.available);
      expect((await nano(NanoStatusMsg(featureStatus: NanoFeatureStatus.downloadable))).state, EngineAvailabilityState.downloadable);
      expect((await nano(NanoStatusMsg(featureStatus: NanoFeatureStatus.downloading))).state, EngineAvailabilityState.downloading);
      final unsupported = await nano(NanoStatusMsg(
          featureStatus: NanoFeatureStatus.unavailable,
          error: ErrorMsg(source: 'nano', code: NanoErrorCode.featureNotFound, message: 'FEATURE_NOT_FOUND')));
      expect(unsupported.state, EngineAvailabilityState.unsupported);
      expect(unsupported.code, 'feature_not_found');
      expect(unsupported.reason, contains('unlocked bootloader'));
    });
  });

  group('lifecycle glue', () {
    test('forgetConversation drops the native sessions of every engine that exists', () async {
      rig = await PlatformRig.create(platform: DevicePlatform.ios);
      await rig.addMlx('q3');
      await rig.registry.resolve(mlxProviderId);
      await rig.registry.resolve(appleFmProviderId);
      await rig.providers.forgetConversation('chat-1');
      expect(rig.apple.drops, containsAll([(AmEngine.mlx, 'chat-1'), (AmEngine.foundationModels, 'chat-1')]));

      final android = await PlatformRig.create(platform: DevicePlatform.android);
      addTearDown(android.dispose);
      await android.addLiteRt('g1');
      await _collect((await android.registry.resolve(liteRtProviderId)).stream(_ask('g1', 'hi', session: 'chat-2')));
      final conversation = android.litert.opened.single.conversationId;
      await android.providers.forgetConversation('chat-2');
      expect(android.litert.closed, [conversation]);
    });

    test('thermal critical pauses MLX once per episode; nothing is built to do it', () async {
      rig = await PlatformRig.create(platform: DevicePlatform.ios);
      await rig.providers.onThermal(ThermalLevel.critical);
      expect(rig.apple.interrupts, isEmpty, reason: 'MLX was never created');
      await rig.registry.resolve(mlxProviderId);
      await rig.providers.onThermal(ThermalLevel.serious);
      await rig.providers.onThermal(ThermalLevel.critical);
      await rig.providers.onThermal(ThermalLevel.critical);
      expect(rig.apple.interrupts, ['thermal_critical']);
      await rig.providers.onThermal(ThermalLevel.fair);
      await rig.providers.onThermal(ThermalLevel.critical);
      expect(rig.apple.interrupts, ['thermal_critical', 'thermal_critical']);
    });

    test('a running MLX reply pauses on the thermal interrupt (Finish(pause))', () async {
      rig = await PlatformRig.create(platform: DevicePlatform.ios);
      await rig.addMlx('q3');
      rig.apple.onGenerate = (g) => g.text('Partial');
      final p = await rig.registry.resolve(mlxProviderId);
      final done = _collect(p.stream(_ask('q3', 'hi')));
      await until(() => rig.apple.generations.isNotEmpty);
      await rig.providers.onThermal(ThermalLevel.critical);
      final r = await done;
      final finish = r.events.whereType<Finish>().single;
      expect(finish.reason, FinishReason.pause);
      expect(finish.rawReason, 'thermal_critical');
    });

    test('one engine holds weights: MLX frees llama.cpp first, llama.cpp frees MLX', () async {
      rig = await PlatformRig.create(platform: DevicePlatform.ios);
      var claims = 0;
      rig.providers.onClaimInAppEngine = () async => claims++;
      rig.apple.onGenerate = (g) => g
        ..text('ok')
        ..finish();
      await rig.addMlx('q3');
      final p = await rig.registry.resolve(mlxProviderId);
      await _collect(p.stream(_ask('q3', 'hi')));
      expect(claims, 1);
      expect(rig.providers.createdMlx!.loaded, isNotNull);
      await rig.providers.releaseForLlama();
      expect(rig.apple.unloads, ['q3']);
      await rig.providers.releaseForLlama();
      expect(rig.apple.unloads, ['q3'], reason: 'nothing loaded, nothing to free');
    });
  });

  group('runner extras', () {
    test('platform chats summarize with their own model; no priority, no exact counter', () async {
      rig = await PlatformRig.create(platform: DevicePlatform.android);
      await rig.addLiteRt('g1');
      for (final id in [liteRtProviderId, geminiNanoProviderId]) {
        final p = await rig.registry.resolve(id);
        final e = localRunnerExtras(p, ModelChoice(providerId: id, modelId: 'g1'), LadderContextManager());
        expect(e.counter, isNull);
        final s = modelSummarizerOf(e.contextManager!)!;
        expect(s.provider, same(p), reason: 'system providers ignore priority: the view is the provider itself');
        expect(s.modelId, 'g1');
      }
      expect(backgroundView(await rig.registry.resolve(geminiNanoProviderId)), isA<GeminiNanoProvider>());
      expect(isPlatformOnDeviceProvider(await rig.registry.resolve('mlx')), isFalse, reason: 'unavailable here');
    });

    test('a Gemini Nano summary in the background is refused before AICore and the ladder falls back', () async {
      rig = await PlatformRig.create(platform: DevicePlatform.android, foreground: false);
      final nano = await rig.registry.resolve(geminiNanoProviderId);
      final r = await _collect(nano.stream(_ask(GeminiNanoProvider.modelId, 'summarize')));
      expect(r.error, isA<ProviderException>().having((e) => e.message, 'message', kNanoBackgroundMessage));
      expect(rig.litert.nanoRequests, isEmpty, reason: 'nothing reached AICore');
    });

    test('the local llama.cpp provider still gets its exact counter', () async {
      rig = await PlatformRig.create(platform: DevicePlatform.ios);
      await rig.local.add(libraryModel('m1'));
      final p = await rig.registry.resolve(localProviderId);
      expect(p, isA<LocalModelProvider>());
      final e = localRunnerExtras(p, const ModelChoice(providerId: localProviderId, modelId: 'm1'), LadderContextManager());
      expect(e.counter, isNotNull);
    });
  });

  test('the llama.cpp side frees the platform engine before it loads', () async {
    rig = await PlatformRig.create(platform: DevicePlatform.ios);
    await rig.addMlx('q3');
    await rig.local.add(libraryModel('m1'));
    rig.local.local.beforeRequest = rig.providers.releaseForLlama;
    rig.apple.onGenerate = (g) => g
      ..text('ok')
      ..finish();
    await _collect((await rig.registry.resolve(mlxProviderId)).stream(_ask('q3', 'hi')));
    expect(rig.providers.createdMlx!.loaded, isNotNull);
    expect(await replyText(await rig.registry.resolve(localProviderId), 'm1', 'hi'), 'ok');
    expect(rig.apple.unloads, ['q3']);
    expect(rig.providers.createdMlx!.loaded, isNull);
  });
}

Future<void> until(bool Function() test, {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!test()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}
