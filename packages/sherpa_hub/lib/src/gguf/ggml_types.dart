// Constant names mirror llama.cpp's own spellings (`q8_0`, `Q4_K_M`) on purpose:
// `KvCacheType.q8_0.name` is exactly the engine's `type_k` string, and grepping
// llama.cpp sources for a name finds the matching entry here.
// ignore_for_file: constant_identifier_names

import 'package:meta/meta.dart';

/// A ggml tensor element type with its block layout.
///
/// Ids are `enum ggml_type` (vendored `ggml/include/ggml.h`); block sizes are
/// `GGML_QUANT_SIZES` from `gguf-py/gguf/constants.py` (R08 §12). Removed ids
/// (4, 5, 31–33, 36–38) are absent, so a tensor of a removed type is reported
/// as unknown instead of silently mis-sized.
@immutable
final class GgmlType {
  const GgmlType(this.id, this.name, this.blockSize, this.typeSize);

  final int id;
  final String name;

  /// Elements per block.
  final int blockSize;

  /// Bytes per block.
  final int typeSize;

  double get bitsPerWeight => typeSize * 8 / blockSize;

  /// `ggml_row_size`: bytes for [elements] values, rounded up to whole
  /// blocks (llama.cpp asserts divisibility; rounding keeps us safe on odd
  /// head sizes instead of under-counting).
  int rowSize(int elements) => ((elements + blockSize - 1) ~/ blockSize) * typeSize;

  @override
  String toString() => name;
}

abstract final class GgmlTypes {
  static const int _qkK = 256;

  static const f32 = GgmlType(0, 'F32', 1, 4);
  static const f16 = GgmlType(1, 'F16', 1, 2);
  static const q4_0 = GgmlType(2, 'Q4_0', 32, 2 + 16);
  static const q4_1 = GgmlType(3, 'Q4_1', 32, 2 + 2 + 16);
  static const q5_0 = GgmlType(6, 'Q5_0', 32, 2 + 4 + 16);
  static const q5_1 = GgmlType(7, 'Q5_1', 32, 2 + 2 + 4 + 16);
  static const q8_0 = GgmlType(8, 'Q8_0', 32, 2 + 32);
  static const q8_1 = GgmlType(9, 'Q8_1', 32, 2 + 2 + 32);
  static const q2_k = GgmlType(10, 'Q2_K', _qkK, 2 + 2 + _qkK ~/ 16 + _qkK ~/ 4);
  static const q3_k = GgmlType(11, 'Q3_K', _qkK, 2 + _qkK ~/ 4 + _qkK ~/ 8 + 12);
  static const q4_k = GgmlType(12, 'Q4_K', _qkK, 2 + 2 + _qkK ~/ 2 + 12);
  static const q5_k = GgmlType(13, 'Q5_K', _qkK, 2 + 2 + _qkK ~/ 2 + _qkK ~/ 8 + 12);
  static const q6_k = GgmlType(14, 'Q6_K', _qkK, 2 + _qkK ~/ 2 + _qkK ~/ 4 + _qkK ~/ 16);
  static const q8_k = GgmlType(15, 'Q8_K', _qkK, 4 + _qkK + _qkK ~/ 8);
  static const iq2_xxs = GgmlType(16, 'IQ2_XXS', _qkK, 2 + _qkK ~/ 4);
  static const iq2_xs = GgmlType(17, 'IQ2_XS', _qkK, 2 + _qkK ~/ 4 + _qkK ~/ 32);
  static const iq3_xxs = GgmlType(18, 'IQ3_XXS', _qkK, 2 + _qkK ~/ 4 + _qkK ~/ 8);
  static const iq1_s = GgmlType(19, 'IQ1_S', _qkK, 2 + _qkK ~/ 8 + _qkK ~/ 16);
  static const iq4_nl = GgmlType(20, 'IQ4_NL', 32, 2 + 16);
  static const iq3_s = GgmlType(21, 'IQ3_S', _qkK, 2 + _qkK ~/ 4 + _qkK ~/ 8 + _qkK ~/ 32 + 4);
  static const iq2_s = GgmlType(22, 'IQ2_S', _qkK, 2 + _qkK ~/ 4 + _qkK ~/ 16);
  static const iq4_xs = GgmlType(23, 'IQ4_XS', _qkK, 2 + 2 + _qkK ~/ 2 + _qkK ~/ 64);
  static const i8 = GgmlType(24, 'I8', 1, 1);
  static const i16 = GgmlType(25, 'I16', 1, 2);
  static const i32 = GgmlType(26, 'I32', 1, 4);
  static const i64 = GgmlType(27, 'I64', 1, 8);
  static const f64 = GgmlType(28, 'F64', 1, 8);
  static const iq1_m = GgmlType(29, 'IQ1_M', _qkK, _qkK ~/ 8 + _qkK ~/ 16 + _qkK ~/ 32);
  static const bf16 = GgmlType(30, 'BF16', 1, 2);
  static const tq1_0 = GgmlType(34, 'TQ1_0', _qkK, 2 + 4 * 13);
  static const tq2_0 = GgmlType(35, 'TQ2_0', _qkK, 2 + 64);
  static const mxfp4 = GgmlType(39, 'MXFP4', 32, 1 + 16);
  static const nvfp4 = GgmlType(40, 'NVFP4', 64, 4 + 32);
  static const q1_0 = GgmlType(41, 'Q1_0', 128, 2 + 16);
  static const q2_0 = GgmlType(42, 'Q2_0', 64, 2 + 16);

  static const List<GgmlType> all = [
    f32, f16, q4_0, q4_1, q5_0, q5_1, q8_0, q8_1, q2_k, q3_k, q4_k, q5_k, q6_k, q8_k, iq2_xxs, iq2_xs,
    iq3_xxs, iq1_s, iq4_nl, iq3_s, iq2_s, iq4_xs, i8, i16, i32, i64, f64, iq1_m, bf16, tq1_0, tq2_0,
    mxfp4, nvfp4, q1_0, q2_0,
  ];

  static final Map<int, GgmlType> _byId = {for (final t in all) t.id: t};

  static GgmlType? byId(int id) => _byId[id];
}

/// KV cache element types llama.cpp accepts for `type_k` / `type_v`
/// (`common/arg.cpp` cache-type list; R04 §5–6).
enum KvCacheType {
  f32(GgmlTypes.f32),
  f16(GgmlTypes.f16),
  bf16(GgmlTypes.bf16),
  q8_0(GgmlTypes.q8_0),
  q4_0(GgmlTypes.q4_0),
  q4_1(GgmlTypes.q4_1),
  iq4_nl(GgmlTypes.iq4_nl),
  q5_0(GgmlTypes.q5_0),
  q5_1(GgmlTypes.q5_1);

  const KvCacheType(this.ggml);

  final GgmlType ggml;

  /// A quantized V cache forces flash attention (R04 §0.6); with FA the
  /// block size must divide the head size.
  bool get isQuantized => ggml.blockSize > 1;
}
