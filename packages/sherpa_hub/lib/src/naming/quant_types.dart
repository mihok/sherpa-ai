// Constant names mirror llama.cpp's own spellings (`q8_0`, `Q4_K_M`) on purpose:
// `KvCacheType.q8_0.name` is exactly the engine's `type_k` string, and grepping
// llama.cpp sources for a name finds the matching entry here.
// ignore_for_file: constant_identifier_names

import 'package:meta/meta.dart';

/// Whether Sherpa's bundled llama.cpp can load a GGUF file type.
enum QuantStatus {
  /// Loads with the pinned llama.cpp (R05) on every platform.
  supported,

  /// Recent addition (Q1_0, Q2_0, NVFP4, MXFP4): older bundled runtimes fail
  /// to load it, so the engine reports whether its build knows the type
  /// (R08 §16 risk 7).
  newRuntime,

  /// Ternary types: only meaningful for ternary-trained (BitNet-style)
  /// models; loads, but quality on ordinary models is unusable.
  ternary,

  /// Removed from GGUF (`Q4_0_4_4/4_8/8_8`, `IQ4_NL_x_y`, `Q4_2/3`):
  /// current llama.cpp refuses the file (R08 §12, quantize.cpp
  /// "removed from gguf files, use Q4_0 and runtime repack").
  removed,
}

/// One llama.cpp file type (`general.file_type` / `llama_ftype`).
///
/// Three different "bits per weight" exist and the UI must not mix them up
/// (R08 §12):
/// - [nominalBpw]: block bytes × 8 / block size of the main tensor type
///   (`gguf-py GGML_QUANT_SIZES`). Exact for the type, not for a file.
/// - [labelBpw]: what `llama-quantize` advertises for i-quant mixes
///   (quantize.cpp help text, e.g. IQ2_M "2.7 bpw"). Falls back to nominal.
/// - [typicalFileBpw]: whole-file bpw measured on Llama-3.1-8B
///   (tools/quantize/README.md), embeddings and output included.
///
/// None of them is reliable for small models: `gemma-3-270m` Q2_K is 7.07
/// effective bpw because the 262k-vocab embeddings dominate (R08 §0.20).
/// The device-fit engine always uses real file bytes.
@immutable
final class QuantType {
  const QuantType({
    required this.id,
    required this.ftype,
    required this.mainTensorType,
    required this.nominalBpw,
    required this.summary,
    required this.quality,
    this.labelBpw,
    this.typicalFileBpw,
    this.measuredBpwMoe30B,
    this.status = QuantStatus.supported,
    this.aliases = const [],
  });

  /// Canonical llama-quantize name, e.g. `Q4_K_M`.
  final String id;

  /// `llama_ftype` value written to `general.file_type`; null for types
  /// without one (the removed IQ4_NL_x_y repack types).
  final int? ftype;

  /// ggml tensor type that carries most weights (`Q4_K (+Q6_K)` → `Q4_K`).
  final String mainTensorType;
  final double? nominalBpw;
  final double? labelBpw;
  final double? typicalFileBpw;

  /// Live effective bpw for unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF
  /// (file bytes × 8 / 30.53B params, R08 §12 last column).
  final double? measuredBpwMoe30B;
  final QuantStatus status;

  /// Other spellings accepted by llama-quantize or used by publishers
  /// (`Q4_K` → `Q4_K_M`, `FP16` → `F16`).
  final List<String> aliases;

  /// Short description of the type for tooltips.
  final String summary;

  /// One-line quality/size trade-off.
  final String quality;

  /// The bpw to show next to the label: llama-quantize's own figure for
  /// i-quant mixes, the exact block bpw otherwise.
  double? get bpw => labelBpw ?? nominalBpw;

  /// Leading integer of the tag, mirroring llama.cpp `extract_quant_bits`
  /// (`Q4_0 → 4`, `F16 → 16`, `NVFP4 → 4`), used to pair sidecars.
  int get bits {
    final m = RegExp(r'\d+').firstMatch(id);
    return m == null ? 0 : int.parse(m.group(0)!);
  }

  bool get isFloat => id == 'F32' || id == 'F16' || id == 'BF16';

  bool get isRemoved => status == QuantStatus.removed;

  /// UI tooltip, e.g. "Q4_K_M: 4-bit k-quant, medium; ~4.9 bits/weight;
  /// good quality/size balance".
  String get explanation {
    if (isRemoved) return '$id: $summary; $quality';
    final b = typicalFileBpw ?? bpw;
    final bits = b == null ? '' : '; ~${formatBpw(b)} bits/weight';
    return '$id: $summary$bits; $quality';
  }

  @override
  String toString() => id;
}

/// One decimal is enough for a tooltip ("~4.9 bits/weight").
String formatBpw(double v) {
  final s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// The vendored llama.cpp quant set (R08 §12; `include/llama.h` ftype enum,
/// `gguf-py/gguf/constants.py GGML_QUANT_SIZES`, `tools/quantize`).
abstract final class QuantTypes {
  static const f32 = QuantType(
    id: 'F32', ftype: 0, mainTensorType: 'F32', nominalBpw: 32, aliases: ['FP32'],
    summary: '32-bit float, unquantized', quality: 'huge, no quality gain over F16',
  );
  static const f16 = QuantType(
    id: 'F16', ftype: 1, mainTensorType: 'F16', nominalBpw: 16, typicalFileBpw: 16, aliases: ['FP16'],
    summary: '16-bit float, unquantized', quality: 'reference quality, about 3× the size of Q4_K_M',
  );
  static const bf16 = QuantType(
    id: 'BF16', ftype: 32, mainTensorType: 'BF16', nominalBpw: 16,
    summary: 'bfloat16, unquantized', quality: 'reference quality, about 3× the size of Q4_K_M',
  );
  static const q8_0 = QuantType(
    id: 'Q8_0', ftype: 7, mainTensorType: 'Q8_0', nominalBpw: 8.5, typicalFileBpw: 8.5, measuredBpwMoe30B: 8.51,
    summary: '8-bit', quality: 'practically lossless (+0.0026 ppl vs F16), twice the size of Q4',
  );
  static const q6_k = QuantType(
    id: 'Q6_K', ftype: 18, mainTensorType: 'Q6_K', nominalBpw: 6.5625, typicalFileBpw: 6.56, measuredBpwMoe30B: 6.57,
    summary: '6-bit k-quant', quality: 'near-lossless (+0.0217 ppl)',
  );
  static const q5_k_m = QuantType(
    id: 'Q5_K_M', ftype: 17, mainTensorType: 'Q5_K', nominalBpw: 5.5, typicalFileBpw: 5.70, measuredBpwMoe30B: 5.69,
    aliases: ['Q5_K'], summary: '5-bit k-quant, medium', quality: 'very good quality (+0.0569 ppl)',
  );
  static const q5_k_s = QuantType(
    id: 'Q5_K_S', ftype: 16, mainTensorType: 'Q5_K', nominalBpw: 5.5, typicalFileBpw: 5.57, measuredBpwMoe30B: 5.52,
    summary: '5-bit k-quant, small', quality: 'very good quality (+0.1049 ppl)',
  );
  static const q5_1 = QuantType(
    id: 'Q5_1', ftype: 9, mainTensorType: 'Q5_1', nominalBpw: 6.0,
    summary: 'legacy 5-bit (with offset)', quality: 'superseded by Q5_K_M (+0.1062 ppl)',
  );
  static const q5_0 = QuantType(
    id: 'Q5_0', ftype: 8, mainTensorType: 'Q5_0', nominalBpw: 5.5,
    summary: 'legacy 5-bit', quality: 'superseded by Q5_K_S (+0.1316 ppl)',
  );
  static const q4_k_m = QuantType(
    id: 'Q4_K_M', ftype: 15, mainTensorType: 'Q4_K', nominalBpw: 4.5, typicalFileBpw: 4.89, measuredBpwMoe30B: 4.86,
    aliases: ['Q4_K'], summary: '4-bit k-quant, medium', quality: 'good quality/size balance (the usual default)',
  );
  static const q4_k_s = QuantType(
    id: 'Q4_K_S', ftype: 14, mainTensorType: 'Q4_K', nominalBpw: 4.5, typicalFileBpw: 4.67, measuredBpwMoe30B: 4.57,
    summary: '4-bit k-quant, small', quality: 'a little below Q4_K_M (+0.2689 ppl)',
  );
  static const q4_1 = QuantType(
    id: 'Q4_1', ftype: 3, mainTensorType: 'Q4_1', nominalBpw: 5.0, measuredBpwMoe30B: 5.03,
    summary: 'legacy 4-bit (with offset)', quality: 'below Q4_K_M at a larger size (+0.4511 ppl)',
  );
  static const q4_0 = QuantType(
    id: 'Q4_0', ftype: 2, mainTensorType: 'Q4_0', nominalBpw: 4.5, measuredBpwMoe30B: 4.55,
    summary: 'legacy 4-bit', quality: 'fast on ARM (repacked at load), lower quality than Q4_K (+0.4685 ppl)',
  );
  static const iq4_nl = QuantType(
    id: 'IQ4_NL', ftype: 25, mainTensorType: 'IQ4_NL', nominalBpw: 4.5, labelBpw: 4.5, typicalFileBpw: 4.68,
    measuredBpwMoe30B: 4.54, summary: '4-bit non-linear i-quant', quality: 'close to Q4_K_S, ARM-friendly',
  );
  static const iq4_xs = QuantType(
    id: 'IQ4_XS', ftype: 30, mainTensorType: 'IQ4_XS', nominalBpw: 4.25, labelBpw: 4.25, typicalFileBpw: 4.46,
    measuredBpwMoe30B: 4.29, summary: '4-bit i-quant, extra small', quality: 'close to Q4_K_S at a smaller size',
  );
  static const mxfp4_moe = QuantType(
    id: 'MXFP4_MOE', ftype: 38, mainTensorType: 'MXFP4', nominalBpw: 4.25, status: QuantStatus.newRuntime,
    summary: 'MXFP4 experts (gpt-oss native format)', quality: 'native quality for MXFP4-trained MoE models',
  );
  static const nvfp4 = QuantType(
    id: 'NVFP4', ftype: 39, mainTensorType: 'NVFP4', nominalBpw: 4.5, status: QuantStatus.newRuntime,
    summary: 'NVIDIA FP4 (E4M3 scales, 64-weight blocks)', quality: 'needs a recent llama.cpp',
  );
  static const q3_k_l = QuantType(
    id: 'Q3_K_L', ftype: 13, mainTensorType: 'Q3_K', nominalBpw: 3.4375, typicalFileBpw: 4.30,
    summary: '3-bit k-quant, large', quality: 'noticeable quality loss (+0.5562 ppl)',
  );
  static const q3_k_m = QuantType(
    id: 'Q3_K_M', ftype: 12, mainTensorType: 'Q3_K', nominalBpw: 3.4375, typicalFileBpw: 4.00, measuredBpwMoe30B: 3.85,
    aliases: ['Q3_K'], summary: '3-bit k-quant, medium', quality: 'noticeable quality loss (+0.6569 ppl)',
  );
  static const q3_k_s = QuantType(
    id: 'Q3_K_S', ftype: 11, mainTensorType: 'Q3_K', nominalBpw: 3.4375, typicalFileBpw: 3.64, measuredBpwMoe30B: 3.48,
    summary: '3-bit k-quant, small', quality: 'large quality loss (+1.6321 ppl)',
  );
  static const iq3_m = QuantType(
    id: 'IQ3_M', ftype: 27, mainTensorType: 'IQ3_S', nominalBpw: 3.4375, labelBpw: 3.66, typicalFileBpw: 3.76,
    summary: '3-bit i-quant mix, medium', quality: 'best of the 3-bit options',
  );
  static const iq3_s = QuantType(
    id: 'IQ3_S', ftype: 26, mainTensorType: 'IQ3_S', nominalBpw: 3.4375, labelBpw: 3.44, typicalFileBpw: 3.66,
    summary: '3-bit i-quant', quality: 'better than Q3_K_S at a similar size',
  );
  static const iq3_xs = QuantType(
    id: 'IQ3_XS', ftype: 22, mainTensorType: 'IQ3_XXS', nominalBpw: null, labelBpw: 3.3, typicalFileBpw: 3.50,
    summary: '3-bit i-quant mix, extra small', quality: 'clear quality loss',
  );
  static const iq3_xxs = QuantType(
    id: 'IQ3_XXS', ftype: 23, mainTensorType: 'IQ3_XXS', nominalBpw: 3.0625, labelBpw: 3.06, typicalFileBpw: 3.25,
    summary: '3-bit i-quant, extra-extra small', quality: 'clear quality loss',
  );
  static const q2_k = QuantType(
    id: 'Q2_K', ftype: 10, mainTensorType: 'Q2_K', nominalBpw: 2.625, typicalFileBpw: 3.16, measuredBpwMoe30B: 2.95,
    summary: '2-bit k-quant', quality: 'heavy quality loss (+3.5199 ppl), last resort',
  );
  static const q2_k_s = QuantType(
    id: 'Q2_K_S', ftype: 21, mainTensorType: 'Q2_K', nominalBpw: 2.625, typicalFileBpw: 2.97,
    summary: '2-bit k-quant, small', quality: 'heavy quality loss (+3.1836 ppl), last resort',
  );
  static const iq2_m = QuantType(
    id: 'IQ2_M', ftype: 29, mainTensorType: 'IQ2_S', nominalBpw: 2.5625, labelBpw: 2.7, typicalFileBpw: 2.93,
    summary: '2-bit i-quant mix, medium', quality: 'heavy quality loss; only for large models',
  );
  static const iq2_s = QuantType(
    id: 'IQ2_S', ftype: 28, mainTensorType: 'IQ2_S', nominalBpw: 2.5625, labelBpw: 2.5, typicalFileBpw: 2.74,
    summary: '2-bit i-quant', quality: 'heavy quality loss; only for large models',
  );
  static const iq2_xs = QuantType(
    id: 'IQ2_XS', ftype: 20, mainTensorType: 'IQ2_XS', nominalBpw: 2.3125, labelBpw: 2.31, typicalFileBpw: 2.59,
    summary: '2-bit i-quant, extra small', quality: 'heavy quality loss; only for large models',
  );
  static const iq2_xxs = QuantType(
    id: 'IQ2_XXS', ftype: 19, mainTensorType: 'IQ2_XXS', nominalBpw: 2.0625, labelBpw: 2.06, typicalFileBpw: 2.38,
    summary: '2-bit i-quant, extra-extra small', quality: 'heavy quality loss; only for large models',
  );
  static const q2_0 = QuantType(
    id: 'Q2_0', ftype: 41, mainTensorType: 'Q2_0', nominalBpw: 2.25, labelBpw: 2.25, status: QuantStatus.newRuntime,
    summary: '2-bit (64-weight groups)', quality: 'needs a recent llama.cpp; heavy quality loss',
  );
  static const tq2_0 = QuantType(
    id: 'TQ2_0', ftype: 37, mainTensorType: 'TQ2_0', nominalBpw: 2.0625, labelBpw: 2.06, status: QuantStatus.ternary,
    summary: 'ternary 2-bit packing', quality: 'only for ternary-trained (BitNet-style) models',
  );
  static const iq1_m = QuantType(
    id: 'IQ1_M', ftype: 31, mainTensorType: 'IQ1_M', nominalBpw: 1.75, labelBpw: 1.75, typicalFileBpw: 2.15,
    summary: '1.75-bit i-quant', quality: 'extreme compression; large models only',
  );
  static const tq1_0 = QuantType(
    id: 'TQ1_0', ftype: 36, mainTensorType: 'TQ1_0', nominalBpw: 1.6875, labelBpw: 1.69, status: QuantStatus.ternary,
    summary: 'ternary 1.69-bit packing', quality: 'only for ternary-trained (BitNet-style) models',
  );
  static const iq1_s = QuantType(
    id: 'IQ1_S', ftype: 24, mainTensorType: 'IQ1_S', nominalBpw: 1.5625, labelBpw: 1.56, typicalFileBpw: 2.00,
    summary: '1.56-bit i-quant', quality: 'extreme compression; large models only',
  );
  static const q1_0 = QuantType(
    id: 'Q1_0', ftype: 40, mainTensorType: 'Q1_0', nominalBpw: 1.125, labelBpw: 1.125, status: QuantStatus.newRuntime,
    summary: '1-bit (128-weight groups)', quality: 'needs a recent llama.cpp; extreme compression',
  );
  static const q4_0_4_4 = QuantType(
    id: 'Q4_0_4_4', ftype: 33, mainTensorType: 'Q4_0_4_4', nominalBpw: 4.5, status: QuantStatus.removed,
    summary: 'ARM-repacked Q4_0, removed from GGUF',
    quality: "current llama.cpp can't load it; use the Q4_0 file (repacked at load time)",
  );
  static const q4_0_4_8 = QuantType(
    id: 'Q4_0_4_8', ftype: 34, mainTensorType: 'Q4_0_4_8', nominalBpw: 4.5, status: QuantStatus.removed,
    summary: 'ARM-repacked Q4_0, removed from GGUF',
    quality: "current llama.cpp can't load it; use the Q4_0 file (repacked at load time)",
  );
  static const q4_0_8_8 = QuantType(
    id: 'Q4_0_8_8', ftype: 35, mainTensorType: 'Q4_0_8_8', nominalBpw: 4.5, status: QuantStatus.removed,
    summary: 'ARM-repacked Q4_0, removed from GGUF',
    quality: "current llama.cpp can't load it; use the Q4_0 file (repacked at load time)",
  );
  static const iq4_nl_4_4 = QuantType(
    id: 'IQ4_NL_4_4', ftype: null, mainTensorType: 'IQ4_NL_4_4', nominalBpw: 4.5, status: QuantStatus.removed,
    summary: 'repacked IQ4_NL, removed from GGUF',
    quality: "current llama.cpp can't load it; use the IQ4_NL file",
  );
  static const iq4_nl_4_8 = QuantType(
    id: 'IQ4_NL_4_8', ftype: null, mainTensorType: 'IQ4_NL_4_8', nominalBpw: 4.5, status: QuantStatus.removed,
    summary: 'repacked IQ4_NL, removed from GGUF',
    quality: "current llama.cpp can't load it; use the IQ4_NL file",
  );
  static const iq4_nl_8_8 = QuantType(
    id: 'IQ4_NL_8_8', ftype: null, mainTensorType: 'IQ4_NL_8_8', nominalBpw: 4.5, status: QuantStatus.removed,
    summary: 'repacked IQ4_NL, removed from GGUF',
    quality: "current llama.cpp can't load it; use the IQ4_NL file",
  );
  static const q4_1_some_f16 = QuantType(
    id: 'Q4_1_SOME_F16', ftype: 4, mainTensorType: 'Q4_1', nominalBpw: null, status: QuantStatus.removed,
    summary: 'pre-2023 mixed type, removed', quality: "current llama.cpp can't load it",
  );
  static const q4_2 = QuantType(
    id: 'Q4_2', ftype: 5, mainTensorType: 'Q4_2', nominalBpw: null, status: QuantStatus.removed,
    summary: 'pre-2023 4-bit type, removed', quality: "current llama.cpp can't load it",
  );
  static const q4_3 = QuantType(
    id: 'Q4_3', ftype: 6, mainTensorType: 'Q4_3', nominalBpw: null, status: QuantStatus.removed,
    summary: 'pre-2023 4-bit type, removed', quality: "current llama.cpp can't load it",
  );

  /// Every type, best quality first (the order the UI lists them in).
  static const List<QuantType> all = [
    f32, bf16, f16, q8_0, q6_k, q5_1, q5_k_m, q5_k_s, q5_0, q4_k_m, q4_1, q4_k_s, q4_0, iq4_nl, iq4_xs,
    mxfp4_moe, nvfp4, q3_k_l, q3_k_m, iq3_m, iq3_s, q3_k_s, iq3_xs, iq3_xxs, q2_k, q2_k_s, iq2_m, iq2_s,
    q2_0, iq2_xs, iq2_xxs, tq2_0, iq1_m, tq1_0, iq1_s, q1_0,
    q4_0_4_4, q4_0_4_8, q4_0_8_8, iq4_nl_4_4, iq4_nl_4_8, iq4_nl_8_8, q4_1_some_f16, q4_2, q4_3,
  ];

  /// `MXFP4` without `_MOE` (ggml-org `gpt-oss-20b-MXFP4.gguf`) is written
  /// with ftype MXFP4_MOE by the converters; treat it as the same type.
  static const Map<String, QuantType> _extraSpellings = {'MXFP4': mxfp4_moe};

  static final Map<String, QuantType> _byName = {
    for (final t in all) ...{t.id: t, for (final a in t.aliases) a: t},
    ..._extraSpellings,
  };

  static final Map<int, QuantType> _byFtype = {
    for (final t in all)
      if (t.ftype != null) t.ftype!: t,
  };

  /// Exact (case-insensitive) lookup of a llama-quantize name or alias.
  static QuantType? byName(String name) => _byName[name.toUpperCase()];

  /// Lookup by `general.file_type`. `1024` (GUESSED) and unknown ids give
  /// null: the caller then trusts the tensor types instead.
  static QuantType? byFtype(int ftype) => _byFtype[ftype];
}
