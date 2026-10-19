import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/features/models/state/local_model_fit.dart';
import 'package:sherpa/features/models/state/model_fit.dart';
import 'package:sherpa/services/downloads/downloads.dart';
import 'package:sherpa/services/inference/local_inference.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_hub/sherpa_hub.dart' show DevicePlatform, DeviceProfile;

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
