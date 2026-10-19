import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

/// How the chat template emits tool calls (`tool_calls.support` in
/// `se_model_info_json`, classified by applying the template to a dummy
/// tool, R04 §21.3).
enum EngineToolSupport {
  /// Lazy grammar triggered on the format's start marker (Qwen3, Hermes,
  /// Granite 4, Mistral, ...): constrained, reliable.
  nativeGrammar,

  /// The template renders tools and the parser extracts calls, but sampling
  /// is unconstrained (Llama 3.x, Phi-3.5, Gemma 2, SmolLM3).
  parsedWithoutGrammar,
  none,
}

/// Parameter count below which parallel tool calls stay off (R11 §9.6.2:
/// "Leave parallel_tool_calls off for models under 8B").
const int kParallelToolCallsMinParams = 8000000000;

/// The parts of `se_model_info_json` the provider and lifecycle use.
/// Unknown keys are ignored (the engine may add keys at any time,
/// CHANGELOG "JSON payloads may gain keys").
@immutable
final class EngineModelInfo {
  const EngineModelInfo({
    required this.raw,
    required this.arch,
    required this.name,
    required this.fileType,
    required this.parameterCount,
    required this.sizeBytes,
    required this.fileBytes,
    required this.contextTrain,
    required this.layerCount,
    required this.vocabSize,
    required this.modelId,
    required this.fingerprint,
    required this.toolSupport,
    required this.templateParallelToolCalls,
    required this.templateUsable,
    required this.supportsSystemRole,
    required this.thinkingSupported,
    required this.vision,
    required this.audio,
    required this.recommendedSampling,
    required this.kvBytesPerToken,
    required this.isRecurrent,
    required this.slidingWindow,
  });

  factory EngineModelInfo.parse(String json) {
    final j = (jsonDecode(json) as Map).cast<String, Object?>();
    JsonMap obj(String k) => (j[k] as Map?)?.cast<String, Object?>() ?? const {};
    int i(Object? v) => v is num ? v.toInt() : 0;
    final tools = obj('tool_calls');
    final template = obj('chat_template');
    final caps = (template['caps'] as Map?)?.cast<String, Object?>() ?? const {};
    final mm = obj('mmproj');
    final kv = obj('kv_bytes_per_token');
    return EngineModelInfo(
      raw: j,
      arch: j['arch'] as String? ?? '',
      name: j['name'] as String? ?? '',
      fileType: j['ftype'] as String? ?? '',
      parameterCount: i(j['n_params']),
      sizeBytes: i(j['size_bytes']),
      fileBytes: i(j['file_bytes']),
      contextTrain: i(j['n_ctx_train']),
      layerCount: i(j['n_layer']),
      vocabSize: i(j['n_vocab']),
      modelId: j['model_id'] as String? ?? '',
      fingerprint: j['fingerprint'] as String? ?? '',
      toolSupport: switch (tools['support']) {
        'native_grammar' => EngineToolSupport.nativeGrammar,
        'parsed_without_grammar' => EngineToolSupport.parsedWithoutGrammar,
        _ => EngineToolSupport.none,
      },
      templateParallelToolCalls: tools['parallel'] == true,
      templateUsable: template['usable'] == true,
      supportsSystemRole: caps['supports_system_role'] != false,
      thinkingSupported: obj('thinking')['supported'] == true,
      // Images are sent only to an engine that takes them (ABI 1.1 reports
      // `image_input`; an older engine with a projector loaded would drop them).
      vision: mm['vision'] == true && mm['image_input'] == true,
      // No audio input path in the engine yet, whatever the projector holds.
      audio: false,
      recommendedSampling: {
        for (final e in obj('recommended_sampling').entries)
          if (e.value != null) e.key: '${e.value}',
      },
      kvBytesPerToken: {for (final e in kv.entries) e.key: i(e.value)},
      isRecurrent: j['is_recurrent'] == true || j['is_hybrid'] == true,
      slidingWindow: i(j['sliding_window']),
    );
  }

  final JsonMap raw;
  final String arch;
  final String name;

  /// llama.cpp ftype name, e.g. "Q4_K - Medium".
  final String fileType;
  final int parameterCount;
  final int sizeBytes;
  final int fileBytes;
  final int contextTrain;
  final int layerCount;
  final int vocabSize;
  final String modelId;
  final String fingerprint;
  final EngineToolSupport toolSupport;
  final bool templateParallelToolCalls;
  final bool templateUsable;
  final bool supportsSystemRole;
  final bool thinkingSupported;

  /// A vision projector (mmproj) is loaded and the engine accepts image
  /// content parts (`mmproj.vision` and `mmproj.image_input`).
  final bool vision;

  /// Audio input. Always false: the engine has no audio input path yet.
  final bool audio;

  /// `general.sampling.*` from the GGUF (author-recommended sampling).
  final Map<String, String> recommendedSampling;

  /// Plain-formula KV bytes per token by type (UI hint; the dry run is the
  /// authority).
  final Map<String, int> kvBytesPerToken;
  final bool isRecurrent;
  final int slidingWindow;

  /// Parallel tool calls are offered only when the template supports them
  /// and the model is large enough to use them well (R11 §9.6.2).
  bool get allowParallelToolCalls =>
      templateParallelToolCalls && parameterCount >= kParallelToolCallsMinParams;

  ToolCallFormat get toolCallFormat => switch (toolSupport) {
        EngineToolSupport.nativeGrammar => ToolCallFormat.jsonGrammar,
        EngineToolSupport.parsedWithoutGrammar => ToolCallFormat.prompted,
        EngineToolSupport.none => ToolCallFormat.none,
      };

  /// Tokenizer family for the core's calibrated estimator (keys of
  /// `token_estimator.dart`'s chars-per-token table).
  String? get tokenizerFamily {
    final a = arch.toLowerCase();
    if (a.startsWith('qwen')) return 'qwen';
    if (a.startsWith('gemma')) return 'gemma';
    if (a.startsWith('phi')) return 'phi';
    if (a.startsWith('llama')) return 'llama3';
    if (a.startsWith('mistral') || a.startsWith('ministral')) return 'mistral';
    if (a.startsWith('lfm')) return 'lfm2';
    if (a.startsWith('granite')) return 'granite';
    return null;
  }

  /// Capabilities of this model in a session of [contextLength] tokens
  /// (the session's real, padded `n_ctx`) using [ramBytes].
  ModelCapabilities capabilities({required int contextLength, int? ramBytes}) => ModelCapabilities(
        contextLength: contextLength,
        toolCallFormat: templateUsable ? toolCallFormat : ToolCallFormat.none,
        parallelToolCalls: allowParallelToolCalls,
        vision: vision,
        audioInput: audio,
        reasoning: thinkingSupported ? ReasoningSupport.optional : ReasoningSupport.none,
        quantization: fileType.isEmpty ? null : fileType,
        parameterCount: parameterCount == 0 ? null : parameterCount,
        ramEstimateBytes: ramBytes,
        tokenizerFamily: tokenizerFamily,
        supportsSystemRole: supportsSystemRole,
        // The engine reuses the longest common token prefix of the KV cache
        // on every request and persists it across launches, so the
        // transcript should only ever be appended to.
        supportsPromptCache: true,
        historyPolicy: HistoryPolicy.appendOnly,
      );
}

/// The resolved parameters of a live session (`se_session_info_json`).
@immutable
final class EngineSessionInfo {
  const EngineSessionInfo({
    required this.nCtx,
    required this.nBatch,
    required this.nUbatch,
    required this.nThreads,
    required this.typeK,
    required this.typeV,
    required this.flashAttention,
    required this.promptCache,
    required this.totalBytes,
    required this.historyTokens,
  });

  factory EngineSessionInfo.parse(String json) {
    final j = (jsonDecode(json) as Map).cast<String, Object?>();
    int i(Object? v) => v is num ? v.toInt() : 0;
    final mem = (j['memory'] as Map?)?.cast<String, Object?>() ?? const {};
    return EngineSessionInfo(
      nCtx: i(j['n_ctx']),
      nBatch: i(j['n_batch']),
      nUbatch: i(j['n_ubatch']),
      nThreads: i(j['n_threads']),
      typeK: j['type_k'] as String? ?? 'f16',
      typeV: j['type_v'] as String? ?? 'f16',
      flashAttention: j['flash_attn'] == true || j['flash_attn'] == 1,
      promptCache: j['prompt_cache'] as String? ?? 'prefix',
      totalBytes: i(mem['total_bytes']),
      historyTokens: i(j['history_tokens']),
    );
  }

  final int nCtx;
  final int nBatch;
  final int nUbatch;
  final int nThreads;
  final String typeK;
  final String typeV;
  final bool flashAttention;

  /// "prefix" (LCP reuse) or "full_only" (recurrent/hybrid memory).
  final String promptCache;
  final int totalBytes;
  final int historyTokens;
}

/// The parts of `se_system_info_json` the app needs (runtime CPU features
/// read from getauxval/sysctl, not ggml's compile-time flags, R04 §18).
@immutable
final class EngineSystemInfo {
  const EngineSystemInfo({
    required this.raw,
    required this.performanceCores,
    required this.logicalCores,
    required this.cpuVariant,
    required this.cpuFeatures,
    required this.backends,
  });

  factory EngineSystemInfo.parse(String json) {
    final j = (jsonDecode(json) as Map).cast<String, Object?>();
    final cpu = (j['cpu'] as Map?)?.cast<String, Object?>() ?? const {};
    final features = (cpu['features'] as Map?)?.cast<String, Object?>() ?? const {};
    int i(Object? v) => v is num ? v.toInt() : 0;
    return EngineSystemInfo(
      raw: j,
      performanceCores: i(cpu['performance_cores']),
      logicalCores: i(cpu['logical_cores']),
      cpuVariant: j['cpu_variant'] as String? ?? '',
      cpuFeatures: {for (final e in features.entries) if (e.value == true) e.key},
      backends: [
        for (final b in (j['backends'] as List?) ?? const <Object?>[])
          if (b is Map && b['name'] is String) b['name']! as String,
      ],
    );
  }

  final JsonMap raw;

  /// Performance-core estimate from cpufreq (the autotune thread ceiling).
  final int performanceCores;
  final int logicalCores;

  /// The `libggml-cpu-android_*` variant that loaded (Android), else "".
  final String cpuVariant;

  /// e.g. {dotprod, i8mm, sve, sme} on ARM; {avx2, fma, ...} on x86.
  final Set<String> cpuFeatures;
  final List<String> backends;
}
