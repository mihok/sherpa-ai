import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/features/models/state/local_model_fit.dart';
import 'package:sherpa/features/models/state/model_fit.dart';
import 'package:sherpa/services/downloads/downloads.dart';
import 'package:sherpa/services/inference/local_inference.dart';
import 'package:sherpa/services/inference/on_device_ids.dart';
import 'package:sherpa/services/inference/platform_models.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_hub/sherpa_hub.dart' show DevicePlatform, DeviceProfile, ModelFormat;

import '../../services/inference/support/local_rig.dart' show gib, libraryModel, llama1bLikeShape, phone12gb;
import '../../services/support/gguf_fixture.dart';

const phone4 = DeviceProfile(platform: DevicePlatform.android, totalRamBytes: 4 * gib);

void main() {
  group('assessLocalModel', () {
    test('a small model fits a 12 GB phone and can be chosen', () {
      final o = assessLocalModel(libraryModel('m1', sizeBytes: 807694464), device: phone12gb, shape: llama1bLikeShape);
      expect(o.fit, FitBadgeKind.fits);
      expect(o.selectable, isTrue);
      expect(o.fitReason, startsWith('Needs about'));
      expect(o.choice, const ModelChoice(providerId: localProviderId, modelId: 'm1'));
      expect(o.descriptor.providerId, localProviderId);
    });

    test("a model too big for the phone won't fit and is disabled with the reason", () {
      final o = assessLocalModel(libraryModel('big', sizeBytes: 9 * gib), device: phone4, shape: llama1bLikeShape);
      expect(o.fit, FitBadgeKind.wontFit);
      expect(o.selectable, isFalse);
      expect(o.unavailableReason, o.fitReason);
      expect(o.fitReason, isNotEmpty);
    });

    test('broken files are blocked; an unreadable header is unknown but selectable', () {
      final broken = assessLocalModel(libraryModel('b', issue: LibraryIssue.missingFiles), device: phone12gb, shape: llama1bLikeShape);
      expect(broken.fit, FitBadgeKind.blocked);
      expect(broken.unavailableReason, LibraryIssue.missingFiles.message);

      final unknown = assessLocalModel(libraryModel('u'), device: phone12gb, shape: null);
      expect(unknown.fit, FitBadgeKind.unknown);
      expect(unknown.fitReason, fitNotCheckedReason);
      expect(unknown.selectable, isTrue);
    });

    test('the warm model fits; an unavailable engine disables every model with its reason', () {
      final loaded = assessLocalModel(libraryModel('m1', sizeBytes: 9 * gib), device: phone4, shape: llama1bLikeShape, loadedModelId: 'm1');
      expect(loaded.fit, FitBadgeKind.fits);
      expect(loaded.loaded, isTrue);

      const engine = LocalEngineStatus(state: LocalEngineState.unavailable, reason: 'no engine in this build');
      final o = assessLocalModel(libraryModel('m1'), device: phone12gb, shape: llama1bLikeShape, engine: engine);
      expect(o.fit, FitBadgeKind.fits, reason: 'the fit is still shown');
      expect(o.selectable, isFalse);
      expect(o.unavailableReason, 'On-device models are unavailable: no engine in this build.');
    });
  });

  group('assessLocalModel: MLX and LiteRT', () {
    const iphone = DeviceProfile(platform: DevicePlatform.ios, totalRamBytes: 8 * gib, availableRamBytes: 5 * gib);
    const ready = EngineAvailability(EngineAvailabilityState.available, 'Ready.', code: 'none');
    const config = {
      'model_type': 'qwen3',
      'num_hidden_layers': 28,
      'num_attention_heads': 16,
      'num_key_value_heads': 8,
      'head_dim': 128,
      'max_position_embeddings': 40960,
    };

    test('an available MLX model is sized from its files and config.json, and routes to mlx', () {
      final m = libraryModel('q3', format: ModelFormat.mlx, sizeBytes: 335 << 20);
      final withConfig = assessLocalModel(m, device: iphone, shape: null, availability: ready, mlxConfig: config);
      final weightsOnly = assessLocalModel(m, device: iphone, shape: null, availability: ready);
      expect(withConfig.choice, const ModelChoice(providerId: mlxProviderId, modelId: 'q3'));
      expect(withConfig.descriptor.providerId, mlxProviderId);
      expect(withConfig.fit, FitBadgeKind.fits);
      expect(withConfig.selectable, isTrue);
      expect(withConfig.engineNote, 'Ready.');
      final kv = runtimeFootprintOf(m, mlxConfig: config).architecture;
      expect(kv, isNotNull);
      expect(weightsOnly.fit, FitBadgeKind.fits);
      expect(weightsOnly.fitReason, isNot(withConfig.fitReason), reason: 'the KV cache only counts with the config');
    });

    test("an MLX model too big for the phone won't fit and can't be chosen", () {
      final m = libraryModel('big', format: ModelFormat.mlx, sizeBytes: 9 * gib);
      final o = assessLocalModel(m, device: iphone, shape: null, availability: ready, mlxConfig: config);
      expect(o.fit, FitBadgeKind.wontFit);
      expect(o.unavailableReason, o.fitReason);
    });

    test("the engine's verdict blocks with its reason (MLX on Android, LiteRT on iOS, an NPU file)", () {
      const elsewhere = EngineAvailability.unsupported('MLX models run on iPhone and iPad only.', code: 'wrong_platform');
      final o = assessLocalModel(libraryModel('q3', format: ModelFormat.mlx), device: phone12gb, shape: null, availability: elsewhere);
      expect(o.fit, FitBadgeKind.blocked);
      expect(o.unavailableReason, 'MLX models run on iPhone and iPad only.');
      final unwired = assessLocalModel(libraryModel('g', format: ModelFormat.litert), device: phone12gb, shape: null);
      expect(unwired.unavailableReason, 'LiteRT-LM is not available in this build of Sherpa.');
      const incomplete = EngineAvailability(EngineAvailabilityState.downloadable, 'Some model files are missing; resume the download.');
      final partial = assessLocalModel(libraryModel('q3', format: ModelFormat.mlx), device: iphone, shape: null, availability: incomplete);
      expect(partial.fit, FitBadgeKind.unknown);
      expect(partial.selectable, isFalse);
    });

    test('LiteRT counts the file and its CPU weight cache', () {
      const runs = EngineAvailability(EngineAvailabilityState.available, 'Runs on GPU (falls back to CPU).', code: 'ok');
      final small = assessLocalModel(libraryModel('g', format: ModelFormat.litert, sizeBytes: 600 << 20),
          device: phone12gb, shape: null, availability: runs);
      expect(small.choice.providerId, liteRtProviderId);
      expect(small.fit, FitBadgeKind.fits);
      expect(small.engineNote, 'Runs on GPU (falls back to CPU).');
      final f = runtimeFootprintOf(libraryModel('g', format: ModelFormat.litert, sizeBytes: 600 << 20));
      expect(f.weightCacheBytes, 600 << 20);
      final big = assessLocalModel(libraryModel('g', format: ModelFormat.litert, sizeBytes: 3 * gib),
          device: phone4, shape: null, availability: runs);
      expect(big.fit, FitBadgeKind.wontFit);
    });
  });

  test('localModelShapeProvider reads an installed GGUF header; non-GGUF files give null', () async {
    final dir = await Directory.systemTemp.createTemp('sherpa_shape_');
    addTearDown(() => dir.delete(recursive: true));
    final gguf = File('${dir.path}/tiny.gguf')..writeAsBytesSync(syntheticGguf(totalBytes: 256 << 10));
    final junk = File('${dir.path}/junk.gguf')..writeAsStringSync('not a gguf');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final shape = await container.read(localModelShapeProvider(gguf.path).future);
    expect(shape, isNotNull);
    expect(shape!.architecture.layerCount, 16);
    expect(shape.architecture.trainContextLength, 8192);
    expect(await container.read(localModelShapeProvider(junk.path).future), isNull);
    expect(await container.read(localModelShapeProvider('${dir.path}/missing.gguf').future), isNull);
  });
}
