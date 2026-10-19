import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';

import '../../../design/semantic_palette.dart';
import '../../../design/tokens.dart';
import '../state/mcp_providers.dart';

/// A small labelled pill: icon + text in a tinted capsule. Its semantics
/// read as one label; text scaling is clamped so it never wraps the row.
class McpPill extends StatelessWidget {
  const McpPill({super.key, required this.label, required this.icon, required this.color, this.semanticsLabel});

  final String label;
  final IconData icon;
  final Color color;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.5,
      child: Semantics(
        label: semanticsLabel ?? label,
        excludeSemantics: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color.withValues(alpha: kSemanticTintAlpha),
            borderRadius: BorderRadius.circular(t.radius.pill),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: t.space.sm, vertical: t.space.xxs + 1),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: color),
                SizedBox(width: t.space.xs),
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
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

/// A server's connection state as a pill.
class McpStatusPill extends StatelessWidget {
  const McpStatusPill({super.key, required this.status});

  final McpServerDisplayStatus status;

  static String labelOf(McpServerDisplayStatus s) => switch (s) {
        McpServerDisplayStatus.connected => 'Connected',
        McpServerDisplayStatus.connecting => 'Connecting…',
        McpServerDisplayStatus.notConnected => 'Not connected yet',
        McpServerDisplayStatus.needsAuth => 'Sign-in needed',
        McpServerDisplayStatus.offline => 'Offline',
        McpServerDisplayStatus.error => 'Error',
        McpServerDisplayStatus.disabled => 'Off',
      };

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final (icon, color) = switch (status) {
      McpServerDisplayStatus.connected => (Icons.check_circle_rounded, t.semantic.success),
      McpServerDisplayStatus.connecting => (Icons.sync, muted),
      McpServerDisplayStatus.notConnected => (Icons.radio_button_unchecked, muted),
      McpServerDisplayStatus.needsAuth => (Icons.lock_outline_rounded, t.semantic.warning),
      McpServerDisplayStatus.offline => (Icons.cloud_off_outlined, t.semantic.warning),
      McpServerDisplayStatus.error => (Icons.error_outline_rounded, t.semantic.danger),
      McpServerDisplayStatus.disabled => (Icons.pause_circle_outline, muted),
    };
    final label = labelOf(status);
    return McpPill(label: label, icon: icon, color: color, semanticsLabel: 'Status: $label');
  }
}

/// "Built in" label for the app's own servers.
class BuiltInPill extends StatelessWidget {
  const BuiltInPill({super.key});

  @override
  Widget build(BuildContext context) => McpPill(
        label: 'Built in',
        icon: Icons.phone_android_rounded,
        color: SherpaTokens.of(context).semantic.onDevice,
      );
}

/// The hygiene state of one tool.
class ToolReviewPill extends StatelessWidget {
  const ToolReviewPill({super.key, required this.entry});

  final McpCatalogEntry entry;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    return switch (entry.review.status) {
      ToolReviewStatus.quarantinedNew => McpPill(label: 'Needs review', icon: Icons.rate_review_outlined, color: t.semantic.warning),
      ToolReviewStatus.quarantinedChanged => McpPill(label: 'Changed, blocked', icon: Icons.difference_outlined, color: t.semantic.danger),
      ToolReviewStatus.approved when entry.flagged =>
        McpPill(label: 'Flagged: always asks', icon: Icons.flag_outlined, color: t.semantic.warning),
      ToolReviewStatus.approved => const SizedBox.shrink(),
    };
  }
}

/// The hints a tool DECLARES, labelled as declared. For an untrusted
/// server the line under them says they are not relied on.
class DeclaredHints extends StatelessWidget {
  const DeclaredHints({super.key, required this.annotations, required this.trusted});

  final ToolAnnotations annotations;

  /// The server is trusted and the tool approved and unflagged: the
  /// approval policy uses these hints.
  final bool trusted;

  static List<(String, IconData)> hintsOf(ToolAnnotations a) => [
        if (a.readOnlyHint == true) ('Read-only', Icons.visibility_outlined),
        if (a.readOnlyHint != true && a.destructiveHint == true) ('May delete or overwrite', Icons.delete_outline_rounded),
        if (a.readOnlyHint != true && a.destructiveHint == false) ('Changes data, non-destructive', Icons.edit_outlined),
        if (a.idempotentHint == true) ('Safe to repeat', Icons.repeat_rounded),
        if (a.openWorldHint == true) ('Reaches the internet', Icons.public_rounded),
        if (a.openWorldHint == false) ('Stays local', Icons.lock_outline_rounded),
      ];

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final hints = hintsOf(annotations);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: t.space.xs,
          runSpacing: t.space.xs,
          children: [
            if (hints.isEmpty) McpPill(label: 'No hints declared', icon: Icons.help_outline, color: muted),
            for (final (label, icon) in hints)
              McpPill(label: label, icon: icon, color: muted, semanticsLabel: 'Declared: $label'),
          ],
        ),
        if (!trusted) ...[
          SizedBox(height: t.space.xs),
          Text(
            'Declared by the server, not verified. Sherpa treats this tool as one that may change data.',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ],
      ],
    );
  }
}

/// Monospace, selectable block for review text and logs.
class MonoBlock extends StatelessWidget {
  const MonoBlock(this.text, {super.key, this.semanticsLabel});

  final String text;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return Semantics(
      label: semanticsLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(color: t.semantic.codeSurface, borderRadius: BorderRadius.circular(t.radius.md)),
        child: Padding(
          padding: EdgeInsets.all(t.space.md),
          child: SelectableText(
            text,
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', fontFamilyFallback: const ['Menlo', 'Roboto Mono']),
          ),
        ),
      ),
    );
  }
}

/// A short, plain-language note in a tinted box (warnings, explanations).
class NoteBox extends StatelessWidget {
  const NoteBox({super.key, required this.text, this.icon = Icons.info_outline_rounded, this.tone = NoteTone.neutral, this.title});

  final String? title;
  final String text;
  final IconData icon;
  final NoteTone tone;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (fg, bg) = switch (tone) {
      NoteTone.neutral => (scheme.onSecondaryContainer, scheme.secondaryContainer),
      NoteTone.warning => (scheme.onTertiaryContainer, scheme.tertiaryContainer),
      NoteTone.danger => (scheme.onErrorContainer, scheme.errorContainer),
    };
    return Semantics(
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(t.radius.md)),
        child: Padding(
          padding: EdgeInsets.all(t.space.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(child: Icon(icon, size: 20, color: fg)),
              SizedBox(width: t.space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title != null)
                      Padding(
                        padding: EdgeInsets.only(bottom: t.space.xxs),
                        child: Text(title!, style: theme.textTheme.titleSmall?.copyWith(color: fg)),
                      ),
                    Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: fg)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum NoteTone { neutral, warning, danger }

/// "in 5 min", "in 3 h", "in 2 days" for an expiry.
String describeExpiry(DateTime? expiresAt, DateTime now) {
  if (expiresAt == null) return 'No expiry';
  final d = expiresAt.difference(now);
  if (d.isNegative) return 'Expired';
  if (d.inMinutes < 1) return 'Expires in under a minute';
  if (d.inHours < 1) return 'Expires in ${d.inMinutes} min';
  if (d.inDays < 1) return 'Expires in ${d.inHours} h';
  return 'Expires in ${d.inDays} day${d.inDays == 1 ? '' : 's'}';
}
