import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../messages.pigeon.dart';

/// The LiteRT-LM runtime this package bundles (android/build.gradle.kts).
const String kLiteRtLmVersion = '0.18.0';

/// Context opened when neither the spec nor the app asks for one: the KV
/// cache grows with it, so the default stays modest; the model's own maximum
/// still caps it.
const int kDefaultLiteRtContext = 8192;

/// A `.litertlm` file the app registered with [LiteRtLmProvider].
@immutable
final class LiteRtModelSpec {
  const LiteRtModelSpec({
    required this.id,
    required this.path,
    this.displayName,
    this.contextLength,
    this.backends,
    this.toolCalling = true,
    this.vision = false,
    this.cpuThreads,
    this.tokenizerFamily,
    this.parameterCount,
  });

  /// The id requests use (`ModelRequest.modelId`).
  final String id;

  /// Absolute path of the `.litertlm` file.
  final String path;
  final String? displayName;

  /// `EngineConfig.maxNumTokens`; null = min(model maximum, 8192).
  final int? contextLength;

  /// Backend order to try (`npu`, `gpu`, `cpu`); null = [planBackends].
  final List<String>? backends;

  /// Offer tools to this model (native function calling when the file
  /// declares it, else the prompted JSON format).
  final bool toolCalling;

  /// Load the vision encoder (GPU) and accept images, when the file has one.
  final bool vision;
  final int? cpuThreads;

  /// Overrides the family guessed from the file name (token estimates).
  final String? tokenizerFamily;
  final int? parameterCount;

  String get label => displayName ?? id;
}

/// [ModelInfoMsg] (`ModelInfo.from` + `LlmCapability`) as Dart values.
@immutable
final class LiteRtModelInfo {
  const LiteRtModelInfo({
    required this.modelType,
    required this.maxContextTokens,
    required this.dynamicContext,
    required this.vision,
    required this.audio,
    required this.textBackends,
    required this.supportsFunctionCalling,
    required this.supportsThinking,
    required this.speculativeDecoding,
    required this.fileBytes,
    this.npuBrand,
    this.socName,
    this.minRuntimeVersion,
    this.defaultTemperature,
    this.defaultTopK,
    this.defaultTopP,
  });

  factory LiteRtModelInfo.fromMsg(ModelInfoMsg m) => LiteRtModelInfo(
        modelType: m.modelType,
        maxContextTokens: m.maxContextTokens,
        dynamicContext: m.dynamicContext,
        vision: m.vision,
        audio: m.audio,
        textBackends: m.textBackends,
        supportsFunctionCalling: m.supportsFunctionCalling,
        supportsThinking: m.supportsThinking,
        speculativeDecoding: m.speculativeDecoding,
        fileBytes: m.fileBytes,
        npuBrand: m.npuBrand,
        socName: m.socName,
        minRuntimeVersion: m.minRuntimeVersion,
        defaultTemperature: m.defaultTemperature,
        defaultTopK: m.defaultTopK,
        defaultTopP: m.defaultTopP,
      );

  final String modelType;
  final int maxContextTokens;
  final bool dynamicContext;
  final bool vision;
  final bool audio;
  final List<String> textBackends;
  final bool supportsFunctionCalling;
  final bool supportsThinking;
  final bool speculativeDecoding;
  final int fileBytes;
  final String? npuBrand;
  final String? socName;
  final String? minRuntimeVersion;
  final double? defaultTemperature;
  final int? defaultTopK;
  final double? defaultTopP;

  bool get isLlm => modelType == 'llm';

  /// Compiled for one NPU only (an SoC-specific file such as
  /// `…_qualcomm_sm8750.litertlm`).
  bool get npuOnly => textBackends.isNotEmpty && textBackends.every((b) => b == 'npu');
}

/// The facts [planBackends] needs about the device.
@immutable
final class LiteRtDevice {
  const LiteRtDevice({required this.apiLevel, this.socModel, this.socManufacturer});

  factory LiteRtDevice.fromMsg(PlatformInfoMsg p) =>
      LiteRtDevice(apiLevel: p.apiLevel, socModel: p.socModel, socManufacturer: p.socManufacturer);

  final int apiLevel;
  final String? socModel;
  final String? socManufacturer;
}

/// Whether an NPU file built for [info]'s SoC matches this [device]
/// (`Build.SOC_MODEL`, API 31+; R07 §1.1 "Select the file by ro.soc.model").
bool npuMatches(LiteRtModelInfo info, LiteRtDevice device) {
  if (device.apiLevel < 31) return false; // "API level 31+ is required for NPU support"
  final soc = info.socName?.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
  final model = device.socModel?.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
  if (soc == null || soc.isEmpty) {
    // A brand without an SoC name: accept a matching manufacturer.
    final brand = info.npuBrand?.toLowerCase() ?? '';
    final maker = device.socManufacturer?.toLowerCase() ?? '';
    return brand.isNotEmpty &&
        ((brand == 'qualcomm' && maker.contains('qti')) ||
            (brand == 'google_tensor' && maker.contains('google')) ||
            (brand == 'mediatek' && maker.contains('mediatek')) ||
            (brand == 'samsung' && maker.contains('samsung')));
  }
  if (model == null || model.isEmpty) return false;
  return model.contains(soc) || soc.contains(model);
}

/// POLICY: the backend order to try for [info] on [device].
///
/// * NPU first, only when the file is built for an NPU and that NPU is this
///   device's SoC (NPU files are per-SoC; the vendor dispatch libraries must
///   also be in the APK, see README).
/// * GPU next when the file supports it: lower anonymous memory than CPU
///   (676 MB vs 1.7 GB peak for Gemma 4 E2B, R07 §1.1), which matters under
///   the Android 17 memory limiter (§2.3).
/// * CPU last, the dependable fallback.
/// Unknown support (empty list) tries GPU then CPU.
List<String> planBackends(LiteRtModelInfo info, LiteRtDevice device) {
  final supported = info.textBackends.isEmpty ? const ['gpu', 'cpu'] : info.textBackends;
  return [
    if (supported.contains('npu') && info.npuBrand != null && npuMatches(info, device)) 'npu',
    if (supported.contains('gpu')) 'gpu',
    if (supported.contains('cpu')) 'cpu',
  ];
}

/// Tokenizer family for the core's estimator, guessed from the file name
/// (`.litertlm` metadata has no architecture field in the Kotlin API).
String? guessTokenizerFamily(String pathOrName) {
  final n = pathOrName.toLowerCase().split(RegExp(r'[\\/]')).last;
  if (n.contains('gemma') || n.contains('gemini')) return 'gemma';
  if (n.contains('qwen') || n.contains('deepseek-r1-distill-qwen')) return 'qwen';
  if (n.contains('phi')) return 'phi';
  if (n.contains('llama') || n.contains('smollm')) return 'llama3';
  if (n.contains('mistral') || n.contains('ministral')) return 'mistral';
  if (n.contains('lfm')) return 'lfm2';
  return null;
}

/// True when [version] (e.g. `0.19.0`) is newer than the bundled runtime.
bool runtimeTooOld(String? version, {String runtime = kLiteRtLmVersion}) {
  if (version == null || version.trim().isEmpty) return false;
  List<int> parts(String v) =>
      v.split(RegExp(r'[.\-+]')).take(3).map((p) => int.tryParse(p.replaceAll(RegExp(r'\D'), '')) ?? 0).toList();
  final need = parts(version);
  final have = parts(runtime);
  for (var i = 0; i < 3; i++) {
    final a = i < need.length ? need[i] : 0;
    final b = i < have.length ? have[i] : 0;
    if (a != b) return a > b;
  }
  return false;
}

/// The context the engine opens for [spec] (`EngineConfig.maxNumTokens`):
/// the spec's request, else [kDefaultLiteRtContext], capped by the model.
int effectiveContext(LiteRtModelSpec spec, LiteRtModelInfo info) {
  final max = info.maxContextTokens > 0 ? info.maxContextTokens : kDefaultLiteRtContext;
  final want = spec.contextLength ?? kDefaultLiteRtContext;
  return want < max ? want : max;
}

/// POLICY: native function calling when the model's chat template renders
/// registered tools (probed at load); before the first load, or when the
/// probe failed, fall back to the metadata flag. The flag alone is not
/// trusted: Qwen3-0.6B's file reports `supportsFunctionCalling() == false`
/// yet its template renders tools and the engine returns structured calls,
/// while SmolLM2's template silently drops tools, tool calls and tool
/// responses (host run with litertlm-jvm 0.18.0, see README).
bool usesNativeTools(LiteRtModelInfo info, bool? templateRendersTools) =>
    templateRendersTools ?? info.supportsFunctionCalling;

/// Honest capabilities of [spec] backed by [info] (and the load-time
/// template probe, when known).
ModelCapabilities liteRtCapabilities(LiteRtModelSpec spec, LiteRtModelInfo info, {bool? templateRendersTools}) {
  return ModelCapabilities(
    contextLength: effectiveContext(spec, info),
    toolCallFormat: !spec.toolCalling
        ? ToolCallFormat.none
        : (usesNativeTools(info, templateRendersTools) ? ToolCallFormat.native : ToolCallFormat.prompted),
    // Calls come back as a list, but small on-device models call tools
    // better one at a time (R11 §9.6.2); several are still reported.
    parallelToolCalls: false,
    vision: spec.vision && info.vision,
    reasoning: info.supportsThinking ? ReasoningSupport.optional : ReasoningSupport.none,
    parameterCount: spec.parameterCount,
    ramEstimateBytes: info.fileBytes > 0 ? info.fileBytes : null,
    tokenizerFamily: spec.tokenizerFamily ?? guessTokenizerFamily(spec.path),
    // The native Conversation keeps the KV cache of the transcript; the
    // provider reuses it while requests only append (see ConversationCache).
    supportsPromptCache: true,
    historyPolicy: HistoryPolicy.appendOnly,
  );
}
