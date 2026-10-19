import 'package:material_ui/material_ui.dart';
import 'package:sherpa_hub/sherpa_hub.dart';

import '../../../design/tokens.dart';
import '../../../design/typography.dart';
import '../../../design/widgets/skeleton.dart';
import '../state/model_fit.dart';
import 'format.dart';
import 'pills.dart';

/// One search result: decoded name, Hub popularity and an honest,
/// clearly-labelled fit estimate.
class ModelCard extends StatelessWidget {
  const ModelCard({super.key, required this.entry, required this.onTap, this.estimate});

  final CatalogEntry entry;
  final VoidCallback onTap;

  /// Null when the name carries no parameter count.
  final CardFitEstimate? estimate;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = entry.name;
    final downloads = entry.downloads;
    final likes = entry.likes;
    final est = estimate;
    final large = isLargeText(context);
    final spoken = [
      '${name.displayName} by ${name.owner}',
      for (final c in modelNameChipData(name)) '${c.kind} ${c.label}',
      if (downloads != null) '$downloads downloads in 30 days',
      if (entry.gating.isGated) 'Gated: needs accepted terms',
      if (est != null) '${_fitWord(est.verdict)}, about ${formatBytes(est.estimatedBytes)} at 4-bit, estimated',
    ].join('. ');

    final metrics = Wrap(
      spacing: t.space.md,
      runSpacing: t.space.xs,
      children: [
        if (downloads != null)
          Metric(
            icon: Icons.download_rounded,
            value: formatCount(downloads),
            explanation: 'Downloads in the last 30 days',
          ),
        if (likes != null)
          Metric(icon: Icons.favorite_border_rounded, value: formatCount(likes), explanation: 'Likes on Hugging Face'),
        if (entry.toolUseHint)
          const Metric(
            icon: Icons.build_outlined,
            value: 'Tools',
            explanation: 'Its chat template or tags mention tool calling. A hint from the repo, '
                'confirmed from the downloaded file itself.',
          ),
      ],
    );

    // One node for the whole card: the spoken summary replaces the chips'
    // abbreviations, so it must carry the tap itself.
    return Semantics(
      container: true,
      button: true,
      label: spoken,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.radius.lg)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(t.space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name.displayName,
                            style: theme.textTheme.titleMedium,
                            maxLines: scaledMaxLines(context),
                            overflow: TextOverflow.ellipsis,
                          ),
                          SizedBox(height: t.space.xxs),
                          Text(
                            entry.id,
                            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                            maxLines: scaledMaxLines(context),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    if (entry.gating.isGated)
                      Padding(
                        padding: EdgeInsetsDirectional.only(start: t.space.sm),
                        child: InfoPill(
                          label: 'Gated',
                          icon: Icons.lock_outline_rounded,
                          explanation: 'The author requires you to accept their terms on huggingface.co '
                              'and sign in before downloading.',
                        ),
                      ),
                  ],
                ),
                SizedBox(height: t.space.md),
                ModelNameChips(name: name, max: 5),
                SizedBox(height: t.space.md),
                // At large text sizes the estimate goes on its own line, so
                // the metrics keep the card's width.
                Flex(
                  direction: large ? Axis.vertical : Axis.horizontal,
                  crossAxisAlignment: large ? CrossAxisAlignment.start : CrossAxisAlignment.center,
                  children: [
                    if (large) metrics else Expanded(child: metrics),
                    if (est != null) ...[
                      SizedBox(width: t.space.sm, height: t.space.sm),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('≈${formatBytes(est.estimatedBytes)}',
                              style: theme.textTheme.metricSmall.copyWith(color: scheme.onSurfaceVariant)),
                          SizedBox(width: t.space.xs),
                          FitBadge(kind: FitBadgeKind.of(est.verdict), estimated: true, explanation: est.explanation),
                        ],
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _fitWord(FitVerdict v) => switch (v) {
        FitVerdict.fits => 'Likely fits',
        FitVerdict.tight => 'Might be tight',
        FitVerdict.wontFit => 'Likely too big',
      };
}

/// Placeholder card while results load (same footprint as [ModelCard]).
class ModelCardSkeleton extends StatelessWidget {
  const ModelCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(t.radius.lg),
      ),
      child: Padding(
        padding: EdgeInsets.all(t.space.lg),
        child: const _SkeletonLines(),
      ),
    );
  }
}

class _SkeletonLines extends StatelessWidget {
  const _SkeletonLines();

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Skeleton(width: 180, height: 16),
        SizedBox(height: t.space.sm),
        const Skeleton(width: 120, height: 12),
        SizedBox(height: t.space.md),
        Row(children: [
          const Skeleton(width: 60, height: 20, radius: 999),
          SizedBox(width: t.space.xs),
          const Skeleton(width: 44, height: 20, radius: 999),
          SizedBox(width: t.space.xs),
          const Skeleton(width: 64, height: 20, radius: 999),
        ]),
        SizedBox(height: t.space.md),
        const Skeleton(width: 140, height: 12),
      ],
    );
  }
}
