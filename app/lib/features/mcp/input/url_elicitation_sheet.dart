import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../design/tokens.dart';
import '../../../services/mcp/input/input_queue.dart';
import '../../../services/mcp/input/url_opener.dart';
import '../../../state/ui_preferences.dart';
import '../../chat/links/link_warnings.dart' show webAddressWarnings;
import '../state/input_providers.dart';
import '../widgets/mcp_widgets.dart';
import 'server_content.dart';

/// Warnings about a URL before anyone opens it: the same checks as links
/// in replies ([webAddressWarnings]), so a non-ASCII host (which `Uri`
/// percent-encodes) and a decimal or hex IP are caught here too.
List<String> urlWarnings(Uri url) => webAddressWarnings(url);

/// URL-mode elicitation consent (client/elicitation.md): the full URL and
/// its domain, highlighted, the server's reason, and nothing opens (or is
/// fetched — no previews) until the user confirms. The page opens outside
/// the app (Custom Tabs / SFSafariViewController, or the browser app);
/// afterwards the sheet waits for the user to come back.
class UrlElicitationSheet extends ConsumerStatefulWidget {
  const UrlElicitationSheet({super.key, required this.pending});

  final PendingUrlElicitation pending;

  @override
  ConsumerState<UrlElicitationSheet> createState() => _UrlElicitationSheetState();
}

class _UrlElicitationSheetState extends ConsumerState<UrlElicitationSheet> {
  bool _opening = false;

  PendingUrlElicitation get _p => widget.pending;

  @override
  void initState() {
    super.initState();
    _p.addListener(_onPending);
  }

  @override
  void dispose() {
    _p.removeListener(_onPending);
    super.dispose();
  }

  void _onPending() {
    if (!mounted) return;
    if (_p.isDone) {
      Navigator.of(context).maybePop();
    } else {
      setState(() {});
    }
  }

  Future<void> _open(McpUrlTarget target) async {
    if (_opening) return;
    setState(() => _opening = true);
    final ok = await ref.read(mcpUrlOpenerProvider).open(_p.url, target: target);
    if (!mounted) return;
    setState(() => _opening = false);
    if (ok) {
      ref.read(hapticsProvider).selection();
      _p.markOpened();
    } else {
      ref.read(hapticsProvider).error();
      _p.markFailed("Sherpa couldn't open a browser for this page.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final url = _p.url;
    final message = safeServerText(_p.request.message);
    final warnings = urlWarnings(url);
    final opened = _p.stage == UrlElicitationStage.opened;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(t.space.xl, t.space.sm, t.space.xl, t.space.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InputRequesterHeader(
              title: opened ? 'Finish in the browser' : 'Open a web page?',
              serverName: _p.serverName,
              trusted: _p.serverTrusted,
              toolName: _p.toolName,
              announceTitle: true,
            ),
            SizedBox(height: t.space.lg),
            InputFact(label: 'Site', value: url.host, emphasize: true),
            InputFact(label: 'Full address', value: safeServerText(url.toString(), max: 2000, keepNewlines: false), mono: true),
            for (final w in warnings) ...[
              SizedBox(height: t.space.sm),
              NoteBox(text: w, tone: NoteTone.warning, icon: Icons.warning_amber_rounded),
            ],
            if (message.isNotEmpty) ...[
              SizedBox(height: t.space.md),
              ServerContentPanel(
                serverName: _p.serverName,
                label: 'Why, according to ${_p.serverName}',
                child: Text(message, style: theme.textTheme.bodyLarge),
              ),
            ],
            SizedBox(height: t.space.md),
            if (opened)
              Text(
                'The page is open outside Sherpa, so neither Sherpa nor the model can see what you enter there. When '
                "you're done, come back and tap Done; ${_p.serverName} then checks the result.",
                style: theme.textTheme.bodyMedium,
              )
            else
              Text(
                'Nothing is loaded until you choose. The page opens in a secure browser window outside Sherpa.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            if (_p.stage == UrlElicitationStage.failed && _p.error != null) ...[
              SizedBox(height: t.space.sm),
              NoteBox(text: _p.error!, tone: NoteTone.danger, icon: Icons.error_outline_rounded),
            ],
            SizedBox(height: t.space.lg),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: t.space.sm,
              runSpacing: t.space.sm,
              children: opened
                  ? [
                      TextButton(onPressed: _p.cancel, child: const Text('Cancel')),
                      OutlinedButton(
                        onPressed: _opening ? null : () => unawaited(_open(McpUrlTarget.inAppBrowser)),
                        child: const Text('Open again'),
                      ),
                      FilledButton(onPressed: _p.complete, child: const Text('Done')),
                    ]
                  : [
                      TextButton(onPressed: _p.cancel, child: const Text('Cancel')),
                      OutlinedButton(onPressed: _p.decline, child: const Text('Decline')),
                      OutlinedButton(
                        onPressed: _opening ? null : () => unawaited(_open(McpUrlTarget.externalBrowser)),
                        child: const Text('Open in browser app'),
                      ),
                      FilledButton.icon(
                        onPressed: _opening ? null : () => unawaited(_open(McpUrlTarget.inAppBrowser)),
                        icon: const Icon(Icons.open_in_browser_rounded),
                        label: Text('Open ${url.host.length > 28 ? 'page' : url.host}'),
                      ),
                    ],
            ),
          ],
        ),
      ),
    );
  }
}
