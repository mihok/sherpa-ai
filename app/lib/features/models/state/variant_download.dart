import 'dart:math' as math;

import 'package:sherpa_hub/sherpa_hub.dart';

import '../../../services/downloads/downloads.dart';
import 'model_fit.dart';

/// What the library records about a variant the user downloads from the
/// Hub detail screen (or onboarding's starter model): the name, quant and
/// format, the trained context, and the context to open with — the largest
/// that fits with headroom, or a small one for a Tight variant.
DownloadMeta downloadMetaFor(CatalogModelDetails d, VariantRow row, ModelShape? shape) {
  final arch = shape?.architecture;
  return DownloadMeta(
    displayName: d.name.displayName,
    quant: row.variant.quant?.label ?? row.label,
    format: row.variant.format,
    contextLength: arch?.trainContextLength,
    // Nothing fits with headroom on a Tight variant, so it opens small.
    recommendedContext: row.fit?.recommendedMaxContext ??
        (row.kind == FitBadgeKind.tight ? math.min(2048, arch?.trainContextLength ?? 2048) : null),
    architecture: arch?.architecture,
    parameterCount: shape?.parameterCount ?? d.parameterCount,
    license: d.license,
    toolUse: d.toolUseHint,
    reasoning: d.reasoningHint,
  );
}

/// Plans [row] of [d] pinned to its commit and queues it on [manager]. A
/// plan the planner refuses comes back as [EnqueueRefused] with its
/// reasons, like a refusal of the manager's own (storage, which also
/// counts LiteRT-LM's weight cache).
Future<EnqueueOutcome> enqueueVariant(
  DownloadManager manager,
  CatalogModelDetails d,
  VariantRow row,
  ModelShape? shape,
) async {
  final plan = planDownload(
    repo: d.id,
    commit: d.commit,
    files: [for (final f in d.files) f.file],
    quant: row.variant.id,
    repoSecurity: d.security,
  );
  if (plan is PlanRefused) return EnqueueRefused(plan.reasons);
  return manager.enqueue(plan as DownloadPlan, meta: downloadMetaFor(d, row, shape));
}
