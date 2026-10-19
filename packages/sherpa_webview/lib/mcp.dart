/// Glue between sherpa_webview and sherpa_mcp: load a `ui://` resource and
/// build [McpAppHostCallbacks] for one server from the tool router.
library;

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';

import 'src/policy/limits.dart';
import 'src/policy/link_policy.dart';
import 'src/resource.dart';
import 'src/types.dart';

/// Validates a `resources/read` result for a View (exactly one content
/// item, the MCP Apps mime type, `_meta.ui` from the item, then
/// [listing]). Throws [McpAppResourceException].
McpAppResource mcpAppResourceFromRead(
  McpReadResourceResult result, {
  required String uri,
  McpResource? listing,
  McpAppLimits limits = const McpAppLimits(),
}) {
  if (result.contents.length != 1) {
    throw McpAppResourceException('expected one content item, got ${result.contents.length}');
  }
  final c = result.contents.single;
  if (c.uri != uri) throw McpAppResourceException('content uri ${c.uri} does not match $uri');
  // Python SDK quirk: `meta` instead of `_meta` (R03 §4).
  final rawMeta = c.raw?['meta'];
  final contentMeta = c.meta ?? (rawMeta is Map ? rawMeta.cast<String, Object?>() : null);
  return McpAppResource.fromContents(
    uri: c.uri,
    mimeType: c.mimeType,
    text: c is McpTextResourceContents ? c.text : null,
    blob: c is McpBlobResourceContents ? c.blob : null,
    contentMeta: contentMeta,
    listingMeta: listing?.meta,
    limits: limits,
  );
}

/// Reads and validates [uri] from [serverId]. The listing entry (for
/// listing-level `_meta.ui`) is looked up only when [useListingMeta].
Future<McpAppResource> loadMcpAppResource(
  McpServerManager manager, {
  required String serverId,
  required String uri,
  bool useListingMeta = true,
  McpAppLimits limits = const McpAppLimits(),
}) async {
  final conn = await manager.connection(serverId);
  final read = await conn.readResource(uri);
  McpResource? listing;
  if (useListingMeta) {
    try {
      for (final r in await conn.listResources()) {
        if (r.uri == uri) {
          listing = r;
          break;
        }
      }
    } on Object {
      // Servers MAY omit UI-only resources from resources/list.
    }
  }
  return mcpAppResourceFromRead(read, uri: uri, listing: listing, limits: limits);
}

/// [McpAppHostCallbacks] for an app of [serverId]:
///
/// - `lookupTool` reads the server's tool list from [manager] and exposes
///   its `_meta.ui.visibility` (the bridge enforces it);
/// - `callTool` runs through [McpToolRouter.executeForApp] (same server,
///   visibility re-checked, hygiene / schema validation / result limits);
/// - [approveToolCall] is the app's approval policy (an app can trigger
///   destructive tools without the model; attribute the request to
///   `request.identity.label`).
///
/// Confirmation, message insertion and link callbacks are passed through.
McpAppHostCallbacks mcpRouterAppCallbacks({
  required McpToolRouter router,
  required McpServerManager manager,
  required String serverId,
  required String sessionId,
  required Future<bool> Function(McpAppToolCallRequest request) approveToolCall,
  Future<bool> Function(McpAppMessageRequest request)? confirmMessage,
  void Function(McpAppMessageRequest request)? insertMessage,
  Future<bool> Function(McpAppLinkRequest request)? confirmOpenLink,
  Future<bool> Function(Uri uri)? launchLink,
  void Function(McpAppModelContext context)? updateModelContext,
  Future<Set<String>> Function(McpAppNetworkRequest request)? requestNetworkAccess,
  void Function(McpAppLogEntry entry)? onLog,
  bool allowResourceReads = false,
  LinkPolicy linkPolicy = const LinkPolicy(),
}) =>
    McpAppHostCallbacks(
      lookupTool: (name) async {
        final tools = await manager.listTools(serverId);
        for (final t in tools) {
          if (t.name != name) continue;
          return McpAppTool(
            name: t.name,
            visibility: t.uiVisibility,
            title: t.title,
            description: t.description,
            annotations: t.annotations,
            definition: router.appToolDefinition(serverId, t.name),
          );
        }
        return null;
      },
      approveToolCall: approveToolCall,
      callTool: (call) => router.executeForApp(
        serverId: call.serverId,
        toolName: call.tool.name,
        arguments: call.arguments,
        context: ToolExecutionContext(
          sessionId: sessionId,
          cancel: call.cancel,
          timeout: call.timeout,
          onProgress: call.onProgress,
        ),
      ),
      confirmMessage: confirmMessage,
      insertMessage: insertMessage,
      confirmOpenLink: confirmOpenLink,
      launchLink: launchLink,
      updateModelContext: updateModelContext,
      readResource: allowResourceReads
          ? (uri) async => (await (await manager.connection(serverId)).readResource(uri)).raw
          : null,
      requestNetworkAccess: requestNetworkAccess,
      onLog: onLog,
      linkPolicy: linkPolicy,
    );

/// The MCP tool definition JSON for `hostContext.toolInfo.tool`.
Future<Map<String, Object?>?> mcpToolJson(McpServerManager manager, String serverId, String toolName) async {
  for (final t in await manager.listTools(serverId)) {
    if (t.name == toolName) return t.raw;
  }
  return null;
}
