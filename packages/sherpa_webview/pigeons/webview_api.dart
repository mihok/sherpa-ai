// Pigeon definition for sherpa_webview (platform-channel mode).
//
// Regenerate from packages/sherpa_webview:
//   dart run pigeon --input pigeons/webview_api.dart
//
// Asynchronous methods use @asyncCallback: callback-style Kotlin and Swift,
// so the plugin needs neither kotlinx.coroutines nor Swift concurrency.
//
// Design rules:
// - Native code is a dumb, checked pipe. It loads the bundled shell page
//   under the virtual origin https://mcp-view.sherpa.invalid with the CSP
//   Dart built, applies the WebView hardening, and relays strings between
//   the shell's MAIN FRAME (origin + frame checked on every message) and
//   Dart. Every protocol decision (visibility, approvals, links, limits) is
//   Dart, unit-tested on the host.
// - The platform view itself is created by Flutter (AndroidView /
//   UiKitView, view type `io.github.mihok.sherpa_webview/mcp_app`) with
//   creation params {viewId}; `createView` must be called first and carries
//   the configuration.
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/src/platform/messages.pigeon.dart',
  dartPackageName: 'sherpa_webview',
  kotlinOut: 'android/src/main/kotlin/io/github/mihok/sherpa_webview/Messages.g.kt',
  kotlinOptions: KotlinOptions(package: 'io.github.mihok.sherpa_webview', errorClassName: 'SherpaWebviewError'),
  swiftOut: 'ios/sherpa_webview/Sources/sherpa_webview/Messages.g.swift',
  swiftOptions: SwiftOptions(errorClassName: 'SherpaWebviewError'),
))
/// Configuration of one native MCP App view.
class NativeViewConfig {
  NativeViewConfig({
    required this.viewId,
    required this.csp,
    required this.allowedOrigins,
    required this.profileKey,
    required this.debuggable,
    required this.maxMessageChars,
  });

  /// Dart-allocated id; also the platform view's creation param.
  int viewId;

  /// The policy substituted into the shell's CSP meta tag. Native checks
  /// its character set and falls back to the no-network default otherwise.
  String csp;

  /// Consented `scheme://[*.]host[:port]` origins. Empty: every network
  /// load is blocked natively too (Android `blockNetworkLoads`, iOS
  /// block-all content rule).
  List<String> allowedOrigins;

  /// Stable per-server key (hex): Android WebView profile name suffix, so
  /// cookies / cache / storage are separated per server and can be wiped.
  String profileKey;

  /// Allow remote debugging of this view (debug builds only).
  bool debuggable;

  /// Strings from the shell longer than this are dropped natively.
  int maxMessageChars;
}

enum NativeViewEventKind {
  /// The shell could not be loaded (asset missing, compile failure, …).
  loadFailed,

  /// The renderer died (Android `onRenderProcessGone`, iOS WebContent
  /// termination). The view is dead; Dart shows an error and may recreate.
  renderProcessGone,

  /// A navigation was cancelled (detail: the URL, truncated).
  navigationBlocked,

  /// A permission request (camera, microphone, geolocation, …) was denied.
  permissionDenied,

  /// A bridge message failed the origin / main-frame / size check.
  bridgeRejected,
}

class NativeViewEvent {
  NativeViewEvent({required this.kind, this.detail});

  NativeViewEventKind kind;
  String? detail;
}

class NativeSupport {
  NativeSupport({required this.supported, this.reason});

  /// The WebView exists and has every feature the sandbox relies on
  /// (Android: WEB_MESSAGE_LISTENER).
  bool supported;
  String? reason;
}

@HostApi()
abstract class McpAppHostApi {
  NativeSupport support();

  /// Registers [config]; the platform view with the same id picks it up.
  void createView(NativeViewConfig config);

  /// Sends one shell envelope (JSON string) to the view's shell.
  void postToShell(int viewId, String message);

  /// Destroys the WebView (if any) and forgets the config. Idempotent.
  void disposeView(int viewId);

  /// Wipes the per-server WebView data (Android profile cookies, storage,
  /// cache; deletes the profile when unused). iOS data stores are
  /// non-persistent per view, so this is a no-op there.
  @asyncCallback
  bool clearProfile(String profileKey);
}

@FlutterApi()
abstract class McpAppFlutterApi {
  // Callback style in Kotlin and Swift (no coroutines / Swift concurrency
  // in the plugin, like sherpa_platform).

  /// One string from the shell's main frame (already origin-checked).
  @asyncCallback
  void onShellMessage(int viewId, String message);

  @asyncCallback
  void onViewEvent(int viewId, NativeViewEvent event);
}
