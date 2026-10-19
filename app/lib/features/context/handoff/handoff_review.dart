import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets/a11y.dart';
import '../state/format.dart';
import '../widgets/context_style.dart';
import '../widgets/untrusted.dart';
import 'handoff_codec.dart';

/// The numbers that decide how a bundle can travel, plus where it is from.
class HandoffFactsCard extends StatelessWidget {
  const HandoffFactsCard({super.key, required this.bundle, required this.title, this.qrPayload});

  final HandoffBundle bundle;
  final String title;

  /// Shown as the compressed size when set.
  final String? qrPayload;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final b = bundle;
    final size = HandoffCodec.fileBytes(b).length;
    final rows = <(String, String)>[
      ('Size', formatBytes(size)),
      if (qrPayload != null) ('Compressed', formatBytes(HandoffCodec.qrBytes(qrPayload!))),
      ('Made with', '${b.source.modelId} (${_where(b.source.location)})'),
      ('Created', _date(b.createdAt)),
      if (b.summary.compactionCount > 0) ('Summarized', plural(b.summary.compactionCount, 'time')),
      ('Your messages', plural(b.summary.userMessages.length, 'message')),
      if (b.recentTurns.isNotEmpty) ('Latest turns', plural(b.recentTurns.length, 'turn')),
      if (b.pinned.isNotEmpty) ('Pinned', plural(b.pinned.length, 'item')),
      if (b.connections.isNotEmpty) ('Servers', plural(b.connections.length, 'server')),
      if (b.artifacts.isNotEmpty) ('Files', plural(b.artifacts.length, 'file')),
    ];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(t.space.lg),
        child: HeadingGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Heading(level: 2, child: Text(title, style: theme.textTheme.titleMedium)),
              SizedBox(height: t.space.xs),
              Text(b.task.trim(), maxLines: 3, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyLarge),
              SizedBox(height: t.space.md),
              for (final (k, v) in rows)
                Semantics(
                  container: true,
                  label: '$k: $v',
                  excludeSemantics: true,
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: t.space.xxs),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 2,
                          child: Text(
                            k,
                            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),
                        Expanded(flex: 3, child: Text(v, style: theme.textTheme.bodyMedium)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _where(ExecutionLocation l) => switch (l) {
        ExecutionLocation.onDevice => 'on device',
        ExecutionLocation.localNetwork => 'local network',
        ExecutionLocation.remote => 'remote',
      };

  static String _date(DateTime d) {
    final l = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }
}

/// The bundle as `HandoffBundle.toMarkdown()` writes it, drawn by a small
/// strict renderer instead of the full Markdown engine.
///
/// Why not `StreamingMarkdown`: the bundle is untrusted, and its Markdown is
/// a fixed, tiny grammar (headings, bullets, quotes, bold labels, italics,
/// code spans, backslash escapes). The full engine also understands links,
/// images, tables and TeX (`toMarkdown` escapes `(` as `\(`, which it reads
/// as inline math), none of which an imported bundle should get to use.
/// Here nothing is tappable or loaded, and "untrusted" markers stand out.
class HandoffMarkdownView extends StatelessWidget {
  const HandoffMarkdownView({super.key, required this.bundle});

  final HandoffBundle bundle;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(t.radius.md),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: EdgeInsets.all(t.space.lg),
        child: SelectionArea(
          child: HeadingGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final b in _blocks(bundle.toMarkdown())) _block(context, b)],
            ),
          ),
        ),
      ),
    );
  }

  static List<(String kind, String text)> _blocks(String md) => [
        for (final line in md.split('\n'))
          if (line.trim().isNotEmpty)
            switch (line) {
              final l when l.startsWith('### ') => ('h3', l.substring(4)),
              final l when l.startsWith('## ') => ('h2', l.substring(3)),
              final l when l.startsWith('# ') => ('h1', l.substring(2)),
              final l when l.startsWith('- ') => ('li', l.substring(2)),
              final l when l.startsWith('> ') => ('quote', l.substring(2)),
              final l => ('p', l),
            },
      ];

  Widget _block(BuildContext context, (String, String) b) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final (kind, text) = b;
    final body = theme.textTheme.bodyMedium!;
    switch (kind) {
      case 'h1' || 'h2' || 'h3':
        final style = switch (kind) {
          'h1' => theme.textTheme.titleLarge!,
          'h2' => theme.textTheme.titleMedium!,
          _ => theme.textTheme.titleSmall!,
        };
        return Padding(
          padding: EdgeInsets.only(top: kind == 'h1' ? 0 : t.space.md, bottom: t.space.xs),
          child: Heading(
            level: kind == 'h1' ? 3 : (kind == 'h2' ? 4 : 5),
            child: Text.rich(_inline(context, text, style)),
          ),
        );
      case 'li':
        // One node per item: the bullet is read with its text.
        return Padding(
          padding: EdgeInsets.only(bottom: t.space.xs),
          child: MergeSemantics(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('•  ', style: body),
                Expanded(child: Text.rich(_inline(context, text, body))),
              ],
            ),
          ),
        );
      case 'quote':
        return Padding(
          padding: EdgeInsets.only(bottom: t.space.xs),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: BorderDirectional(start: BorderSide(color: theme.colorScheme.outlineVariant, width: t.space.xs - 1)),
            ),
            child: Padding(
              padding: EdgeInsetsDirectional.only(start: t.space.md),
              child: Text.rich(_inline(context, text, body)),
            ),
          ),
        );
      default:
        return Padding(
          padding: EdgeInsets.only(bottom: t.space.xs),
          child: Text.rich(_inline(context, text, body)),
        );
    }
  }

  static const String _untrustedMarker = '(from tool output, untrusted)';

  /// `**bold**`, `*italic*`, `` `code` `` and `\x` escapes; everything else
  /// is literal text.
  static TextSpan _inline(BuildContext context, String src, TextStyle base) {
    final warning = SherpaTokens.of(context).semantic.warning;
    final spans = <InlineSpan>[];
    final buf = StringBuffer();
    var bold = false;
    var italic = false;
    TextStyle style() => base.copyWith(
          fontWeight: bold ? FontWeight.w600 : null,
          fontStyle: italic ? FontStyle.italic : null,
        );
    void flush() {
      if (buf.isEmpty) return;
      final s = buf.toString();
      buf.clear();
      final untrusted = italic && s == _untrustedMarker;
      spans.add(TextSpan(
        text: untrusted ? ' $s' : s,
        style: untrusted ? style().copyWith(color: warning, fontWeight: FontWeight.w600) : style(),
      ));
    }

    var i = 0;
    while (i < src.length) {
      final c = src[i];
      if (c == r'\' && i + 1 < src.length) {
        buf.write(src[i + 1]);
        i += 2;
      } else if (c == '`') {
        final end = src.indexOf('`', i + 1);
        if (end < 0) {
          buf.write(c);
          i++;
          continue;
        }
        flush();
        spans.add(TextSpan(text: src.substring(i + 1, end), style: contextMonoStyle(context)));
        i = end + 1;
      } else if (src.startsWith('**', i)) {
        flush();
        bold = !bold;
        i += 2;
      } else if (c == '*') {
        flush();
        italic = !italic;
        i++;
      } else {
        buf.write(c);
        i++;
      }
    }
    flush();
    return TextSpan(children: spans);
  }
}

/// MCP servers the bundle names. Never credentials: the bundle format has
/// no field for them, and URLs with user info or token parameters are
/// rejected when parsing.
class ConnectionsManifest extends StatelessWidget {
  const ConnectionsManifest({super.key, required this.connections});

  final List<HandoffConnection> connections;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return HeadingGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Heading(level: 2, child: Text('Servers it used', style: theme.textTheme.titleMedium)),
          SizedBox(height: t.space.xs),
          Text(
            'No passwords, keys or tokens are included. You will be asked to connect and sign in to each one '
            'yourself; nothing connects automatically.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          for (final c in connections)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.dns_outlined),
              title: Text(c.name),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.url, style: contextMonoStyle(context, color: theme.colorScheme.onSurfaceVariant)),
                  Text(switch (c.authKind) {
                    HandoffAuthKind.none => 'No sign-in',
                    HandoffAuthKind.oauth => 'Sign-in needed',
                    HandoffAuthKind.header => 'Needs its own key',
                  }),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The import warning: where the content came from and what Sherpa does
/// about it (R11 §9.7).
class UntrustedImportNotice extends StatelessWidget {
  const UntrustedImportNotice({super.key});

  @override
  Widget build(BuildContext context) => UntrustedFrame(
        label: 'Imported content is untrusted',
        child: Text(
          'This handoff came from outside this app, and anyone could have written it. The model reads its task and '
          'summary as the starting point of your new chat; tool output inside it stays marked as untrusted data. '
          "Read it before you continue, and don't resume a handoff you don't recognize.",
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
}
