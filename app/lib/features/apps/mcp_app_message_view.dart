import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_webview/sherpa_webview.dart';

import '../../app_info.dart';
import '../../design/theme.dart';
import '../../design/tokens.dart';
import 'app_prompts.dart';
import 'app_view_pool.dart';
import 'state/apps_providers.dart';
import 'viewport_visibility.dart';

/// An MCP App (`io.modelcontextprotocol/ui`) inside a chat message.
///
/// Give it the tool result that carries the view ([result] with
/// `uiResourceUri` and `meta[ToolResultPart.metaServerId]`, as the agent
/// loop stores it) or a stored [resource] part. It loads and validates the
/// `ui://` resource from the server, renders it in sherpa_webview's
/// sandbox with host chrome, and falls back to the result's text whenever
/// the view can't be shown (apps turned off for the server, an invalid
/// resource, no WebView, an error). Servers must always send meaningful
/// text, so nothing is lost.
///
/// Everything the view asks for goes through the app's real services:
/// tool calls through `McpToolRouter.executeForApp` after the approval
/// policy (evaluated as tainted; the chat's approval UI via
/// [mcpAppApprovalHandlerProvider], else an approval sheet), messages
/// through [mcpAppMessageSinkProvider] after the user confirms, links in
/// Custom Tabs / SFSafariViewController after the user confirms, network
/// only with consent (remembered per server + resource hash).
///
/// Views are pooled ([McpAppViewPool]): at most a few run at once, the
/// ones scrolled away are suspended and re-render when shown again.
class McpAppMessageView extends ConsumerStatefulWidget {
  const McpAppMessageView({
    super.key,
    required this.sessionId,
    this.result,
    this.resource,
    this.toolArguments,
    this.fallback,
  }) : assert(result != null || resource != null, 'a tool result or a UI resource part');

  final String sessionId;

  /// A tool result whose `uiResourceUri` is set.
  final ToolResultPart? result;

  /// A stored UI part (used when [result] is null, or for its server/uri).
  final UiResourcePart? resource;

  /// The tool call's arguments (`ui/notifications/tool-input`), if known.
  final JsonMap? toolArguments;

  /// Shown instead of the view when it can't be shown; defaults to the
  /// result's text.
  final Widget? fallback;

  /// The view spec for a result or part, or null when it has no view.
  static McpAppViewSpec? specFor({required String sessionId, ToolResultPart? result, UiResourcePart? resource, JsonMap? toolArguments}) {
    final serverId = resource?.serverId ?? (result?.meta[ToolResultPart.metaServerId] is String ? result!.meta[ToolResultPart.metaServerId]! as String : null);
    final uri = resource?.resourceUri ?? result?.uiResourceUri;
    if (serverId == null || uri == null || !uri.startsWith('ui://')) return null;
    final tool = result?.meta[ToolResultPart.metaTool];
    return McpAppViewSpec(
      sessionId: sessionId,
      serverId: serverId,
      resourceUri: uri,
      callId: result?.callId ?? resource?.callId,
      toolModelName: tool is String ? tool : result?.toolName,
      result: result,
      toolArguments: toolArguments,
    );
  }

  @override
  ConsumerState<McpAppMessageView> createState() => _McpAppMessageViewState();
}

class _McpAppMessageViewState extends ConsumerState<McpAppMessageView> implements McpAppPrompter {
  McpAppViewEntry? _entry;
  McpAppViewPool? _pool;

  McpAppViewSpec? get _spec => McpAppMessageView.specFor(
        sessionId: widget.sessionId,
        result: widget.result,
        resource: widget.resource,
        toolArguments: widget.toolArguments,
      );

  @override
  void dispose() {
    _unbind();
    super.dispose();
  }

  void _unbind() {
    final e = _entry, p = _pool;
    if (e != null && p != null) {
      e.removeListener(_onEntry);
      p.detach(e, this);
    }
    _entry = null;
  }

  void _onEntry() {
    if (mounted) setState(() {});
  }

  McpAppViewEntry? _bind() {
    final spec = _spec;
    if (spec == null) {
      _unbind();
      return null;
    }
    final McpAppViewPool pool;
    try {
      pool = ref.read(mcpAppViewPoolProvider);
    } on Object catch (e) {
      // MCP is not wired (previews, some tests): the text fallback.
      debugPrint('McpAppMessageView: no view pool ($e)');
      _unbind();
      return null;
    }
    final current = _entry;
    if (current != null && !current.isClosed && current.spec.key == spec.key && identical(pool, _pool)) return current;
    _unbind();
    final McpAppViewEntry e;
    try {
      e = pool.entryFor(spec);
    } on Object catch (err) {
      debugPrint('McpAppMessageView: $err');
      return null;
    }
    _pool = pool;
    e.addListener(_onEntry);
    pool.attach(e, this);
    _entry = e;
    return e;
  }

  Widget _fallback(BuildContext context) {
    final f = widget.fallback;
    if (f != null) return f;
    final text = widget.result?.text ?? '';
    return Text(text.isEmpty ? 'No text was returned with this content.' : text);
  }

  McpAppHostContext _hostContext(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final other = SherpaTheme.brandScheme(dark ? Brightness.light : Brightness.dark);
    return McpAppHostContext(
      styleVariables: mcpAppStyleVariables(light: dark ? other : scheme, dark: dark ? scheme : other),
      userAgent: 'Sherpa/${AppInfo.version} (mobile)',
      timeZone: ref.read(mcpAppTimeZoneProvider),
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = _bind();
    if (e == null) return _fallback(context);
    final t = SherpaTokens.maybeOf(context);
    switch (e.status) {
      case McpAppEntryStatus.loading:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            McpAppSourceLabel(serverName: e.serverName),
            const SizedBox(height: 120, child: McpAppLoading(label: 'Loading interactive content…')),
          ],
        );
      case McpAppEntryStatus.unavailable:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // The text is the server's too: say whose it is.
            McpAppSourceLabel(serverName: e.serverName),
            _fallback(context),
            if (e.unavailableReason != null) ...[
              SizedBox(height: t?.space.xs ?? 4),
              Text(
                e.unavailableReason!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ],
        );
      case McpAppEntryStatus.ready:
        final c = e.controller!;
        c.baseHostContext = _hostContext(context);
        return ViewportVisibility(
          onChanged: (v) => _pool?.setVisible(e, v),
          child: McpAppView(controller: c, fallback: _fallback(context)),
        );
    }
  }

  // ------------------------------------------------------------ McpAppPrompter

  @override
  Future<ApprovalResponse?> confirmToolCall(McpAppToolCallRequest request, ToolDefinition tool, NeedsConfirmation requirement) async {
    if (!mounted) return null;
    return showAppToolApprovalSheet(context, request: request, tool: tool, requirement: requirement);
  }

  @override
  Future<bool> confirmMessage(McpAppMessageRequest request) async => mounted && await showAppMessageSheet(context, request);

  @override
  Future<bool> confirmOpenLink(McpAppLinkRequest request) async => mounted && await showAppLinkSheet(context, request);

  @override
  Future<Set<String>?> requestNetwork(McpAppNetworkRequest request) async {
    if (!mounted) return null;
    return showAppNetworkSheet(context, request);
  }
}
