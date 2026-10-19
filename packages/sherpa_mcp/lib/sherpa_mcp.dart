/// Sherpa's pure-Dart, dual-era MCP client.
///
/// Speaks the stateless 2026-07-28 revision (per-request `_meta`,
/// `server/discover`, multi round-trip requests, `subscriptions/listen`,
/// POST-only Streamable HTTP) and the `initialize` era (2025-03-26 …
/// 2025-11-25 Streamable HTTP with sessions, and the deprecated 2024-11-05
/// HTTP+SSE transport), detecting which one a server speaks and exposing
/// both through one [McpConnection] API. On-device servers connect through
/// [InProcessTransport].
///
/// Start with [McpConnection.connect]. Plug in [InputRequestHandler] for
/// elicitation / sampling / roots (both eras), [McpAuthHook] for OAuth.
library;

export 'src/auth.dart';
export 'src/client/changes.dart';
export 'src/client/connection.dart' show McpConnection, McpResourceSubscription, McpServerDescription;
export 'src/config.dart';
export 'src/era/era.dart';
export 'src/era/handshake.dart' show LegacyHandshake, McpDiscoverResult;
export 'src/era/probe.dart';
export 'src/errors.dart';
export 'src/protocol/content.dart';
export 'src/protocol/headers.dart';
export 'src/protocol/input.dart';
export 'src/protocol/jsonrpc.dart';
export 'src/protocol/primitives.dart' hide withHeaderScan;
export 'src/protocol/tasks.dart';
export 'src/protocol/types.dart';
export 'src/protocol/versions.dart';
export 'src/router/approval.dart';
export 'src/router/bm25.dart';
export 'src/router/budget.dart';
export 'src/router/canonical.dart' show canonicalJson, sha256Hex;
export 'src/router/enablement.dart';
export 'src/router/hygiene.dart';
export 'src/router/injection_scanner.dart';
export 'src/router/mcp_tool_router.dart';
export 'src/router/result_limits.dart';
export 'src/router/schema_normalizer.dart';
export 'src/router/server_manager.dart';
export 'src/router/tool_names.dart';
export 'src/router/tool_pin.dart';
export 'src/servers/dart_server.dart';
export 'src/servers/device_server.dart';
export 'src/servers/memory_server.dart';
export 'src/servers/on_device.dart';
export 'src/transport/http.dart' show McpHttp, McpHttpResponse, parseRpcErrorBody;
export 'src/transport/in_process.dart';
export 'src/transport/legacy_sse.dart';
export 'src/transport/legacy_streamable_http.dart';
export 'src/transport/modern_http.dart';
export 'src/transport/transport.dart' show McpInbound, McpSendOptions, McpTransport;
