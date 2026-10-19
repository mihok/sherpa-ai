import 'package:material_ui/material_ui.dart';

import '../../../design/tokens.dart';
import '../state/transcript_model.dart';
import 'chat_style.dart';

/// A resource attached to a message: a compact chip with what it is and
/// which server it came from. Resources are untrusted content, so the
/// server is always named.
class ResourceChip extends StatelessWidget {
  const ResourceChip({super.key, required this.label, this.serverName, this.embedded = true, this.onRemove});

  ResourceChip.of(AttachedResource r, {Key? key})
      : this(key: key, label: r.label, serverName: r.serverName, embedded: r.embedded);

  final String label;
  final String? serverName;

  /// Text read into the message (else only a link to it).
  final bool embedded;

  /// Shows a remove button (composer chips).
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final from = serverName == null ? null : 'from $serverName';
    final spoken = ['${embedded ? 'Resource' : 'Link to resource'} $label', ?from].join(', ');
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: kChromeMaxTextScale,
      child: Semantics(
        container: true,
        label: spoken,
        excludeSemantics: onRemove == null,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainer,
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(t.radius.pill),
          ),
          child: Padding(
            padding: EdgeInsetsDirectional.only(
              start: t.space.sm,
              end: onRemove == null ? t.space.sm : 0,
              top: t.space.xxs,
              bottom: t.space.xxs,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(embedded ? Icons.description_outlined : Icons.link_rounded, size: ChatIconSize.small, color: muted),
                SizedBox(width: t.space.xs),
                Flexible(
                  child: ExcludeSemantics(
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(text: label, style: const TextStyle(fontWeight: FontWeight.w600)),
                        if (from != null) TextSpan(text: ' · $serverName', style: TextStyle(color: muted)),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium,
                    ),
                  ),
                ),
                if (onRemove != null)
                  IconButton(
                    tooltip: 'Remove $label',
                    visualDensity: VisualDensity.compact,
                    iconSize: ChatIconSize.small,
                    onPressed: onRemove,
                    icon: const Icon(Icons.close_rounded),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "From Example tools · /example:review · untrusted" above a message an
/// MCP prompt wrote, so server text never reads as the user's own words.
class PromptSourceLabel extends StatelessWidget {
  const PromptSourceLabel({super.key, required this.source});

  final PromptSource source;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final color = source.untrusted ? t.semantic.warning : theme.colorScheme.onSurfaceVariant;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: kChromeMaxTextScale,
      child: Semantics(
        container: true,
        label: source.semanticLabel,
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(source.untrusted ? Icons.gpp_maybe_outlined : Icons.extension_outlined, size: ChatIconSize.small, color: color),
            SizedBox(width: t.space.xs),
            Flexible(
              child: Text(
                source.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "42 tok/s · TTFT 0.4 s" under a reply whose provider reported timing
/// (the on-device engine, llama.cpp-compatible servers). Quiet: small,
/// muted, details in the tooltip and the spoken label.
class ReplyPerfFooter extends StatelessWidget {
  const ReplyPerfFooter({super.key, required this.perf});

  final ReplyPerf perf;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = SherpaTokens.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: kChromeMaxTextScale,
      child: Tooltip(
        message: perf.semanticLabel,
        excludeFromSemantics: true,
        child: Semantics(
          container: true,
          label: perf.semanticLabel,
          excludeSemantics: true,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: t.space.sm, vertical: t.space.xs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.speed_rounded, size: ChatIconSize.small, color: color),
                SizedBox(width: t.space.xs),
                Text(
                  perf.label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: color,
                    fontFeatures: const [FontFeature.tabularFigures()],
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
