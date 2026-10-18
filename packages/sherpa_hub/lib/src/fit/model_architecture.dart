import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../gguf/ggml_types.dart';
import '../gguf/gguf_metadata.dart';
import 'fit_constants.dart';

/// The shape facts memory planning needs, per layer where models differ
/// per layer (GQA head counts, SWA, hybrid recurrent layers, shared KV).
///
/// Built from GGUF metadata ([ModelArchitecture.fromGguf]) — never from the
/// Hub's repo-level `gguf` summary, which describes one arbitrary file of
/// the repo (R08 §0.5).
@immutable
final class ModelArchitecture {
  const ModelArchitecture({
    required this.layerCount,
    required this.kvHeadsPerLayer,
    required this.keyLength,
    required this.valueLength,
    this.keyLengthSwa,
    this.valueLengthSwa,
    this.slidingWindow,
    this.swaLayers = const [],
    this.mlaKvRank,
    this.mlaRopeDim,
    this.trainContextLength,
    this.embeddingLength,
    this.feedForwardLength,
    this.vocabSize,
    this.headCount,
    this.expertCount,
    this.expertUsedCount,
    this.parameterCount,
    this.architecture,
    this.notes = const [],
  });

  /// Plain dense transformer (every layer full attention, same heads).
  factory ModelArchitecture.dense({
    required int layers,
    required int kvHeads,
    required int headDim,
    int? trainContextLength,
    int? embeddingLength,
    int? feedForwardLength,
    int? vocabSize,
    int? headCount,
    int? expertCount,
    int? expertUsedCount,
    int? parameterCount,
    String? architecture,
  }) =>
      ModelArchitecture(
        layerCount: layers,
        kvHeadsPerLayer: List.filled(layers, kvHeads),
        keyLength: headDim,
        valueLength: headDim,
        trainContextLength: trainContextLength,
        embeddingLength: embeddingLength,
        feedForwardLength: feedForwardLength,
        vocabSize: vocabSize,
        headCount: headCount,
        expertCount: expertCount,
        expertUsedCount: expertUsedCount,
        parameterCount: parameterCount,
        architecture: architecture,
      );

  factory ModelArchitecture.fromJson(JsonMap j) => ModelArchitecture(
        layerCount: j.req<num>('layerCount').toInt(),
        kvHeadsPerLayer: [for (final v in j.req<List<Object?>>('kvHeadsPerLayer')) (v! as num).toInt()],
        keyLength: j.req<num>('keyLength').toInt(),
        valueLength: j.req<num>('valueLength').toInt(),
        keyLengthSwa: j.optInt('keyLengthSwa'),
        valueLengthSwa: j.optInt('valueLengthSwa'),
        slidingWindow: j.optInt('slidingWindow'),
        swaLayers: [for (final v in j.opt<List<Object?>>('swaLayers') ?? const <Object?>[]) v == true],
        mlaKvRank: j.optInt('mlaKvRank'),
        mlaRopeDim: j.optInt('mlaRopeDim'),
        trainContextLength: j.optInt('trainContextLength'),
        embeddingLength: j.optInt('embeddingLength'),
        feedForwardLength: j.optInt('feedForwardLength'),
        vocabSize: j.optInt('vocabSize'),
        headCount: j.optInt('headCount'),
        expertCount: j.optInt('expertCount'),
        expertUsedCount: j.optInt('expertUsedCount'),
        parameterCount: j.optInt('parameterCount'),
        architecture: j.opt<String>('architecture'),
        notes: [for (final v in j.opt<List<Object?>>('notes') ?? const <Object?>[]) '$v'],
      );

  /// Layers in the main (trunk) context.
  final int layerCount;

  /// KV heads per layer; 0 = the layer keeps no KV (recurrent, convolution,
  /// shared-KV or NextN/MTP layers).
  final List<int> kvHeadsPerLayer;
  final int keyLength;
  final int valueLength;
  final int? keyLengthSwa;
  final int? valueLengthSwa;

  /// `n_swa` in tokens; null/0 = no sliding-window layers.
  final int? slidingWindow;

  /// Per-layer SWA flags (empty = none).
  final List<bool> swaLayers;

  /// MLA (DeepSeek-style) compressed KV: rank and RoPE dims; when set the
  /// cache holds one `(rank + rope)` K row and one `rank` V row per layer.
  final int? mlaKvRank;
  final int? mlaRopeDim;
  final int? trainContextLength;
  final int? embeddingLength;

  /// Per-token FFN width that is live at once (dense `n_ff`, or MoE
  /// `n_ff_exp × n_expert_used`).
  final int? feedForwardLength;
  final int? vocabSize;
  final int? headCount;
  final int? expertCount;
  final int? expertUsedCount;

  /// Exact count from the GGUF tensor table when known.
  final int? parameterCount;
  final String? architecture;

  /// Where the estimate is approximate (shown as reasons).
  final List<String> notes;

  bool get isMoe => (expertCount ?? 0) > 1;

  bool isSwa(int il) => il < swaLayers.length && swaLayers[il];

  /// Reads the shape from GGUF metadata, or returns null when the header
  /// lacks the keys KV sizing needs (block count and head geometry).
  static ModelArchitecture? fromGguf(GgufMetadata m, {int? parameterCount}) {
    final blocks = m.blockCount;
    if (blocks == null || blocks <= 0) return null;
    final notes = <String>[];
    final nextn = m.nextnPredictLayers ?? 0;
    final layers = math.max(1, blocks - nextn);

    var heads = m.headCountKvPerLayer;
    if (heads == null) {
      if (!m.hasSsmState) return null;
      heads = List.filled(layers, 0);
      notes.add('state-space model: fixed-size recurrent state not included');
    }
    final h = heads;
    final kv = List<int>.generate(layers, (i) => i < h.length ? h[i] : (h.isEmpty ? 0 : h.last));

    // Hybrid models: recurrent layers keep no KV (Qwen3.5/Qwen3-Next, MiniMax-01).
    final recurrent = m.recurrentLayers;
    final interval = m.fullAttentionInterval;
    if (recurrent != null) {
      for (var i = 0; i < layers && i < recurrent.length; i++) {
        if (recurrent[i]) kv[i] = 0;
      }
    } else if (interval != null && interval > 1) {
      for (var i = 0; i < layers; i++) {
        if ((i + 1) % interval != 0) kv[i] = 0;
      }
    }
    if (recurrent != null || (interval != null && interval > 1)) {
      notes.add('hybrid model: recurrent-layer state (small, fixed) not included');
    }

    // Trailing layers that reuse earlier KV (Gemma 4 key; Gemma 3n hard-codes
    // 20 KV layers in vendored src/models/gemma3n.cpp).
    final shared = m.sharedKvLayers;
    final kvFromStart = shared != null && shared > 0
        ? blocks - shared
        : m.architecture == 'gemma3n'
            ? 20
            : null;
    if (kvFromStart != null) {
      for (var i = math.max(0, kvFromStart); i < layers; i++) {
        kv[i] = 0;
      }
    }

    final window = m.slidingWindow;
    var swa = const <bool>[];
    if (window != null && window > 0) {
      final pattern = m.slidingWindowPattern ?? SwaDefaults.byArchitecture[m.architecture];
      if (pattern == null) {
        notes.add('sliding-window layout unknown: assumed full attention (over-estimates KV)');
      } else {
        swa = List<bool>.generate(layers, pattern.isSwa);
      }
    }

    final mla = m.kvLoraRank;
    if (mla != null && mla > 0) notes.add('MLA cache estimated from kv_lora_rank (approximate)');

    final keyLength = m.keyLength;
    if (keyLength == null && mla == null && kv.any((h) => h > 0)) return null;

    final ff = m.isMoe && m.expertFeedForwardLength != null
        ? m.expertFeedForwardLength! * (m.expertUsedCount ?? 1) +
            (m.expertSharedFeedForwardLength ?? 0) * (m.expertSharedCount ?? (m.expertSharedFeedForwardLength == null ? 0 : 1))
        : m.feedForwardLength;

    return ModelArchitecture(
      layerCount: layers,
      kvHeadsPerLayer: List.unmodifiable(kv),
      keyLength: keyLength ?? 0,
      valueLength: m.valueLength ?? keyLength ?? 0,
      keyLengthSwa: m.keyLengthSwa,
      valueLengthSwa: m.valueLengthSwa,
      slidingWindow: window,
      swaLayers: List.unmodifiable(swa),
      mlaKvRank: mla,
      mlaRopeDim: m.ropeDimensionCount,
      trainContextLength: m.contextLength,
      embeddingLength: m.embeddingLength,
      feedForwardLength: ff,
      vocabSize: m.vocabSize,
      headCount: m.headCount,
      expertCount: m.expertCount,
      expertUsedCount: m.expertUsedCount,
      parameterCount: parameterCount,
      architecture: m.architecture,
      notes: List.unmodifiable(notes),
    );
  }

  JsonMap toJson() => compact({
        'layerCount': layerCount,
        'kvHeadsPerLayer': kvHeadsPerLayer,
        'keyLength': keyLength,
        'valueLength': valueLength,
        'keyLengthSwa': keyLengthSwa,
        'valueLengthSwa': valueLengthSwa,
        'slidingWindow': slidingWindow,
        'swaLayers': swaLayers.isEmpty ? null : swaLayers,
        'mlaKvRank': mlaKvRank,
        'mlaRopeDim': mlaRopeDim,
        'trainContextLength': trainContextLength,
        'embeddingLength': embeddingLength,
        'feedForwardLength': feedForwardLength,
        'vocabSize': vocabSize,
        'headCount': headCount,
        'expertCount': expertCount,
        'expertUsedCount': expertUsedCount,
        'parameterCount': parameterCount,
        'architecture': architecture,
        'notes': notes.isEmpty ? null : notes,
      });
}

/// KV cache size for one context configuration.
@immutable
final class KvEstimate {
  const KvEstimate({
    required this.bytes,
    required this.contextCells,
    required this.swaCells,
    required this.streams,
    required this.attentionLayers,
    required this.swaLayerCount,
    required this.bytesPerFullCell,
  });

  final int bytes;

  /// `n_ctx_seq` after padding to 256.
  final int contextCells;

  /// Cells in the SWA cache (equals [contextCells] when `swa_full`).
  final int swaCells;

  /// KV streams (1 when unified, else one per sequence).
  final int streams;
  final int attentionLayers;
  final int swaLayerCount;

  /// Bytes one token costs across full-attention layers.
  final int bytesPerFullCell;
}

int _pad(int v, int to) => (v + to - 1) ~/ to * to;

/// llama.cpp's KV formula (R04 §6, `src/llama-kv-cache.cpp:209-234`):
///
/// ```
/// bytes_per_cell = Σ_attention layers row_size(type_k, n_head_kv·key_length)
///                                   + row_size(type_v, n_head_kv·value_length)
/// KV_bytes       = bytes_per_cell · kv_size · n_stream
/// ```
///
/// `key_length` comes from the metadata, not `n_embd / n_head` (wrong for
/// Qwen3). SWA layers use the smaller SWA cache unless [swaFull]. For
/// Qwen3-0.6B at 4096 this gives f16 448 MiB, q8_0 238 MiB, q4_0 126 MiB —
/// exactly PROBE-1.
KvEstimate estimateKvCache(
  ModelArchitecture a, {
  required int contextLength,
  KvCacheType typeK = KvCacheType.q8_0,
  KvCacheType typeV = KvCacheType.q8_0,
  int sequences = 1,
  bool unified = true,
  bool swaFull = false,
  int nUbatch = 256,
}) {
  final seqs = math.max(1, sequences);
  final ctx = math.max(1, contextLength);
  final cells = unified ? _pad(ctx, FitConstants.contextPadding) : _pad((ctx + seqs - 1) ~/ seqs, FitConstants.contextPadding);
  final streams = unified ? 1 : seqs;
  final window = a.slidingWindow ?? 0;
  final swaCells = swaFull || window <= 0
      ? cells
      : math.min(cells, _pad(math.min(cells, window * (unified ? seqs : 1) + nUbatch), FitConstants.swaPadding));

  var bytes = 0;
  var full = 0;
  var attn = 0;
  var swaCount = 0;
  for (var il = 0; il < a.layerCount; il++) {
    final heads = il < a.kvHeadsPerLayer.length ? a.kvHeadsPerLayer[il] : 0;
    if (heads <= 0 && a.mlaKvRank == null) continue;
    final swa = a.isSwa(il);
    final int rowK;
    final int rowV;
    final mla = a.mlaKvRank;
    if (mla != null && mla > 0) {
      rowK = typeK.ggml.rowSize(mla + (a.mlaRopeDim ?? 0));
      rowV = typeV.ggml.rowSize(mla);
    } else {
      final kLen = swa ? (a.keyLengthSwa ?? a.keyLength) : a.keyLength;
      final vLen = swa ? (a.valueLengthSwa ?? a.valueLength) : a.valueLength;
      rowK = typeK.ggml.rowSize(heads * kLen);
      rowV = typeV.ggml.rowSize(heads * vLen);
    }
    attn++;
    if (swa) {
      swaCount++;
      bytes += (rowK + rowV) * swaCells * streams;
    } else {
      full += rowK + rowV;
      bytes += (rowK + rowV) * cells * streams;
    }
  }
  return KvEstimate(
    bytes: bytes,
    contextCells: cells,
    swaCells: swaCells,
    streams: streams,
    attentionLayers: attn,
    swaLayerCount: swaCount,
    bytesPerFullCell: full,
  );
}

/// Compute-buffer estimate fitted to R04 PROBE-1b (see [FitConstants]).
///
/// [outputs] is `n_outputs_max`: the default 0 means `n_batch` outputs and
/// costs a full `n_batch × n_vocab` f32 logits buffer (302.8 MiB for Qwen3),
/// which Sherpa avoids by setting it to `max(n_seq, n_draft + 1)` (R04 §21).
/// Without flash attention one layer's f32 `KQ` scores are added.
int estimateComputeBytes(
  ModelArchitecture a, {
  required int nUbatch,
  int outputs = 1,
  required int contextCells,
  bool flashAttention = true,
}) {
  final embd = a.embeddingLength ?? ((a.headCount ?? 32) * (a.keyLength == 0 ? 128 : a.keyLength));
  final ff = a.feedForwardLength ?? embd * FitConstants.fallbackFfMultiplier;
  final vocab = a.vocabSize ?? FitConstants.fallbackVocab;
  const f = FitConstants.activationBytes;
  final ffn = nUbatch * f * (FitConstants.computeEmbdFactor * embd + FitConstants.computeFfFactor * ff);
  final out = math.max(1, outputs) * vocab * f + nUbatch * f * FitConstants.computeEmbdFactor * embd;
  final kq = flashAttention ? 0 : nUbatch * contextCells * (a.headCount ?? 32) * f;
  return math.max(ffn, out) + kq;
}
