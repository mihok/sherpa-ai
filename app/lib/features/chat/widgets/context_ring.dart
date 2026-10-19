import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets/a11y.dart';
import '../state/model_selection.dart';
import 'chat_style.dart';

/// Color and words for a [ContextLevel]. Status colors always travel with
/// a label (never color alone).
(Color, String) contextLevelStyle(BuildContext context, ContextLevel? level) {
  final tokens = SherpaTokens.of(context);
  final scheme = Theme.of(context).colorScheme;
  return switch (level) {
    null => (scheme.outline, 'Not measured yet'),
    ContextLevel.healthy => (scheme.primary, 'Plenty of room'),
    ContextLevel.pruning => (scheme.primary, 'Filling up'),
    ContextLevel.compacting => (tokens.semantic.warning, 'Getting full'),
    ContextLevel.handoff => (tokens.semantic.warning, 'Nearly full'),
    ContextLevel.overflow => (tokens.semantic.danger, 'Full'),
  };
}

/// Compact context meter for the app bar: a ring showing how much of the
/// model's window the next request uses. Sherpa doesn't hide the budget
/// (docs/research/12 §2 "avoid"): compaction should never surprise anyone.
class ContextRing extends StatelessWidget {
  const ContextRing({super.key, required this.budget, required this.level, required this.onTap, this.estimate = false});

  final ContextBudget? budget;
  final ContextLevel? level;
  final bool estimate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final b = budget;
    final ratio = b == null || b.ratio.isNaN ? 0.0 : b.ratio.clamp(0.0, 1.0);
    final (color, words) = contextLevelStyle(context, level);
    final percent = b == null ? null : (math.min(b.ratio, 9.99) * 100).round();
    final label = b == null
        ? 'Context usage not measured yet'
        : 'Context ${estimate ? 'about ' : ''}$percent% used of ${formatTokenCount(b.usableInput)} tokens, $words';
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      button: true,
      label: label,
      hint: 'Show details',
      onTap: onTap,
      excludeSemantics: true,
      child: Tooltip(
        message: b == null ? 'Context' : 'Context: $percent% used',
        child: InkWell(
          onTap: onTap,
          customBorder: const StadiumBorder(),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: tokens.space.minTouchTarget,
              minWidth: tokens.space.minTouchTarget,
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: tokens.space.sm),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox.square(
                    dimension: tokens.space.lg + tokens.space.xxs,
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(end: ratio),
                      duration: chatMotionOf(context).medium,
                      builder: (context, value, _) => CustomPaint(
                        painter: _RingPainter(
                          value: value,
                          color: color,
                          track: color.withValues(alpha: 0.18),
                          stroke: tokens.space.xs - 1,
                        ),
                      ),
                    ),
                  ),
                  // A number next to the ring: a nearly empty ring alone
                  // reads like a loading spinner.
                  if (percent != null) ...[
                    SizedBox(width: tokens.space.xs),
                    MediaQuery.withClampedTextScaling(
                      maxScaleFactor: kChromeMaxTextScale,
                      child: Text(
                        '$percent%',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.value, required this.color, required this.track, required this.stroke});

  final double value;
  final Color color;
  final Color track;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset(stroke / 2, stroke / 2) & Size(size.width - stroke, size.height - stroke);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, math.pi * 2, false, paint..color = track);
    if (value > 0) {
      canvas.drawArc(rect, -math.pi / 2, value * math.pi * 2, false, paint..color = color);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value || old.color != color || old.track != track || old.stroke != stroke;
}

/// Small sheet with the budget breakdown, the last context change (why it
/// happened, in the ladder's own words) and the way into the full inspector.
class ContextBudgetSheet extends StatelessWidget {
  const ContextBudgetSheet({
    super.key,
    required this.budget,
    required this.level,
    this.estimate = false,
    this.modelName,
    this.lastChange,
    this.onInspect,
  });

  final ContextBudget? budget;
  final ContextLevel? level;
  final bool estimate;
  final String? modelName;

  /// The newest overlay (elision, truncation or summary), if any.
  final Future<ContextOverlay?>? lastChange;

  /// Opens the context inspector; the sheet closes first.
  final VoidCallback? onInspect;

  static Future<void> show(
    BuildContext context, {
    required ContextBudget? budget,
    required ContextLevel? level,
    bool estimate = false,
    String? modelName,
    Future<ContextOverlay?>? lastChange,
    VoidCallback? onInspect,
  }) =>
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        useSafeArea: true,
        isScrollControlled: true,
        sheetAnimationStyle: motionStyleOf(context),
        builder: (sheet) => ContextBudgetSheet(
          budget: budget,
          level: level,
          estimate: estimate,
          modelName: modelName,
          lastChange: lastChange,
          onInspect: onInspect == null
              ? null
              : () {
                  Navigator.of(sheet).pop();
                  onInspect();
                },
        ),
      );

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final b = budget;
    final (color, words) = contextLevelStyle(context, level);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(tokens.space.xl, 0, tokens.space.xl, tokens.space.xl),
      child: HeadingGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Heading(child: Text('Context window', style: theme.textTheme.titleLarge)),
            SizedBox(height: tokens.space.xs),
            Text(
              b == null
                  ? 'Sherpa measures how much of the model\'s memory this chat uses before each reply. '
                      'Send a message to see it.'
                  : 'How much of ${modelName ?? 'the model'}\'s context the next request uses'
                      '${estimate || !b.exact ? ' (estimated)' : ''}.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (b != null) ...[
              SizedBox(height: tokens.space.lg),
              Row(
                children: [
                  Icon(
                    level == ContextLevel.overflow ? Icons.error_outline_rounded : Icons.data_usage_rounded,
                    color: color,
                  ),
                  SizedBox(width: tokens.space.sm),
                  Expanded(
                    child: Text(
                      '${(math.min(b.ratio, 9.99) * 100).round()}% used · $words',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              SizedBox(height: tokens.space.md),
              _BudgetBar(budget: b),
              SizedBox(height: tokens.space.lg),
              _row(context, 'System prompt', b.systemTokens, swatch: 0),
              _row(context, 'Tool definitions', b.toolTokens, swatch: 1),
              if (b.pinnedTokens > 0) _row(context, 'Pinned', b.pinnedTokens, swatch: 2),
              _row(context, 'Conversation', b.historyTokens, swatch: 3),
              const Divider(),
              _row(context, 'Reserved for the reply', b.outputReserve),
              if (b.safetyMargin > 0) _row(context, 'Safety margin (estimate)', b.safetyMargin),
              _row(context, 'Free', math.max(0, b.remaining)),
              _row(context, 'Window', b.limit, bold: true),
            ],
            if (lastChange != null) _LastChange(change: lastChange!),
            if (onInspect != null) ...[
              SizedBox(height: tokens.space.lg),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: onInspect,
                  icon: const Icon(Icons.manage_search_rounded),
                  label: const Text('See what the model sees'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, String label, int tokens, {int? swatch, bool bold = false}) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final style = bold ? theme.textTheme.titleSmall : theme.textTheme.bodyMedium;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: t.space.xs),
      child: Row(
        children: [
          SizedBox.square(
            dimension: t.space.md,
            child: swatch == null
                ? null
                : DecoratedBox(
                    decoration: BoxDecoration(
                      color: _BudgetBar.segmentColor(context, swatch),
                      borderRadius: BorderRadius.circular(t.space.xxs),
                    ),
                  ),
          ),
          SizedBox(width: t.space.sm),
          Expanded(child: Text(label, style: style)),
          Text(
            '${formatTokenCount(tokens)} tokens',
            style: style?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ],
      ),
    );
  }
}

/// One horizontal meter, a single-hue ramp with surface gaps between
/// segments (dataviz guidance: magnitude parts share one hue; the table
/// beneath carries the numbers).
class _BudgetBar extends StatelessWidget {
  const _BudgetBar({required this.budget});

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
                decoration: BoxDecoration(color: segmentColor(context, i), borderRadius: BorderRadius.circular(t.space.xxs)),
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

/// "Last change": the newest overlay's own reason line ("Context was 83%
/// full (compaction starts at 80%): summarized 14 earlier messages…"), so
/// a shorter context is never a mystery (docs/research/11 §9).
class _LastChange extends StatelessWidget {
  const _LastChange({required this.change});

  final Future<ContextOverlay?> change;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return FutureBuilder<ContextOverlay?>(
      future: change,
      builder: (context, snap) {
        final o = snap.data;
        if (o == null) return const SizedBox.shrink();
        final what = switch (o) {
          CompactedRange() => 'Earlier messages were summarized',
          ToolOutputElided() => 'An old tool result was shortened',
          PayloadTruncated() => 'A large payload was trimmed',
        };
        return Padding(
          padding: EdgeInsets.only(top: t.space.lg),
          child: Semantics(
            container: true,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(t.radius.md),
              ),
              child: Padding(
                padding: EdgeInsets.all(t.space.md),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.history_rounded, color: theme.colorScheme.onSurfaceVariant),
                    SizedBox(width: t.space.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Last change: $what', style: theme.textTheme.titleSmall),
                          SizedBox(height: t.space.xxs),
                          Text(
                            o.reason,
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
