import 'package:meta/meta.dart';

import '../naming/quant_types.dart';
import 'gguf_reader.dart';

/// Per-layer sliding-window layout.
///
/// GGUF stores it either as a per-layer bool array or as a period `n`
/// (`<arch>.attention.sliding_window_pattern`); llama.cpp expands a period
/// with `set_swa_pattern` (vendored `src/llama-hparams.cpp`): layer `il` is
/// SWA when `il % n < n - 1` (or `il % n != 0` for dense-first archs).
@immutable
final class SwaPattern {
  const SwaPattern.period(int this.period, {this.denseFirst = false}) : layers = null;

  const SwaPattern.layers(List<bool> this.layers)
      : period = null,
        denseFirst = false;

  final int? period;
  final bool denseFirst;
  final List<bool>? layers;

  bool isSwa(int il) {
    final l = layers;
    if (l != null) return il < l.length && l[il];
    final n = period!;
    if (n == 0) return true;
    return denseFirst ? il % n != 0 : il % n < n - 1;
  }

  @override
  String toString() => layers != null ? 'SwaPattern($layers)' : 'SwaPattern(period $period)';
}

/// Typed, lenient view over GGUF key/value metadata.
///
/// Key names are llama.cpp's (`src/llama-arch.cpp` `LLM_KV_NAMES`; R04 §4).
/// Architecture keys are `<general.architecture>.<suffix>`. Every getter
/// tolerates a missing key or a different numeric type, because quantizers
/// write metadata with many tool versions.
@immutable
final class GgufMetadata {
  const GgufMetadata(this.values);

  /// Raw values: `String`, `int`, `double`, `bool`, [GgufArray] or
  /// [GgufSkippedString].
  final Map<String, Object?> values;

  Object? operator [](String key) => values[key];

  bool containsKey(String key) => values.containsKey(key);

  String? string(String key) {
    final v = values[key];
    return v is String ? v : null;
  }

  int? integer(String key) {
    final v = values[key];
    return switch (v) {
      int() => v,
      double() when v == v.roundToDouble() => v.toInt(),
      bool() => v ? 1 : 0,
      _ => null,
    };
  }

  double? number(String key) {
    final v = values[key];
    return v is num ? v.toDouble() : null;
  }

  bool? boolean(String key) {
    final v = values[key];
    return switch (v) {
      bool() => v,
      int() => v != 0,
      _ => null,
    };
  }

  GgufArray? array(String key) {
    final v = values[key];
    return v is GgufArray ? v : null;
  }

  /// Int list for keys that may be scalar or per-layer arrays.
  List<int>? intList(String key) {
    final a = array(key);
    if (a == null || a.isSkipped) return null;
    return [for (final v in a.values!) if (v is num) v.toInt() else if (v is bool) (v ? 1 : 0)];
  }

  // ---- general.* ----------------------------------------------------------

  String? get architecture => string('general.architecture');
  String? get type => string('general.type');
  String? get name => string('general.name');
  String? get basename => string('general.basename');
  String? get sizeLabel => string('general.size_label');
  String? get finetune => string('general.finetune');
  String? get version => string('general.version');
  String? get license => string('general.license');
  String? get quantizedBy => string('general.quantized_by');
  int? get fileType => integer('general.file_type');
  int? get quantizationVersion => integer('general.quantization_version');

  /// `general.alignment`, default 32 (GGUF spec `GGUF_DEFAULT_ALIGNMENT`).
  int get alignment {
    final a = integer('general.alignment');
    return a == null || a <= 0 ? 32 : a;
  }

  /// The llama.cpp file type named by `general.file_type` (authoritative
  /// over the file name, R08 §12).
  QuantType? get fileTypeInfo {
    final f = fileType;
    return f == null ? null : QuantTypes.byFtype(f);
  }

  // ---- <arch>.* -----------------------------------------------------------

  String _a(String suffix) => '${architecture ?? ''}.$suffix';

  int? archInt(String suffix) => architecture == null ? null : integer(_a(suffix));

  double? archNumber(String suffix) => architecture == null ? null : number(_a(suffix));

  int? get contextLength => archInt('context_length');
  int? get blockCount => archInt('block_count');
  int? get embeddingLength => archInt('embedding_length');

  /// Scalar, or the largest per-layer value when stored as an array
  /// (OpenELM, Gemma 3n) — the compute buffer is sized for the widest layer.
  int? get feedForwardLength => archInt('feed_forward_length') ?? _maxOf(intList(_a('feed_forward_length')));

  int? get headCount => archInt('attention.head_count') ?? _maxOf(intList(_a('attention.head_count')));

  /// KV heads per layer. Scalar keys expand to every layer; arrays are kept
  /// as-is (LFM2 writes 0 for its convolution layers, which have no KV).
  /// Missing key → `head_count` (llama.cpp default: no GQA).
  List<int>? get headCountKvPerLayer {
    final layers = blockCount;
    final list = intList(_a('attention.head_count_kv'));
    if (list != null && list.isNotEmpty) return list;
    final scalar = archInt('attention.head_count_kv') ?? headCount;
    if (scalar == null || layers == null) return null;
    return List.filled(layers, scalar);
  }

  int? get headCountKv => archInt('attention.head_count_kv') ?? _maxOf(intList(_a('attention.head_count_kv')));

  /// Key head size. Falls back to `n_embd / n_head`, which is **wrong** for
  /// Qwen3 (64 instead of 128, R04 §0.5) — so prefer the explicit key.
  int? get keyLength {
    final explicit = archInt('attention.key_length');
    if (explicit != null) return explicit;
    final e = embeddingLength;
    final h = headCount;
    return e != null && h != null && h > 0 ? e ~/ h : null;
  }

  int? get valueLength => archInt('attention.value_length') ?? keyLength;
  int? get keyLengthSwa => archInt('attention.key_length_swa');
  int? get valueLengthSwa => archInt('attention.value_length_swa');

  /// Sliding-window size in tokens (`n_swa`); null or 0 = no SWA.
  int? get slidingWindow => archInt('attention.sliding_window');

  /// Explicit pattern from the file, if any. When absent the architecture's
  /// built-in default applies ([SwaDefaults]).
  SwaPattern? get slidingWindowPattern {
    final key = _a('attention.sliding_window_pattern');
    final a = array(key);
    if (a != null && !a.isSkipped) {
      return SwaPattern.layers([for (final v in a.values!) v == true || (v is num && v != 0)]);
    }
    final n = integer(key);
    return n == null ? null : SwaPattern.period(n);
  }

  int? get expertCount => archInt('expert_count');
  int? get expertUsedCount => archInt('expert_used_count');
  int? get expertSharedCount => archInt('expert_shared_count');
  int? get expertFeedForwardLength => archInt('expert_feed_forward_length');
  int? get expertSharedFeedForwardLength => archInt('expert_shared_feed_forward_length');
  bool get isMoe => (expertCount ?? 0) > 1;

  int? get ropeDimensionCount => archInt('rope.dimension_count');
  double? get ropeFreqBase => archNumber('rope.freq_base');
  String? get ropeScalingType => architecture == null ? null : string(_a('rope.scaling.type'));
  double? get ropeScalingFactor => archNumber('rope.scaling.factor');
  int? get ropeScalingOriginalContextLength => archInt('rope.scaling.original_context_length');

  /// MTP / NextN layers appended to the trunk (draft heads, `-mtp` models).
  int? get nextnPredictLayers => archInt('nextn_predict_layers');

  /// Trailing layers that reuse earlier layers' KV (Gemma 3n/4).
  int? get sharedKvLayers => archInt('attention.shared_kv_layers');

  /// MLA (DeepSeek-style) compressed KV rank.
  int? get kvLoraRank => archInt('attention.kv_lora_rank');

  /// Hybrid models: one full-attention layer every N (Qwen3.5/Qwen3-Next,
  /// MiniMax-01); the others are recurrent and keep no KV.
  int? get fullAttentionInterval => archInt('full_attention_interval');

  /// Hybrid models: explicit per-layer recurrent flags.
  List<bool>? get recurrentLayers {
    final a = array(_a('attention.recurrent_layers'));
    if (a == null || a.isSkipped) return null;
    return [for (final v in a.values!) v == true || (v is num && v != 0)];
  }

  /// Pure state-space models (Mamba, RWKV) keep a fixed-size state instead
  /// of a KV cache.
  bool get hasSsmState => architecture != null && (containsKey(_a('ssm.state_size')) || containsKey(_a('wkv.head_size')));

  /// `<arch>.vocab_size`, else the length of `tokenizer.ggml.tokens`
  /// (kept even when the array itself is skipped).
  int? get vocabSize => archInt('vocab_size') ?? array('tokenizer.ggml.tokens')?.length;

  // ---- tokenizer.* --------------------------------------------------------

  String? get tokenizerModel => string('tokenizer.ggml.model');
  String? get tokenizerPre => string('tokenizer.ggml.pre');
  int? get bosTokenId => integer('tokenizer.ggml.bos_token_id');
  int? get eosTokenId => integer('tokenizer.ggml.eos_token_id');

  /// Default chat template (`tokenizer.chat_template`).
  String? get chatTemplate => string('tokenizer.chat_template');

  /// Dedicated tool-use template variant (`tokenizer.chat_template.tool_use`).
  String? get toolUseChatTemplate => string('tokenizer.chat_template.tool_use');

  /// Whether the chat template renders tools — the best local tool-use
  /// signal (R08 §10). Quantizers patch templates, so this reads the file's
  /// own template, not the upstream repo's.
  bool get chatTemplateMentionsTools {
    final t = [chatTemplate, toolUseChatTemplate].whereType<String>().join('\n');
    return t.isNotEmpty && ChatTemplateSignals.mentionsTools(t);
  }

  bool get chatTemplateMentionsReasoning {
    final t = chatTemplate;
    return t != null && ChatTemplateSignals.mentionsReasoning(t);
  }

  // ---- split.* / quantize.* -----------------------------------------------

  int? get splitCount => integer('split.count');
  int? get splitNo => integer('split.no');
  int? get splitTensorsCount => integer('split.tensors.count');
  String? get imatrixFile => string('quantize.imatrix.file');
  bool get usedImatrix => containsKey('quantize.imatrix.file') || containsKey('quantize.imatrix.dataset');

  static int? _maxOf(List<int>? xs) => xs == null || xs.isEmpty ? null : xs.reduce((a, b) => a > b ? a : b);
}

/// Template heuristics from R08 §10 (case-sensitive, on the raw Jinja).
abstract final class ChatTemplateSignals {
  static final List<RegExp> _tools = [
    RegExp(r'\btools\b'),
    RegExp('tool_calls'),
    RegExp('\'tool\'|"tool"|ipython'),
    RegExp('<tool_call>'),
    RegExp(r'<\|tool_call\|>'),
    RegExp(r'\[TOOL_CALLS\]'),
  ];

  static final List<RegExp> _reasoning = [
    RegExp('<think>'),
    RegExp('enable_thinking'),
    RegExp('reasoning_content'),
    RegExp('reasoning_effort'),
  ];

  static bool mentionsTools(String template) => _tools.any((r) => r.hasMatch(template));

  static bool mentionsReasoning(String template) => _reasoning.any((r) => r.hasMatch(template));
}

/// Built-in SWA layouts for architectures whose GGUF omits the pattern key
/// (`load_swa_pattern(ml, n[, dense_first])` defaults in vendored
/// `src/models/*.cpp`). Unknown architectures with a sliding window but no
/// pattern are treated as all-full-attention, which over-estimates memory —
/// the safe direction for admission control.
abstract final class SwaDefaults {
  static const Map<String, SwaPattern> byArchitecture = {
    'gemma2': SwaPattern.period(2),
    'gemma3': SwaPattern.period(6),
    'gemma3n': SwaPattern.period(5),
    'gemma-embedding': SwaPattern.period(6),
    'cohere2': SwaPattern.period(4),
    'llama4': SwaPattern.period(4),
    'gpt-oss': SwaPattern.period(2),
    'exaone4': SwaPattern.period(4),
    'olmo2': SwaPattern.period(4),
    'mellum': SwaPattern.period(4),
    'afmoe': SwaPattern.period(4),
    'plamo3': SwaPattern.period(8),
    'smallthinker': SwaPattern.period(4, denseFirst: true),
    'modern-bert': SwaPattern.period(3, denseFirst: true),
  };
}
