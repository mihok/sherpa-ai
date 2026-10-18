import 'package:meta/meta.dart';

import 'quant_types.dart';

/// Where a decoded field came from. R08 §13.4 precedence: GGUF header >
/// Hub metadata > file name > repo name; the parser only sees names, so it
/// records which name won so the UI can say "size from the repo name".
enum FieldSource { file, folder, repo, branch }

/// A decoded name field plus a short user-facing tooltip.
@immutable
final class Decoded<T extends Object> {
  const Decoded(this.value, {required this.raw, required this.explanation, required this.source});

  final T value;

  /// The token(s) as written in the name.
  final String raw;

  /// One-line tooltip text for the UI.
  final String explanation;
  final FieldSource source;

  Decoded<T> withSource(FieldSource s) => Decoded(value, raw: raw, explanation: explanation, source: s);

  @override
  String toString() => '$value';
}

/// Weight container / quantization family, as the R08 §14 corpus classifies
/// files.
enum ModelFormat {
  gguf('GGUF: llama.cpp single-file weights; runs on Android and iOS'),
  ggufPart('GGUF byte-split part: download every part and join them in order before loading'),
  ggml('Legacy GGML .bin: current llama.cpp cannot load it'),
  mlx('MLX: Apple-silicon safetensors format (iOS)'),
  mlxNpz('Legacy MLX .npz weights: not supported by current mlx-lm'),
  safetensors('safetensors: plain tensor container (no code runs on load)'),
  gptq('GPTQ: CUDA-oriented 4-bit format; no mobile runtime'),
  awq('AWQ: CUDA-oriented 4-bit format; no mobile runtime'),
  exl2('EXL2 (ExLlamaV2): CUDA-only; no mobile runtime'),
  exl3('EXL3 (ExLlamaV3): CUDA-only; no mobile runtime'),
  litert('LiteRT-LM: Google on-device format (Android CPU/GPU/NPU)'),
  onnx('ONNX: not used by Sherpa runtimes'),
  onnxData('External weights of an ONNX model'),
  pickle('Python pickle: can run arbitrary code when loaded, so Sherpa never downloads it'),
  other('Not a model weights file');

  const ModelFormat(this.explanation);

  final String explanation;

  bool get isPickle => this == pickle;
}

/// What a file is for inside a repo.
enum FileRole {
  model('Main model weights'),
  mmproj('Multimodal projector: needed for image/audio input; pairs with the main model'),
  draft('Speculative-decoding draft: optional, can speed up generation'),
  imatrix('Importance matrix used to make the quants; not a model'),
  layout('Quantization layout description; not a model'),
  calibration('Calibration data; not a model'),
  externalData('External tensor data of another file'),
  config('Configuration / tokenizer file'),
  unknownSidecar('Unrecognized companion file (unknown prefix); not the main model');

  const FileRole(this.explanation);

  final String explanation;

  bool get isWeights => this == model || this == mmproj || this == draft;
}

/// Kind of speculative draft (llama.cpp `common/speculative.h`, R04 §15).
enum DraftKind { mtp, eagle3, dflash, dspark }

/// Fine-tune / purpose markers in model names (R08 §13.4 Variant row).
enum NameVariant {
  base('Base: pre-trained only, not tuned to follow instructions'),
  instruct('Instruction-tuned: follows chat instructions ("it" is Google\'s spelling)'),
  chat('Chat-tuned'),
  thinking('Thinking: emits a reasoning trace before answering'),
  reasoning('Reasoning-tuned: emits a reasoning trace before answering'),
  coder('Code-specialized'),
  vision('Vision-language: accepts images (needs the mmproj file)'),
  audio('Audio input model (needs the mmproj file)'),
  embedding('Embedding model: produces vectors, not chat replies'),
  reranker('Reranker: scores documents for a query, not a chat model'),
  toolUse('Tuned for tool / function calling'),
  rl('Further trained with reinforcement learning'),
  distill('Distilled: a smaller model trained to imitate a larger teacher'),
  abliterated('Abliterated: refusal behaviour removed; hidden by default'),
  uncensored('Uncensored fine-tune: refusal behaviour removed; hidden by default'),
  qat('Quantization-aware trained: built to survive 4-bit quantization'),
  qad('Quantization-aware distilled source weights'),
  pruned('Pruned: layers or experts removed to shrink the model'),
  next('"Next" generation preview of the family'),
  textOnly('Text-only build ("lm"): vision/audio towers removed'),
  mtp('Ships multi-token-prediction heads for faster decoding'),
  aggressive('Aggressive fine-tune variant (publisher label)');

  const NameVariant(this.explanation);

  final String explanation;

  /// Variants the default content filter hides (PLAN §7 Q7).
  bool get isUncensored => this == abliterated || this == uncensored;
}

/// Quantization family of a [QuantLabel].
enum QuantScheme {
  /// llama.cpp file type (GGUF / legacy GGML).
  ggml,

  /// MLX affine / DWQ / mxfp4 (bits + group size in config.json).
  mlx,
  gptq,
  awq,
  exl2,
  exl3,

  /// bitsandbytes NF4/int8 (CUDA only).
  bnb,
  fp8,
  nvfp4,

  /// llm-compressor `compressed-tensors` (`w4a16`).
  compressedTensors,

  /// LiteRT-LM quantization (`q8`, `q4_block128`, `int4`, `wi4b32`).
  litert,

  /// ONNX quantization (`q4f16`, `int8`, `fp16`).
  onnx,

  /// Unquantized floats named in a non-GGUF repo (`bf16`, `fp16`).
  float,

  /// A label nobody documents (`oQ4e`) — size must come from bytes.
  unknown,
}

/// A decoded quantization label.
@immutable
final class QuantLabel {
  const QuantLabel({
    required this.label,
    required this.raw,
    required this.scheme,
    required this.explanation,
    this.ggufType,
    this.bits,
    this.groupSize,
    this.bpw,
    this.bpwIsLowerBound = false,
    this.dynamic = false,
    this.imatrix = false,
    this.embedOutputQ8 = false,
    this.custom = false,
    this.ambiguous = false,
    this.approximateBase = false,
    this.mixed = false,
    this.mode,
    this.headBits,
  });

  /// Normalized label (`UD-Q4_K_XL`, `i1-Q4_K_M`, `F16`, `4bit-gs32`).
  final String label;
  final String raw;
  final QuantScheme scheme;

  /// The llama.cpp file type the label maps to (`Q4_K_XL` → `Q4_K_M`).
  final QuantType? ggufType;
  final int? bits;
  final int? groupSize;

  /// Name-implied bits per weight. Null for dynamic/mixed/unknown labels.
  /// Never use it for memory math — file bytes win (R08 §0.20).
  final double? bpw;

  /// `_L`/`_XL` keep embeddings/output at Q8_0, so the base bpw is a floor.
  final bool bpwIsLowerBound;

  /// Unsloth Dynamic (`UD-`): per-layer types vary; bpw from bytes only.
  final bool dynamic;

  /// Weighted/imatrix quant (`i1-`, `-imat`, `-i1-GGUF` repo).
  final bool imatrix;

  /// bartowski `_L`/`_XL`: "Uses Q8_0 for embed and output weights".
  final bool embedOutputQ8;

  /// Publisher-specific label with undocumented semantics (`Q4_K_P`).
  final bool custom;

  /// Too short to identify (`q4`): read `general.file_type` from the header.
  final bool ambiguous;

  /// No real ftype behind the label (`UD-Q8_K_XL` → nearest is Q8_0).
  final bool approximateBase;

  /// Two schemes in one model (`MXFP4-Q8`).
  final bool mixed;

  /// MLX mode (`affine`, `dwq`, `mxfp4`) or other scheme detail.
  final String? mode;

  /// EXL2/EXL3 head (lm_head) bits (`h6`, `H5`).
  final int? headBits;
  final String explanation;

  bool get isRemoved => ggufType?.isRemoved ?? false;

  @override
  String toString() => label;
}

enum ParamSizeKind {
  /// Total parameters (`27B`, `270M`).
  total,

  /// MoE written as experts × per-expert size (`8x7B`).
  experts,

  /// Gemma 3n/4 effective parameters (`E2B`): raw weights are far larger.
  effective,
}

/// A parameter-count label.
@immutable
final class ParamSize {
  const ParamSize({required this.label, required this.billions, this.kind = ParamSizeKind.total, this.experts});

  /// Normalized label: `27B`, `0.6B`, `270M`, `8x7B`, `E2B`, `A3B`.
  final String label;

  /// Parameters in billions as written (for `8x7B`: 8 × 7 = 56, an upper
  /// bound — Mixtral shares attention, so read the header for the truth).
  final double billions;
  final ParamSizeKind kind;
  final int? experts;

  int get approximateParameters => (billions * 1e9).round();

  @override
  String toString() => label;
}

/// Shard / part position.
@immutable
final class ShardInfo {
  const ShardInfo({required this.index, this.count, required this.byteSplit});

  /// 1-based.
  final int index;

  /// Null when the name has no total (`model-00001.safetensors`).
  final int? count;

  /// `.gguf.part1of2`: raw byte split, concatenate before loading. False for
  /// llama.cpp `-00001-of-00003.gguf` splits (separate files, all loaded
  /// together) and safetensors shards.
  final bool byteSplit;

  bool get isFirst => index == 1;

  @override
  String toString() => count == null ? 'part $index' : 'part $index of $count';
}

/// Problems and notable traits the UI and planner act on.
enum NameFlag {
  pickle('Pickle file: can execute code when loaded; blocked'),
  legacyGgml('Legacy GGML format: unsupported by current llama.cpp'),
  legacyFormat('Legacy format that current runtimes do not load'),
  removedQuant('Quant type removed from GGUF: current llama.cpp cannot load it'),
  bigEndian('Big-endian GGUF: cannot be loaded on phones'),
  gpuOnly('CUDA/server-only quantization: no mobile runtime'),
  notAModel('Not a model weights file'),
  unknownSidecar('Unrecognized companion file; not offered as a model'),
  byteSplit('Byte-split part: join all parts in order before loading'),
  ambiguousQuant('Quant label is ambiguous; the GGUF header decides'),
  customQuant('Publisher-specific quant label with undocumented semantics'),
  unknownQuantScheme('Unknown quantization scheme; size comes from file bytes'),
  newRuntimeQuant('Quant type needs a recent llama.cpp build'),
  ternaryQuant('Ternary quant: only meaningful for ternary-trained models'),
  uncensored('Uncensored/abliterated fine-tune: hidden by the default content filter');

  const NameFlag(this.explanation);

  final String explanation;

  /// Flags that make a file unusable as a model in Sherpa.
  bool get blocking => switch (this) {
        pickle || legacyGgml || legacyFormat || removedQuant || bigEndian || gpuOnly || notAModel || unknownSidecar => true,
        _ => false,
      };
}
