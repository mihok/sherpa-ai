import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../../design/tokens.dart';
import 'untrusted.dart';

/// A compaction summary (schema v2) laid out for reading.
///
/// The model receives `CompactionSummary.render()`; this shows the same
/// fields structurally so the user can check them: every list item keeps
/// its origin, and anything from tool output (`[tool:*]` items, files,
/// state handles) sits in an [UntrustedFrame], because a summary must not
/// launder injected text into something that looks like the user's words.
class SummaryView extends StatelessWidget {
  const SummaryView({super.key, required this.summary});

  final CompactionSummary summary;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final s = summary;
    final children = <Widget>[
      _field(context, 'Goal', s.goal),
      if (s.task != null && s.task!.trim() != s.goal.trim()) _field(context, 'Task', s.task),
      _list(context, 'Constraints (still apply)', s.constraints),
      _list(context, 'Your preferences', s.userPreferences),
      _list(context, 'Decisions', s.decisions),
      _list(context, 'Done', s.completed),
      _list(context, 'Open tasks', s.openTasks),
      _field(context, 'Current work', s.currentWork),
      _field(context, 'Next step', s.nextStep),
      if (s.nextStepQuote != null && s.nextStepQuote!.trim().isNotEmpty)
        _field(context, 'It serves your request', '“${s.nextStepQuote!.trim()}”'),
      _list(context, 'Key facts', s.keyFacts),
      _list(context, 'Failed approaches', s.failedApproaches),
      _field(context, 'Notes', s.notes),
      if (s.plan != null && !s.plan!.isEmpty) _plan(context, s.plan!),
      if (s.sideEffectLedger.isNotEmpty) _ledger(context, s.sideEffectLedger),
      if (s.artifacts.isNotEmpty || s.stateHandles.isNotEmpty)
        _section(
          context,
          'Files, links and handles',
          UntrustedFrame(
            label: 'Collected from tool output: untrusted',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final a in s.artifacts) _bullet(context, a),
                for (final h in s.stateHandles) _bullet(context, '${h.key} = ${h.value}${h.tool == null ? '' : ' (${h.tool})'}'),
              ],
            ),
          ),
        ),
      if (s.userMessages.isNotEmpty)
        _section(
          context,
          'Your earlier messages, word for word',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final m in s.userMessages)
                Padding(
                  padding: EdgeInsets.only(bottom: t.space.sm),
                  child: _Quote(text: m.trim()),
                ),
            ],
          ),
        ),
      if (s.taint.isNotEmpty)
        _section(
          context,
          'Untrusted sources in these turns',
          Text(
            s.taint.map((x) => x.source).join(', '),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  Widget _section(BuildContext context, String title, Widget body) {
    final t = SherpaTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: t.space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            headingLevel: 3,
            child: Text(title, style: Theme.of(context).textTheme.titleSmall),
          ),
          SizedBox(height: t.space.xs),
          body,
        ],
      ),
    );
  }

  Widget _field(BuildContext context, String title, String? value) {
    if (value == null || value.trim().isEmpty) return const SizedBox.shrink();
    return _section(context, title, SelectableText(value.trim(), style: Theme.of(context).textTheme.bodyMedium));
  }

  Widget _list(BuildContext context, String title, List<String> items) {
    if (items.isEmpty) return const SizedBox.shrink();
    final t = SherpaTokens.of(context);
    return _section(
      context,
      title,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final raw in items)
            Padding(
              padding: EdgeInsets.only(bottom: t.space.sm),
              child: _TaggedItemView(item: parseTagged(raw)),
            ),
        ],
      ),
    );
  }

  Widget _bullet(BuildContext context, String text) {
    final t = SherpaTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: t.space.xxs),
      child: SelectableText('• $text', style: Theme.of(context).textTheme.bodySmall),
    );
  }

  Widget _plan(BuildContext context, Plan plan) => _section(
        context,
        'Plan',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final i in plan.items)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    i.status == PlanStatus.done ? Icons.check_box_outlined : Icons.check_box_outline_blank_rounded,
                    size: 18,
                    semanticLabel: i.status.name,
                  ),
                  SizedBox(width: SherpaTokens.of(context).space.xs),
                  Expanded(child: Text(i.title, style: Theme.of(context).textTheme.bodyMedium)),
                ],
              ),
          ],
        ),
      );

  Widget _ledger(BuildContext context, List<SideEffectRecord> ledger) => _section(
        context,
        'Actions already performed (the model is told not to repeat them)',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final e in ledger)
              _bullet(
                context,
                '${e.tool}${e.server == null ? '' : ' on ${e.server}'}: '
                '${e.outcome == SideEffectOutcome.ok ? 'done' : 'failed'}'
                '${e.argsPreview == null ? '' : ' · ${e.argsPreview}'}',
              ),
          ],
        ),
      );
}

class _TaggedItemView extends StatelessWidget {
  const _TaggedItemView({required this.item});

  final TaggedItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = SherpaTokens.of(context);
    final body = SelectableText(item.text, style: theme.textTheme.bodyMedium);
    if (item.origin == ItemOrigin.tool) {
      return UntrustedFrame(label: 'Untrusted · from the ${item.tool ?? 'unknown'} tool', child: body);
    }
    return Padding(
      padding: EdgeInsets.only(left: t.space.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OriginLabel(origin: item.origin, tool: item.tool),
          SizedBox(height: t.space.xxs),
          body,
        ],
      ),
    );
  }
}

class _Quote extends StatelessWidget {
  const _Quote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: theme.colorScheme.outlineVariant, width: t.space.xs - 1)),
      ),
      child: Padding(
        padding: EdgeInsets.only(left: t.space.md),
        child: SelectableText(text, style: theme.textTheme.bodyMedium),
      ),
    );
  }
}
