import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'ggml_types.dart';
import 'gguf_metadata.dart';

/// GGUF metadata value types (ggml `docs/gguf.md`, `enum gguf_type`).
enum GgufValueType {
  uint8(0, 1),
  int8(1, 1),
  uint16(2, 2),
  int16(3, 2),
  uint32(4, 4),
  int32(5, 4),
  float32(6, 4),
  boolean(7, 1),
  string(8, 0),
  array(9, 0),
  uint64(10, 8),
  int64(11, 8),
  float64(12, 8);

  const GgufValueType(this.id, this.fixedSize);

  final int id;

  /// Encoded size for scalar types; 0 for variable-length ones.
  final int fixedSize;

  static GgufValueType? byId(int id) => id >= 0 && id < values.length ? values[id] : null;
}

/// An array value. Long arrays (tokenizer vocabularies, merges, scores) are
/// skipped without materializing them: only [length] is kept and [values] is
/// null. The header peek must stay cheap on a phone — a 152k-entry vocab
/// would otherwise allocate ~150k strings per probe.
@immutable
final class GgufArray {
  const GgufArray({required this.elementType, required this.length, this.values});

  final GgufValueType elementType;
  final int length;
  final List<Object?>? values;

  bool get isSkipped => values == null;

  @override
  String toString() => isSkipped ? 'array<${elementType.name}>[$length] (skipped)' : 'array$values';
}

/// A string longer than [GgufReadLimits.maxRetainedStringBytes] (e.g. an
/// embedded `tokenizer.huggingface.json`); only its length is kept.
@immutable
final class GgufSkippedString {
  const GgufSkippedString(this.byteLength);

  final int byteLength;

  @override
  String toString() => 'string[$byteLength bytes] (skipped)';
}

/// One tensor-info record. Offsets are relative to the aligned data section.
@immutable
final class GgufTensorInfo {
  const GgufTensorInfo({required this.name, required this.dims, required this.typeId, required this.offset});

  final String name;
  final List<int> dims;
  final int typeId;
  final int offset;

  /// Null for unknown or removed ggml types (e.g. 31–33 `Q4_0_4_4/4_8/8_8`).
  GgmlType? get type => GgmlTypes.byId(typeId);

  int get elementCount => dims.fold(1, (a, b) => a * b);

  /// Bytes of this tensor's data, or null when the type is unknown.
  int? get byteSize {
    final t = type;
    if (t == null) return null;
    // ggml_nbytes: rows of ne[0] elements, each rounded to whole blocks.
    final rows = elementCount ~/ dims.first;
    return t.rowSize(dims.first) * rows;
  }
}

/// Defensive limits. Real files have tens of KV pairs and at most a few
/// thousand tensors; vocab arrays reach ~280k entries (R08 §11, "we saw
/// n_kv=35, arrays of 280k"). Anything far outside is treated as corrupt or
/// hostile rather than allocated.
@immutable
final class GgufReadLimits {
  const GgufReadLimits({
    this.maxKvCount = 1 << 16,
    this.maxTensorCount = 1 << 20,
    this.maxKeyBytes = 1 << 16,
    this.maxStringBytes = 256 << 20,
    this.maxRetainedStringBytes = 1 << 20,
    this.maxArrayLength = 1 << 32,
    this.maxRetainedArrayLength = 8192,
    this.maxArrayDepth = 3,
    this.maxTensorDims = 4,
  });

  final int maxKvCount;
  final int maxTensorCount;
  final int maxKeyBytes;

  /// Any string longer than this is corruption (a GGUF string is a single
  /// metadata value, not tensor data).
  final int maxStringBytes;

  /// Longer strings are skipped and kept as [GgufSkippedString].
  final int maxRetainedStringBytes;
  final int maxArrayLength;

  /// Longer arrays are skipped (values null). Per-layer arrays (head counts,
  /// SWA patterns) are far below this.
  final int maxRetainedArrayLength;
  final int maxArrayDepth;

  /// `GGML_MAX_DIMS`.
  final int maxTensorDims;
}

/// The file is not a loadable GGUF (bad magic, wrong endianness,
/// unsupported version, absurd counts, or contradicting sizes).
final class GgufFormatException implements Exception {
  const GgufFormatException(this.message, {this.offset, this.bigEndian = false});

  final String message;
  final int? offset;

  /// The file is a big-endian GGUF (e.g. `ggml-model-f16-big-endian.gguf`,
  /// R08 §14 row 63): valid for s390x, unloadable on phones.
  final bool bigEndian;

  @override
  String toString() => 'GgufFormatException: $message${offset == null ? '' : ' (at byte $offset)'}';
}

sealed class GgufParseResult {
  const GgufParseResult();
}

/// The buffer ends inside the header or KV section. Fetch at least
/// [requiredBytes] from the start of the file and parse again.
final class GgufNeedMoreBytes extends GgufParseResult {
  const GgufNeedMoreBytes({required this.requiredBytes, required this.availableBytes, required this.kvParsed});

  final int requiredBytes;
  final int availableBytes;

  /// KV pairs completely parsed before the buffer ran out (progress hint).
  final int kvParsed;

  @override
  String toString() => 'GgufNeedMoreBytes(need $requiredBytes, have $availableBytes, kv parsed $kvParsed)';
}

/// A parsed header. [metadata] is always complete; the tensor-info table is
/// optional because device fit only needs the KV section, but it gives the
/// exact parameter count and data offset when it fits in the buffer.
final class GgufHeader extends GgufParseResult {
  const GgufHeader({
    required this.version,
    required this.tensorCount,
    required this.kvCount,
    required this.metadata,
    required this.kvEndOffset,
    this.tensors,
    this.tensorInfoEndOffset,
    this.tensorInfoRequiredBytes,
  });

  final int version;
  final int tensorCount;
  final int kvCount;
  final GgufMetadata metadata;

  /// Byte offset just after the last KV pair.
  final int kvEndOffset;

  /// Null when the buffer ended inside the tensor-info table (or it was not
  /// requested); see [tensorInfoRequiredBytes].
  final List<GgufTensorInfo>? tensors;
  final int? tensorInfoEndOffset;

  /// Bytes needed to also read the tensor-info table, when [tensors] is null
  /// because the buffer was too short.
  final int? tensorInfoRequiredBytes;

  bool get hasTensorInfo => tensors != null;

  /// Start of tensor data: tensor-info end rounded up to `general.alignment`.
  int? get dataOffset {
    final end = tensorInfoEndOffset;
    if (end == null) return null;
    final a = metadata.alignment;
    return (end + a - 1) ~/ a * a;
  }

  /// Σ elements over all tensors — the model's real parameter count
  /// (Qwen3-0.6B: 596,049,920, matching `llama_model_n_params`, R04 §4).
  int? get parameterCount => tensors?.fold<int>(0, (a, t) => a + t.elementCount);

  /// Σ tensor bytes (`llama_model_size`); null if any type is unknown.
  int? get tensorDataBytes {
    final ts = tensors;
    if (ts == null) return null;
    var sum = 0;
    for (final t in ts) {
      final b = t.byteSize;
      if (b == null) return null;
      sum += b;
    }
    return sum;
  }

  /// Tensor count per ggml type name (`Q4_K: 168, Q6_K: 29, F32: 113`).
  Map<String, int> get tensorTypeCounts {
    final out = <String, int>{};
    for (final t in tensors ?? const <GgufTensorInfo>[]) {
      final name = t.type?.name ?? 'type#${t.typeId}';
      out[name] = (out[name] ?? 0) + 1;
    }
    return out;
  }

  /// Tensors whose ggml type this reader does not know — removed repack
  /// types (31–33, 36–38) or something newer than the vendored llama.cpp.
  List<GgufTensorInfo> get unknownTypeTensors =>
      [for (final t in tensors ?? const <GgufTensorInfo>[]) if (t.type == null) t];
}

final class _Truncated implements Exception {
  const _Truncated(this.required);

  final int required;
}

/// Pure-Dart GGUF header reader.
///
/// The GGUF layout puts all metadata (architecture, context length, layer
/// and head counts, chat template) before the tensor data, so one Range
/// request of a few MB answers every device-fit question before a
/// multi-GB download (R08 §5.6: a 128k-vocab model's KV section ended at
/// 7.83 MB). The parser is restartable rather than resumable: when the
/// buffer is short it reports how many bytes it needs and the caller
/// re-parses a longer prefix. Re-parsing skips arrays in O(1) (fixed-size
/// elements) or O(n) length hops (strings), so it stays cheap.
abstract final class GgufReader {
  /// `GGUF` read as a little-endian uint32.
  static const int magic = 0x46554747;

  /// Magic + version + tensor count + KV count.
  static const int fixedHeaderBytes = 24;

  /// Parses a prefix of a GGUF file.
  ///
  /// [fileSize], when known (from `Content-Range` or the tree listing), lets
  /// the reader reject lengths that point past the end of the file instead
  /// of asking for more bytes forever.
  static GgufParseResult parse(
    Uint8List bytes, {
    GgufReadLimits limits = const GgufReadLimits(),
    bool readTensorInfo = true,
    int? fileSize,
  }) {
    final r = _Reader(bytes, limits, fileSize);
    final GgufMetadata metadata;
    final int version;
    final int tensorCount;
    final int kvCount;
    try {
      r.need(4);
      final m = r.u32();
      if (m != magic) {
        throw GgufFormatException('not a GGUF file (magic 0x${m.toRadixString(16)})', offset: 0);
      }
      r.need(4);
      version = r.u32();
      if (version != 2 && version != 3) {
        final swapped = _swap32(version);
        if (swapped >= 1 && swapped <= 3) {
          throw const GgufFormatException('big-endian GGUF; phones are little-endian', offset: 4, bigEndian: true);
        }
        throw GgufFormatException(
          version == 1 ? 'GGUF v1 (32-bit lengths) is no longer supported' : 'unsupported GGUF version $version',
          offset: 4,
        );
      }
      tensorCount = r.u64();
      kvCount = r.u64();
      if (tensorCount < 0 || tensorCount > limits.maxTensorCount) {
        throw GgufFormatException('implausible tensor count $tensorCount', offset: 8);
      }
      if (kvCount < 0 || kvCount > limits.maxKvCount) {
        throw GgufFormatException('implausible metadata count $kvCount', offset: 16);
      }
      final kv = <String, Object?>{};
      for (var i = 0; i < kvCount; i++) {
        r.progress = i;
        final keyOffset = r.pos;
        final key = r.string(maxBytes: limits.maxKeyBytes, retainLimit: limits.maxKeyBytes);
        if (key is! String || key.isEmpty) {
          throw GgufFormatException('invalid metadata key', offset: keyOffset);
        }
        r.need(4);
        final typeOffset = r.pos;
        final type = GgufValueType.byId(r.u32());
        if (type == null) throw GgufFormatException('unknown value type for "$key"', offset: typeOffset);
        final value = r.value(type, 0);
        if (kv.containsKey(key)) {
          // llama.cpp's gguf_init rejects duplicate keys; so do we, rather
          // than offering a file the engine will refuse.
          throw GgufFormatException('duplicate metadata key "$key"', offset: keyOffset);
        }
        kv[key] = value;
      }
      metadata = GgufMetadata(kv);
    } on _Truncated catch (t) {
      return GgufNeedMoreBytes(requiredBytes: t.required, availableBytes: bytes.length, kvParsed: r.progress);
    }

    final kvEnd = r.pos;
    if (!readTensorInfo) {
      return GgufHeader(
        version: version,
        tensorCount: tensorCount,
        kvCount: kvCount,
        metadata: metadata,
        kvEndOffset: kvEnd,
      );
    }
    try {
      final tensors = <GgufTensorInfo>[];
      for (var i = 0; i < tensorCount; i++) {
        final at = r.pos;
        final name = r.string(maxBytes: limits.maxKeyBytes, retainLimit: limits.maxKeyBytes);
        if (name is! String) throw GgufFormatException('invalid tensor name', offset: at);
        r.need(4);
        final nDims = r.u32();
        if (nDims < 1 || nDims > limits.maxTensorDims) {
          throw GgufFormatException('tensor "$name" has $nDims dimensions', offset: at);
        }
        final dims = <int>[];
        var elements = 1;
        for (var d = 0; d < nDims; d++) {
          final v = r.u64();
          // 2^40 per dimension and 2^50 elements are far above any real
          // tensor and keep the products inside 64-bit ints.
          if (v < 0 || v > (1 << 40)) throw GgufFormatException('tensor "$name" dimension $v', offset: at);
          elements *= v;
          if (elements > (1 << 50)) throw GgufFormatException('tensor "$name" is implausibly large', offset: at);
          dims.add(v);
        }
        r.need(4);
        final typeId = r.u32();
        final offset = r.u64();
        if (offset < 0) throw GgufFormatException('tensor "$name" has a negative offset', offset: at);
        tensors.add(GgufTensorInfo(name: name, dims: List.unmodifiable(dims), typeId: typeId, offset: offset));
      }
      return GgufHeader(
        version: version,
        tensorCount: tensorCount,
        kvCount: kvCount,
        metadata: metadata,
        kvEndOffset: kvEnd,
        tensors: List.unmodifiable(tensors),
        tensorInfoEndOffset: r.pos,
      );
    } on _Truncated catch (t) {
      return GgufHeader(
        version: version,
        tensorCount: tensorCount,
        kvCount: kvCount,
        metadata: metadata,
        kvEndOffset: kvEnd,
        tensorInfoRequiredBytes: t.required,
      );
    }
  }

  static int _swap32(int v) =>
      ((v & 0xff) << 24) | ((v & 0xff00) << 8) | ((v >> 8) & 0xff00) | ((v >> 24) & 0xff);
}

final class _Reader {
  _Reader(this.bytes, this.limits, this.fileSize) : data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData data;
  final GgufReadLimits limits;
  final int? fileSize;
  int pos = 0;
  int progress = 0;

  void need(int n) {
    final end = pos + n;
    if (n < 0 || end < pos) throw GgufFormatException('length overflow', offset: pos);
    final size = fileSize;
    if (size != null && end > size) {
      throw GgufFormatException('value runs past the end of the file ($end > $size)', offset: pos);
    }
    if (end > bytes.length) throw _Truncated(end);
  }

  int u32() {
    final v = data.getUint32(pos, Endian.little);
    pos += 4;
    return v;
  }

  int u64() {
    need(8);
    // Dart ints are signed 64-bit; values >= 2^63 come back negative and are
    // rejected by the callers' range checks.
    final v = data.getUint64(pos, Endian.little);
    pos += 8;
    return v;
  }

  Object string({required int maxBytes, required int retainLimit}) {
    final at = pos;
    final len = u64();
    if (len < 0 || len > maxBytes) throw GgufFormatException('string of $len bytes', offset: at);
    need(len);
    if (len > retainLimit) {
      pos += len;
      return GgufSkippedString(len);
    }
    final s = utf8.decode(Uint8List.sublistView(bytes, pos, pos + len), allowMalformed: true);
    pos += len;
    return s;
  }

  Object? value(GgufValueType type, int depth) {
    switch (type) {
      case GgufValueType.string:
        return string(maxBytes: limits.maxStringBytes, retainLimit: limits.maxRetainedStringBytes);
      case GgufValueType.array:
        return array(depth + 1);
      default:
        need(type.fixedSize);
        return scalar(type);
    }
  }

  Object scalar(GgufValueType type) {
    final Object v = switch (type) {
      GgufValueType.uint8 => data.getUint8(pos),
      GgufValueType.int8 => data.getInt8(pos),
      GgufValueType.uint16 => data.getUint16(pos, Endian.little),
      GgufValueType.int16 => data.getInt16(pos, Endian.little),
      GgufValueType.uint32 => data.getUint32(pos, Endian.little),
      GgufValueType.int32 => data.getInt32(pos, Endian.little),
      GgufValueType.float32 => data.getFloat32(pos, Endian.little),
      GgufValueType.boolean => data.getUint8(pos) != 0,
      GgufValueType.uint64 => data.getUint64(pos, Endian.little),
      GgufValueType.int64 => data.getInt64(pos, Endian.little),
      GgufValueType.float64 => data.getFloat64(pos, Endian.little),
      GgufValueType.string || GgufValueType.array => throw StateError('not a scalar'),
    };
    pos += type.fixedSize;
    return v;
  }

  GgufArray array(int depth) {
    final at = pos;
    if (depth > limits.maxArrayDepth) throw GgufFormatException('arrays nested too deep', offset: at);
    need(4);
    final type = GgufValueType.byId(u32());
    if (type == null) throw GgufFormatException('unknown array element type', offset: at);
    final n = u64();
    if (n < 0 || n > limits.maxArrayLength) throw GgufFormatException('array of $n elements', offset: at);
    final retain = n <= limits.maxRetainedArrayLength;
    if (type.fixedSize > 0) {
      final bytesNeeded = n * type.fixedSize;
      if (!retain) {
        // O(1) skip: score/token-type arrays of ~150k floats/ints.
        need(bytesNeeded);
        pos += bytesNeeded;
        return GgufArray(elementType: type, length: n);
      }
      need(bytesNeeded);
      final values = <Object?>[for (var i = 0; i < n; i++) scalar(type)];
      return GgufArray(elementType: type, length: n, values: List.unmodifiable(values));
    }
    if (type == GgufValueType.string) {
      if (!retain) {
        // Length hops only: no string is decoded or allocated.
        for (var i = 0; i < n; i++) {
          final sAt = pos;
          final len = u64();
          if (len < 0 || len > limits.maxStringBytes) throw GgufFormatException('string of $len bytes', offset: sAt);
          need(len);
          pos += len;
        }
        return GgufArray(elementType: type, length: n);
      }
      final values = <Object?>[
        for (var i = 0; i < n; i++)
          string(maxBytes: limits.maxStringBytes, retainLimit: limits.maxRetainedStringBytes),
      ];
      return GgufArray(elementType: type, length: n, values: List.unmodifiable(values));
    }
    // Nested arrays.
    final values = <Object?>[];
    for (var i = 0; i < n; i++) {
      final v = array(depth);
      if (retain) values.add(v);
    }
    return GgufArray(elementType: type, length: n, values: retain ? List.unmodifiable(values) : null);
  }
}
