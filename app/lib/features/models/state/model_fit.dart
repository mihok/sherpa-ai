import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;
import 'package:sherpa_hub/sherpa_hub.dart';

/// The shape facts of a model, from one GGUF header peek.
@immutable
final class ModelShape {
  const ModelShape({required this.architecture, required this.metadata, this.parameterCount, this.bytesFetched});

  final ModelArchitecture architecture;
  final GgufMetadata metadata;

  /// Exact count from the GGUF tensor table.
  final int? parameterCount;

  /// What the peek cost (shown in the tooltip: it is mobile data too).
  final int? bytesFetched;
}

/// Reads a model's architecture without downloading it.
abstract interface class ModelShapeSource {
  Future<ModelShape> peek(String repo, String commit, String path);
}

/// One Range-request peek of a GGUF header (2 MB first, up to ~8 MB for
/// big vocabularies, R08 §5.6). Layers, KV heads, head size and trained
/// context are the same for every quant of a repo, so one peek of the
/// default variant sizes all of them; the bytes per variant come from the
/// real file sizes, never from names or the repo-level `gguf` summary
/// (which describes one arbitrary file, R08 §0.5).
final class HubModelShapeSource implements ModelShapeSource {
  HubModelShapeSource(this.client);

  final HfHubClient client;
  final Map<(String, String, String), Future<ModelShape>> _cache = {};

  @override
  Future<ModelShape> peek(String repo, String commit, String path) {
    final key = (repo, commit, path);
    final cached = _cache[key];
    if (cached != null) return cached;
    final f = _peek(repo, commit, path);
    _cache[key] = f;
    // Failures are not cached: signing in or reconnecting should retry.
    unawaited(f.then<void>((_) {}, onError: (Object _) => _cache.remove(key)));
    return f;
  }

  Future<ModelShape> _peek(String repo, String commit, String path) async {
    final peek = await client.readGgufHeader(repo, commit, path, readTensorInfo: true, maxBytes: 16 << 20);
    final arch = ModelArchitecture.fromGguf(peek.header.metadata, parameterCount: peek.header.parameterCount);
    if (arch == null) throw const GgufFormatException('the header lacks the layer and head counts');
    return ModelShape(
      architecture: arch,
      metadata: peek.header.metadata,
      parameterCount: peek.header.parameterCount,
      bytesFetched: peek.bytesFetched,
    );
  }
}

/// The verdict a variant row shows.
enum FitBadgeKind {
  fits,
  tight,
  wontFit,

  /// The shape could not be read (gated, offline, not GGUF).
  unknown,

  /// Unsafe or broken (a file flagged, a part or the config missing):
  /// never downloadable.
  blocked,

  /// No runtime on this device loads its format (Transformers weights on
  /// any device, MLX on Android, LiteRT-LM on iOS): not downloadable here,
  /// though nothing is wrong with the files.
  unsupported;

  static FitBadgeKind of(FitVerdict v) => switch (v) {
        FitVerdict.fits => fits,
        FitVerdict.tight => tight,
        FitVerdict.wontFit => wontFit,
      };
}

/// The sentence under an unknown badge.
const String fitNotCheckedReason = 'Fit not checked: the model header could not be read.';

/// The sentence under a fit badge: the first blocking reason, else the
/// first warning, else how much of the budget the model needs.
String fitReasonText(FitResult f) {
  final blocking = f.reasons.where((r) => r.severity == FitSeverity.blocking);
  if (blocking.isNotEmpty) return blocking.first.message;
  final warn = f.reasons.where((r) => r.severity == FitSeverity.warning);
  if (warn.isNotEmpty) return warn.first.message;
  return 'Needs about ${_gb(f.demandBytes)} of the ~${_gb(f.budgetBytes)} available.';
}

/// One downloadable (or explicitly not downloadable) variant of a repo.
@immutable
final class VariantRow {
  const VariantRow({
    required this.variant,
    required this.downloadBytes,
    required this.kind,
    this.mmproj,
    this.fit,
    this.effectiveBpw,
    this.recommended = false,
    this.blockedReasons = const [],
    this.unsupportedReasons = const [],
    this.warnings = const [],
    this.runtimeCacheBytes = 0,
  });

  final RepoVariant variant;

  /// Disk the runtime adds on first load (LiteRT-LM's CPU weight cache,
  /// about the model's size); the storage check counts it.
  final int runtimeCacheBytes;

  /// Every byte the plan would fetch: shards + paired projector.
  final int downloadBytes;
  final FitBadgeKind kind;

  /// The projector llama.cpp's own rules pair with this variant.
  final HubRepoFile? mmproj;
  final FitResult? fit;

  /// Weight bytes × 8 / parameters: what the file really spends per weight
  /// (names lie for small models: gemma-3-270m Q2_K is 7.07, R08 §0.20).
  final double? effectiveBpw;
  final bool recommended;

  /// What is wrong with the files themselves (unsafe, incomplete). For a
  /// format this device can't run, only the Hub's scanner verdicts: the
  /// rest would never stop a download that can't happen here.
  final List<String> blockedReasons;

  /// Why no runtime on this device loads the variant, and what runs here
  /// instead: a fact about its format, not a fault, so the UI words it
  /// plainly rather than as an error.
  final List<String> unsupportedReasons;
  final List<String> warnings;

  String get label => variant.label;

  /// Listed greyed out and never selectable: broken, or not for this device.
  bool get unavailable => kind == FitBadgeKind.blocked || kind == FitBadgeKind.unsupported;

  /// Download is never offered for Won't fit, unsafe or broken files, or a
  /// format this device can't run.
  bool get canDownload => !unavailable && kind != FitBadgeKind.wontFit;

  /// Tight, or unknown because the shape could not be read: the user
  /// confirms with the reason in front of them.
  bool get needsConfirm => kind == FitBadgeKind.tight || kind == FitBadgeKind.unknown;

  /// The sentence under the badge.
  String get reason {
    if (blockedReasons.isNotEmpty) return blockedReasons.first;
    if (unsupportedReasons.isNotEmpty) return unsupportedReasons.join(' ');
    final f = fit;
    if (f == null) return fitNotCheckedReason;
    return fitReasonText(f);
  }

  /// Bits per weight to show: measured when the parameter count is known,
  /// else the label's nominal figure.
  double? get bitsPerWeight => effectiveBpw ?? variant.quant?.bpw ?? variant.quant?.ggufType?.typicalFileBpw;

  bool get bpwMeasured => effectiveBpw != null;
}

/// Everything the detail screen shows about fit, computed from the Hub
/// listing, one header peek and the device profile. Pure: no IO.
@immutable
final class ModelAssessment {
  const ModelAssessment({
    required this.rows,
    required this.summary,
    this.recommended,
    this.otherFiles = const [],
    this.notForThisDevice = false,
  });

  /// Usable variants first (best quality first), unavailable ones last.
  final List<VariantRow> rows;
  final VariantRow? recommended;
  final String summary;

  /// No variant here is in a format this device runs: another version of
  /// the model, a GGUF one, is the way forward. [summary] says so, with
  /// what runs here.
  final bool notForThisDevice;

  /// Sidecars and files that are not a model variant (imatrix, configs,
  /// pickles…), each with why it is not offered.
  final List<(HubRepoFile file, String why)> otherFiles;
}

/// The file whose header the detail screen peeks: the default variant's
/// first shard (llama.cpp's own `-hf` pick, R08 §13.2).
HubRepoFile? peekTarget(CatalogModelDetails d) {
  final v = d.defaultVariant;
  if (v == null || v.runtime != SherpaRuntime.llamaCpp) return null;
  return v.weights.first;
}

/// Builds the rows. [shape] null = header unknown (GGUF rows get
/// [FitBadgeKind.unknown]); the device's platform gates MLX (iOS) and
/// LiteRT (Android), and formats no Sherpa runtime loads are
/// [FitBadgeKind.unsupported] everywhere, with what runs on this platform
/// instead. MLX and LiteRT variants are sized from their files
/// ([assessRuntimeFit]: MLX weights, plus KV when [mlxConfig] — the repo's
/// `config.json` — is known; LiteRT the file plus its CPU weight cache).
ModelAssessment assessVariants(
  CatalogModelDetails details,
  DeviceProfile device, {
  ModelShape? shape,
  FitOptions options = const FitOptions(),
  Map<String, Object?>? mlxConfig,
}) {
  final mlxArch = mlxConfig == null ? null : ModelArchitecture.fromMlxConfig(mlxConfig);
  final files = [for (final f in details.files) f.file];
  final rows = <VariantRow>[];
  final candidates = <QuantCandidate>[];
  final mmprojFor = <String, HubRepoFile?>{};
  final blockedFor = <String, List<String>>{};
  final unsupportedFor = <String, List<String>>{};
  final p = device.platform;
  // No variant is in a format this device runs: the summary says what runs
  // here and to look for another version, once. Otherwise the variants that
  // do run here (even broken ones, whose problems are the story) are the
  // answer.
  final notForThisDevice = details.variants.isNotEmpty && !details.variants.any((v) => _formatRunsOn(v, p));
  for (final v in details.variants) {
    // A variant in a format this device can't run is never offered here, so
    // what is wrong with its files is moot: it reads as plain "can't run
    // here", save the Hub's own verdict on a file, which holds anywhere.
    // In a format that runs here, its problems are the story.
    final blocked = _formatRunsOn(v, p)
        ? [
            ...v.fileProblems,
            if (!v.complete) 'Missing part(s) ${v.missingParts.join(', ')} of ${v.expectedParts}.',
          ]
        : v.hubFlags;
    final unsupported = _unsupportedOn(v, p, alone: notForThisDevice);
    blockedFor[v.id] = blocked;
    unsupportedFor[v.id] = unsupported;
    final mm = v.runtime == SherpaRuntime.llamaCpp ? pairSidecar(details.id, v, files, role: FileRole.mmproj) : null;
    mmprojFor[v.id] = mm;
    if (blocked.isEmpty && unsupported.isEmpty && v.runtime == SherpaRuntime.llamaCpp) {
      candidates.add(QuantCandidate(
        id: v.id,
        weightBytes: v.weightBytes,
        quant: v.quant,
        mmprojBytes: mm?.size ?? mm?.lfsSize ?? 0,
        parameterCount: shape?.parameterCount ?? details.parameterCount,
      ));
    }
  }
  final arch = shape?.architecture;
  final rec = arch == null || candidates.isEmpty ? null : recommendQuant(device, arch, candidates, options: options);
  final params = shape?.parameterCount ?? details.parameterCount;

  for (final v in details.variants) {
    final blocked = blockedFor[v.id]!;
    final unsupported = unsupportedFor[v.id]!;
    final runs = blocked.isEmpty && unsupported.isEmpty;
    final mm = mmprojFor[v.id];
    final bytes = v.totalBytes + (mm?.size ?? mm?.lfsSize ?? 0);
    FitResult? fit;
    if (runs && arch != null && v.runtime == SherpaRuntime.llamaCpp) {
      fit = assessFit(
        device,
        ModelFootprintInput(
          architecture: arch,
          weightBytes: v.weightBytes,
          mmprojBytes: mm?.size ?? mm?.lfsSize ?? 0,
          quant: v.quant?.ggufType,
          label: v.label,
        ),
        options: options,
      );
    } else if (runs && (v.runtime == SherpaRuntime.mlx || v.runtime == SherpaRuntime.litert)) {
      fit = assessRuntimeFit(
        device,
        v.runtime == SherpaRuntime.mlx
            ? RuntimeFootprintInput.mlx(weightBytes: v.weightBytes, architecture: mlxArch, label: v.label)
            : RuntimeFootprintInput.liteRt(fileBytes: v.weightBytes, label: v.label),
        options: options,
      );
    }
    final kind = blocked.isNotEmpty
        ? FitBadgeKind.blocked
        : unsupported.isNotEmpty
            ? FitBadgeKind.unsupported
            : fit == null
                ? FitBadgeKind.unknown
                : FitBadgeKind.of(fit.verdict);
    final ranked = rec?.ranked.where((r) => r.candidate.id == v.id).firstOrNull;
    final eff = ranked?.effectiveBpw ?? effectiveBitsPerWeight(v.weightBytes, params);
    rows.add(VariantRow(
      variant: v,
      downloadBytes: bytes,
      kind: kind,
      mmproj: mm,
      fit: fit,
      effectiveBpw: eff,
      recommended: rec?.best?.candidate.id == v.id,
      blockedReasons: List.unmodifiable(blocked),
      unsupportedReasons: List.unmodifiable(unsupported),
      warnings: v.warnings,
      runtimeCacheBytes: v.runtime == SherpaRuntime.litert ? liteRtWeightCacheBytes(v.weightBytes) : 0,
    ));
  }

  int quality(VariantRow r) => r.unavailable ? 1 : 0;
  rows.sort((a, b) {
    final q = quality(a).compareTo(quality(b));
    if (q != 0) return q;
    return b.downloadBytes.compareTo(a.downloadBytes);
  });

  final recommended = rows.where((r) => r.recommended).firstOrNull;
  final variantFiles = {for (final v in details.variants) for (final f in [...v.weights, ...v.support]) f.path};
  final pairedProjectors = {for (final m in mmprojFor.values) ?m?.path};
  final others = <(HubRepoFile, String)>[];
  for (final f in details.files) {
    final path = f.file.path;
    if (variantFiles.contains(path) || pairedProjectors.contains(path)) continue;
    if (f.file.isDirectory) continue;
    final safety = FileSafety.check(f.file, repoSecurity: details.security);
    final role = f.name.role.value;
    final why = !safety.allowed
        ? safety.reason!
        : role != FileRole.model
            ? role.explanation
            : f.name.flags.where((x) => x.blocking).map((x) => x.explanation).firstOrNull ?? 'Not part of a model variant';
    others.add((f.file, why));
  }

  String labelOf(RankedQuant? r) =>
      rows.where((x) => x.variant.id == r?.candidate.id).firstOrNull?.label ?? r?.candidate.id ?? '';
  final String summary;
  final runtimeRows = [for (final r in rows) if (r.fit != null && r.variant.runtime != SherpaRuntime.llamaCpp) r];
  if (notForThisDevice) {
    summary = 'Nothing in this repository runs on ${_platformName(p)}. ${_runsOn(p)} ${_lookFor(p)}';
  } else if (candidates.isEmpty && runtimeRows.isNotEmpty) {
    final fitting = runtimeRows.where((r) => r.kind == FitBadgeKind.fits).firstOrNull;
    final tight = runtimeRows.where((r) => r.kind == FitBadgeKind.tight).firstOrNull;
    summary = fitting != null
        ? '${fitting.label} fits this device (estimated from its file sizes).'
        : tight != null
            ? 'Nothing fits with headroom; ${tight.label} might load, but memory is tight.'
            : 'No variant of this model fits this device.';
  } else if (arch == null) {
    summary = rows.any((r) => !r.unavailable)
        ? "Fit couldn't be checked; sizes are real, the memory estimate is missing."
        : 'Nothing in this repository can run in Sherpa.';
  } else if (rec?.best != null) {
    summary = '${labelOf(rec!.best)} is the best quality that fits this device with headroom.';
  } else if (rec?.fallback != null) {
    summary = 'Nothing fits with headroom; ${labelOf(rec!.fallback)} might load, but memory is tight.';
  } else if (candidates.isEmpty) {
    summary = 'No variant in this repository can run in Sherpa.';
  } else {
    summary = 'No variant of this model fits this device.';
  }
  return ModelAssessment(
    rows: List.unmodifiable(rows),
    recommended: recommended,
    summary: summary,
    otherFiles: others,
    notForThisDevice: notForThisDevice,
  );
}

/// Whether a runtime on [p] loads [v]'s format (its files may still be
/// broken).
bool _formatRunsOn(RepoVariant v, DevicePlatform p) => switch (v.runtime) {
      SherpaRuntime.llamaCpp => true,
      SherpaRuntime.mlx => p == DevicePlatform.ios,
      SherpaRuntime.litert => p == DevicePlatform.android,
      SherpaRuntime.none => false,
    };

/// Why no runtime on [p] loads [v]; empty when one does. A format no Sherpa
/// runtime loads is named (the planner's [RepoVariant.unsupportedFormat]),
/// then what Sherpa on [p] runs, unless the summary says that for the
/// whole repo ([alone]: nothing in it runs here).
List<String> _unsupportedOn(RepoVariant v, DevicePlatform p, {required bool alone}) {
  if (_formatRunsOn(v, p)) return const [];
  return switch (v.runtime) {
    SherpaRuntime.mlx => const ['MLX models run on iPhone and iPad only.'],
    SherpaRuntime.litert => const ['LiteRT-LM models run on Android only.'],
    _ => [
        v.unsupportedFormat ?? "Sherpa can't run these files.",
        if (!alone) _runsOn(p),
      ],
  };
}

String _platformName(DevicePlatform p) => switch (p) {
      DevicePlatform.android => 'Android',
      DevicePlatform.ios => 'iPhone or iPad',
      DevicePlatform.other => 'this device',
    };

String _runsOn(DevicePlatform p) => switch (p) {
      DevicePlatform.android => 'Sherpa on Android runs GGUF and LiteRT-LM models.',
      DevicePlatform.ios => 'Sherpa on iPhone and iPad runs GGUF and MLX models.',
      DevicePlatform.other => 'Sherpa on this device runs GGUF models.',
    };

String _lookFor(DevicePlatform p) => switch (p) {
      DevicePlatform.ios => 'Look for a GGUF or MLX version of this model.',
      DevicePlatform.android || DevicePlatform.other => 'Look for a GGUF version of this model.',
    };

/// The formats a model page with nothing for [p] finds other versions in:
/// the ones its summary says to look for.
List<HubFormatFilter> versionFormats(DevicePlatform p) =>
    [HubFormatFilter.gguf, if (p == DevicePlatform.ios) HubFormatFilter.mlx];

/// A browse card's estimate, before any file size is known.
@immutable
final class CardFitEstimate {
  const CardFitEstimate({required this.verdict, required this.estimatedBytes, required this.parameters, required this.bits});

  final FitVerdict verdict;
  final int estimatedBytes;
  final int parameters;
  final double bits;

  String get explanation =>
      'Estimated from ${_params(parameters)} parameters at ~${formatBpw(bits)} bits per weight (a typical 4-bit '
      'download). Open the model to check its real file sizes against this device.';
}

/// List responses carry no file sizes (R08 §2.4), so cards estimate from
/// the parameter count — `safetensors.total` when the Hub has it, else the
/// size in the name — at a typical 4-bit quant, and say it's an estimate.
/// Effective-parameter labels (`E2B`) are skipped: their raw weights are
/// far larger (R08 §13.4).
CardFitEstimate? estimateCardFit(CatalogEntry e, DeviceProfile device) {
  final size = e.name.size?.value;
  final params = e.summary?.safetensors?.total ??
      (size == null || size.kind == ParamSizeKind.effective ? null : size.approximateParameters);
  if (params == null || params <= 0) return null;
  final bits = switch (e.name.format) {
    ModelFormat.mlx || ModelFormat.litert => 4.5,
    _ => QuantTypes.q4_k_m.typicalFileBpw ?? 4.9,
  };
  final bytes = (params * bits / 8).round();
  final b = params / 1e9;
  final layers = b < 1 ? 24 : b < 4 ? 28 : b < 10 ? 36 : b < 40 ? 48 : 80;
  final arch = ModelArchitecture.dense(layers: layers, kvHeads: 8, headDim: 128, trainContextLength: 4096);
  final fit = assessFit(device, ModelFootprintInput(architecture: arch, weightBytes: bytes), computeMaxContext: false);
  return CardFitEstimate(verdict: fit.verdict, estimatedBytes: bytes, parameters: params, bits: bits);
}

String _params(int n) {
  final b = n / 1e9;
  if (b >= 10) return '${b.round()}B';
  if (b >= 1) {
    final t = b.toStringAsFixed(1);
    return '${t.endsWith('.0') ? t.substring(0, t.length - 2) : t}B';
  }
  return '${math.max(1, (n / 1e6).round())}M';
}

String _gb(int bytes) {
  final g = bytes / (1024 * 1024 * 1024);
  if (g >= 1) return '${g.toStringAsFixed(g >= 10 ? 0 : 1)} GB';
  return '${(bytes / (1024 * 1024)).round()} MB';
}
