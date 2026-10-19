import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../../design/tokens.dart';
import '../../chat/widgets/context_ring.dart' show contextLevelStyle;
import '../state/format.dart';

/// The inspector's header: how full the window is, against the ladder's
/// thresholds, and what the tokens are spent on.
///
/// Why both bars: the level bar answers "what will Sherpa do next" (prune at
/// 60%, summarize at 80%, suggest a handoff at 92% for this window), the
/// composition table answers "where did the room go".
class BudgetOverview extends StatelessWidget {
  const BudgetOverview({
    super.key,
    required this.budget,
    required this.level,
    required this.thresholds,
    this.modelName,
  });

  final ContextBudget budget;
  final ContextLevel level;
  final ContextThresholds thresholds;
  final String? modelName;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final b = budget;
    final (color, words) = contextLevelStyle(context, level);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: t.space.sm,
          runSpacing: t.space.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '${formatPercent(math.min(b.ratio, 9.99))} used',
              style: theme.textTheme.headlineSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
            _Pill(icon: level == ContextLevel.overflow ? Icons.error_outline_rounded : Icons.data_usage_rounded,
                text: words, color: color),
            _Pill(
              icon: b.exact ? Icons.check_circle_outline_rounded : Icons.straighten_rounded,
              text: b.exact ? 'Exact count' : 'Estimated',
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
        SizedBox(height: t.space.xs),
        Text(
          '${groupDigits(b.inputTokens)} of ${groupDigits(b.usableInput)} input tokens'
          '${modelName == null ? '' : ' for $modelName'}'
          ' (window ${groupDigits(b.limit)}).',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        SizedBox(height: t.space.lg),
        LevelBar(ratio: b.ratio, level: level, thresholds: thresholds),
        SizedBox(height: t.space.sm),
        _Legend(thresholds: thresholds),
        SizedBox(height: t.space.lg),
        _CompositionBar(budget: b),
        SizedBox(height: t.space.sm),
        _row(context, 'System prompt', b.systemTokens, swatch: 0),
        _row(context, 'Tool definitions', b.toolTokens, swatch: 1),
        _row(context, 'Pinned (summaries, handoff, plan)', b.pinnedTokens, swatch: 2),
        _row(context, 'Conversation', b.historyTokens, swatch: 3),
        const Divider(),
        _row(context, 'Reserved for the reply', b.outputReserve),
        _row(context, b.exact ? 'Safety margin' : 'Safety margin (estimates can be off)', b.safetyMargin),
        _row(context, 'Free', math.max(0, b.remaining)),
        _row(context, 'Window', b.limit, bold: true),
        if (!b.exact) ...[
          SizedBox(height: t.space.sm),
          Text(
            'Counts are estimated from text length. The safety margin keeps an estimate that runs low from '
            'overflowing the window; it shrinks once real usage has calibrated the estimate.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  Widget _row(BuildContext context, String label, int tokens, {int? swatch, bool bold = false}) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final style = bold ? theme.textTheme.titleSmall : theme.textTheme.bodyMedium;
    return Semantics(
      container: true,
      label: '$label: ${groupDigits(tokens)} tokens',
      excludeSemantics: true,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: t.space.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.only(top: t.space.xxs),
              child: SizedBox.square(
                dimension: t.space.md,
                child: swatch == null
                    ? null
                    : DecoratedBox(
                        decoration: BoxDecoration(
                          color: _CompositionBar.segmentColor(context, swatch),
                          borderRadius: BorderRadius.circular(t.space.xxs),
                        ),
                      ),
              ),
            ),
            SizedBox(width: t.space.sm),
            Expanded(child: Text(label, style: style)),
            SizedBox(width: t.space.sm),
            Text(
              groupDigits(tokens),
              style: style?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(t.radius.pill),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: t.space.sm, vertical: t.space.xxs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            SizedBox(width: t.space.xs),
            Flexible(
              child: Text(
                text,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The ladder at a glance: zones between the prune, compact and handoff
/// thresholds, filled to the current ratio.
class LevelBar extends StatelessWidget {
  const LevelBar({super.key, required this.ratio, required this.level, required this.thresholds});

  final double ratio;
  final ContextLevel level;
  final ContextThresholds thresholds;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (color, words) = contextLevelStyle(context, level);
    final th = thresholds;
    return Semantics(
      label: 'Context level: $words, ${formatPercent(ratio)} used. Old tool results are shortened from '
          '${formatPercent(th.prune)}, earlier messages are summarized from ${formatPercent(th.compact)}, and a '
          'handoff is suggested from ${formatPercent(th.handoff)}.',
      excludeSemantics: true,
      child: SizedBox(
        height: t.space.lg,
        child: CustomPaint(
          painter: _LevelPainter(
            ratio: ratio.isFinite ? ratio : 1.0,
            thresholds: th,
            fill: color,
            zones: [
              scheme.surfaceContainerHighest,
              scheme.primary.withValues(alpha: 0.12),
              SherpaTokens.of(context).semantic.warning.withValues(alpha: 0.16),
              SherpaTokens.of(context).semantic.danger.withValues(alpha: 0.18),
            ],
            tick: scheme.onSurfaceVariant,
            radius: t.space.xs,
            textDirection: Directionality.of(context),
          ),
        ),
      ),
    );
  }
}

class _LevelPainter extends CustomPainter {
  _LevelPainter({
    required this.ratio,
    required this.thresholds,
    required this.fill,
    required this.zones,
    required this.tick,
    required this.radius,
    required this.textDirection,
  });

  final double ratio;
  final ContextThresholds thresholds;
  final Color fill;
  final List<Color> zones;
  final Color tick;
  final double radius;

  /// The bar fills from the reading start: right to left in RTL.
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    if (textDirection == TextDirection.rtl) {
      canvas
        ..save()
        ..translate(size.width, 0)
        ..scale(-1, 1);
    }
    final w = size.width;
    final barTop = size.height * 0.25;
    final barH = size.height * 0.5;
    final rrect = RRect.fromRectAndRadius(Rect.fromLTWH(0, barTop, w, barH), Radius.circular(radius));
    canvas.save();
    canvas.clipRRect(rrect);
    final stops = [0.0, thresholds.prune, thresholds.compact, thresholds.handoff, 1.0];
    for (var i = 0; i < 4; i++) {
      canvas.drawRect(
        Rect.fromLTRB(stops[i] * w, barTop, stops[i + 1] * w, barTop + barH),
        Paint()..color = zones[i],
      );
    }
    final fillW = (ratio.clamp(0.0, 1.0)) * w;
    canvas.drawRect(Rect.fromLTWH(0, barTop + barH * 0.25, fillW, barH * 0.5), Paint()..color = fill);
    canvas.restore();
    final p = Paint()
      ..color = tick
      ..strokeWidth = 1.5;
    for (final s in stops.sublist(1, 4)) {
      canvas.drawLine(Offset(s * w, 0), Offset(s * w, size.height), p);
    }
    if (textDirection == TextDirection.rtl) canvas.restore();
  }

  @override
  bool shouldRepaint(_LevelPainter old) =>
      old.ratio != ratio ||
      old.thresholds != thresholds ||
      old.fill != fill ||
      old.tick != tick ||
      old.textDirection != textDirection;
}

class _Legend extends StatelessWidget {
  const _Legend({required this.thresholds});

  final ContextThresholds thresholds;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    Widget line(double at, String what) => Padding(
          padding: EdgeInsets.only(bottom: t.space.xxs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: t.space.xxxl,
                child: Text(
                  formatPercent(at),
                  style: style?.copyWith(fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
              Expanded(child: Text(what, style: style)),
            ],
          ),
        );
    return ExcludeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          line(thresholds.prune, 'Old, large tool results are shortened'),
          line(thresholds.compact, 'Earlier messages are summarized'),
          line(thresholds.handoff, 'Sherpa suggests continuing in a new chat'),
        ],
      ),
    );
  }
}

/// Where the input tokens go: one hue, segments separated by gaps.
class _CompositionBar extends StatelessWidget {
  const _CompositionBar({required this.budget});

  final ContextBudget budget;

  static Color segmentColor(BuildContext context, int i) {
    final primary = Theme.of(context).colorScheme.primary;
    const alphas = [1.0, 0.72, 0.5, 0.86];
    return primary.withValues(alpha: alphas[i % alphas.length]);
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final total = math.max(1, budget.usableInput);
    final parts = [budget.systemTokens, budget.toolTokens, budget.pinnedTokens, budget.historyTokens];
    return ExcludeSemantics(
      child: SizedBox(
        height: t.space.md,
        child: LayoutBuilder(
          builder: (context, c) {
            final children = <Widget>[];
            var used = 0.0;
            for (final (i, p) in parts.indexed) {
              if (p <= 0) continue;
              final w = math.min(c.maxWidth - used - t.space.xxs, c.maxWidth * p / total);
              if (w <= 0) break;
              children.add(Container(
                width: w,
                margin: EdgeInsetsDirectional.only(end: t.space.xxs),
                decoration: BoxDecoration(
                  color: segmentColor(context, i),
                  borderRadius: BorderRadius.circular(t.space.xxs),
                ),
              ));
              used += w + t.space.xxs;
            }
            return DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(t.space.xxs),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(t.space.xxs),
                child: Row(children: children),
              ),
            );
          },
        ),
      ),
    );
  }
}
