import 'package:meta/meta.dart';

import 'name_types.dart';
import 'quant_types.dart';

/// Everything a repo id + file name (+ branch) say about a model.
///
/// Names are the least trusted source (R08 §13.4 precedence: GGUF header >
/// Hub metadata > file name > repo name). They are still what the browser
/// shows before any download, so every field carries a tooltip
/// ([Decoded.explanation]) and where it came from ([Decoded.source]).
@immutable
final class ParsedModelName {
  const ParsedModelName({
    required this.repoId,
    required this.owner,
    required this.repoName,
    required this.format,
    required this.role,
    this.fileName,
    this.revision,
    this.folder,
    this.draftKind,
    this.family,
    this.namePrefix,
    this.baseFamily,
    this.teacher,
    this.qualifiers = const [],
    this.version,
    this.build,
    this.size,
    this.tier,
    this.activeParams,
    this.contextHint,
    this.variants = const [],
    this.quant,
    this.shard,
    this.deviceTarget,
    this.flags = const {},
    this.unrecognized = const [],
  });

  final String repoId;
  final String owner;
  final String repoName;

  /// Path inside the repo, as given.
  final String? fileName;

  /// Branch / tag the variant lives on (EXL2/EXL3/GPTQ repos).
  final String? revision;

  /// Directory part of [fileName] (`BF16`, `UD-IQ1_S`, `MTP`).
  final String? folder;
  final ModelFormat format;
  final Decoded<FileRole> role;
  final DraftKind? draftKind;

  /// Core family (`Qwen`, `Gemma`, `Muse Spark Open`).
  final Decoded<String>? family;

  /// Publisher / fine-tuner prefix (`google` in `google_gemma-…`, `NVIDIA`).
  final Decoded<String>? namePrefix;

  /// Base model of a fine-tune or distill (`Llama` for `L3-…`, `Qwen` for
  /// `…-Distill-Qwen-…`).
  final Decoded<String>? baseFamily;

  /// Teacher of a distill written after the size (`Kimi k3` in
  /// `Qwen3.5-9B-Kimi-k3-Distilled`).
  final Decoded<String>? teacher;

  /// Other name words (`Groq` in `Llama-3-Groq-8B-Tool-Use`).
  final List<String> qualifiers;
  final Decoded<String>? version;

  /// Release tag such as `2507` (YYMM).
  final Decoded<String>? build;
  final Decoded<ParamSize>? size;

  /// Size tier word (`mini`, `Small`, `Flash`, `Super`).
  final Decoded<String>? tier;

  /// MoE active parameters (`A3B`).
  final Decoded<ParamSize>? activeParams;

  /// Context length implied by the name (`1M`, `4k`, `32K`, `ekv4096`).
  final Decoded<int>? contextHint;
  final List<Decoded<NameVariant>> variants;
  final Decoded<QuantLabel>? quant;
  final Decoded<ShardInfo>? shard;

  /// LiteRT build target (`Google Tensor G5`, `Qualcomm SM8650`, `web`).
  final String? deviceTarget;
  final Set<NameFlag> flags;

  /// Tokens the parser could not classify (`fl2va`, `lr3e`).
  final List<String> unrecognized;

  bool get isBlocked => flags.any((f) => f.blocking);

  /// A file Sherpa can offer as the main model of a variant.
  bool get isPrimaryModel => role.value == FileRole.model && !isBlocked;

  bool get isMoe => activeParams != null || size?.value.kind == ParamSizeKind.experts;

  bool get isUncensored => variants.any((v) => v.value.isUncensored);

  bool hasVariant(NameVariant v) => variants.any((d) => d.value == v);

  /// "Qwen 3.8 27B", "Gemma 4 E2B it", "Muse Spark Open 816B-A42B".
  String get displayName {
    final parts = <String>[
      if (family != null) family!.value,
      if (version != null) version!.value,
      if (size != null) size!.value.label + (activeParams == null ? '' : '-${activeParams!.value.label}'),
      if (size == null && tier != null) tier!.value,
    ];
    return parts.isEmpty ? repoName : parts.join(' ');
  }

  @override
  String toString() => 'ParsedModelName($repoId${fileName == null ? '' : ' / $fileName'}: $displayName, '
      '${format.name}, ${role.value.name}${quant == null ? '' : ', ${quant!.value.label}'})';
}

/// Decodes a model's repo id and (optionally) one of its files.
///
/// Repo id and file name are parsed separately and merged field by field
/// (R08 §13.4): `ggml-org/SmolLM3-3B-GGUF` + `SmolLM3-Q4_K_M.gguf` takes the
/// size from the repo, `unsloth/Qwen3.8-27B-GGUF` + `mmproj-F16.gguf` takes
/// everything but the quant from the repo. [revision] carries the branch for
/// repos that keep variants in branches (`4_25`, `gptq-4bit-32g-actorder_True`).
ParsedModelName parseModelName(String repoId, {String? fileName, String? revision}) =>
    _NameParser(repoId, fileName, revision).run();

/// Decodes a llama.cpp quant tag (`Q4_K_M`, `UD-Q4_K_XL`, `i1-IQ1_S`,
/// `fp16`, `Q4_0_4_4`) as written at the end of a GGUF file name. Returns
/// null when the text is not a quant tag.
QuantLabel? parseGgufQuantTag(String tag) {
  final m = RegExp(r'^((?:UD-)?(?:i1-)?)(' + _ggufTagPattern + r')$', caseSensitive: false).firstMatch(tag);
  if (m == null) return null;
  return _classifyGgufTag(m.group(1)!, m.group(2)!, raw: tag);
}

// ---------------------------------------------------------------------------
// GGUF quant tags
// ---------------------------------------------------------------------------

const String _ggufTagPattern = r'(?:I?Q\d+(?:_[0-9A-Z]+)*|TQ\d_\d|BF16|FP16|FP32|F16|F32|MXFP4(?:_MOE)?|NVFP4)';

final RegExp _ggufTail = RegExp(r'(?:^|[-._])((?:UD-)?(?:i1-)?)(' + _ggufTagPattern + r')$', caseSensitive: false);

QuantLabel _classifyGgufTag(String prefix, String tag, {required String raw, bool imatrixHint = false}) {
  final upper = tag.toUpperCase();
  final ud = prefix.toUpperCase().contains('UD-');
  final i1 = prefix.toLowerCase().contains('i1-') || imatrixHint;
  final label = '${ud ? 'UD-' : ''}${i1 && prefix.toLowerCase().contains('i1-') ? 'i1-' : ''}'
      '${upper == 'FP16' ? 'F16' : upper == 'FP32' ? 'F32' : upper}';

  QuantType? base = QuantTypes.byName(upper);
  var embedQ8 = false;
  var custom = false;
  var approximate = false;
  var ambiguous = false;
  String? suffixNote;

  if (base == null) {
    // Community suffixes on top of real ftypes (R08 §12 "Community labels").
    for (final s in const ['_XL', '_L', '_M', '_S', '_P']) {
      if (!upper.endsWith(s)) continue;
      final stem = upper.substring(0, upper.length - s.length);
      switch (s) {
        case '_XL':
          // bartowski Q3_K_XL = Q3_K_L + Q8_0 embed/output; UD-Q4_K_XL = dynamic Q4_K_M.
          base = QuantTypes.byName('${stem}_L') ?? QuantTypes.byName(stem);
          embedQ8 = !ud;
        case '_L':
          base = QuantTypes.byName(stem);
          embedQ8 = !ud;
        case '_M' || '_S':
          base = QuantTypes.byName(stem);
          custom = !ud;
        case '_P':
          base = QuantTypes.byName(stem);
          custom = true;
          suffixNote = 'publisher-specific mix (semantics undocumented)';
      }
      if (base == null && RegExp(r'^Q8_K').hasMatch(stem)) {
        // UD-Q8_K_XL: there is no Q8_K file type; the nearest real one is Q8_0.
        base = QuantTypes.q8_0;
        approximate = true;
      }
      break;
    }
  }
  if (base == null && RegExp(r'^I?Q\d+$').hasMatch(upper)) ambiguous = true;

  final bits = base?.bits ?? int.tryParse(RegExp(r'\d+').firstMatch(upper)?.group(0) ?? '');
  final double? bpw = ud || ambiguous || approximate ? null : base?.bpw;
  final parts = <String>[];
  if (base != null) {
    parts.add(base.explanation.replaceFirst('${base.id}: ', '$label: '));
  } else if (ambiguous) {
    parts.add('$label: ${bits ?? '?'}-bit, exact type not stated in the name — the GGUF header decides');
  } else {
    parts.add('$label: unknown quant label; size comes from the file bytes');
  }
  if (base != null && base.aliases.contains(upper)) {
    parts.add('"$upper" is llama-quantize shorthand for ${base.id}');
  }
  if (ud) parts.add('Unsloth Dynamic: per-layer types vary, so bits/weight come from the file size');
  if (approximate) parts.add('no real Q8_K file type exists; treated as a Q8_0-based mix');
  if (embedQ8) parts.add('embedding and output weights kept at Q8_0 (slightly larger, slightly better)');
  if (custom) parts.add(suffixNote ?? 'publisher-specific variant of ${base?.id ?? upper}');
  if (i1) parts.add('imatrix-weighted quant: calibrated, usually better quality at the same size');
  return QuantLabel(
    label: label,
    raw: raw,
    scheme: QuantScheme.ggml,
    ggufType: base,
    bits: bits,
    bpw: bpw,
    bpwIsLowerBound: embedQ8 && bpw != null,
    dynamic: ud,
    imatrix: i1,
    embedOutputQ8: embedQ8,
    custom: custom,
    ambiguous: ambiguous,
    approximateBase: approximate,
    explanation: parts.join('; '),
  );
}

// ---------------------------------------------------------------------------
// Dictionaries
// ---------------------------------------------------------------------------

/// Families whose display case differs from how names spell them, plus
/// families the corpus shows behind publisher prefixes (`Cyber-Ornith`).
const Map<String, String> _knownFamilies = {
  'qwen': 'Qwen', 'gemma': 'Gemma', 'embeddinggemma': 'EmbeddingGemma', 'functiongemma': 'FunctionGemma',
  'llama': 'Llama', 'tinyllama': 'TinyLlama', 'codellama': 'CodeLlama', 'mistral': 'Mistral',
  'mixtral': 'Mixtral', 'ministral': 'Ministral', 'devstral': 'Devstral', 'magistral': 'Magistral',
  'codestral': 'Codestral', 'phi': 'Phi', 'smollm': 'SmolLM', 'lfm': 'LFM', 'granite': 'Granite',
  'nemotron': 'Nemotron', 'gptoss': 'gpt-oss', 'deepseek': 'DeepSeek', 'mimo': 'MiMo', 'mellum': 'Mellum',
  'vicuna': 'Vicuna', 'whisper': 'Whisper', 'bielik': 'Bielik', 'minimax': 'MiniMax', 'ornith': 'Ornith',
  'kat': 'KAT', 'stheno': 'Stheno', 'capybara': 'Capybara', 'orion': 'Orion', 'thomson': 'Thomson',
  'bge': 'BGE', 'kimi': 'Kimi', 'glm': 'GLM', 'olmo': 'OLMo', 'falcon': 'Falcon', 'yi': 'Yi',
  'internlm': 'InternLM', 'exaone': 'EXAONE', 'hermes': 'Hermes', 'starcoder': 'StarCoder', 'aya': 'Aya',
  'jamba': 'Jamba', 'command': 'Command', 'seed': 'Seed', 'ernie': 'ERNIE', 'hunyuan': 'Hunyuan',
};

/// Org / fine-tuner words that prefix a family (`NVIDIA-Nemotron`,
/// `Meta-Llama`, `Nous-Capybara`; R08 §13.4 "Publisher prefix").
const Map<String, String> _knownPrefixes = {
  'nvidia': 'NVIDIA', 'meta': 'Meta', 'huihui': 'Huihui', 'nous': 'Nous', 'cyber': 'Cyber', 'bert': 'bert',
  'google': 'google', 'microsoft': 'microsoft', 'ibm': 'ibm', 'apple': 'apple',
};

const Map<String, NameVariant> _variantWords = {
  'base': NameVariant.base, 'instruct': NameVariant.instruct, 'it': NameVariant.instruct,
  'chat': NameVariant.chat, 'thinking': NameVariant.thinking, 'reasoning': NameVariant.reasoning,
  'coder': NameVariant.coder, 'code': NameVariant.coder, 'vl': NameVariant.vision, 'vision': NameVariant.vision,
  'audio': NameVariant.audio, 'embedding': NameVariant.embedding, 'reranker': NameVariant.reranker,
  'tooluse': NameVariant.toolUse, 'rl': NameVariant.rl, 'distill': NameVariant.distill,
  'distilled': NameVariant.distill, 'abliterated': NameVariant.abliterated, 'obliterated': NameVariant.abliterated,
  'heretic': NameVariant.abliterated, 'uncensored': NameVariant.uncensored, 'qat': NameVariant.qat,
  'qad': NameVariant.qad, 'pruned': NameVariant.pruned, 'next': NameVariant.next, 'lm': NameVariant.textOnly,
  'mtp': NameVariant.mtp, 'aggressive': NameVariant.aggressive,
};

/// Size-tier words: a tier, not a number (R08 §13.4 "Size words").
const Set<String> _tierWords = {
  'mini', 'small', 'nano', 'flash', 'lightning', 'super', 'bolt', 'lite', 'dev', 'medium', 'large',
};

/// Words that carry no identity (`model.safetensors`, `consolidated.00.pth`).
const Set<String> _genericWords = {
  'model', 'models', 'pytorch', 'consolidated', 'weights', 'ggml', 'output', 'original', 'moved', 'embed',
  'adapter', 'layouts',
};

/// Known filler tokens, dropped silently.
const Set<String> _noiseWords = {
  'quantized', 'compat', 'noactorder', 'actorder', 'true', 'false', 'multiprefillseq',
};

/// Multi-token labels glued before splitting on separators.
final List<(RegExp, String Function(Match))> _compounds = [
  (RegExp('tool-use', caseSensitive: false), (_) => 'ToolUse'),
  (RegExp('litert-lm', caseSensitive: false), (_) => 'litertlm'),
  (RegExp('gpt-oss', caseSensitive: false), (_) => 'gptoss'),
  (RegExp('bnb-4bit', caseSensitive: false), (_) => 'bnb4bit'),
  (RegExp('mxfp4-q8', caseSensitive: false), (_) => 'mxfp4q8'),
  (RegExp(r'gptq-int(\d)', caseSensitive: false), (m) => 'GPTQInt${m.group(1)}'),
  (RegExp('no-act-order', caseSensitive: false), (_) => 'noactorder'),
  (RegExp('multi-prefill-seq', caseSensitive: false), (_) => 'multiprefillseq'),
  // `-lr3e-7`: a learning-rate tag in DWQ repo names, not a version.
  (RegExp(r'lr(\d+)e-(\d+)', caseSensitive: false), (m) => 'lr${m.group(1)}e${m.group(2)}'),
];

final RegExp _splitter = RegExp(r'[-_\s/]+|\.(?!\d)|(?<!\d)\.');

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

final class _Group {
  _Group(this.start);

  final int start;
  int end = -1;
  final List<String> words = [];
  bool closed = false;
}

final class _QuantAcc {
  final List<String> raw = [];
  int? bits;
  int? group;
  double? bpw;
  int? headBits;
  bool gptq = false, awq = false, exl2 = false, exl3 = false, bnb = false, fp8 = false, nvfp4 = false;
  bool w4a16 = false, ct = false, dwq = false, mxfp4 = false, mixedQ8 = false, q4f16 = false, unknown = false;
  bool litertQ = false, wi = false, afp32 = false, dtypeFloat = false, mixed = false;

  bool get isEmpty => raw.isEmpty;
}

/// One parsed stem (repo name, file stem or folder).
final class _Stem {
  String? family;
  String? familyRaw;
  String? prefix;
  String? base;
  String? baseVersion;
  String? teacher;
  final List<String> qualifiers = [];
  String? version;
  String? versionRaw;
  String? build;
  ParamSize? size;
  String? sizeRaw;
  String? tier;
  ParamSize? active;
  String? activeRaw;
  int? context;
  String? contextRaw;
  final List<(NameVariant, String)> variants = [];
  QuantLabel? ggufQuant;
  final _QuantAcc acc = _QuantAcc();
  final Set<String> formatHints = {};
  bool imatrixHint = false;
  bool bigEndian = false;
  bool legacyGgml = false;
  final List<String> unrecognized = [];

  bool get hasIdentity => family != null || size != null;
}

final class _NameParser {
  _NameParser(this.repoId, this.fileName, this.revision) {
    final slash = repoId.indexOf('/');
    owner = slash < 0 ? '' : repoId.substring(0, slash);
    repoName = slash < 0 ? repoId : repoId.substring(slash + 1);
  }

  final String repoId;
  final String? fileName;
  final String? revision;
  late final String owner;
  late final String repoName;

  ParsedModelName run() {
    final repo = _parseRepo();
    String? folder;
    _Stem? file;
    _Stem? folderStem;
    var format = ModelFormat.other;
    var role = FileRole.model;
    DraftKind? draft;
    ShardInfo? shard;
    String? device;
    String? unknownPrefix;
    final flags = <NameFlag>{};

    final path = fileName;
    if (path != null) {
      final cut = path.lastIndexOf('/');
      folder = cut < 0 ? null : path.substring(0, cut);
      var stem = cut < 0 ? path : path.substring(cut + 1);
      final lower = stem.toLowerCase();

      // 1. Extension → container format.
      final part = RegExp(r'\.gguf\.part(\d+)of(\d+)$').firstMatch(lower);
      if (part != null) {
        format = ModelFormat.ggufPart;
        shard = ShardInfo(index: int.parse(part.group(1)!), count: int.parse(part.group(2)!), byteSplit: true);
        stem = stem.substring(0, part.start);
      } else if (lower.endsWith('.gguf')) {
        format = ModelFormat.gguf;
        stem = stem.substring(0, stem.length - 5);
      } else if (lower.endsWith('.bin') && RegExp(r'\.ggml(v\d+)?\.|ggmlv\d').hasMatch(lower)) {
        format = ModelFormat.ggml;
        stem = stem.substring(0, stem.length - 4);
      } else if (RegExp(r'\.(bin|pt|pth|pkl|pickle|ckpt|joblib)$').hasMatch(lower)) {
        format = ModelFormat.pickle;
        stem = stem.substring(0, stem.lastIndexOf('.'));
      } else if (lower.endsWith('.safetensors')) {
        format = ModelFormat.safetensors;
        stem = stem.substring(0, stem.length - 12);
      } else if (lower.endsWith('.npz')) {
        format = ModelFormat.mlxNpz;
        stem = stem.substring(0, stem.length - 4);
      } else if (lower.endsWith('.onnx_data')) {
        format = ModelFormat.onnxData;
        role = FileRole.externalData;
        stem = stem.substring(0, stem.length - 10);
      } else if (lower.endsWith('.onnx')) {
        format = ModelFormat.onnx;
        stem = stem.substring(0, stem.length - 5);
      } else if (RegExp(r'\.(litertlm|task|tflite)$').hasMatch(lower)) {
        format = ModelFormat.litert;
        stem = stem.substring(0, stem.lastIndexOf('.'));
      } else if (lower.endsWith('.layout.json')) {
        role = FileRole.layout;
        stem = stem.substring(0, stem.length - 12);
      } else if (lower.endsWith('.imatrix') || lower.endsWith('.gguf_file')) {
        role = FileRole.imatrix;
        stem = stem.substring(0, stem.lastIndexOf('.'));
      } else {
        role = FileRole.config;
        final dot = stem.lastIndexOf('.');
        if (dot > 0) stem = stem.substring(0, dot);
      }

      // 2. Shards: llama.cpp `-00001-of-00003` (5 digits), safetensors
      //    `-00001-of-000002` (6), `model.safetensors-00001-of-00002`.
      final split = RegExp(r'[-.](\d{1,6})-of-(\d{1,6})$', caseSensitive: false).firstMatch(stem);
      if (split != null && shard == null) {
        shard = ShardInfo(index: int.parse(split.group(1)!), count: int.parse(split.group(2)!), byteSplit: false);
        stem = stem.substring(0, split.start);
      } else if (shard == null && format != ModelFormat.other) {
        final lone = RegExp(r'-(\d{5})$').firstMatch(stem);
        if (lone != null) {
          shard = ShardInfo(index: int.parse(lone.group(1)!), byteSplit: false);
          stem = stem.substring(0, lone.start);
        }
      }
      if (stem.toLowerCase().endsWith('.safetensors')) stem = stem.substring(0, stem.length - 12);

      // 3. Sidecar roles (llama.cpp `gguf_filename_is_model` keywords).
      if (role == FileRole.imatrix && stem.toLowerCase().contains('imatrix')) {
        stem = _removeToken(stem, 'imatrix');
      }
      if (role == FileRole.model) {
        final l = stem.toLowerCase();
        if (l.contains('mmproj')) {
          role = FileRole.mmproj;
          stem = _removeToken(stem, 'mmproj');
        } else if (RegExp(r'^(mtp|eagle3|dflash|dspark)-', caseSensitive: false).hasMatch(stem)) {
          final kind = stem.substring(0, stem.indexOf('-')).toLowerCase();
          draft = DraftKind.values.byName(kind);
          role = FileRole.draft;
          stem = stem.substring(kind.length + 1);
        } else if (l.contains('fastmtp')) {
          role = FileRole.draft;
          draft = DraftKind.mtp;
          stem = _removeToken(stem, 'fastmtp');
        } else if (RegExp(r'[-_]mtp$', caseSensitive: false).hasMatch(stem)) {
          role = FileRole.draft;
          draft = DraftKind.mtp;
          stem = stem.substring(0, stem.length - 4);
        } else if (l.contains('imatrix')) {
          role = FileRole.imatrix;
          stem = _removeToken(stem, 'imatrix');
        } else if (l.contains('cal_trace')) {
          role = FileRole.calibration;
          stem = _removeToken(stem, 'cal_trace');
        } else {
          unknownPrefix = _unknownSidecarPrefix(stem);
          if (unknownPrefix != null) {
            role = FileRole.unknownSidecar;
            stem = stem.substring(unknownPrefix.length + 1);
          }
        }
      }

      // 4. LiteRT build targets.
      if (format == ModelFormat.litert) {
        final d = RegExp(
          r'(?:^|[-_.])(Google_Tensor_G\d+|qualcomm[._-]sm\d+|mediatek[._-]mt\d+|Intel_PTL|web|gpu|cpu|npu)(?=$|[-_.])',
          caseSensitive: false,
        ).firstMatch(stem);
        if (d != null) {
          device = _deviceName(d.group(1)!);
          stem = stem.substring(0, d.start) + stem.substring(d.end);
        }
      }

      final weightsWithGgufTags = format == ModelFormat.gguf || format == ModelFormat.ggufPart || format == ModelFormat.ggml;
      // Strip the tag from non-weight files too (`….Q4_K_M.layout.json`) so it
      // does not leak into the name words; their quant is dropped below.
      file = _parseStem(stem, ggufTail: weightsWithGgufTags || repo.formatHints.contains('gguf'));
      if (!file.hasIdentity && folder != null) {
        final f = folder.split('/').last;
        if (parseGgufQuantTag(f) == null) {
          final s = _parseStem(f, ggufTail: false);
          if (s.hasIdentity) folderStem = s;
        }
      }
    }

    final branch = _parseBranch(repo);

    // ---- format refinement -------------------------------------------------
    final hints = {...repo.formatHints, ...?file?.formatHints, ...?branch?.formatHints};
    if (owner.toLowerCase() == 'mlx-community') hints.add('mlx');
    if (owner.toLowerCase() == 'litert-community') hints.add('litert');
    if (path == null) {
      format = _formatFromHints(hints, repo, branch);
    } else if (format == ModelFormat.safetensors) {
      final refined = _formatFromHints(hints, repo, branch);
      if (refined != ModelFormat.safetensors && refined != ModelFormat.gguf) format = refined;
    }

    // ---- merge identity: file (or folder) first, then repo -----------------
    final primary = file != null && file.hasIdentity ? file : folderStem;
    final idSource = primary == file ? FieldSource.file : FieldSource.folder;
    T? pick<T>(T? Function(_Stem s) f) => (primary == null ? null : f(primary)) ?? f(repo);
    FieldSource src<T>(T? Function(_Stem s) f) =>
        primary != null && f(primary) != null ? idSource : FieldSource.repo;

    final familyName = pick((s) => s.family);
    final prefix = pick((s) => s.prefix);
    final base = pick((s) => s.base);
    final teacher = pick((s) => s.teacher);
    final versionValue = pick((s) => s.version);
    final versionRaw = pick((s) => s.versionRaw);
    final build = pick((s) => s.build);
    final size = pick((s) => s.size);
    final sizeRaw = pick((s) => s.sizeRaw);
    final tier = pick((s) => s.tier);
    final active = pick((s) => s.active);
    final activeRaw = pick((s) => s.activeRaw);
    final ctx = file?.context ?? repo.context;
    final ctxRaw = file?.contextRaw ?? repo.contextRaw;
    final variantSource = primary ?? repo;
    final variants = [
      for (final (v, raw) in variantSource.variants)
        Decoded(v, raw: raw, explanation: _variantExplanation(v, raw),
            source: variantSource == repo ? FieldSource.repo : idSource),
    ];
    final qualifiers = [...variantSource.qualifiers];

    // ---- quant: file > branch > repo ---------------------------------------
    Decoded<QuantLabel>? quant;
    final imatrixHint = repo.imatrixHint || (file?.imatrixHint ?? false);
    final fileQuant = file?.ggufQuant ?? (file == null ? null : _buildQuant(file.acc, format, hints));
    if (fileQuant != null) {
      // mradermacher `-i1-GGUF` repos hold only imatrix quants.
      final q = imatrixHint && fileQuant.scheme == QuantScheme.ggml && !fileQuant.imatrix
          ? _withImatrix(fileQuant)
          : fileQuant;
      quant = Decoded(q, raw: q.raw, explanation: q.explanation, source: FieldSource.file);
    } else if (role.isWeights || path == null) {
      final b = branch == null ? null : _buildQuant(branch.acc, format, hints, extra: repo.acc);
      final r = repo.ggufQuant ?? _buildQuant(repo.acc, format, hints);
      if (b != null) {
        quant = Decoded(b, raw: b.raw, explanation: b.explanation, source: FieldSource.branch);
      } else if (r != null && (path == null || role.isWeights)) {
        quant = Decoded(r, raw: r.raw, explanation: r.explanation, source: FieldSource.repo);
      }
    }
    if (role == FileRole.layout || role == FileRole.imatrix || role == FileRole.config || role == FileRole.calibration) {
      quant = null;
    }

    // ---- flags ---------------------------------------------------------------
    if (format == ModelFormat.pickle) flags.add(NameFlag.pickle);
    if (format == ModelFormat.ggml || (file?.legacyGgml ?? false)) flags.add(NameFlag.legacyGgml);
    if (format == ModelFormat.mlxNpz) flags.add(NameFlag.legacyFormat);
    if (file?.bigEndian ?? false) flags.add(NameFlag.bigEndian);
    if (role == FileRole.unknownSidecar) flags.add(NameFlag.unknownSidecar);
    if (!role.isWeights && role != FileRole.unknownSidecar && role != FileRole.externalData) flags.add(NameFlag.notAModel);
    if (shard?.byteSplit ?? false) flags.add(NameFlag.byteSplit);
    final ql = quant?.value;
    if (ql != null) {
      if (ql.isRemoved) flags.add(NameFlag.removedQuant);
      if (ql.ambiguous) flags.add(NameFlag.ambiguousQuant);
      if (ql.custom && !ql.dynamic) flags.add(NameFlag.customQuant);
      if (ql.scheme == QuantScheme.unknown) flags.add(NameFlag.unknownQuantScheme);
      if (ql.ggufType?.status == QuantStatus.newRuntime) flags.add(NameFlag.newRuntimeQuant);
      if (ql.ggufType?.status == QuantStatus.ternary) flags.add(NameFlag.ternaryQuant);
      if (const {
        QuantScheme.gptq, QuantScheme.awq, QuantScheme.exl2, QuantScheme.exl3, QuantScheme.bnb, QuantScheme.fp8,
        QuantScheme.compressedTensors,
      }.contains(ql.scheme)) {
        flags.add(NameFlag.gpuOnly);
      }
      if (ql.scheme == QuantScheme.nvfp4 && format != ModelFormat.mlx) flags.add(NameFlag.gpuOnly);
    }
    if (const {ModelFormat.gptq, ModelFormat.awq, ModelFormat.exl2, ModelFormat.exl3}.contains(format)) {
      flags.add(NameFlag.gpuOnly);
    }
    if (variants.any((v) => v.value.isUncensored)) flags.add(NameFlag.uncensored);

    // ---- assemble ------------------------------------------------------------
    Decoded<String>? d(String? v, String? raw, String expl, FieldSource s) =>
        v == null ? null : Decoded(v, raw: raw ?? v, explanation: expl, source: s);

    return ParsedModelName(
      repoId: repoId,
      owner: owner,
      repoName: repoName,
      fileName: fileName,
      revision: revision,
      folder: folder,
      format: format,
      role: Decoded(role, raw: unknownPrefix ?? draft?.name ?? role.name,
          explanation: _roleExplanation(role, draft, unknownPrefix), source: FieldSource.file),
      draftKind: draft,
      family: d(familyName, pick((s) => s.familyRaw), '$familyName model family', src((s) => s.family)),
      namePrefix: d(prefix, prefix, '$prefix: publisher or fine-tuner prefix in the name', src((s) => s.prefix)),
      baseFamily: d(base, base, _baseExplanation(base, pick((s) => s.baseVersion), variants), src((s) => s.base)),
      teacher: d(teacher, teacher, 'Distilled from $teacher (teacher model)', src((s) => s.teacher)),
      qualifiers: List.unmodifiable(qualifiers),
      version: d(versionValue, versionRaw, '${versionRaw ?? versionValue}: model version', src((s) => s.version)),
      build: d(build, build, _buildExplanation(build), src((s) => s.build)),
      size: size == null
          ? null
          : Decoded(size, raw: sizeRaw ?? size.label, explanation: _sizeExplanation(size), source: src((s) => s.size)),
      tier: d(tier, tier, '$tier: size tier name, not a parameter count', src((s) => s.tier)),
      activeParams: active == null
          ? null
          : Decoded(active, raw: activeRaw ?? active.label,
              explanation: '${active.label}: mixture-of-experts with ~${_num(active.billions)}B parameters active per '
                  'token; speed follows the active count, memory the total',
              source: src((s) => s.active)),
      contextHint: ctx == null
          ? null
          : Decoded(ctx, raw: ctxRaw ?? '$ctx', explanation: _contextExplanation(ctxRaw ?? '$ctx', ctx),
              source: file?.context != null ? FieldSource.file : FieldSource.repo),
      variants: List.unmodifiable(variants),
      quant: quant,
      shard: shard == null
          ? null
          : Decoded(shard, raw: shard.toString(), explanation: _shardExplanation(shard), source: FieldSource.file),
      deviceTarget: device,
      flags: Set.unmodifiable(flags),
      unrecognized: List.unmodifiable([...?file?.unrecognized, ...repo.unrecognized]),
    );
  }

  // ---- repo / branch -------------------------------------------------------

  _Stem _parseRepo() {
    var stem = repoName;
    var gguf = false;
    var imatrix = false;
    final tail = RegExp(r'[-_.](GGUF|GGML)$', caseSensitive: false).firstMatch(stem);
    if (tail != null) {
      gguf = tail.group(1)!.toUpperCase() == 'GGUF';
      stem = stem.substring(0, tail.start);
    }
    final i1 = RegExp(r'[-_.]i1$', caseSensitive: false).firstMatch(stem);
    if (i1 != null) {
      imatrix = true;
      stem = stem.substring(0, i1.start);
    }
    final s = _parseStem(stem, ggufTail: gguf);
    if (gguf) s.formatHints.add('gguf');
    if (tail != null && !gguf) s.formatHints.add('ggml');
    s.imatrixHint = imatrix;
    return s;
  }

  /// The repo name with format/quant suffixes removed — what a file name
  /// usually starts with (used for the unknown-sidecar rule).
  String _repoCore() {
    var stem = repoName.replaceFirst(RegExp(r'[-_.](GGUF|GGML)$', caseSensitive: false), '');
    stem = stem.replaceFirst(RegExp(r'[-_.]i1$', caseSensitive: false), '');
    return stem;
  }

  _Stem? _parseBranch(_Stem repo) {
    final rev = revision;
    if (rev == null || rev == 'main' || RegExp(r'^[0-9a-f]{40}$').hasMatch(rev)) return null;
    final s = _Stem();
    final exl = RegExp(r'^(\d+)_(\d+)$').firstMatch(rev);
    if (exl != null) {
      // bartowski EXL2 branches: `4_25` = 4.25 bpw.
      s.acc.bpw = double.parse('${exl.group(1)}.${exl.group(2)}');
      s.acc.raw.add(rev);
      return s;
    }
    final tokens = rev.split(_splitter).where((t) => t.isNotEmpty).toList();
    final hasExl = repo.formatHints.contains('exl2') || repo.formatHints.contains('exl3');
    for (final t in tokens) {
      _quantToken(t, s, hasExl);
    }
    return s.acc.isEmpty ? null : s;
  }

  ModelFormat _formatFromHints(Set<String> hints, _Stem repo, _Stem? branch) {
    if (hints.contains('exl3')) return ModelFormat.exl3;
    if (hints.contains('exl2')) return ModelFormat.exl2;
    if (hints.contains('gptq')) return ModelFormat.gptq;
    if (hints.contains('awq')) return ModelFormat.awq;
    if (hints.contains('mlx')) return ModelFormat.mlx;
    if (hints.contains('litert')) return ModelFormat.litert;
    if (hints.contains('onnx')) return ModelFormat.onnx;
    if (hints.contains('gguf')) return ModelFormat.gguf;
    if (hints.contains('ggml')) return ModelFormat.ggml;
    return ModelFormat.safetensors;
  }

  String? _unknownSidecarPrefix(String stem) {
    // `lilicorr-NVIDIA-Nemotron-…` inside `…/NVIDIA-Nemotron-…-GGUF`: an
    // extra leading token in front of the repo's model name (R08 §14 row 23).
    final core = _repoCore();
    final m = RegExp(r'^([A-Za-z0-9]+)-(.+)$').firstMatch(stem);
    if (m == null || core.isEmpty) return null;
    final head = m.group(1)!;
    final rest = m.group(2)!.toLowerCase();
    if (!rest.startsWith(core.toLowerCase())) return null;
    if (core.toLowerCase().startsWith(head.toLowerCase())) return null;
    return head;
  }

  // ---- stem parsing --------------------------------------------------------

  _Stem _parseStem(String input, {required bool ggufTail}) {
    final s = _Stem();
    var stem = input;

    if (RegExp('big-endian', caseSensitive: false).hasMatch(stem)) {
      s.bigEndian = true;
      stem = stem.replaceAll(RegExp(r'[-_.]?big-endian', caseSensitive: false), '');
    }
    if (RegExp(r'(?:^|[-_.])ggmlv\d+(?=$|[-_.])', caseSensitive: false).hasMatch(stem)) {
      s.legacyGgml = true;
      stem = stem.replaceAll(RegExp(r'(?:^|[-_.])ggmlv\d+(?=$|[-_.])', caseSensitive: false), '');
    }
    var imat = false;
    final imatTail = RegExp(r'[-_.]imat$', caseSensitive: false).firstMatch(stem);
    if (imatTail != null) {
      imat = true;
      stem = stem.substring(0, imatTail.start);
    }
    if (ggufTail) {
      final m = _ggufTail.firstMatch(stem);
      if (m != null) {
        final q = _classifyGgufTag(m.group(1)!, m.group(2)!, raw: '${m.group(1)}${m.group(2)}', imatrixHint: imat);
        s.ggufQuant = q;
        stem = stem.substring(0, m.start);
      }
    }
    if (imat) s.imatrixHint = true;

    // bartowski `{publisher}_{Name}` prefix: one word before the first `_`,
    // a dashed model name after it.
    final pre = RegExp(r'^([A-Za-z][A-Za-z0-9]*(?:-ai)?)_([A-Za-z].*)$').firstMatch(stem);
    if (pre != null && pre.group(2)!.contains('-')) {
      s.prefix = pre.group(1);
      stem = pre.group(2)!;
    }

    for (final (re, rep) in _compounds) {
      stem = stem.replaceAllMapped(re, rep);
    }
    final tokens = stem.split(_splitter).where((t) => t.isNotEmpty).toList();
    final hasExl = tokens.any((t) => RegExp(r'^exl[23]$', caseSensitive: false).hasMatch(t));
    final ownerLower = owner.toLowerCase();
    final ownerOnlyNoise = ownerLower.isNotEmpty && !repoName.toLowerCase().startsWith(ownerLower);

    final groups = <_Group>[];
    _Group? open;
    void close() {
      if (open != null) {
        open!.closed = true;
        groups.add(open!);
        open = null;
      }
    }

    final distillAt = <int>[];
    var sawGeneric = false;

    for (var i = 0; i < tokens.length; i++) {
      final t = tokens[i];
      final l = t.toLowerCase();

      if (_formatToken(l, s)) {
        close();
        continue;
      }
      if (_quantToken(t, s, hasExl)) {
        close();
        continue;
      }
      final ekv = RegExp(r'^ekv(\d+)$').firstMatch(l);
      if (ekv != null) {
        s.context ??= int.parse(ekv.group(1)!);
        s.contextRaw ??= t;
        close();
        continue;
      }
      if (RegExp(r'^lr\d+e\d+$').hasMatch(l) || _noiseWords.contains(l)) {
        close();
        continue;
      }
      if (_genericWords.contains(l)) {
        sawGeneric = true;
        close();
        continue;
      }
      if (ownerOnlyNoise && l == ownerLower) {
        // `…-unsloth-bnb-4bit`, `…-HauhauCS-Aggressive`: the uploader's name.
        close();
        continue;
      }
      final k = RegExp(r'^(\d+(?:\.\d+)?)k$', caseSensitive: false).firstMatch(t);
      if (k != null) {
        s.context ??= (double.parse(k.group(1)!) * 1024).round();
        s.contextRaw ??= t;
        close();
        continue;
      }
      final ex = RegExp(r'^(\d+)x(\d+(?:\.\d+)?)([bm])$', caseSensitive: false).firstMatch(t);
      if (ex != null && s.size == null) {
        final n = int.parse(ex.group(1)!);
        final per = double.parse(ex.group(2)!) * (ex.group(3)!.toLowerCase() == 'm' ? 0.001 : 1);
        s.size = ParamSize(label: '${n}x${ex.group(2)}${ex.group(3)!.toUpperCase()}', billions: n * per,
            kind: ParamSizeKind.experts, experts: n);
        s.sizeRaw = t;
        close();
        continue;
      }
      final eff = RegExp(r'^e(\d+(?:\.\d+)?)b$', caseSensitive: false).firstMatch(t);
      if (eff != null && s.size == null) {
        s.size = ParamSize(label: 'E${eff.group(1)}B', billions: double.parse(eff.group(1)!), kind: ParamSizeKind.effective);
        s.sizeRaw = t;
        close();
        continue;
      }
      final act = RegExp(r'^a(\d+(?:\.\d+)?)b$', caseSensitive: false).firstMatch(t);
      if (act != null && s.size != null && s.active == null) {
        s.active = ParamSize(label: 'A${act.group(1)}B', billions: double.parse(act.group(1)!));
        s.activeRaw = t;
        close();
        continue;
      }
      final sz = RegExp(r'^(\d+(?:\.\d+)?)([bmt])$', caseSensitive: false).firstMatch(t);
      if (sz != null) {
        final unit = sz.group(2)!.toUpperCase();
        final v = double.parse(sz.group(1)!);
        if (s.size == null && !(unit == 'M' && v < 10 && s.variants.isNotEmpty)) {
          final billions = switch (unit) { 'M' => v / 1000, 'T' => v * 1000, _ => v };
          s.size = ParamSize(label: '${sz.group(1)}$unit', billions: billions);
          s.sizeRaw = t;
        } else if (unit == 'M') {
          // `1M` after a size/variant is a context length (R08 §14 row 11).
          s.context ??= (v * 1024 * 1024).round();
          s.contextRaw ??= t;
        } else {
          s.unrecognized.add(t);
        }
        close();
        continue;
      }
      if (RegExp(r'^\d{4}$').hasMatch(t)) {
        s.build ??= t;
        close();
        continue;
      }
      final vv = RegExp(r'^v(\d+(?:\.\d+)*)$', caseSensitive: false).firstMatch(t);
      if (vv != null) {
        if (s.version == null) {
          s.version = vv.group(1);
          s.versionRaw = t;
        }
        close();
        continue;
      }
      final llama = RegExp(r'^L(\d+(?:\.\d+)?)$').firstMatch(t);
      if (llama != null && i == 0 && s.family == null) {
        // `L3-8B-Stheno`: L3 is shorthand for a Llama 3 base.
        s.base = 'Llama';
        s.baseVersion = llama.group(1);
        continue;
      }
      if (RegExp(r'^\d+(?:\.\d+)*n?$').hasMatch(t)) {
        if (s.version == null && (groups.isNotEmpty || open != null)) {
          s.version = t;
          s.versionRaw = t;
        } else if (!sawGeneric) {
          // `consolidated.00`: an index after a generic word is not news.
          s.unrecognized.add(t);
        }
        close();
        continue;
      }
      final variant = _variantWords[l];
      if (variant != null) {
        close();
        if (!s.variants.any((v) => v.$1 == variant && v.$2.toLowerCase() == l)) s.variants.add((variant, t));
        if (variant == NameVariant.distill) distillAt.add(i);
        continue;
      }
      if (_tierWords.contains(l)) {
        s.tier ??= t;
        close();
        continue;
      }
      if (RegExp(r'^[a-z]\d+(?:\.\d+)*$', caseSensitive: false).hasMatch(t)) {
        if (s.version == null && groups.isEmpty && open != null) {
          // `DeepSeek-R1`, `MiniMax-H3`: letter versions display uppercase.
          s.version = t.toUpperCase();
          s.versionRaw = t.toUpperCase();
          close();
        } else if (open != null) {
          open!.words.add(t);
          open!.end = i;
        } else {
          s.unrecognized.add(t);
        }
        continue;
      }
      final glued = RegExp(r'^([a-z][a-z]*[a-z])(\d+(?:\.\d+)*n?)$', caseSensitive: false).firstMatch(t);
      if (glued != null) {
        open ??= _Group(i);
        open!.words.add(glued.group(1)!);
        open!.end = i;
        if (s.version == null && groups.isEmpty) {
          s.version = glued.group(2);
          s.versionRaw = glued.group(2);
        }
        close();
        continue;
      }
      if (RegExp(r'^[a-z]+$', caseSensitive: false).hasMatch(t)) {
        open ??= _Group(i);
        open!.words.add(t);
        open!.end = i;
        continue;
      }
      s.unrecognized.add(t);
      close();
    }
    close();

    // ---- assign word groups -------------------------------------------------
    if (groups.isNotEmpty) {
      final g = groups.first;
      var words = g.words;
      var k = words.indexWhere((w) => _knownFamilies.containsKey(w.toLowerCase()));
      if (k <= 0 && words.length > 1 && _knownPrefixes.containsKey(words.first.toLowerCase())) k = 1;
      if (k > 0) {
        final p = words.sublist(0, k).map((w) => _knownPrefixes[w.toLowerCase()] ?? w).join(' ');
        s.prefix = s.prefix == null ? p : '${s.prefix} $p';
        words = words.sublist(k);
      }
      s.familyRaw = words.join('-');
      s.family = words.map((w) => _knownFamilies[w.toLowerCase()] ?? w).join(' ');
      if (words.length == 1 && words.first.toLowerCase().contains('embedding') &&
          !s.variants.any((v) => v.$1 == NameVariant.embedding)) {
        s.variants.add((NameVariant.embedding, words.first));
      }
    }
    for (final g in groups.skip(1)) {
      final display = g.words.map((w) => _knownFamilies[w.toLowerCase()] ?? w).join(' ');
      if (distillAt.any((at) => g.start == at + 1)) {
        s.base ??= display;
      } else if (distillAt.any((at) => g.end == at - 1)) {
        s.teacher ??= display;
      } else {
        s.qualifiers.add(display);
      }
    }
    return s;
  }

  bool _formatToken(String l, _Stem s) {
    switch (l) {
      case 'mlx':
        s.formatHints.add('mlx');
      case 'onnx':
        s.formatHints.add('onnx');
      case 'litertlm' || 'litert':
        s.formatHints.add('litert');
      case 'gguf':
        s.formatHints.add('gguf');
      case 'safetensors':
        break;
      default:
        return false;
    }
    return true;
  }

  /// Non-GGUF quant tokens (R08 §13.4 "Quant (other)").
  bool _quantToken(String t, _Stem s, bool hasExl) {
    final l = t.toLowerCase();
    final a = s.acc;
    RegExpMatch? m;
    void add() => a.raw.add(t);
    if ((m = RegExp(r'^(\d+)bit$').firstMatch(l)) != null) {
      a.bits ??= int.parse(m!.group(1)!);
      add();
    } else if ((m = RegExp(r'^(\d+\.\d+)bit$').firstMatch(l)) != null) {
      a.bpw ??= double.parse(m!.group(1)!);
      add();
    } else if ((m = RegExp(r'^(\d+(?:\.\d+)?)bpw$').firstMatch(l)) != null) {
      a.bpw ??= double.parse(m!.group(1)!);
      add();
    } else if ((m = RegExp(r'^gs(\d+)$').firstMatch(l)) != null) {
      a.group = int.parse(m!.group(1)!);
      add();
    } else if ((m = RegExp(r'^(\d+)g$').firstMatch(l)) != null) {
      a.group = int.parse(m!.group(1)!);
      add();
    } else if ((m = RegExp(r'^block(\d+)$').firstMatch(l)) != null) {
      a.group = int.parse(m!.group(1)!);
      add();
    } else if ((m = RegExp(r'^wi(\d+)b(\d+)$').firstMatch(l)) != null) {
      a.bits ??= int.parse(m!.group(1)!);
      a.group = int.parse(m!.group(2)!);
      a.wi = true;
      add();
    } else if (RegExp(r'^a(fp|int)\d+$').hasMatch(l)) {
      a.afp32 = true;
      add();
    } else if (hasExl && (m = RegExp(r'^h(\d)$').firstMatch(l)) != null) {
      a.headBits = int.parse(m!.group(1)!);
      add();
    } else if (l == 'exl2' || l == 'exl3') {
      if (l == 'exl2') {
        a.exl2 = true;
      } else {
        a.exl3 = true;
      }
      s.formatHints.add(l);
      add();
    } else if (l == 'gptq' || l.startsWith('gptqint')) {
      a.gptq = true;
      s.formatHints.add('gptq');
      final b = RegExp(r'int(\d+)$').firstMatch(l);
      if (b != null) a.bits ??= int.parse(b.group(1)!);
      add();
    } else if (l == 'awq') {
      a.awq = true;
      s.formatHints.add('awq');
      add();
    } else if (l == 'bnb4bit' || l == 'bnb' || l == 'bnb4') {
      a.bnb = true;
      a.bits ??= 4;
      add();
    } else if (l == 'fp8') {
      a.fp8 = true;
      add();
    } else if (l == 'nvfp4') {
      a.nvfp4 = true;
      add();
    } else if (l == 'mxfp4') {
      a.mxfp4 = true;
      add();
    } else if (l == 'mxfp4q8') {
      a.mxfp4 = true;
      a.mixedQ8 = true;
      add();
    } else if (RegExp(r'^w\da\d+$').hasMatch(l)) {
      a.w4a16 = true;
      a.bits ??= int.parse(l.substring(1, 2));
      add();
    } else if (l == 'ct') {
      a.ct = true;
      add();
    } else if (l == 'dwq') {
      a.dwq = true;
      add();
    } else if (RegExp(r'^q\df16$').hasMatch(l)) {
      a.q4f16 = true;
      a.bits ??= int.parse(l.substring(1, 2));
      add();
    } else if (RegExp(r'^o?q\d+e$').hasMatch(l)) {
      a.unknown = true;
      a.bits ??= int.parse(RegExp(r'\d+').firstMatch(l)!.group(0)!);
      add();
    } else if ((m = RegExp(r'^q(\d)$').firstMatch(l)) != null) {
      a.litertQ = true;
      a.bits ??= int.parse(m!.group(1)!);
      add();
    } else if ((m = RegExp(r'^u?int(\d+)$').firstMatch(l)) != null) {
      a.bits ??= int.parse(m!.group(1)!);
      add();
    } else if (RegExp(r'^(bf16|fp16|f16|fp32|f32)$').hasMatch(l)) {
      a.dtypeFloat = true;
      add();
    } else if (l == 'mixed' || l == 'dynamic') {
      a.mixed = a.mixed || l == 'mixed';
      add();
    } else {
      return false;
    }
    return true;
  }

  QuantLabel? _buildQuant(_QuantAcc a, ModelFormat format, Set<String> hints, {_QuantAcc? extra}) {
    if (a.isEmpty) return null;
    final label = a.raw.join('-');
    final hasExl = a.exl2 || a.exl3 || hints.contains('exl2') || hints.contains('exl3');
    double r2(double v) => (v * 1000).round() / 1000;
    QuantLabel q(QuantScheme scheme, String expl, {int? bits, int? group, double? bpw, String? mode, bool mixed = false}) =>
        QuantLabel(label: label, raw: label, scheme: scheme, explanation: '$label: $expl', bits: bits, groupSize: group,
            bpw: bpw == null ? null : r2(bpw), mode: mode, mixed: mixed, headBits: a.headBits ?? extra?.headBits);

    if (hasExl) {
      final scheme = a.exl3 || hints.contains('exl3') ? QuantScheme.exl3 : QuantScheme.exl2;
      final bpw = a.bpw ?? extra?.bpw;
      final head = a.headBits ?? extra?.headBits;
      return q(scheme,
          '${scheme == QuantScheme.exl3 ? 'EXL3' : 'EXL2'} average ${bpw == null ? '?' : bpw.toStringAsFixed(2)} bits/weight'
          '${head == null ? '' : ', $head-bit output head'}; CUDA-only',
          bpw: bpw);
    }
    if (a.gptq || a.awq) {
      final bits = a.bits ?? 4;
      final group = a.group ?? 128;
      // fp16 scale + packed zero per group (R08 §13.3: 4-bit g128 ≈ 4.16).
      final bpw = bits + (16 + bits) / group;
      return q(a.gptq ? QuantScheme.gptq : QuantScheme.awq,
          '${a.gptq ? 'GPTQ' : 'AWQ'} $bits-bit, group $group (~${formatBpw(bpw)} bits/weight); CUDA-oriented',
          bits: bits, group: group, bpw: bpw);
    }
    if (a.bnb) {
      return q(QuantScheme.bnb, 'bitsandbytes 4-bit (NF4, ~4.5 bits/weight); GPU-only, not loadable on phones',
          bits: 4, bpw: 4.5);
    }
    if (a.w4a16) {
      return q(QuantScheme.compressedTensors,
          '4-bit weights, 16-bit activations (compressed-tensors, ~4.1 bits/weight); vLLM-oriented',
          bits: 4, group: 128, bpw: 4 + 16 / 128);
    }
    if (a.fp8) return q(QuantScheme.fp8, '8-bit float weights (F8_E4M3); server GPUs', bits: 8, bpw: 8);
    if (a.nvfp4 && format != ModelFormat.mlx) {
      return q(QuantScheme.nvfp4, 'NVIDIA FP4 (~4.5 bits/weight); Blackwell-class GPUs', bits: 4, bpw: 4.5);
    }
    if (format == ModelFormat.litert) {
      final bits = a.bits;
      final group = a.group;
      final bpw = bits == null ? null : (group == null ? bits.toDouble() : bits + 16 / group);
      return q(QuantScheme.litert,
          'LiteRT ${bits == null ? '' : '$bits-bit '}weights${group == null ? '' : ' in blocks of $group'}'
          '${a.afp32 ? ', float32 activations' : ''}${bpw == null ? '' : ' (~${formatBpw(bpw)} bits/weight)'}',
          bits: bits, group: group, bpw: bpw, mixed: a.mixed);
    }
    if (format == ModelFormat.onnx || format == ModelFormat.onnxData) {
      final bits = a.dtypeFloat ? 16 : a.bits;
      return q(QuantScheme.onnx,
          'ONNX ${bits == null ? '' : '$bits-bit '}weights${a.q4f16 ? ' with float16 activations' : ''}',
          bits: bits, bpw: bits?.toDouble());
    }
    if (a.unknown) {
      return q(QuantScheme.unknown, 'undocumented quant scheme; size comes from the file bytes', bits: a.bits);
    }
    if (a.mxfp4 && a.mixedQ8) {
      return q(QuantScheme.mlx, 'MXFP4 experts with 8-bit other weights (mixed); size comes from the file bytes',
          mode: 'mxfp4', mixed: true);
    }
    if (a.mxfp4) {
      return q(QuantScheme.mlx, 'MLX mxfp4 (4-bit float, scale per 32 weights, ~4.25 bits/weight)',
          bits: 4, group: 32, bpw: 4.25, mode: 'mxfp4');
    }
    if (a.dtypeFloat && a.bits == null) {
      return q(QuantScheme.float, 'unquantized 16-bit weights', bits: 16, bpw: 16);
    }
    final bits = a.bits;
    if (bits != null) {
      final group = a.group ?? 64;
      // Affine: fp16 scale + bias per group → bits + 32/group (R08 §13.3).
      final bpw = bits + 32 / group;
      return q(QuantScheme.mlx,
          '${a.dwq ? 'MLX DWQ (distilled) ' : 'MLX '}$bits-bit, group $group (~${formatBpw(bpw)} bits/weight)',
          bits: bits, group: group, bpw: bpw, mode: a.dwq ? 'dwq' : 'affine');
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

QuantLabel _withImatrix(QuantLabel q) {
  final m = RegExp(r'^((?:UD-)?(?:i1-)?)(.*)$', caseSensitive: false).firstMatch(q.raw)!;
  return _classifyGgufTag(m.group(1)!, m.group(2)!, raw: q.raw, imatrixHint: true);
}

String _removeToken(String stem, String token) {
  final out = stem.replaceFirst(RegExp('(?:^|[-_.])${RegExp.escape(token)}(?=\$|[-_.])', caseSensitive: false), '');
  final trimmed = out.replaceFirst(RegExp(r'^[-_.]+'), '');
  return trimmed == stem ? stem.replaceFirst(RegExp(RegExp.escape(token), caseSensitive: false), '') : trimmed;
}

String _deviceName(String raw) {
  final l = raw.toLowerCase();
  final soc = RegExp(r'^(qualcomm|mediatek)[._-](\w+)$').firstMatch(l);
  if (soc != null) return '${soc.group(1) == 'qualcomm' ? 'Qualcomm' : 'MediaTek'} ${soc.group(2)!.toUpperCase()}';
  return raw.replaceAll('_', ' ');
}

String _num(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

String _sizeExplanation(ParamSize s) => switch (s.kind) {
      ParamSizeKind.experts => '${s.label}: ${s.experts} experts of ~${s.label.split('x').last} each; the real total is '
          'smaller than ${_num(s.billions)}B because attention is shared — the GGUF header has the exact count',
      ParamSizeKind.effective => '${s.label}: ~${_num(s.billions)}B effective parameters (per-layer embeddings); '
          'the raw weight count is much larger, so the download size comes from file bytes',
      ParamSizeKind.total => '${s.label}: about ${_num(s.billions >= 1 ? s.billions : s.billions * 1000)}'
          '${s.billions >= 1 ? ' billion' : ' million'} parameters',
    };

String _variantExplanation(NameVariant v, String raw) =>
    raw.toLowerCase() == v.name.toLowerCase() ? v.explanation : '$raw: ${v.explanation}';

String _roleExplanation(FileRole role, DraftKind? draft, String? prefix) => switch (role) {
      FileRole.draft => switch (draft) {
          DraftKind.mtp => 'MTP draft head: optional speculative decoding sidecar for this model',
          DraftKind.eagle3 => 'EAGLE-3 draft model: optional speculative decoding sidecar',
          DraftKind.dflash => 'DFlash draft model: optional speculative decoding sidecar',
          DraftKind.dspark => 'DSpark draft model: optional speculative decoding sidecar',
          null => role.explanation,
        },
      FileRole.unknownSidecar => '"$prefix-" prefix is not a known llama.cpp sidecar; not offered as the main model',
      _ => role.explanation,
    };

String _baseExplanation(String? base, String? baseVersion, List<Decoded<NameVariant>> variants) {
  if (base == null) return '';
  final v = baseVersion == null ? '' : ' $baseVersion';
  return variants.any((d) => d.value == NameVariant.distill)
      ? 'Distilled into a $base$v base model'
      : 'Fine-tune built on $base$v';
}

const List<String> _months = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November',
  'December',
];

String _buildExplanation(String? build) {
  if (build == null) return '';
  final yy = int.parse(build.substring(0, 2));
  final mm = int.parse(build.substring(2));
  if (yy >= 23 && yy <= 30 && mm >= 1 && mm <= 12) {
    return '$build: release tag (YYMM: ${_months[mm - 1]} 20$yy)';
  }
  return '$build: release/date tag (format ambiguous)';
}

String _contextExplanation(String raw, int tokens) => raw.toLowerCase().startsWith('ekv')
    ? '$raw: KV cache built for $tokens tokens (LiteRT; inferred from the name)'
    : '$raw: context-length hint ($tokens tokens), not a parameter count';

String _shardExplanation(ShardInfo s) => s.byteSplit
    ? '${s.toString().replaceFirst('part', 'Part')} of a byte split: download all parts and join them in order, then load'
    : s.count == null
        ? 'Shard ${s.index}: load all shards together'
        : 'Part ${s.index} of ${s.count}: download every part into one folder; the loader opens part 1';
