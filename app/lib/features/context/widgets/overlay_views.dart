import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../../design/semantic_palette.dart';
import '../../../design/tokens.dart';
import '../../home/relative_time.dart';
import '../state/context_actions.dart';
import '../state/format.dart';
import 'context_style.dart';
import 'item_views.dart';
import 'summary_view.dart';
import 'untrusted.dart';

/// Short title for an overlay ("Summarized 14 messages").
String overlayTitle(ContextDiff d, ContextOverlay? o) => switch (d.kind) {
      ContextDiffKind.compaction => 'Summarized ${plural(d.messageIds.length, 'earlier message')}',
      ContextDiffKind.elision => 'Shortened ${o is ToolOutputElided ? _toolOf(o, d) : 'a'} tool result',
      ContextDiffKind.truncation => 'Trimmed a large ${d.before?.trimLeft().startsWith('{') ?? false ? 'tool input' : 'payload'}',
    };

String _toolOf(ToolOutputElided o, ContextDiff d) {
  final m = RegExp(r'tool result elided: ([^,\]]+)').firstMatch(o.stub);
  return m == null ? 'a' : 'a ${m[1]}';
}

/// Tokens the change keeps out of each request.
///
/// A summary uses what it saved when it was made: that was measured against
/// the view of the time (old tool results already shortened), which is also
/// what undoing it brings back, since those shortenings apply again. The raw
/// transcript size would overstate it. Part edits in effect are measured now.
int savedTokens(ContextDiff d) => d.kind != ContextDiffKind.compaction && d.status == OverlayStatus.active
    ? d.tokensSaved
    : d.recordedTokensSaved;

IconData overlayIcon(ContextDiffKind k) => switch (k) {
      ContextDiffKind.compaction => Icons.compress_rounded,
      ContextDiffKind.elision => Icons.content_cut_rounded,
      ContextDiffKind.truncation => Icons.short_text_rounded,
    };

(String, IconData) overlayStatus(OverlayStatus s) => switch (s) {
      OverlayStatus.active => ('In effect', Icons.check_circle_outline_rounded),
      OverlayStatus.shadowed => ('Inside a later summary', Icons.layers_outlined),
      OverlayStatus.inactive => ('Not on this branch', Icons.call_split_rounded),
    };

/// One recorded context change: what, why, when, how much it saved, and
/// the two things the user can do about it (look at the diff, undo).
class OverlayCard extends StatelessWidget {
  const OverlayCard({
    super.key,
    required this.diff,
    required this.overlay,
    required this.now,
    required this.onShowDiff,
    required this.onUndo,
    this.undoDisabledReason,
  });

  final ContextDiff diff;
  final ContextOverlay? overlay;
  final DateTime now;
  final VoidCallback onShowDiff;

  /// Null while undo is unavailable ([undoDisabledReason] says why).
  final VoidCallback? onUndo;
  final String? undoDisabledReason;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final (statusText, statusIcon) = overlayStatus(diff.status);
    final saved = savedTokens(diff);
    final title = overlayTitle(diff, overlay);
    return Card(
      margin: EdgeInsets.symmetric(horizontal: t.space.lg, vertical: t.space.xs),
      child: Padding(
        padding: EdgeInsets.fromLTRB(t.space.lg, t.space.md, t.space.sm, t.space.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              container: true,
              label: '$title. $statusText. ${formatRelativeSpoken(diff.createdAt, now)}. '
                  'Saves ${groupDigits(saved)} tokens. ${diff.reason}',
              excludeSemantics: true,
              child: Padding(
                padding: EdgeInsets.only(right: t.space.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(overlayIcon(diff.kind), color: theme.colorScheme.primary),
                        SizedBox(width: t.space.sm),
                        Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
                        SizedBox(width: t.space.sm),
                        Text(
                          formatRelativeShort(diff.createdAt, now),
                          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                    SizedBox(height: t.space.xs),
                    Wrap(
                      spacing: t.space.xs,
                      runSpacing: t.space.xs,
                      children: [
                        ContextTag(icon: statusIcon, label: statusText),
                        ContextTag(icon: Icons.savings_outlined, label: 'Saves ${groupDigits(saved)} tokens'),
                      ],
                    ),
                    SizedBox(height: t.space.sm),
                    Text(diff.reason, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
            Wrap(
              alignment: WrapAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: onShowDiff,
                  icon: const Icon(Icons.compare_arrows_rounded),
                  label: const Text('Before / after'),
                ),
                Tooltip(
                  message: onUndo == null ? (undoDisabledReason ?? '') : 'Put the original back',
                  child: TextButton.icon(
                    onPressed: onUndo,
                    icon: const Icon(Icons.undo_rounded),
                    label: const Text('Undo'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

enum _Side { before, after }

/// Before/after for one overlay. For a summary, "before" is the messages it
/// stands in for (still in the transcript), "after" what the model gets.
class OverlayDiffView extends StatefulWidget {
  const OverlayDiffView({super.key, required this.diff, required this.snapshot});

  final ContextDiff diff;
  final ContextSnapshot snapshot;

  @override
  State<OverlayDiffView> createState() => _OverlayDiffViewState();
}

class _OverlayDiffViewState extends State<OverlayDiffView> {
  _Side _side = _Side.after;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final d = widget.diff;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          d.kind == ContextDiffKind.compaction
              ? 'The original messages: ${groupDigits(d.tokensBefore)} tokens · the summary: '
                  '${groupDigits(d.tokensAfter)} tokens'
              : 'The original: ${groupDigits(d.tokensBefore)} tokens · now: ${groupDigits(d.tokensAfter)} tokens',
          style: theme.textTheme.bodyMedium,
        ),
        SizedBox(height: t.space.md),
        SegmentedButton<_Side>(
          segments: const [
            ButtonSegment(value: _Side.before, label: Text('Before'), icon: Icon(Icons.history_rounded)),
            ButtonSegment(value: _Side.after, label: Text('After'), icon: Icon(Icons.visibility_outlined)),
          ],
          selected: {_side},
          onSelectionChanged: (s) => setState(() => _side = s.first),
        ),
        SizedBox(height: t.space.md),
        Text(
          _side == _Side.before
              ? (d.kind == ContextDiffKind.compaction
                  ? 'These messages are no longer sent. They stay in your transcript.'
                  : 'The original, still in your transcript.')
              : 'What the model receives instead.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        SizedBox(height: t.space.sm),
        if (_side == _Side.before) _before(context) else _after(context),
      ],
    );
  }

  Widget _before(BuildContext context) {
    final d = widget.diff;
    final t = SherpaTokens.of(context);
    if (d.kind != ContextDiffKind.compaction) {
      final text = d.before;
      if (text == null) return const Text('The original is not on this branch.');
      return _Mono(text: text);
    }
    final messages = [
      for (final id in d.messageIds)
        ?widget.snapshot.message(id),
    ];
    if (messages.isEmpty) return const Text('The summarized messages are not on this branch.');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final m in messages)
          Padding(
            padding: EdgeInsets.only(bottom: t.space.sm),
            child: _DroppedMessage(message: m),
          ),
      ],
    );
  }

  Widget _after(BuildContext context) {
    final d = widget.diff;
    final o = widget.snapshot.overlay(d.overlayId);
    if (o is CompactedRange) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [SummaryView(summary: o.summary), ExactText(text: d.after)],
      );
    }
    return _Mono(text: d.after);
  }
}

class _Mono extends StatefulWidget {
  const _Mono({required this.text});

  final String text;

  @override
  State<_Mono> createState() => _MonoState();
}

class _MonoState extends State<_Mono> {
  static const int _clip = 4000;
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final long = widget.text.length > _clip;
    final shown = long && !_all ? '${widget.text.substring(0, _clip)}…' : widget.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(color: t.semantic.codeSurface, borderRadius: BorderRadius.circular(t.radius.sm)),
          child: Padding(
            padding: EdgeInsets.all(t.space.md),
            child: SelectableText(shown, style: contextMonoStyle(context)),
          ),
        ),
        if (long)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: () => setState(() => _all = !_all),
              child: Text(_all ? 'Show less' : 'Show all ${groupDigits(widget.text.length)} characters'),
            ),
          ),
      ],
    );
  }
}

class _DroppedMessage extends StatelessWidget {
  const _DroppedMessage({required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final m = message;
    final who = switch (m.role) {
      Role.user => 'You',
      Role.assistant => 'Assistant',
      Role.tool => 'Tool result',
      Role.system => 'System',
    };
    final text = [
      if (m.text.trim().isNotEmpty) m.text.trim(),
      for (final c in m.toolCalls) 'Calls ${c.name}',
      for (final r in m.toolResults) '${r.toolName}: ${previewLine(r.text, max: 400)}',
    ].join('\n');
    final body = Text(
      text.isEmpty ? '(no text)' : text,
      maxLines: 8,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(t.radius.sm),
      ),
      child: Padding(
        padding: EdgeInsets.all(t.space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(who, style: theme.textTheme.labelMedium),
            SizedBox(height: t.space.xxs),
            if (m.role == Role.tool) UntrustedFrame(label: 'Tool output: treated as data', child: body) else body,
          ],
        ),
      ),
    );
  }
}

/// The ladder's advice when the next request should not go ahead as is
/// (R11 §9.3 stages 5–6), with the three ways out.
class RecommendationBanner extends StatelessWidget {
  const RecommendationBanner({
    super.key,
    required this.recommendation,
    required this.onHandOff,
    required this.onSwitchModel,
    this.onCompact,
  });

  final ContextRecommendation recommendation;
  final VoidCallback onHandOff;
  final VoidCallback onSwitchModel;

  /// Null when compaction is not possible right now.
  final VoidCallback? onCompact;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final stop = recommendation.kind == ContextRecommendationKind.hardStop;
    final color = stop ? t.semantic.danger : t.semantic.warning;
    return Padding(
      padding: EdgeInsets.fromLTRB(t.space.lg, t.space.md, t.space.lg, 0),
      child: Semantics(
        container: true,
        liveRegion: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color.withValues(alpha: kSemanticTintAlpha),
            borderRadius: BorderRadius.circular(t.radius.md),
            border: Border.all(color: color.withValues(alpha: 0.5)),
          ),
          child: Padding(
            padding: EdgeInsets.all(t.space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(stop ? Icons.block_rounded : Icons.lightbulb_outline_rounded, color: color),
                    SizedBox(width: t.space.sm),
                    Expanded(
                      child: Semantics(
                        headingLevel: 2,
                        child: Text(
                          stop ? 'This chat no longer fits' : 'Consider continuing in a new chat',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: t.space.sm),
                Text(recommendation.message, style: theme.textTheme.bodyMedium),
                SizedBox(height: t.space.md),
                Wrap(
                  spacing: t.space.sm,
                  runSpacing: t.space.sm,
                  children: [
                    FilledButton.icon(
                      onPressed: onHandOff,
                      icon: const Icon(Icons.move_up_rounded),
                      label: const Text('Hand off…'),
                    ),
                    OutlinedButton.icon(
                      onPressed: onCompact,
                      icon: const Icon(Icons.compress_rounded),
                      label: const Text('Compact'),
                    ),
                    TextButton.icon(
                      onPressed: onSwitchModel,
                      icon: const Icon(Icons.swap_horiz_rounded),
                      label: const Text('Switch model'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
