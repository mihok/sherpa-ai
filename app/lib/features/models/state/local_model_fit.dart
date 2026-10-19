import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart';

import '../../../services/device/device_profile_source.dart';
import '../../../services/downloads/model_library.dart';
import '../../../services/inference/local_inference.dart';
import '../../../services/inference/local_model_specs.dart';
import '../../../state/services.dart' show ModelChoice;
import 'local_inference_providers.dart';
import 'local_model_choice.dart';
import 'model_fit.dart';
import 'models_providers.dart';

/// One installed model as the model picker offers it: what it can do, how
/// it fits this device right now, and why it can't be chosen (if so).
@immutable
final class LocalModelOption {
  const LocalModelOption({
    required this.model,
    required this.descriptor,
    required this.fit,
    required this.fitReason,
    this.unavailableReason,
    this.loaded = false,
  });

  final LibraryModel model;
  final ModelDescriptor descriptor;

  /// Fits / Tight / Won't fit (or unknown / blocked), same vocabulary as the
  /// download screens ([FitBadgeKind]).
  final FitBadgeKind fit;

  /// The sentence under the badge.
  final String fitReason;

  /// Why the model can't be picked right now: Won't fit, broken files, the
  /// engine is unavailable. Null = selectable.
  final String? unavailableReason;

  /// It is the warm model.
  final bool loaded;

  bool get selectable => unavailableReason == null;

  ModelChoice get choice => localModelChoice(model);
}

/// The fit of an installed model on [device], from its GGUF header
/// [shape] (the same estimate the Hub browser and the importer use). Pure.
LocalModelOption assessLocalModel(
  LibraryModel m, {
  required DeviceProfile? device,
  required ModelShape? shape,
  LocalEngineStatus? engine,
  String? loadedModelId,
  FitOptions options = const FitOptions(),
}) {
  final descriptor = localModelDescriptor(m);
  if (!isRunnableLocally(m)) {
    final why = m.usable ? 'Only GGUF models run on this device.' : m.issue.message;
    return LocalModelOption(model: m, descriptor: descriptor, fit: FitBadgeKind.blocked, fitReason: why, unavailableReason: why);
  }
  final engineReason = engine?.unavailableMessage;
  if (loadedModelId == m.id) {
    return LocalModelOption(
      model: m,
      descriptor: descriptor,
      fit: FitBadgeKind.fits,
      fitReason: 'Loaded and ready on this device.',
      unavailableReason: engineReason,
      loaded: true,
    );
  }
  if (device == null || shape == null) {
    return LocalModelOption(
      model: m,
      descriptor: descriptor,
      fit: FitBadgeKind.unknown,
      fitReason: fitNotCheckedReason,
      unavailableReason: engineReason,
    );
  }
  int bytesOf(FileRole role) => m.files.where((f) => f.role == role).fold(0, (a, f) => a + f.sizeBytes);
  final fit = assessFit(
    device,
    ModelFootprintInput(
      architecture: shape.architecture,
      weightBytes: bytesOf(FileRole.model),
      mmprojBytes: bytesOf(FileRole.mmproj),
      quant: shape.metadata.fileTypeInfo,
      label: m.quant,
    ),
    options: options,
    computeMaxContext: false,
  );
  final kind = FitBadgeKind.of(fit.verdict);
  final reason = fitReasonText(fit);
  return LocalModelOption(
    model: m,
    descriptor: descriptor,
    fit: kind,
    fitReason: reason,
    unavailableReason: engineReason ?? (kind == FitBadgeKind.wontFit ? reason : null),
  );
}

/// Reads an installed GGUF's header once per file (2–8 MB from disk):
/// architecture and exact parameter count. Null when it can't be read.
final localModelShapeProvider = FutureProvider.family<ModelShape?, String>((ref, absolutePath) async {
  try {
    final info = await readLocalGgufHeader(absolutePath);
    final arch = ModelArchitecture.fromGguf(info.metadata, parameterCount: info.header.parameterCount);
    if (arch == null) return null;
    return ModelShape(architecture: arch, metadata: info.metadata, parameterCount: info.header.parameterCount);
  } on Object {
    return null;
  }
});

/// The picker's "On this device" list: every installed model with its fit
/// on this device right now (fresh memory reading each time the picker
/// opens) and whether it can be chosen. Empty when local inference is not
/// wired.
final localModelOptionsProvider = FutureProvider.autoDispose<List<LocalModelOption>>((ref) async {
  final local = ref.watch(localInferenceProvider);
  if (local == null) return const [];
  final status = ref.watch(localEngineStatusProvider).value ?? local.status;
  final models = await ref.watch(localLibraryModelsProvider.future);
  final layout = ref.watch(modelStorageLayoutProvider);
  DeviceProfile? device;
  try {
    device = await ref.watch(deviceProfileSourceProvider).current();
  } on Object {
    device = null;
  }
  final out = <LocalModelOption>[];
  for (final m in models) {
    ModelShape? shape;
    if (isRunnableLocally(m)) {
      try {
        shape = await ref.watch(localModelShapeProvider(layout.libraryPath(m.loadPath)).future);
      } on Object {
        shape = null;
      }
    }
    out.add(assessLocalModel(m, device: device, shape: shape, engine: status, loadedModelId: local.loadedModelId));
  }
  return out;
});
