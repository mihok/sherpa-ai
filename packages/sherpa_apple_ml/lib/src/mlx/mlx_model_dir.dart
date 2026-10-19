import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

/// `model_type`s registered in `LLMModelFactory` (`LLMTypeRegistry`) of
/// mlx-swift-lm **3.32.3** (Libraries/MLXLLM/LLMModelFactory.swift at tag
/// 3.32.3, commit 3b339ad). Update together with the SwiftPM pin.
const Set<String> kMlxSupportedModelTypes = {
  'mistral', 'mixtral', 'llama', 'phi', 'phi3', 'phimoe', 'gemma', 'gemma2', 'gemma3', 'gemma3_text', //
  'gemma3n', 'gemma4', 'gemma4_unified', 'gemma4_text', 'qwen2', 'qwen3', 'qwen3_moe', 'qwen3_next',
  'qwen3_5', 'qwen3_5_moe', 'qwen3_5_text', 'nanbeige', 'minicpm', 'starcoder2', 'cohere', 'openelm',
  'internlm2', 'deepseek_v2', 'deepseek_v3', 'granite', 'helium', 'granitemoehybrid', 'mimo',
  'mimo_v2_flash', 'minimax', 'glm4', 'glm4_moe', 'glm4_moe_lite', 'acereason', 'falcon_h1', 'bitnet',
  'smollm3', 'ernie4_5', 'lfm2', 'baichuan_m1', 'exaone4', 'gpt_oss', 'olmoe', 'olmo2', 'olmo3',
  'bailing_moe', 'lfm2_moe', 'nanochat', 'nemotron_h', 'afmoe', 'jamba', 'mamba2', 'mistral3', 'apertus',
  'hunyuan_v1_dense', 'nemotron_labs_diffusion',
};

/// What is on disk in an MLX model directory, read without MLX (dart:io), so
/// availability and capabilities are known before anything is loaded.
@immutable
final class MlxModelDirectory {
  const MlxModelDirectory({
    required this.directory,
    required this.exists,
    this.config,
    this.modelType,
    this.contextLength,
    this.weightsBytes = 0,
    this.weightFiles = const [],
    this.missingWeightFiles = const [],
    this.hasNpzWeights = false,
    this.hasTokenizer = false,
    this.hasChatTemplate = false,
    this.templateMentionsTools = false,
    this.templateMentionsThinking = false,
    this.numLayers,
    this.numKvHeads,
    this.headDim,
    this.quantBits,
  });

  /// Accepts the directory itself or any file inside it (the library's
  /// `loadPath` is the first weight file).
  static Future<MlxModelDirectory> inspect(String path) async {
    var dir = Directory(path);
    if (!await dir.exists() && await File(path).exists()) dir = File(path).parent;
    if (!await dir.exists()) return MlxModelDirectory(directory: dir.path, exists: false);
    final entries = await dir.list(followLinks: false).toList();
    final files = {for (final e in entries.whereType<File>()) e.uri.pathSegments.last: e};

    Map<String, Object?>? json(String name) {
      final f = files[name];
      if (f == null) return null;
      try {
        final v = jsonDecode(f.readAsStringSync());
        return v is Map ? v.cast<String, Object?>() : null;
      } on Object {
        return null;
      }
    }

    final config = json('config.json');
    final text = _textConfig(config);
    int? intOf(Map<String, Object?>? m, String k) => (m?[k] is num) ? (m![k]! as num).toInt() : null;

    // Weights: the safetensors index names the shards when there is one.
    final index = json('model.safetensors.index.json');
    final indexed = <String>{
      for (final v in ((index?['weight_map'] as Map?) ?? const {}).values)
        if (v is String) v,
    };
    final present = [
      for (final n in files.keys)
        if (n.endsWith('.safetensors')) n,
    ]..sort();
    final expected = indexed.isEmpty ? present : (indexed.toList()..sort());
    var bytes = 0;
    for (final n in present) {
      bytes += await files[n]!.length();
    }

    final tokConfig = json('tokenizer_config.json');
    final template =
        '${tokConfig?['chat_template'] ?? ''}'
        '${files.containsKey('chat_template.jinja') ? files['chat_template.jinja']!.readAsStringSync() : ''}'
        '${json('chat_template.json')?['chat_template'] ?? ''}';

    final heads = intOf(text, 'num_attention_heads');
    final hidden = intOf(text, 'hidden_size');
    final quant = (config?['quantization'] ?? config?['quantization_config']) as Map?;
    return MlxModelDirectory(
      directory: dir.path,
      exists: true,
      config: config,
      modelType: config?['model_type'] as String?,
      contextLength: intOf(text, 'max_position_embeddings') ?? intOf(config, 'max_position_embeddings'),
      weightsBytes: bytes,
      weightFiles: present,
      missingWeightFiles: [
        for (final n in expected)
          if (!files.containsKey(n)) n,
      ],
      hasNpzWeights: files.keys.any((n) => n.endsWith('.npz')),
      // swift-transformers' PreTrainedTokenizer needs tokenizer.json.
      hasTokenizer: files.containsKey('tokenizer.json'),
      hasChatTemplate: template.trim().isNotEmpty,
      templateMentionsTools: template.contains('tools'),
      templateMentionsThinking: template.contains('enable_thinking') || template.contains('<think>'),
      numLayers: intOf(text, 'num_hidden_layers'),
      numKvHeads: intOf(text, 'num_key_value_heads') ?? heads,
      headDim: intOf(text, 'head_dim') ?? (heads != null && hidden != null && heads > 0 ? hidden ~/ heads : null),
      quantBits: quant?['bits'] is num ? (quant!['bits']! as num).toInt() : null,
    );
  }

  /// Multimodal checkpoints (Gemma 3/4, Qwen-VL) nest the LM config.
  static Map<String, Object?>? _textConfig(Map<String, Object?>? config) {
    final t = config?['text_config'];
    if (t is Map) return {...?config, ...t.cast<String, Object?>()};
    return config;
  }

  final String directory;
  final bool exists;
  final Map<String, Object?>? config;
  final String? modelType;
  final int? contextLength;
  final int weightsBytes;
  final List<String> weightFiles;
  final List<String> missingWeightFiles;
  final bool hasNpzWeights;
  final bool hasTokenizer;
  final bool hasChatTemplate;
  final bool templateMentionsTools;
  final bool templateMentionsThinking;
  final int? numLayers;
  final int? numKvHeads;
  final int? headDim;
  final int? quantBits;

  bool get hasConfig => config != null;

  bool get isSupportedArchitecture => modelType != null && kMlxSupportedModelTypes.contains(modelType);

  bool get isComplete => hasConfig && weightFiles.isNotEmpty && missingWeightFiles.isEmpty && hasTokenizer;

  /// KV bytes per token for full-attention layers (keys + values), at
  /// [kvBits] (null = fp16), plus the per-group scales MLX keeps for
  /// quantized caches. An estimate: hybrid/SSM layers (Mamba, GDN) hold a
  /// fixed state instead and are over-counted here, which errs safe.
  int? kvBytesPerToken({int? kvBits, int groupSize = 64}) {
    final l = numLayers, h = numKvHeads, d = headDim;
    if (l == null || h == null || d == null) return null;
    final elements = 2 * l * h * d;
    if (kvBits == null) return elements * 2;
    // packed values + fp16 scale and bias per group
    return (elements * kvBits / 8 + elements / groupSize * 4).ceil();
  }
}
