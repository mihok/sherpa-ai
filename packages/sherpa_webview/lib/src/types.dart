/// Data the bridge hands to the app's callbacks, and what the app provides.
library;

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import 'policy/csp.dart';
import 'policy/link_policy.dart';
import 'resource.dart';

/// What one view shows: a server's UI resource for one tool call.
@immutable
final class McpAppSession {
  const McpAppSession({
    required this.serverId,
    required this.serverName,
    required this.resource,
    this.tool,
    this.toolCallRequestId,
    this.callId,
  });

  final String serverId;

  /// Shown in the `Content from <server>` label and every prompt.
  final String serverName;
  final McpAppResource resource;

  /// The full MCP tool definition (`hostContext.toolInfo.tool`), if known.
  final Map<String, Object?>? tool;

  /// JSON-RPC id of the host→server `tools/call` (`toolInfo.id`), if known.
  final Object? toolCallRequestId;

  /// Sherpa's call id (the `ToolResultPart.callId` / `UiResourcePart.callId`).
  final String? callId;

  Map<String, Object?>? get toolInfo => tool == null
      ? null
      : {
          if (toolCallRequestId != null) 'id': toolCallRequestId,
          'tool': tool,
        };
}

/// Who is asking. [appName] / [appVersion] come from the View's
/// `ui/initialize` and are UNTRUSTED display text; [serverName] is the
/// host's own name for the server.
@immutable
final class McpAppIdentity {
  const McpAppIdentity({required this.serverId, required this.serverName, this.appName, this.appVersion});

  final String serverId;
  final String serverName;
  final String? appName;
  final String? appVersion;

  /// "Weather Dashboard (from Weather)" style attribution.
  String get label => appName == null || appName!.isEmpty ? serverName : '$appName (from $serverName)';
}

/// A tool of the View's OWN server, as the bridge needs it to decide
/// whether the View may call it.
@immutable
final class McpAppTool {
  const McpAppTool({
    required this.name,
    this.visibility,
    this.title,
    this.description,
    this.annotations = const ToolAnnotations(),
    this.definition,
  });

  /// Wire name on the server.
  final String name;

  /// `_meta.ui.visibility`; null means the default `["model","app"]`.
  final List<String>? visibility;
  final String? title;
  final String? description;

  /// Hints from the server (untrusted unless the server is trusted).
  final ToolAnnotations annotations;

  /// The router's definition (for the approval sheet), when available.
  final ToolDefinition? definition;

  /// Spec predicate: callable by an app of the same server unless the
  /// visibility list exists and lacks `app` (`[]` is NOT callable).
  bool get appCallable => visibility?.contains('app') ?? true;

  String get displayName => title ?? annotations.title ?? name;
}

/// Asked before a View-initiated tool call runs.
@immutable
final class McpAppToolCallRequest {
  const McpAppToolCallRequest({required this.identity, required this.tool, required this.arguments});

  final McpAppIdentity identity;
  final McpAppTool tool;
  final Map<String, Object?> arguments;
}

/// An approved View-initiated tool call, for the app to execute (normally
/// `McpToolRouter.executeForApp`).
@immutable
final class McpAppToolCall {
  const McpAppToolCall({
    required this.serverId,
    required this.tool,
    required this.arguments,
    required this.cancel,
    required this.timeout,
    this.onProgress,
  });

  final String serverId;
  final McpAppTool tool;
  final Map<String, Object?> arguments;
  final CancellationToken cancel;
  final Duration timeout;

  /// Relayed to the View as `notifications/progress` with its own token.
  final void Function(ToolProgress progress)? onProgress;
}

/// A `ui/message` the View proposes to add to the conversation as a USER
/// message. Untrusted text: render it attributed to the app.
@immutable
final class McpAppMessageRequest {
  const McpAppMessageRequest({required this.identity, required this.text, required this.content});

  final McpAppIdentity identity;

  /// The text blocks joined with blank lines.
  final String text;

  /// The validated content blocks (text only in this version).
  final List<Map<String, Object?>> content;
}

/// A link the View wants opened (`ui/open-link`, or a plain `<a href>`
/// activation reported by the shell prelude when [fromAnchor]).
@immutable
final class McpAppLinkRequest {
  const McpAppLinkRequest({required this.identity, required this.uri, this.fromAnchor = false});

  final McpAppIdentity identity;
  final Uri uri;
  final bool fromAnchor;
}

/// `ui/update-model-context`: overwrite semantics; the app sends only the
/// latest one before the next user turn, wrapped as untrusted app data.
@immutable
final class McpAppModelContext {
  const McpAppModelContext({required this.identity, this.content = const [], this.structuredContent});

  final McpAppIdentity identity;
  final List<Map<String, Object?>> content;
  final Map<String, Object?>? structuredContent;
}

/// A `notifications/message` from the View (logs only, never model input).
@immutable
final class McpAppLogEntry {
  const McpAppLogEntry({required this.level, required this.data, this.logger});

  final String level;
  final String? logger;

  /// JSON-encoded and truncated.
  final String data;
}

/// What the user is asked before a View may use the network.
@immutable
final class McpAppNetworkRequest {
  const McpAppNetworkRequest({
    required this.serverId,
    required this.serverName,
    required this.resourceUri,
    required this.resourceSha256,
    required this.declared,
  });

  final String serverId;
  final String serverName;
  final String resourceUri;

  /// Consent should be stored per server + this hash and asked again when
  /// the UI changes (R03 §11.8).
  final String resourceSha256;

  /// Validated declarations; `declared.rejected` lists what was refused.
  final DeclaredDomains declared;
}

/// Everything the app must provide. The bridge enforces the order:
/// visibility → [approveToolCall] → [callTool]; scheme check →
/// [confirmOpenLink] → [launchLink]; validation → [confirmMessage] →
/// [insertMessage]. A callback that throws counts as "no".
@immutable
final class McpAppHostCallbacks {
  const McpAppHostCallbacks({
    required this.lookupTool,
    required this.approveToolCall,
    required this.callTool,
    this.confirmMessage,
    this.insertMessage,
    this.confirmOpenLink,
    this.launchLink,
    this.updateModelContext,
    this.readResource,
    this.requestNetworkAccess,
    this.onLog,
    this.linkPolicy = const LinkPolicy(),
  });

  /// A tool of THIS session's server by wire name; null when unknown. The
  /// bridge checks [McpAppTool.appCallable] itself.
  final FutureOr<McpAppTool?> Function(String name) lookupTool;

  /// The app's approval policy for app-initiated calls (an app can trigger
  /// destructive tools without the model). Return true to run the call.
  final Future<bool> Function(McpAppToolCallRequest request) approveToolCall;

  /// Executes an approved call on the session's server.
  final Future<ToolResult> Function(McpAppToolCall call) callTool;

  /// Shows the proposed user message; true only if the user confirmed.
  /// `ui/message` is advertised only when both this and [insertMessage]
  /// are set.
  final Future<bool> Function(McpAppMessageRequest request)? confirmMessage;

  /// Adds a CONFIRMED message to the conversation.
  final FutureOr<void> Function(McpAppMessageRequest request)? insertMessage;

  /// Shows the link (full URL, host emphasized); true only if confirmed.
  /// `openLinks` is advertised only when both this and [launchLink] are set.
  final Future<bool> Function(McpAppLinkRequest request)? confirmOpenLink;

  /// Opens a CONFIRMED link outside the app (Custom Tabs /
  /// SFSafariViewController / browser). Returns false on failure.
  final Future<bool> Function(Uri uri)? launchLink;

  /// Stores the latest model context; advertised only when set.
  final void Function(McpAppModelContext context)? updateModelContext;

  /// `resources/read` on the session's server; advertised only when set.
  /// Returns the raw `ReadResourceResult` JSON.
  final Future<Map<String, Object?>> Function(String uri)? readResource;

  /// Asked once per view when the resource declares network domains;
  /// returns the [CspOrigin.source] strings the user allowed (persist per
  /// server + hash). Null: no network, ever.
  final Future<Set<String>> Function(McpAppNetworkRequest request)? requestNetworkAccess;

  final void Function(McpAppLogEntry entry)? onLog;
  final LinkPolicy linkPolicy;

  bool get supportsMessages => confirmMessage != null && insertMessage != null;
  bool get supportsLinks => confirmOpenLink != null && launchLink != null;
}
