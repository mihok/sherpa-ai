import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../../design/semantic_palette.dart';
import '../../../design/tokens.dart';
import 'context_style.dart';

/// Where a summary item came from, from its provenance tag (R11 §9.1:
/// `[user]`, `[model]`, `[tool:<name>]`).
enum ItemOrigin { user, model, tool, unknown }

/// A summary list item split into its origin and its text.
typedef TaggedItem = ({ItemOrigin origin, String? tool, String text});

final RegExp _tag = RegExp(r'^\s*\[(user|model|tool:([^\]]*))\]\s*', caseSensitive: false);

TaggedItem parseTagged(String item) {
  final m = _tag.firstMatch(item);
  if (m == null) return (origin: ItemOrigin.unknown, tool: null, text: item.trim());
  final tag = m[1]!.toLowerCase();
  final origin = tag == 'user' ? ItemOrigin.user : (tag == 'model' ? ItemOrigin.model : ItemOrigin.tool);
  return (origin: origin, tool: m[2]?.trim(), text: item.substring(m.end).trim());
}

/// A small label: icon + text, never color alone.
class OriginLabel extends StatelessWidget {
  const OriginLabel({super.key, required this.origin, this.tool});

  final ItemOrigin origin;
  final String? tool;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final untrusted = origin == ItemOrigin.tool;
    final color = untrusted ? t.semantic.warning : theme.colorScheme.onSurfaceVariant;
    final (icon, text) = switch (origin) {
      ItemOrigin.user => (Icons.person_outline_rounded, 'From you'),
      ItemOrigin.model => (Icons.auto_awesome_outlined, 'From the model'),
      ItemOrigin.tool => (Icons.gpp_maybe_outlined, 'Untrusted · tool ${tool ?? ''}'.trim()),
      ItemOrigin.unknown => (Icons.notes_rounded, 'Untagged'),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        SizedBox(width: t.space.xs),
        Flexible(
          child: Text(
            text,
            style: theme.textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

/// A frame for content that came from tools, web pages or another device:
/// tinted, outlined, and labelled, so it never reads like Sherpa's own or
/// the user's words (R11 §9.7: `[tool:*]` items are untrusted data).
class UntrustedFrame extends StatelessWidget {
  const UntrustedFrame({super.key, required this.child, this.label});

  final Widget child;

  /// Defaults to "Untrusted data".
  final String? label;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final color = t.semantic.warning;
    return Semantics(
      container: true,
      label: label ?? 'Untrusted data',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: kSemanticTintAlpha),
          border: Border(left: BorderSide(color: color, width: t.space.xs - 1)),
          borderRadius: BorderRadius.circular(t.radius.sm),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(t.space.md, t.space.sm, t.space.md, t.space.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Row(
                  children: [
                    Icon(Icons.gpp_maybe_outlined, size: 14, color: color),
                    SizedBox(width: t.space.xs),
                    Expanded(
                      child: Text(
                        label ?? 'Untrusted data',
                        style: theme.textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: t.space.xs),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// Raw model-facing text with every `<untrusted_data …>` block framed and
/// labelled with its source, so "what will be sent" can be read exactly
/// while the untrusted parts still stand out.
class UntrustedAwareText extends StatelessWidget {
  const UntrustedAwareText(this.text, {super.key, this.mono = true});

  final String text;
  final bool mono;

  static final RegExp _block = RegExp(
    r'<untrusted_data(?:\s+source="([^"]*)")?(?:\s+id="[^"]*")?>\n?([\s\S]*?)\n?</untrusted_data(?:\s+id="[^"]*")?>',
  );

  /// Splits [text] into plain and untrusted runs (source is null for plain).
  static List<({String? source, String text})> split(String text) {
    final out = <({String? source, String text})>[];
    var at = 0;
    for (final m in _block.allMatches(text)) {
      if (m.start > at) out.add((source: null, text: text.substring(at, m.start)));
      out.add((source: m[1] ?? 'unknown', text: m[2] ?? ''));
      at = m.end;
    }
    if (at < text.length) out.add((source: null, text: text.substring(at)));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final style = mono ? contextMonoStyle(context) : Theme.of(context).textTheme.bodyMedium;
    final runs = split(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in runs)
          if (r.source == null)
            if (r.text.trim().isNotEmpty) SelectableText(r.text.trim(), style: style)
            else const SizedBox.shrink()
          else
            Padding(
              padding: EdgeInsets.symmetric(vertical: t.space.sm),
              child: UntrustedFrame(
                label: 'Untrusted data from ${_sourceLabel(r.source!)} (the model is told not to follow it)',
                child: SelectableText(r.text, style: style),
              ),
            ),
      ],
    );
  }

  static String _sourceLabel(String source) {
    if (source.startsWith('tool:')) return 'the ${source.substring(5)} tool';
    if (source == 'summary') return 'tool output in the summary';
    return source;
  }
}

/// True when [s] has items that came from tool output.
bool summaryHasUntrusted(CompactionSummary s) =>
    s.isTainted ||
    s.artifacts.isNotEmpty ||
    s.stateHandles.isNotEmpty ||
    [
      ...s.constraints,
      ...s.userPreferences,
      ...s.decisions,
      ...s.completed,
      ...s.openTasks,
      ...s.keyFacts,
      ...s.failedApproaches,
    ].any(Provenance.isTool);
