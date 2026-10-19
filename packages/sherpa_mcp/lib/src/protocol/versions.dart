/// Protocol revisions, reserved `_meta` keys and extension identifiers.
library;

/// MCP protocol revisions Sherpa speaks (R01 §0).
///
/// Revisions are `YYYY-MM-DD` strings and compare lexicographically; the
/// stateless era starts at [firstModern] (basic/versioning.md).
abstract final class McpVersions {
  /// The first and current stateless revision.
  static const String firstModern = '2026-07-28';

  /// Modern revisions this client offers, most preferred first.
  static const List<String> modern = [firstModern];

  /// The newest `initialize`-era revision; offered first in `initialize`.
  static const String latestLegacy = '2025-11-25';

  /// `initialize`-era revisions accepted as a server counter-offer on
  /// Streamable HTTP (introduced in 2025-03-26), most preferred first.
  static const List<String> legacyStreamable = ['2025-11-25', '2025-06-18', '2025-03-26'];

  /// Revisions accepted on the deprecated HTTP+SSE transport, whose servers
  /// commonly still negotiate 2024-11-05.
  static const List<String> legacySse = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];

  /// True for 2026-07-28 and later (TS v2 `isModernProtocolVersion`).
  static bool isModern(String version) => version.compareTo(firstModern) >= 0;
}

/// Reserved `_meta` keys (basic/index.md §_meta, §General fields).
abstract final class McpMetaKeys {
  static const String protocolVersion = 'io.modelcontextprotocol/protocolVersion';
  static const String clientCapabilities = 'io.modelcontextprotocol/clientCapabilities';
  static const String clientInfo = 'io.modelcontextprotocol/clientInfo';
  static const String logLevel = 'io.modelcontextprotocol/logLevel';
  static const String serverInfo = 'io.modelcontextprotocol/serverInfo';
  static const String subscriptionId = 'io.modelcontextprotocol/subscriptionId';

  /// Legacy (2025-11-25) tasks: `{taskId}` on task-related messages.
  static const String relatedTask = 'io.modelcontextprotocol/related-task';
  static const String progressToken = 'progressToken';

  /// Advisory idempotency key Sherpa attaches to tool calls (R11 §9.8).
  /// Servers are free to ignore it; it lets cooperating servers dedupe a
  /// call that Sherpa re-issues after a broken stream or process death.
  static const String idempotencyKey = 'ai.sherpa/idempotencyKey';

  /// Whether [key] uses a prefix reserved for the protocol: one whose
  /// second dot-separated label is `modelcontextprotocol` or `mcp`
  /// (`io.modelcontextprotocol/…`, `dev.mcp/…`).
  static bool isReserved(String key) {
    final slash = key.indexOf('/');
    if (slash <= 0) return false;
    final labels = key.substring(0, slash).split('.');
    return labels.length >= 2 && (labels[1] == 'modelcontextprotocol' || labels[1] == 'mcp');
  }
}

/// Extension identifiers (extensions/overview.md).
abstract final class McpExtensionIds {
  /// MCP Apps (R03 §2).
  static const String ui = 'io.modelcontextprotocol/ui';

  /// The MIME type the Apps extension negotiates.
  static const String uiMimeType = 'text/html;profile=mcp-app';

  /// Tasks (R01 §8, ext-tasks schema 2026-07-28).
  static const String tasks = 'io.modelcontextprotocol/tasks';
}
