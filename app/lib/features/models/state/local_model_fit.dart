import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sherpa_apple_ml/sherpa_apple_ml.dart' show AppleFoundationModelsProvider;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart';
import 'package:sherpa_litert/sherpa_litert.dart' show GeminiNanoProvider;

import '../../../services/device/device_profile_source.dart';
import '../../../services/downloads/model_library.dart';
import '../../../services/downloads/storage_layout.dart';
import '../../../services/inference/local_inference.dart';
import '../../../services/inference/local_model_specs.dart';
import '../../../services/inference/on_device_ids.dart';
import '../../../services/inference/platform_models.dart';
import '../../../state/providers.dart';
import '../../../state/services.dart' show ModelChoice;
import 'local_inference_providers.dart';
import 'local_model_choice.dart';
import 'model_fit.dart';
import 'models_providers.dart';
import 'platform_models_providers.dart';

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
    this.engineNote,
  });

  final LibraryModel model;
  final ModelDescriptor descriptor;

  /// Fits / Tight / Won't fit (or unknown / blocked), same vocabulary as the
  /// download screens ([FitBadgeKind]).
  final FitBadgeKind fit;

  /// The sentence under the badge.
  final String fitReason;

  /// Why the model can't be picked right now: Won't fit, broken files, the
  /// engine is unavailable or can't run it here (MLX on Android, an NPU
  /// file for another chip…). Null = selectable.
  final String? unavailableReason;

  /// It is the warm model.
  final bool loaded;

  /// What the platform engine said about an available model ("Runs on GPU
  /// (falls back to CPU).").
  final String? engineNote;

  bool get selectable => unavailableReason == null;

  /// GGUF → `local`, MLX → `mlx`, LiteRT → `litert_lm`.
  ModelChoice get choice => localModelChoice(model);
}

/// What the picker knows about a platform (MLX / LiteRT) library model
/// before it loads; the provider's own listing replaces it once loaded.
ModelDescriptor platformModelDescriptor(LibraryModel m) {
  final provider = libraryProviderIdFor(m.format) ?? localProviderId;
  return ModelDescriptor(
    id: m.id,
    providerId: provider,
    displayName: m.displayName,
    capabilities: ModelCapabilities(
      contextLength: preferredLocalContext(m),
      // Both parse calls from the model's own template output.
      toolCallFormat: ToolCallFormat.prompted,
      parallelToolCalls: false,
      reasoning: m.reasoning ? ReasoningSupport.optional : ReasoningSupport.none,
      quantization: m.quant,
      parameterCount: m.parameterCount,
      supportsPromptCache: true,
      historyPolicy: HistoryPolicy.appendOnly,
    ),
    description: m.repo,
  );
}

/// The fit of an installed model on [device] (the same estimates the Hub
/// browser uses). Pure.
///
/// * GGUF: from its header [shape] (llama.cpp's estimate), unavailable
///   when [engine] (llama.cpp) is.
/// * MLX / LiteRT: [availability] is the platform engine's verdict
///   (`MlxProvider.availability`, `LiteRtLmProvider.availability`); null =
///   the platform engines are not wired. When available, the fit is
///   [assessRuntimeFit]: MLX weights from the files and KV from
///   [mlxConfig] (the library's `config.json`), LiteRT the file plus its
///   CPU weight cache.
LocalModelOption assessLocalModel(
  LibraryModel m, {
  required DeviceProfile? device,
  required ModelShape? shape,
  LocalEngineStatus? engine,
  String? loadedModelId,
  FitOptions options = const FitOptions(),
  EngineAvailability? availability,
  Map<String, Object?>? mlxConfig,
}) {
  final provider = libraryProviderIdFor(m.format);
  if (provider == mlxProviderId || provider == liteRtProviderId) {
    return _assessPlatformModel(m, provider!, device: device, availability: availability, mlxConfig: mlxConfig, options: options);
  }
  final descriptor = localModelDescriptor(m);
  if (!isRunnableLocally(m)) {
    final why = m.usable ? 'Sherpa has no on-device runtime for ${m.format.name} files.' : m.issue.message;
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
  final fit = assessFit(
    device,
    ModelFootprintInput(
      architecture: shape.architecture,
      weightBytes: _bytesOf(m, FileRole.model),
      mmprojBytes: _bytesOf(m, FileRole.mmproj),
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

int _bytesOf(LibraryModel m, FileRole role) => m.files.where((f) => f.role == role).fold(0, (a, f) => a + f.sizeBytes);

LocalModelOption _assessPlatformModel(
  LibraryModel m,
  String provider, {
  required DeviceProfile? device,
  required EngineAvailability? availability,
  required Map<String, Object?>? mlxConfig,
  required FitOptions options,
}) {
  final descriptor = platformModelDescriptor(m);
  final engineName = provider == mlxProviderId ? 'MLX' : 'LiteRT-LM';
  if (!m.usable) {
    return LocalModelOption(
      model: m,
      descriptor: descriptor,
      fit: FitBadgeKind.blocked,
      fitReason: m.issue.message,
      unavailableReason: m.issue.message,
    );
  }
  if (availability == null || !availability.isAvailable) {
    final why = availability?.reason ?? '$engineName is not available in this build of Sherpa.';
    return LocalModelOption(
      model: m,
      descriptor: descriptor,
      fit: availability?.state == EngineAvailabilityState.downloadable ? FitBadgeKind.unknown : FitBadgeKind.blocked,
      fitReason: why,
      unavailableReason: why,
    );
  }
  if (device == null) {
    return LocalModelOption(
      model: m,
      descriptor: descriptor,
      fit: FitBadgeKind.unknown,
      fitReason: fitNotCheckedReason,
      engineNote: availability.reason,
    );
  }
  final fit = assessRuntimeFit(device, runtimeFootprintOf(m, mlxConfig: mlxConfig), options: options, computeMaxContext: false);
  final kind = FitBadgeKind.of(fit.verdict);
  final reason = fitReasonText(fit);
  return LocalModelOption(
    model: m,
    descriptor: descriptor,
    fit: kind,
    fitReason: reason,
    unavailableReason: kind == FitBadgeKind.wontFit ? reason : null,
    engineNote: availability.reason,
  );
}

/// The fit input of an installed MLX / LiteRT model: MLX weights = Σ weight
/// files (KV from [mlxConfig] when given); LiteRT = the `.litertlm` file.
RuntimeFootprintInput runtimeFootprintOf(LibraryModel m, {Map<String, Object?>? mlxConfig}) {
  final weights = _bytesOf(m, FileRole.model);
  if (m.format == ModelFormat.litert) return RuntimeFootprintInput.liteRt(fileBytes: weights, label: m.displayName);
  return RuntimeFootprintInput.mlx(
    weightBytes: weights,
    architecture: mlxConfig == null ? null : ModelArchitecture.fromMlxConfig(mlxConfig),
    label: m.displayName,
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

/// The library's `config.json` of an installed MLX model (its KV geometry
/// sizes the fit). Null when missing or unreadable.
Future<Map<String, Object?>?> readMlxConfig(LibraryModel m, ModelStorageLayout layout) async {
  for (final f in m.files) {
    if (f.path.split('/').last.toLowerCase() != 'config.json') continue;
    try {
      final v = jsonDecode(await File(layout.libraryPath(f.path)).readAsString());
      return v is Map ? v.cast<String, Object?>() : null;
    } on Object {
      return null;
    }
  }
  return null;
}

/// [readMlxConfig] once per installed model id.
final localMlxConfigProvider = FutureProvider.family<Map<String, Object?>?, String>((ref, modelId) async {
  final library = ref.watch(modelLibraryProvider);
  await library.load();
  final m = library.byId(modelId);
  if (m == null) return null;
  return readMlxConfig(m, ref.watch(modelStorageLayoutProvider));
});

/// The picker's "On this device" list: every installed model with its fit
/// on this device right now (fresh memory reading each time the picker
/// opens) and whether it can be chosen — GGUF on llama.cpp, MLX and LiteRT
/// on their platform engine (with its availability). Empty when local
/// inference is not wired.
final localModelOptionsProvider = FutureProvider.autoDispose<List<LocalModelOption>>((ref) async {
  final local = ref.watch(localInferenceProvider);
  if (local == null) return const [];
  final status = ref.watch(localEngineStatusProvider).value ?? local.status;
  final models = await ref.watch(localLibraryModelsProvider.future);
  final layout = ref.watch(modelStorageLayoutProvider);
  final platform = ref.watch(platformModelProvidersProvider);
  DeviceProfile? device;
  try {
    device = await ref.watch(deviceProfileSourceProvider).current();
  } on Object {
    device = null;
  }
  final out = <LocalModelOption>[];
  for (final m in models) {
    ModelShape? shape;
    EngineAvailability? availability;
    Map<String, Object?>? config;
    final provider = libraryProviderIdFor(m.format);
    if (isRunnableLocally(m)) {
      try {
        shape = await ref.watch(localModelShapeProvider(layout.libraryPath(m.loadPath)).future);
      } on Object {
        shape = null;
      }
    } else if (provider == mlxProviderId || provider == liteRtProviderId) {
      availability = platform == null ? null : await platform.modelAvailability(m);
      if (provider == mlxProviderId && (availability?.isAvailable ?? false)) {
        config = await ref.watch(localMlxConfigProvider(m.id).future);
      }
    }
    out.add(assessLocalModel(
      m,
      device: device,
      shape: shape,
      engine: status,
      loadedModelId: local.loadedModelId,
      availability: availability,
      mlxConfig: config,
    ));
  }
  return out;
});

/// Apple Intelligence or Gemini Nano as the picker offers it.
@immutable
final class SystemModelOption {
  const SystemModelOption({required this.providerId, required this.modelId, required this.name, required this.availability});

  final String providerId;
  final String modelId;
  final String name;
  final EngineAvailability availability;

  /// Gemini Nano: only while Sherpa is on screen.
  bool get foregroundOnly => isForegroundOnlyProvider(providerId);

  bool get selectable => availability.isAvailable;

  /// Why it can't be chosen: unsupported here, or the system has to
  /// download it / Apple Intelligence is off.
  String? get unavailableReason => selectable
      ? null
      : availability.state == EngineAvailabilityState.downloadable && providerId == geminiNanoProviderId
          ? 'Download Gemini Nano in Models & downloads first.'
          : availability.reason;

  ModelChoice get choice => ModelChoice(providerId: providerId, modelId: modelId);
}

/// The system model ids (`AppleFoundationModelsProvider.systemModelId`,
/// `GeminiNanoProvider.modelId`).
const Map<String, String> systemModelIds = {
  appleFmProviderId: AppleFoundationModelsProvider.systemModelId,
  geminiNanoProviderId: GeminiNanoProvider.modelId,
};

const Map<String, String> systemModelNames = {appleFmProviderId: 'Apple Intelligence', geminiNanoProviderId: 'Gemini Nano'};

/// The picker's system models with their status (Apple Intelligence on
/// iOS, Gemini Nano on Android). A model whose platform can't run it at
/// all is left out; one that needs a download or a setting is listed,
/// disabled, with the reason.
final systemModelOptionsProvider = FutureProvider.autoDispose<List<SystemModelOption>>((ref) async {
  final ids = ref.watch(systemModelIdsProvider);
  final out = <SystemModelOption>[];
  for (final id in ids) {
    final status = await ref.watch(systemModelStatusProvider(id).future);
    if (status == null || status.state == EngineAvailabilityState.unsupported) continue;
    var name = systemModelNames[id]!;
    if (status.isAvailable) {
      try {
        final listed = await ref.read(providerRegistryProvider).models(id);
        if (listed.isNotEmpty) name = listed.first.displayName;
      } on Object {
        // Keep the plain name.
      }
    }
    out.add(SystemModelOption(providerId: id, modelId: systemModelIds[id]!, name: name, availability: status));
  }
  return out;
});
