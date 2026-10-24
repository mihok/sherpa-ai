import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../fit/device_fit.dart' show liteRtWeightCacheBytes;
import '../hub/hub_models.dart';
import '../naming/model_name.dart';
import '../naming/name_types.dart';
import '../naming/quant_types.dart';
import 'download_record.dart';
import 'file_safety.dart';

/// Which Sherpa runtime would load a variant.
enum SherpaRuntime { llamaCpp, mlx, litert, none }

/// One downloadable variant of a repo: a quant (all its shards) for GGUF,
/// the whole weight set for MLX/safetensors, or one LiteRT bundle.
@immutable
final class RepoVariant {
  const RepoVariant({
    required this.id,
    required this.label,
    required this.format,
    required this.runtime,
    required this.weights,
    required this.primaryName,
    this.support = const [],
    this.quant,
    this.expectedParts,
    this.missingParts = const [],
    this.blockedReasons = const [],
    this.unsupportedFormat,
    this.hubFlags = const [],
    this.warnings = const [],
  });

  /// Unique within the repo: the shard-less path stem (`BF16/Qwen3.8-27B-BF16`).
  final String id;

  /// What the UI shows: the quant label, or the file name.
  final String label;
  final ModelFormat format;
  final SherpaRuntime runtime;

  /// Weight files in load order (shard 1 first).
  final List<HubRepoFile> weights;

  /// Config/tokenizer files MLX needs next to the weights.
  final List<HubRepoFile> support;
  final ParsedModelName primaryName;
  final QuantLabel? quant;
  final int? expectedParts;

  /// Shard/part numbers that are missing from the listing.
  final List<int> missingParts;
  final List<String> blockedReasons;

  /// Why no Sherpa runtime loads this variant's format on any device
  /// ([unsupportedFormatReason]), or null when one does. It is one of
  /// [blockedReasons]: a fact about the files rather than a fault in them,
  /// which the app words for the device it runs on.
  final String? unsupportedFormat;

  /// The [fileProblems] that are the Hub scanners' verdicts on its files
  /// (`The Hub flags … as unsafe`): a fact about the upload whatever runs
  /// it, where its other problems only matter to a device that could.
  final List<String> hubFlags;
  final List<String> warnings;

  bool get complete => missingParts.isEmpty;

  /// [blockedReasons] other than [unsupportedFormat]: something wrong with
  /// the files themselves (unsafe, a config missing, a removed quant).
  List<String> get fileProblems => [for (final r in blockedReasons) if (r != unsupportedFormat) r];

  /// Offered for download (greyed out with [blockedReasons] otherwise).
  bool get usable => complete && blockedReasons.isEmpty;

  bool get isByteSplit => primaryName.shard?.value.byteSplit ?? false;

  int get weightBytes => weights.fold(0, (a, f) => a + (f.size ?? f.lfsSize ?? 0));

  int get totalBytes => weightBytes + support.fold(0, (a, f) => a + (f.size ?? 0));

  /// The path the engine opens: shard 1, or the joined file for byte splits.
  String get loadPath => isByteSplit ? _joinTarget(weights.first.path) : weights.first.path;
}

String _joinTarget(String partPath) => partPath.replaceFirst(RegExp(r'\.part\d+of\d+$', caseSensitive: false), '');

final RegExp _shardSuffix = RegExp(r'-(\d{5,6})-of-(\d{5,6})$', caseSensitive: false);
final RegExp _partRe = RegExp(r'\.gguf\.part(\d+)of(\d+)$', caseSensitive: false);

/// MLX/transformers files that must sit next to the weights.
const Set<String> _supportFiles = {
  'config.json', 'generation_config.json', 'tokenizer.json', 'tokenizer_config.json', 'tokenizer.model',
  'special_tokens_map.json', 'added_tokens.json', 'vocab.json', 'merges.txt', 'chat_template.jinja',
  'chat_template.json', 'preprocessor_config.json', 'processor_config.json', 'model.safetensors.index.json',
};

/// Why no Sherpa runtime loads [format], on any device, naming the format
/// the way its model pages do. Null for the formats Sherpa runs (GGUF,
/// MLX, LiteRT-LM); which of those run on a given device is the app's call,
/// and the app says what runs there, so these lines name no platform.
/// [fileName], the variant's first weight file, tells a LiteRT-LM bundle
/// (`.litertlm`) from the TensorFlow Lite and MediaPipe files that the name
/// parser also reads as LiteRT. [mlxRepo]: the repo is an MLX conversion,
/// so its `.npz` files are old MLX weights rather than any NumPy arrays.
String? unsupportedFormatReason(ModelFormat format, {required String fileName, bool mlxRepo = false}) =>
    switch (format) {
      ModelFormat.safetensors => "Sherpa can't run Transformers weights (safetensors).",
      ModelFormat.pickle => "Sherpa can't run PyTorch weights (.bin, .pt).",
      ModelFormat.gptq => "Sherpa can't run GPTQ weights (made for CUDA GPUs).",
      ModelFormat.awq => "Sherpa can't run AWQ weights (made for CUDA GPUs).",
      ModelFormat.exl2 => "Sherpa can't run EXL2 weights (made for CUDA GPUs).",
      ModelFormat.exl3 => "Sherpa can't run EXL3 weights (made for CUDA GPUs).",
      ModelFormat.ggml => "Sherpa can't run old GGML files (llama.cpp now reads GGUF).",
      ModelFormat.mlxNpz when mlxRepo => "Sherpa can't run old MLX .npz weights.",
      ModelFormat.mlxNpz => "Sherpa can't run NumPy .npz files.",
      ModelFormat.onnx || ModelFormat.onnxData => "Sherpa can't run ONNX models.",
      ModelFormat.other => "Sherpa can't run these files.",
      ModelFormat.litert when fileName.toLowerCase().endsWith('.task') => "Sherpa can't run MediaPipe .task bundles.",
      ModelFormat.litert when !_isLiteRtLm(fileName) => "Sherpa can't run TensorFlow Lite .tflite files.",
      ModelFormat.gguf || ModelFormat.ggufPart || ModelFormat.mlx || ModelFormat.litert => null,
    };

/// The only LiteRT files Sherpa's LiteRT-LM runtime loads.
bool _isLiteRtLm(String path) => path.toLowerCase().endsWith('.litertlm');

/// Formats that share their extension with pickles (`.bin`, `.npz`) without
/// being one. [FileSafety] refuses them by that extension; a variant in one
/// says why nothing loads it with [unsupportedFormatReason] instead of
/// calling it a pickle.
const Set<ModelFormat> _pickleNamed = {ModelFormat.ggml, ModelFormat.mlxNpz};

/// Name flags that only restate that a format has no runtime; a variant
/// in such a format says so once, with [unsupportedFormatReason].
const Set<NameFlag> _formatFlags = {NameFlag.gpuOnly, NameFlag.legacyGgml, NameFlag.legacyFormat};

/// Groups a repo listing into [RepoVariant]s. Blocked variants are kept so
/// the UI can list them greyed out with the reason (R08 §15.2).
///
/// [formatHints] are what the Hub says about the whole repo's format
/// ([HubModelInfo.formatHints]), read with its file names: many MLX
/// conversions of language models are tagged `mlx` without "mlx" in their
/// name, so their safetensors folders count as MLX the way an `mlx` name
/// token or the `mlx-community` owner makes them.
List<RepoVariant> groupVariants(
  String repo,
  List<HubRepoFile> files, {
  HubRepoSecurity? repoSecurity,
  Map<String, Uint8List> sniffedHeads = const {},
  Set<String> formatHints = const {},
}) {
  final parsed = <String, ParsedModelName>{
    for (final f in files)
      if (!f.isDirectory) f.path: parseModelName(repo, fileName: f.path, repoHints: formatHints),
  };
  final groups = <String, List<HubRepoFile>>{};
  final kinds = <String, ModelFormat>{};
  final mlxWeights = <String, List<HubRepoFile>>{};
  final mlxRepo = parseModelName(repo, repoHints: formatHints).format == ModelFormat.mlx;

  for (final f in files) {
    if (f.isDirectory) continue;
    final p = parsed[f.path]!;
    final role = p.role.value;
    if (role != FileRole.model) continue;
    switch (p.format) {
      case ModelFormat.gguf || ModelFormat.ggml || ModelFormat.pickle:
        // Shard-less stem: `BF16/X-BF16-00001-of-00002.gguf` → `BF16/X-BF16`.
        final key = f.path.replaceFirst(RegExp(r'\.[^./]+$'), '').replaceFirst(_shardSuffix, '');
        groups.putIfAbsent(key, () => []).add(f);
        kinds[key] = p.format;
      case ModelFormat.ggufPart:
        final key = f.path.replaceFirst(_partRe, '');
        groups.putIfAbsent(key, () => []).add(f);
        kinds[key] = ModelFormat.ggufPart;
      case ModelFormat.litert || ModelFormat.onnx || ModelFormat.mlxNpz:
        groups[f.path] = [f];
        kinds[f.path] = p.format;
      case ModelFormat.safetensors ||
            ModelFormat.mlx ||
            ModelFormat.gptq ||
            ModelFormat.awq ||
            ModelFormat.exl2 ||
            ModelFormat.exl3:
        final dir = f.path.contains('/') ? f.path.substring(0, f.path.lastIndexOf('/')) : '';
        mlxWeights.putIfAbsent(dir, () => []).add(f);
      case ModelFormat.onnxData || ModelFormat.other:
        break;
    }
  }

  final out = <RepoVariant>[];
  for (final e in groups.entries) {
    final fs = [...e.value]..sort((a, b) => _partIndex(parsed[a.path]!).compareTo(_partIndex(parsed[b.path]!)));
    final primary = parsed[fs.first.path]!;
    final format = kinds[e.key]!;
    final expected = primary.shard?.value.count;
    final present = {for (final f in fs) _partIndex(parsed[f.path]!)};
    final missing = expected == null ? <int>[] : [for (var i = 1; i <= expected; i++) if (!present.contains(i)) i];
    final runtime = switch (format) {
      ModelFormat.gguf || ModelFormat.ggufPart => SherpaRuntime.llamaCpp,
      ModelFormat.litert when _isLiteRtLm(fs.first.path) => SherpaRuntime.litert,
      _ => SherpaRuntime.none,
    };
    final unsupported = runtime == SherpaRuntime.none
        ? unsupportedFormatReason(format, fileName: fs.first.path, mlxRepo: mlxRepo)
        : null;
    final blocked = <String>{};
    final flagged = <String>{};
    final warnings = <String>{};
    for (final f in fs) {
      final p = parsed[f.path]!;
      for (final flag in p.flags) {
        if (flag.blocking && !(unsupported != null && _formatFlags.contains(flag))) blocked.add(flag.explanation);
      }
      final s = FileSafety.check(f, repoSecurity: repoSecurity, head: sniffedHeads[f.path]);
      if (!s.allowed && !(s.byExtension && _pickleNamed.contains(format))) blocked.add(s.reason!);
      if (s.hubFlagged) flagged.add(s.reason!);
      warnings.addAll(s.warnings);
    }
    final q = primary.quant?.value;
    if (q != null && q.ggufType?.status == QuantStatus.newRuntime) warnings.add(NameFlag.newRuntimeQuant.explanation);
    if (q != null && q.ambiguous) warnings.add(NameFlag.ambiguousQuant.explanation);
    if (primary.flags.contains(NameFlag.byteSplit)) warnings.add(NameFlag.byteSplit.explanation);
    if (unsupported != null) blocked.add(unsupported);
    out.add(RepoVariant(
      id: e.key,
      label: q?.label ?? fs.first.name,
      format: format,
      runtime: runtime,
      weights: List.unmodifiable(fs),
      primaryName: primary,
      quant: q,
      expectedParts: expected,
      missingParts: List.unmodifiable(missing),
      blockedReasons: List.unmodifiable(blocked),
      unsupportedFormat: unsupported,
      hubFlags: List.unmodifiable(flagged),
      warnings: List.unmodifiable(warnings),
    ));
  }

  // One variant per directory of safetensors weights (MLX, or HF formats
  // that Sherpa can't run — kept so the UI can say why).
  for (final e in mlxWeights.entries) {
    final dir = e.key;
    final fs = [...e.value]..sort((a, b) => a.path.compareTo(b.path));
    final primary = parsed[fs.first.path]!;
    final format = primary.format;
    final unsupported = unsupportedFormatReason(format, fileName: fs.first.path, mlxRepo: mlxRepo);
    final support = [
      for (final f in files)
        if (!f.isDirectory &&
            _supportFiles.contains(f.name.toLowerCase()) &&
            (f.path.contains('/') ? f.path.substring(0, f.path.lastIndexOf('/')) : '') == dir)
          f,
    ];
    final blocked = <String>{};
    final flagged = <String>{};
    final warnings = <String>{};
    for (final f in [...fs, ...support]) {
      for (final flag in parsed[f.path]?.flags ?? const <NameFlag>{}) {
        if (flag.blocking && flag != NameFlag.notAModel && !(unsupported != null && _formatFlags.contains(flag))) {
          blocked.add(flag.explanation);
        }
      }
      final s = FileSafety.check(f, repoSecurity: repoSecurity, head: sniffedHeads[f.path]);
      if (!s.allowed) blocked.add(s.reason!);
      if (s.hubFlagged) flagged.add(s.reason!);
      warnings.addAll(s.warnings);
    }
    if (unsupported != null) blocked.add(unsupported);
    if (!support.any((f) => f.name.toLowerCase() == 'config.json')) blocked.add('config.json is missing');
    // MLX loads every weight file in the folder: two shard sets side by side
    // (`model-…-of-00018` and `model-…-of-00028`, or `consolidated-…-of-00003`
    // and `model-…-of-00002`) would load as one model. A lone file of another
    // stem next to a set (`model-extra-00001-of-00001`, which the index maps
    // tensors to) is part of that model, not a second set.
    final parts = <(String, int), Set<int>>{};
    for (final f in fs) {
      if (parsed[f.path]!.shard?.value case ShardInfo(:final index, count: final n?)) {
        parts.putIfAbsent((_shardStem(f.name), n), () => {}).add(index);
      }
    }
    final sets = [
      for (final k in parts.keys)
        if (k.$2 > 1 || parts.keys.where((o) => o.$1 == k.$1).length > 1) k,
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    if (format == ModelFormat.mlx && sets.length > 1) {
      blocked.add('This folder holds more than one set of weights (in ${_andList([for (final s in sets) s.$2])} parts).');
    }
    // The parts to check are the largest set's, wherever its files sort.
    final main = sets.lastOrNull ?? parts.keys.firstOrNull;
    final expected = main?.$2;
    final present = parts[main] ?? const <int>{};
    final missing = expected == null ? <int>[] : [for (var i = 1; i <= expected; i++) if (!present.contains(i)) i];
    out.add(RepoVariant(
      id: dir.isEmpty ? format.name : '$dir/${format.name}',
      label: primary.quant?.value.label ?? format.name,
      format: format,
      runtime: format == ModelFormat.mlx ? SherpaRuntime.mlx : SherpaRuntime.none,
      weights: List.unmodifiable(fs),
      support: List.unmodifiable(support),
      primaryName: primary,
      quant: primary.quant?.value,
      expectedParts: expected,
      missingParts: List.unmodifiable(missing),
      blockedReasons: List.unmodifiable(blocked),
      unsupportedFormat: unsupported,
      hubFlags: List.unmodifiable(flagged),
      warnings: List.unmodifiable(warnings),
    ));
  }

  int rank(RepoVariant v) {
    final t = v.quant?.ggufType;
    final i = t == null ? -1 : QuantTypes.all.indexOf(t);
    return i < 0 ? QuantTypes.all.length : i;
  }

  out.sort((a, b) {
    if (a.usable != b.usable) return a.usable ? -1 : 1;
    final r = rank(a).compareTo(rank(b));
    return r != 0 ? r : a.id.compareTo(b.id);
  });
  return List.unmodifiable(out);
}

int _partIndex(ParsedModelName p) => p.shard?.value.index ?? 1;

/// A weight file's name without its extension and shard suffix: what the
/// files of one shard set share (`model` for `model-00002-of-00028.safetensors`).
String _shardStem(String name) => name
    .replaceFirst(RegExp(r'\.[^.]+$'), '')
    .replaceFirst(RegExp(r'[-.]\d{1,6}-of-\d{1,6}$', caseSensitive: false), '');

/// `1, 18 and 28`.
String _andList(List<Object> items) =>
    items.length < 2 ? items.join() : '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';

/// llama.cpp's `-hf` default: first `Q4_K_M`, then `Q8_0`, then the first
/// usable model (R08 §13.2, vendored `common/download.cpp find_best_model`).
RepoVariant? defaultVariant(List<RepoVariant> variants) {
  final usable = variants.where((v) => v.usable).toList();
  for (final tag in const ['Q4_K_M', 'Q8_0']) {
    for (final v in usable) {
      if (v.quant?.label.toUpperCase() == tag) return v;
    }
  }
  return usable.isEmpty ? null : usable.first;
}

/// Finds a variant by id, or by quant label (case-insensitive). Several
/// variants with one label (split and unsplit copies) → the complete one
/// with fewer files.
RepoVariant? findVariant(List<RepoVariant> variants, String idOrQuant) {
  for (final v in variants) {
    if (v.id == idOrQuant) return v;
  }
  final want = idOrQuant.toUpperCase();
  final matches = variants.where((v) => v.label.toUpperCase() == want).toList()
    ..sort((a, b) {
      if (a.usable != b.usable) return a.usable ? -1 : 1;
      return a.weights.length.compareTo(b.weights.length);
    });
  return matches.isEmpty ? null : matches.first;
}

/// Pairs a sidecar (`mmproj`, `mtp-`, `eagle3-`, …) with a model file the
/// way llama.cpp's `find_best_sibling` does (R08 §13.2): the sidecar's
/// directory must be the model's or an ancestor, deeper wins; then an exact
/// `-TAG.` match; then the closest bit width.
///
/// Deviations: bits come from the name parser (llama.cpp reads the last
/// `[-.]TAG`, which yields 0 for `…-BF16-mmproj.gguf`), and when no sidecar
/// shares an ancestor directory (unsloth keeps drafts in `MTP/`) the others
/// are considered at the lowest priority instead of being ignored. On a
/// full tie F16 beats other types (BF16, F32): the Adreno OpenCL backend
/// has F16 but no BF16 kernels (R07 §1.7), while llama.cpp keeps whichever
/// file is listed first.
HubRepoFile? pairSidecar(
  String repo,
  RepoVariant model,
  List<HubRepoFile> files, {
  required FileRole role,
  DraftKind? draftKind,
  String? tag,
}) {
  final modelPath = model.weights.first.path;
  final modelDirs = modelPath.split('/')..removeLast();
  final modelBits = model.quant?.bits ?? 0;
  final upperTag = tag?.toUpperCase();
  HubRepoFile? best;
  var bestDepth = -2;
  var bestExact = false;
  var bestDiff = 1 << 30;
  var bestF16 = false;
  for (final f in files) {
    if (f.isDirectory || !f.path.toLowerCase().endsWith('.gguf')) continue;
    final p = parseModelName(repo, fileName: f.path);
    if (p.role.value != role) continue;
    if (draftKind != null && p.draftKind != draftKind) continue;
    if (!FileSafety.check(f).allowed || p.isBlocked) continue;
    final dirs = f.path.split('/')..removeLast();
    var depth = -1; // not an ancestor directory: lowest priority
    if (dirs.length <= modelDirs.length && Iterable<int>.generate(dirs.length).every((i) => dirs[i] == modelDirs[i])) {
      depth = dirs.length;
    }
    final exact = upperTag != null && f.path.toUpperCase().contains('-$upperTag.');
    final diff = ((p.quant?.value.bits ?? 0) - modelBits).abs();
    final f16 = p.quant?.value.ggufType == QuantTypes.f16;
    final better = best == null ||
        depth > bestDepth ||
        (depth == bestDepth && exact && !bestExact) ||
        (depth == bestDepth && exact == bestExact && diff < bestDiff) ||
        (depth == bestDepth && exact == bestExact && diff == bestDiff && f16 && !bestF16);
    if (better) {
      best = f;
      bestDepth = depth;
      bestExact = exact;
      bestDiff = diff;
      bestF16 = f16;
    }
  }
  return best;
}

/// One file of a plan.
@immutable
final class PlannedFile {
  const PlannedFile({
    required this.path,
    required this.role,
    required this.sizeBytes,
    this.sha256,
    this.gitBlobSha1,
    this.xetHash,
    this.shardIndex,
    this.shardCount,
    this.joinInto,
  });

  final String path;
  final FileRole role;
  final int sizeBytes;

  /// `lfs.oid`: verify after download.
  final String? sha256;

  /// Small non-LFS files only.
  final String? gitBlobSha1;
  final String? xetHash;
  final int? shardIndex;
  final int? shardCount;

  /// Byte-split parts are concatenated in order into this path.
  final String? joinInto;
}

sealed class PlanOutcome {
  const PlanOutcome();
}

/// Everything the download manager needs, pinned to one commit.
final class DownloadPlan extends PlanOutcome {
  const DownloadPlan({
    required this.repo,
    required this.commit,
    required this.variant,
    required this.files,
    required this.totalBytes,
    required this.tempBytes,
    this.runtimeCacheBytes = 0,
    this.mmproj,
    this.draft,
    this.warnings = const [],
  });

  final String repo;
  final String commit;
  final RepoVariant variant;

  /// Weights (shard order), then projector, draft, support files.
  final List<PlannedFile> files;

  /// Bytes to download (the storage check input).
  final int totalBytes;

  /// Extra bytes the download needs on top of [totalBytes] (the storage
  /// check counts them): the byte-split join peak (joining appends each
  /// verified part to the target and deletes it, so the peak is the
  /// largest part) plus [runtimeCacheBytes].
  final int tempBytes;

  /// Disk the runtime writes on the model's first load and keeps: LiteRT-LM's
  /// CPU weight cache in the app's cache directory, about the model's size
  /// ([liteRtWeightCacheBytes]). 0 for other runtimes. Included in
  /// [tempBytes], so a storage check that counts [tempBytes] counts it too.
  final int runtimeCacheBytes;
  final PlannedFile? mmproj;
  final PlannedFile? draft;
  final List<String> warnings;

  /// Folder that keeps all shards together (llama.cpp finds siblings by
  /// name, R08 §15.4).
  String get folder => '${repo.replaceAll('/', '__')}@${commit.substring(0, math.min(12, commit.length))}';

  /// Initial `queued` records, one per file.
  List<DownloadRecord> toRecords({required DateTime now, required IdGenerator ids}) {
    final group = ids.next('dlg');
    return [
      for (final f in files)
        DownloadRecord(
          id: ids.next('dl'),
          groupId: group,
          repo: repo,
          commit: commit,
          path: f.path,
          localPath: '$folder/${f.path}',
          role: f.role,
          expectedBytes: f.sizeBytes,
          state: DownloadState.queued,
          createdAt: now,
          updatedAt: now,
          sha256: f.sha256,
          gitBlobSha1: f.gitBlobSha1,
          expectedXetHash: f.xetHash,
          joinInto: f.joinInto == null ? null : '$folder/${f.joinInto}',
          partIndex: f.joinInto == null ? null : f.shardIndex,
          shardIndex: f.shardIndex,
          shardCount: f.shardCount,
        ),
    ];
  }
}

/// The plan was refused; [reasons] are user-facing.
final class PlanRefused extends PlanOutcome {
  const PlanRefused(this.reasons, {this.variant});

  final List<String> reasons;
  final RepoVariant? variant;
}

/// Turns a repo listing + a chosen quant into the exact files to fetch.
///
/// Refuses (never silently drops) when: the commit is not pinned, the
/// variant is unknown or incomplete, any file is a pickle (unless its first
/// bytes prove safetensors/GGUF), the Hub flags a file unsafe/suspicious,
/// the quant type was removed or the bundled runtime can't load it, or a
/// weight file lacks a size or SHA-256.
PlanOutcome planDownload({
  required String repo,
  required String commit,
  required List<HubRepoFile> files,
  String? quant,
  bool? includeMmproj,
  DraftKind? draft,
  HubRepoSecurity? repoSecurity,
  Set<String> unsupportedQuants = const {},
  Map<String, Uint8List> sniffedHeads = const {},
  Set<String> formatHints = const {},
}) {
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(commit)) {
    return const PlanRefused(['Downloads must be pinned to a commit sha, not a branch name.']);
  }
  final variants =
      groupVariants(repo, files, repoSecurity: repoSecurity, sniffedHeads: sniffedHeads, formatHints: formatHints);
  final v = quant == null ? defaultVariant(variants) : findVariant(variants, quant);
  if (v == null) {
    return PlanRefused([quant == null ? 'No loadable model in $repo.' : 'No "$quant" variant in $repo.']);
  }
  final reasons = <String>[...v.blockedReasons];
  if (!v.complete) reasons.add('Missing part(s) ${v.missingParts.join(', ')} of ${v.expectedParts}.');
  final type = v.quant?.ggufType;
  if (type != null && type.isRemoved && !reasons.any((r) => r.contains('removed'))) {
    reasons.add(type.explanation);
  }
  if (type != null && unsupportedQuants.contains(type.id)) reasons.add('${type.id} needs a newer llama.cpp than the bundled one.');
  if (v.runtime == SherpaRuntime.none && reasons.isEmpty) reasons.add('No Sherpa runtime can load ${v.format.name} files.');

  final planned = <PlannedFile>[];
  final warnings = <String>[...v.warnings];
  PlannedFile? toPlanned(HubRepoFile f, FileRole role, {required bool weights}) {
    final size = f.size ?? f.lfsSize;
    if (size == null) {
      reasons.add('${f.path}: size unknown (list files with blobs/tree first).');
      return null;
    }
    if (weights && f.lfsSha256 == null) {
      reasons.add('${f.path}: no SHA-256 to verify against.');
      return null;
    }
    final s = FileSafety.check(f, repoSecurity: repoSecurity, head: sniffedHeads[f.path]);
    if (!s.allowed && !reasons.contains(s.reason)) reasons.add(s.reason!);
    final p = parseModelName(repo, fileName: f.path);
    final shard = p.shard?.value;
    return PlannedFile(
      path: f.path,
      role: role,
      sizeBytes: size,
      sha256: f.lfsSha256,
      gitBlobSha1: f.isLfs ? null : f.oid,
      xetHash: f.xetHash,
      shardIndex: shard?.index,
      shardCount: shard?.count,
      joinInto: shard != null && shard.byteSplit ? _joinTarget(f.path) : null,
    );
  }

  for (final f in v.weights) {
    final pf = toPlanned(f, FileRole.model, weights: true);
    if (pf != null) planned.add(pf);
  }

  PlannedFile? mmproj;
  final hasProjector = files.any((f) => !f.isDirectory && parseModelName(repo, fileName: f.path).role.value == FileRole.mmproj);
  if (v.runtime == SherpaRuntime.llamaCpp && (includeMmproj ?? hasProjector)) {
    final m = pairSidecar(repo, v, files, role: FileRole.mmproj);
    if (m != null) {
      mmproj = toPlanned(m, FileRole.mmproj, weights: true);
      if (mmproj != null) planned.add(mmproj);
    } else if (includeMmproj ?? false) {
      warnings.add('No multimodal projector (mmproj) found; image input will be unavailable.');
    }
  }
  PlannedFile? draftFile;
  if (draft != null && v.runtime == SherpaRuntime.llamaCpp) {
    final d = pairSidecar(repo, v, files, role: FileRole.draft, draftKind: draft, tag: v.quant?.label);
    if (d == null) {
      warnings.add('No ${draft.name} draft in this repository; speculative decoding will use n-gram drafting.');
    } else {
      draftFile = toPlanned(d, FileRole.draft, weights: true);
      if (draftFile != null) planned.add(draftFile);
    }
  }
  for (final f in v.support) {
    final pf = toPlanned(f, FileRole.config, weights: f.isLfs);
    if (pf != null) planned.add(pf);
  }
  if (reasons.isNotEmpty) return PlanRefused(List.unmodifiable(reasons), variant: v);

  final total = planned.fold<int>(0, (a, f) => a + f.sizeBytes);
  final join = v.isByteSplit ? planned.where((f) => f.joinInto != null).fold<int>(0, (a, f) => math.max(a, f.sizeBytes)) : 0;
  final cache = v.runtime == SherpaRuntime.litert
      ? liteRtWeightCacheBytes(planned.where((f) => f.role == FileRole.model).fold<int>(0, (a, f) => a + f.sizeBytes))
      : 0;
  return DownloadPlan(
    repo: repo,
    commit: commit,
    variant: v,
    files: List.unmodifiable(planned),
    totalBytes: total,
    tempBytes: join + cache,
    runtimeCacheBytes: cache,
    mmproj: mmproj,
    draft: draftFile,
    warnings: List.unmodifiable(warnings),
  );
}
