import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../../design/tokens.dart';
import '../state/format.dart';
import '../state/item_labels.dart';
import 'context_style.dart';
import 'summary_view.dart';
import 'untrusted.dart';

IconData itemIcon(ItemFacts f) {
  final m = f.message;
  if (f.summary != null) return Icons.summarize_outlined;
  return switch (m.kind) {
    MessageKind.handoff => Icons.move_down_rounded,
    MessageKind.notice => Icons.info_outline_rounded,
    MessageKind.plan => Icons.checklist_rounded,
    MessageKind.summary => Icons.summarize_outlined,
    MessageKind.normal => switch (m.role) {
        Role.user => Icons.person_outline_rounded,
        Role.assistant => Icons.auto_awesome_outlined,
        Role.tool => Icons.build_outlined,
        Role.system => Icons.settings_outlined,
      },
  };
}

IconData markerIcon(ItemMarker m) => switch (m) {
      ItemMarker.compacted => Icons.compress_rounded,
      ItemMarker.elided => Icons.content_cut_rounded,
      ItemMarker.truncated => Icons.short_text_rounded,
      ItemMarker.reasoningDropped => Icons.visibility_off_outlined,
      ItemMarker.added => Icons.add_circle_outline_rounded,
    };

/// A small outlined tag: icon + words, so markers never rely on color.
class ContextTag extends StatelessWidget {
  const ContextTag({super.key, required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.onSurfaceVariant;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: c.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(t.radius.sm),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: t.space.xs + 2, vertical: 1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: c),
            SizedBox(width: t.space.xs),
            Flexible(child: Text(label, style: theme.textTheme.labelSmall?.copyWith(color: c))),
          ],
        ),
      ),
    );
  }
}

/// Tags for an item: kind, pinned, and every marker.
List<Widget> itemTags(BuildContext context, ItemFacts f) {
  final warning = SherpaTokens.of(context).semantic.warning;
  return [
    if (f.kindLabel != null && f.summary == null) ContextTag(icon: Icons.label_outline_rounded, label: f.kindLabel!),
    if (f.message.pinned) const ContextTag(icon: Icons.push_pin_outlined, label: 'Pinned'),
    for (final m in f.markers)
      ContextTag(
        icon: markerIcon(m),
        label: ItemFacts.markerLabel(m),
        color: m == ItemMarker.compacted || m == ItemMarker.added ? null : warning,
      ),
  ];
}

/// One row of "What the model sees".
class ContextItemTile extends StatelessWidget {
  const ContextItemTile({super.key, required this.facts, required this.onTap});

  final ItemFacts facts;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final tags = itemTags(context, facts);
    return Semantics(
      container: true,
      button: true,
      label: facts.semanticLabel,
      hint: 'Show what is sent',
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: t.space.minTouchTarget),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: t.space.lg, vertical: t.space.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(top: t.space.xxs),
                  child: Icon(itemIcon(facts), size: 20, color: theme.colorScheme.onSurfaceVariant),
                ),
                SizedBox(width: t.space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              facts.title,
                              style: theme.textTheme.titleSmall,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          SizedBox(width: t.space.sm),
                          Text(
                            groupDigits(facts.item.tokens),
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                      if (facts.preview.isNotEmpty) ...[
                        SizedBox(height: t.space.xxs),
                        Text(
                          facts.preview,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (tags.isNotEmpty) ...[
                        SizedBox(height: t.space.xs),
                        Wrap(spacing: t.space.xs, runSpacing: t.space.xs, children: tags),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens a scrollable bottom sheet with [title] and [body] (detail views).
Future<void> showContextSheet(
  BuildContext context, {
  required String title,
  required Widget Function(BuildContext context) body,
  Widget? header,
  List<Widget> actions = const [],
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheet) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 1,
        builder: (context, scroll) {
          final t = SherpaTokens.of(context);
          return ListView(
            controller: scroll,
            padding: EdgeInsets.fromLTRB(t.space.xl, 0, t.space.xl, t.space.xl + MediaQuery.paddingOf(context).bottom),
            children: [
              Semantics(headingLevel: 2, child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
              if (header != null) ...[SizedBox(height: t.space.sm), header],
              if (actions.isNotEmpty) ...[
                SizedBox(height: t.space.sm),
                Wrap(spacing: t.space.sm, runSpacing: t.space.xs, children: actions),
              ],
              SizedBox(height: t.space.lg),
              body(context),
            ],
          );
        },
      ),
    );

/// The rendered content of one item, the way it is sent.
class MessageContentView extends StatelessWidget {
  const MessageContentView({super.key, required this.facts});

  final ItemFacts facts;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final m = facts.message;
    final summary = facts.summary;
    if (summary != null && m.metadata['ack'] != true) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SummaryView(summary: summary.summary),
          ExactText(text: m.text),
        ],
      );
    }
    if (m.kind == MessageKind.handoff) return UntrustedAwareText(m.text, mono: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final p in m.content)
          Padding(padding: EdgeInsets.only(bottom: t.space.md), child: _PartView(part: p)),
      ],
    );
  }
}

/// "Exact text sent to the model", collapsed by default.
class ExactText extends StatelessWidget {
  const ExactText({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Exact text sent to the model'),
          childrenPadding: EdgeInsets.only(bottom: SherpaTokens.of(context).space.md),
          children: [UntrustedAwareText(text)],
        ),
      );
}

class _PartView extends StatelessWidget {
  const _PartView({required this.part});

  final ContentPart part;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final p = part;
    switch (p) {
      case TextPart(:final text):
        return text.contains('<untrusted_data')
            ? UntrustedAwareText(text, mono: false)
            : SelectableText(text, style: theme.textTheme.bodyLarge);
      case ReasoningPart():
        final text = p.text.isEmpty ? '(encrypted reasoning, not readable)' : p.text;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Reasoning', style: theme.textTheme.labelMedium),
            SizedBox(height: t.space.xxs),
            SelectableText(text, style: theme.textTheme.bodyMedium?.copyWith(color: t.semantic.reasoning)),
          ],
        );
      case ToolCallPart(:final call):
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Calls ${call.name} (call ${call.id})', style: theme.textTheme.labelMedium),
            SizedBox(height: t.space.xxs),
            DecoratedBox(
              decoration: BoxDecoration(
                color: t.semantic.codeSurface,
                borderRadius: BorderRadius.circular(t.radius.sm),
              ),
              child: Padding(
                padding: EdgeInsets.all(t.space.sm),
                child: SelectableText(
                  const JsonEncoder.withIndent('  ').convert(call.arguments),
                  style: contextMonoStyle(context),
                ),
              ),
            ),
          ],
        );
      case ToolResultPart():
        final structured = p.structured;
        return UntrustedFrame(
          label: '${p.isError ? 'Error from' : 'Output of'} ${p.toolName} (call ${p.callId}): treated as data',
          child: SelectableText(
            [
              if (p.text.isNotEmpty) p.text,
              if (structured != null && structured.isNotEmpty) const JsonEncoder.withIndent('  ').convert(structured),
            ].join('\n'),
            style: contextMonoStyle(context),
          ),
        );
      default:
        return Text('[${p.type}]', style: theme.textTheme.bodySmall);
    }
  }
}
