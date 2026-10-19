import 'package:material_ui/material_ui.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets/a11y.dart';
import '../widgets/mcp_widgets.dart';

/// [s] made safe to show as server text: control and bidi-override
/// characters removed (they can make text read differently than it is,
/// e.g. reversing a domain), whitespace runs collapsed (unless
/// [keepNewlines]), clipped to [max] characters.
String safeServerText(String s, {int max = 2000, bool keepNewlines = true}) {
  var out = s.replaceAll(RegExp('[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F\\x7F\\u200E\\u200F\\u202A-\\u202E\\u2066-\\u2069]'), '');
  out = keepNewlines ? out.replaceAll(RegExp(r'[ \t]+'), ' ').replaceAll(RegExp(r'\n{3,}'), '\n\n') : out.replaceAll(RegExp(r'\s+'), ' ');
  out = out.trim();
  return out.length > max ? '${out.substring(0, max - 1)}…' : out;
}

/// Who is asking, shown prominently above every input sheet: the server's
/// name as the USER configured it (never its self-description), and a
/// warning when the user has not marked it trusted.
class InputRequesterHeader extends StatelessWidget {
  const InputRequesterHeader({
    super.key,
    required this.serverName,
    required this.trusted,
    required this.title,
    this.toolName,
    this.announceTitle = false,
  });

  final String serverName;
  final bool trusted;

  /// App copy: what kind of request this is.
  final String title;

  /// The tool whose call asked, when known.
  final String? toolName;

  /// The title is a live region: sheets whose title follows their stage
  /// (sampling: "Writing an answer…" → "Send this answer?") say so.
  final bool announceTitle;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return HeadingGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Heading(
            child: Semantics(liveRegion: announceTitle, child: Text(title, style: theme.textTheme.titleLarge)),
          ),
          SizedBox(height: t.space.sm),
          Row(
            children: [
              Icon(Icons.dns_outlined, size: 20, color: theme.colorScheme.primary),
              SizedBox(width: t.space.sm),
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    const TextSpan(text: 'Asked by '),
                    TextSpan(text: serverName, style: const TextStyle(fontWeight: FontWeight.w700)),
                    if (toolName != null) TextSpan(text: ' · while running $toolName'),
                  ]),
                  style: theme.textTheme.bodyLarge,
                ),
              ),
            ],
          ),
          if (!trusted) ...[
            SizedBox(height: t.space.sm),
            const NoteBox(
              tone: NoteTone.warning,
              icon: Icons.gpp_maybe_outlined,
              text: "You haven't marked this server as trusted. What it writes below may be wrong or "
                  'misleading; only continue if you expected this request.',
            ),
          ],
        ],
      ),
    );
  }
}

/// A frame around content the SERVER wrote (its message, field labels and
/// descriptions, prompts): a tinted, bordered panel labelled as coming
/// from the server, so server text can never pass for Sherpa's own UI.
class ServerContentPanel extends StatelessWidget {
  const ServerContentPanel({super.key, required this.serverName, required this.child, this.label});

  final String serverName;
  final Widget child;

  /// Defaults to "Written by `server`".
  final String? label;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      container: true,
      label: label ?? 'Content written by $serverName',
      // A Material (not a DecoratedBox) so list tiles inside paint on it.
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.radius.md),
          side: BorderSide(color: scheme.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ColoredBox(
              color: scheme.surfaceContainerHigh,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: t.space.md, vertical: t.space.xs),
                child: Row(
                  children: [
                    ExcludeSemantics(child: Icon(Icons.format_quote_rounded, size: 16, color: scheme.onSurfaceVariant)),
                    SizedBox(width: t.space.xs),
                    Expanded(
                      child: ExcludeSemantics(
                        child: Text(
                          label ?? 'Written by $serverName, not by Sherpa',
                          style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(padding: EdgeInsets.all(t.space.md), child: child),
          ],
        ),
      ),
    );
  }
}

/// A fact row ("Label: value") in app copy, value optionally emphasized.
class InputFact extends StatelessWidget {
  const InputFact({super.key, required this.label, required this.value, this.emphasize = false, this.mono = false});

  final String label;
  final String value;
  final bool emphasize;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final base = emphasize ? theme.textTheme.titleMedium : theme.textTheme.bodyMedium;
    return Semantics(
      label: '$label: $value',
      excludeSemantics: true,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: t.space.xxs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            Text(value, style: mono ? base?.copyWith(fontFamily: 'monospace', fontFamilyFallback: const ['Menlo', 'Roboto Mono']) : base),
          ],
        ),
      ),
    );
  }
}
