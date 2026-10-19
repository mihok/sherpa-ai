/// Sandboxed MCP Apps host for Sherpa (`io.modelcontextprotocol/ui`,
/// stable spec 2026-01-26).
///
/// - [McpAppView] / [McpAppController]: the widget and its state (consent,
///   native view, sizing, inline ↔ fullscreen).
/// - [McpAppsBridge]: the View protocol, testable without a WebView over an
///   injectable [McpAppChannel].
/// - [McpAppCsp], [DeclaredDomains], [CspOrigin], [LinkPolicy]: policy.
/// - [McpAppResource]: a validated `ui://` resource.
///
/// See `package:sherpa_webview/mcp.dart` for the sherpa_mcp adapter and
/// `package:sherpa_webview/testing.dart` for fakes.
library;

export 'src/bridge.dart';
export 'src/channel.dart';
export 'src/platform/messages.pigeon.dart' show NativeViewEventKind;
export 'src/platform/platform.dart';
export 'src/policy/csp.dart';
export 'src/policy/limits.dart';
export 'src/policy/link_policy.dart';
export 'src/protocol/host_context.dart';
export 'src/protocol/jsonrpc.dart' show McpAppMethods, RpcCode, latestProtocolVersion, supportedProtocolVersions;
export 'src/protocol/shell_envelope.dart' show shellProtocolVersion;
export 'src/protocol/tool_result_json.dart';
export 'src/resource.dart';
export 'src/types.dart';
export 'src/widget/controller.dart';
export 'src/widget/styles.dart';
export 'src/widget/view.dart';
