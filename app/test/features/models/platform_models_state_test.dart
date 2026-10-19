import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/features/models/state/local_inference_providers.dart';
import 'package:sherpa/features/models/state/local_model_fit.dart';
import 'package:sherpa/features/models/state/models_providers.dart';
import 'package:sherpa/features/models/state/platform_models_providers.dart';
import 'package:sherpa/services/device/device_profile_source.dart';
import 'package:sherpa/services/inference/on_device_ids.dart';
import 'package:sherpa/services/inference/platform_models.dart';
import 'package:sherpa/state/app_providers.dart';
import 'package:sherpa/state/observable_session_store.dart';
import 'package:sherpa/state/providers.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa/state/sessions.dart';
import 'package:sherpa_apple_ml/testing.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart' show DevicePlatform, DeviceProfile;
import 'package:sherpa_litert/sherpa_litert.dart';

import '../../services/inference/support/local_rig.dart' show gib, libraryModel;
import '../../services/inference/support/platform_rig.dart';

const _ios8 = DeviceProfile(platform: DevicePlatform.ios, totalRamBytes: 8 * gib, availableRamBytes: 5 * gib);
const _android12 = DeviceProfile(platform: DevicePlatform.android, totalRamBytes: 12 * gib, availableRamBytes: 7 * gib);

ProviderContainer _container(PlatformRig rig, {DeviceProfile device = _ios8, ObservableSessionStore? store}) {
  final c = ProviderContainer(overrides: [
    modelRecordStoreProvider.overrideWithValue(rig.local.records),
    modelStorageLayoutProvider.overrideWithValue(rig.layout),
    modelLibraryProvider.overrideWithValue(rig.local.library),
    localInferenceProvider.overrideWithValue(rig.local.local),
    platformModelProvidersProvider.overrideWithValue(rig.providers),
    providerRegistryProvider.overrideWithValue(rig.registry),
    deviceProfileSourceProvider.overrideWithValue(FixedDeviceProfileSource(device)),
    sessionStoreProvider.overrideWithValue(store ?? ObservableSessionStore(InMemorySessionStore())),
    // What bootstrap composes next to MCP's hooks.
    sessionDeletedHooksProvider.overrideWith((ref) => ref.watch(onDeviceSessionDeletedHooksProvider)),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  late PlatformRig rig;
  tearDown(() => rig.dispose());

  test('deleting a chat forgets it on every on-device engine (through sessionDeletedHooksProvider)', () async {
    rig = await PlatformRig.create(platform: DevicePlatform.ios);
    await rig.addMlx('q3');
    final store = ObservableSessionStore(InMemorySessionStore());
    final c = _container(rig, store: store);
    final chat = await c.read(sessionActionsProvider).create(model: const ModelChoice(providerId: mlxProviderId, modelId: 'q3'));
    rig.apple.onGenerate = (g) => g
      ..text('hi')
      ..finish();
    final mlx = await rig.registry.resolve(mlxProviderId);
    await mlx
        .stream(ModelRequest(
          modelId: 'q3',
          messages: [Message(id: 'u', role: Role.user, content: const [TextPart('hello')], createdAt: DateTime.utc(2026))],
          cache: CacheHints(sessionId: chat.id),
        ))
        .drain<void>();
    await rig.registry.resolve(appleFmProviderId);

    final pending = c.read(sessionActionsProvider).deleteWithUndo(chat.id);
    expect(rig.apple.drops, isEmpty, reason: 'nothing is forgotten during the undo window');
    await pending.commit();
    expect(rig.apple.drops, containsAll([(AmEngine.mlx, chat.id), (AmEngine.foundationModels, chat.id)]));
  });

  test('an undone delete forgets nothing', () async {
    rig = await PlatformRig.create(platform: DevicePlatform.ios);
    final c = _container(rig);
    final chat = await c.read(sessionActionsProvider).create(model: const ModelChoice(providerId: appleFmProviderId, modelId: 'apple-system'));
    await rig.registry.resolve(appleFmProviderId);
    await c.read(sessionActionsProvider).deleteWithUndo(chat.id).undo();
    expect(rig.apple.drops, isEmpty);
  });

  test('Gemini Nano download: progress, completion, and the status refreshes', () async {
    rig = await PlatformRig.create(platform: DevicePlatform.android);
    rig.litert.nano = NanoStatusMsg(featureStatus: NanoFeatureStatus.downloadable);
    final c = _container(rig, device: _android12);
    expect((await c.read(systemModelStatusProvider(geminiNanoProviderId).future))!.state, EngineAvailabilityState.downloadable);
    final keep = c.listen(systemModelStatusProvider(geminiNanoProviderId), (_, _) {});
    addTearDown(keep.close);

    final release = Completer<void>();
    rig.litert.scripts.add((s) async {
      s.batch([LiteRtEvent(kind: EventKind.downloadStarted, value: 1000)]);
      s.batch([LiteRtEvent(kind: EventKind.downloadProgress, value: 400)]);
      await release.future;
      rig.litert.nano = NanoStatusMsg(featureStatus: NanoFeatureStatus.available, baseModelName: 'nano-v3');
      s.batch([LiteRtEvent(kind: EventKind.downloadCompleted)]);
    });
    final seen = <NanoDownloadState>[];
    final sub = c.listen(nanoDownloadProvider, (_, next) => seen.add(next));
    addTearDown(sub.close);
    final changes = <void>[];
    final ch = rig.providers.modelChanges.listen(changes.add);
    addTearDown(ch.cancel);

    final done = c.read(nanoDownloadProvider.notifier).start();
    await until(() => seen.any((s) => s.fraction == 0.4));
    final mid = seen.lastWhere((s) => s.fraction == 0.4);
    expect(mid.running, isTrue);
    expect(mid.downloadedBytes, 400);
    expect(mid.totalBytes, 1000);
    release.complete();
    await done;
    expect(c.read(nanoDownloadProvider).running, isFalse);
    expect(c.read(nanoDownloadProvider).error, isNull);
    expect(changes, isNotEmpty, reason: 'pickers re-list once it is there');
    expect((await c.read(systemModelStatusProvider(geminiNanoProviderId).future))!.isAvailable, isTrue);
    expect((await c.read(systemModelOptionsProvider.future)).single.selectable, isTrue);
  });

  test('a failed Nano download says why', () async {
    rig = await PlatformRig.create(platform: DevicePlatform.android);
    rig.litert.nano = NanoStatusMsg(featureStatus: NanoFeatureStatus.downloadable);
    final c = _container(rig, device: _android12);
    rig.litert.scripts.add((s) => s.batch([
          LiteRtEvent(kind: EventKind.downloadFailed, error: ErrorMsg(source: 'nano', code: 501, message: 'disk full')),
        ]));
    await c.read(nanoDownloadProvider.notifier).start();
    expect(c.read(nanoDownloadProvider).error, isNotNull);
    expect(c.read(nanoDownloadProvider).running, isFalse);
  });

  group('app providers treat every on-device id as on device', () {
    test('privacy, names and the on-device model list', () async {
      rig = await PlatformRig.create(platform: DevicePlatform.android);
      await rig.addLiteRt('g1', name: 'Gemma 3 1B');
      await rig.local.add(libraryModel('m1', name: 'Qwen3 0.6B'));
      final c = _container(rig, device: _android12);
      for (final id in onDeviceProviderIds) {
        expect(c.read(providerPrivacyProvider(id))?.location, ExecutionLocation.onDevice, reason: id);
      }
      expect(c.read(providerDisplayNameProvider(liteRtProviderId)), 'On this device (LiteRT)');
      expect(c.read(providerDisplayNameProvider(geminiNanoProviderId)), 'Gemini Nano');
      final all = await c.read(localModelsProvider.future);
      expect({for (final m in all) (m.providerId, m.id)}, {
        (localProviderId, 'm1'),
        (liteRtProviderId, 'g1'),
        (geminiNanoProviderId, GeminiNanoProvider.modelId),
      });
      expect(c.read(modelDisplayNameProvider(const ModelChoice(providerId: liteRtProviderId, modelId: 'g1'))), 'Gemma 3 1B');
      expect(c.read(modelDisplayNameProvider(const ModelChoice(providerId: localProviderId, modelId: 'g1'))), 'g1',
          reason: 'the provider is part of the key');
    });
  });

  group('picker options', () {
    test('MLX on iOS: availability and fit from config.json; LiteRT here is blocked with the reason', () async {
      rig = await PlatformRig.create(platform: DevicePlatform.ios);
      await rig.addMlx('q3');
      await rig.addLiteRt('g1');
      final c = _container(rig);
      // Listened, as the picker does (an unlistened provider is paused).
      final keep = c.listen(localModelOptionsProvider, (_, _) {});
      addTearDown(keep.close);
      final options = await c.read(localModelOptionsProvider.future);
      final mlx = options.firstWhere((o) => o.model.id == 'q3');
      expect(mlx.choice.providerId, mlxProviderId);
      expect(mlx.selectable, isTrue);
      expect(mlx.engineNote, 'Ready.');
      expect(mlx.fitReason, startsWith('Needs about'));
      final lite = options.firstWhere((o) => o.model.id == 'g1');
      expect(lite.selectable, isFalse);
      expect(lite.unavailableReason, 'LiteRT-LM models run on Android only.');
      final system = await c.read(systemModelOptionsProvider.future);
      expect(system.single.providerId, appleFmProviderId);
      expect(system.single.foregroundOnly, isFalse);
    });

    test('Gemini Nano is offered as on-screen only; a downloadable one is disabled with what to do', () async {
      rig = await PlatformRig.create(platform: DevicePlatform.android);
      final c = _container(rig, device: _android12);
      final ready = (await c.read(systemModelOptionsProvider.future)).single;
      expect(ready.foregroundOnly, isTrue);
      expect(ready.selectable, isTrue);
      expect(ready.name, 'Gemini Nano (nano-v3)');

      rig.litert.nano = NanoStatusMsg(featureStatus: NanoFeatureStatus.downloadable);
      c.invalidate(systemModelStatusProvider(geminiNanoProviderId));
      final later = (await c.read(systemModelOptionsProvider.future)).single;
      expect(later.selectable, isFalse);
      expect(later.unavailableReason, 'Download Gemini Nano in Models & downloads first.');

      rig.litert.nano = NanoStatusMsg(featureStatus: NanoFeatureStatus.unavailable);
      c.invalidate(systemModelStatusProvider(geminiNanoProviderId));
      expect(await c.read(systemModelOptionsProvider.future), isEmpty, reason: 'unsupported here: not offered');
    });
  });
}

Future<void> until(bool Function() test, {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!test()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}
