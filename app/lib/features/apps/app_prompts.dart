import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_webview/sherpa_webview.dart';

import '../../design/tokens.dart';
import '../mcp/input/server_content.dart';
import '../mcp/input/url_elicitation_sheet.dart' show urlWarnings;
import '../mcp/widgets/mcp_widgets.dart';

Future<T?> _sheet<T>(BuildContext context, Widget child) => showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => SafeArea(top: false, child: SingleChildScrollView(child: child)),
    );

class _SheetBody extends StatelessWidget {
  const _SheetBody({required this.children, required this.actions});

  final List<Widget> children;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(t.space.xl, t.space.sm, t.space.xl, t.space.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...children,
          SizedBox(height: t.space.lg),
          Wrap(alignment: WrapAlignment.end, spacing: t.space.sm, runSpacing: t.space.sm, children: actions),
        ],
      ),
    );
  }
}

/// "Requested by `app`, an app from `server`": the View's own name is untrusted.
String appAttribution(McpAppIdentity id) {
  final app = id.appName == null || id.appName!.trim().isEmpty ? null : safeServerText(id.appName!, max: 60, keepNewlines: false);
  return app == null ? 'Requested by an app from ${id.serverName}' : 'Requested by "$app", an app from ${id.serverName}';
}

/// The approval sheet for a tool call an app view (not the model) wants to
/// make: Deny or Allow once. App calls are judged as tainted (untrusted
/// content drives them), where a chat-scoped grant would never skip the
/// next prompt, so none is offered.
Future<ApprovalResponse?> showAppToolApprovalSheet(
  BuildContext context, {
  required McpAppToolCallRequest request,
  required ToolDefinition tool,
  required NeedsConfirmation requirement,
}) {
  final t = SherpaTokens.of(context);
  final theme = Theme.of(context);
  final args = const JsonEncoder.withIndent('  ').convert(request.arguments);
  return _sheet<ApprovalResponse>(
    context,
    Builder(
      builder: (context) => _SheetBody(
        children: [
          Semantics(
            headingLevel: 2,
            child: Text('Allow “${safeServerText(request.tool.displayName, max: 80, keepNewlines: false)}”?', style: theme.textTheme.titleLarge),
          ),
          Text('${tool.name} · ${request.identity.serverName}', style: theme.textTheme.bodySmall),
          SizedBox(height: t.space.xs),
          Text(appAttribution(request.identity), style: theme.textTheme.bodyLarge),
          SizedBox(height: t.space.md),
          NoteBox(
            tone: requirement.risk == RiskLevel.destructive ? NoteTone.danger : NoteTone.warning,
            icon: Icons.shield_outlined,
            text: '${requirement.reason} The app asked for this itself, not the model.',
          ),
          SizedBox(height: t.space.md),
          Text('Arguments', style: theme.textTheme.labelMedium),
          SizedBox(height: t.space.xs),
          MonoBlock(args.length > 4000 ? '${args.substring(0, 3999)}…' : args, semanticsLabel: 'Arguments'),
        ],
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(const ApprovalResponse(UserDecision.deny)), child: const Text('Deny')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(const ApprovalResponse(UserDecision.approve)),
            child: const Text('Allow once'),
          ),
        ],
      ),
    ),
  );
}

/// Confirms a `ui/message`: the exact text the app wants to send as YOU.
Future<bool> showAppMessageSheet(BuildContext context, McpAppMessageRequest request) async {
  final t = SherpaTokens.of(context);
  final theme = Theme.of(context);
  final ok = await _sheet<bool>(
    context,
    Builder(
      builder: (context) => _SheetBody(
        children: [
          Semantics(headingLevel: 2, child: Text('Send this message?', style: theme.textTheme.titleLarge)),
          SizedBox(height: t.space.xs),
          Text(appAttribution(request.identity), style: theme.textTheme.bodyLarge),
          SizedBox(height: t.space.md),
          ServerContentPanel(
            serverName: request.identity.serverName,
            label: 'Written by the app, sent as your message',
            child: SelectableText(safeServerText(request.text, max: 8000)),
          ),
          SizedBox(height: t.space.sm),
          Text('It is added to the chat as if you wrote it, and the model answers it.', style: theme.textTheme.bodySmall),
        ],
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text("Don't send")),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.send_rounded),
            label: const Text('Send'),
          ),
        ],
      ),
    ),
  );
  return ok ?? false;
}

/// Confirms a link from a view: the full URL with its site emphasized.
Future<bool> showAppLinkSheet(BuildContext context, McpAppLinkRequest request) async {
  final t = SherpaTokens.of(context);
  final theme = Theme.of(context);
  final url = request.uri;
  final ok = await _sheet<bool>(
    context,
    Builder(
      builder: (context) => _SheetBody(
        children: [
          Semantics(headingLevel: 2, child: Text('Open this link?', style: theme.textTheme.titleLarge)),
          SizedBox(height: t.space.xs),
          Text(appAttribution(request.identity), style: theme.textTheme.bodyLarge),
          SizedBox(height: t.space.md),
          InputFact(label: 'Site', value: url.host, emphasize: true),
          InputFact(label: 'Full address', value: safeServerText(url.toString(), keepNewlines: false), mono: true),
          for (final w in urlWarnings(url)) ...[
            SizedBox(height: t.space.sm),
            NoteBox(text: w, tone: NoteTone.warning, icon: Icons.warning_amber_rounded),
          ],
          SizedBox(height: t.space.sm),
          Text('It opens in a secure browser window outside Sherpa.', style: theme.textTheme.bodySmall),
        ],
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.open_in_browser_rounded),
            label: const Text('Open'),
          ),
        ],
      ),
    ),
  );
  return ok ?? false;
}

/// Asks whether a view may use the network, listing exactly the domains it
/// declared (connect and content), plus anything Sherpa refused. Returns
/// the granted `CspOrigin.source` set, `{}` to keep it offline, or null
/// for "not now" (asked again next time).
Future<Set<String>?> showAppNetworkSheet(BuildContext context, McpAppNetworkRequest request) {
  final t = SherpaTokens.of(context);
  final theme = Theme.of(context);
  final d = request.declared;
  return _sheet<Set<String>>(
    context,
    Builder(
      builder: (context) => _SheetBody(
        children: [
          Semantics(headingLevel: 2, child: Text('Let this view use the internet?', style: theme.textTheme.titleLarge)),
          SizedBox(height: t.space.xs),
          Text('Interactive content from ${request.serverName}', style: theme.textTheme.bodyLarge),
          SizedBox(height: t.space.md),
          if (d.connect.isNotEmpty) ...[
            Text('It would send and receive data with', style: theme.textTheme.labelLarge),
            for (final o in d.connect) Text('• ${o.source}', style: theme.textTheme.bodyMedium),
            SizedBox(height: t.space.sm),
          ],
          if (d.resource.where((o) => !d.connect.contains(o)).isNotEmpty) ...[
            Text('It would load scripts, styles and images from', style: theme.textTheme.labelLarge),
            for (final o in d.resource.where((o) => !d.connect.contains(o))) Text('• ${o.source}', style: theme.textTheme.bodyMedium),
            SizedBox(height: t.space.sm),
          ],
          if (d.rejected.isNotEmpty)
            NoteBox(
              tone: NoteTone.warning,
              icon: Icons.block_rounded,
              text: 'Sherpa refused ${d.rejected.length} other address${d.rejected.length == 1 ? '' : 'es'} it asked for '
                  '(not plain web origins).',
            ),
          SizedBox(height: t.space.sm),
          Text(
            'These sites could see what the view sends them, including anything you type into it. Your answer is '
            'remembered for this version of the view; you can revoke it in the server\'s settings.',
            style: theme.textTheme.bodySmall,
          ),
        ],
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Not now')),
          OutlinedButton(onPressed: () => Navigator.of(context).pop(<String>{}), child: const Text('Keep offline')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop({for (final o in d.all) o.source}),
            child: const Text('Allow'),
          ),
        ],
      ),
    ),
  );
}
