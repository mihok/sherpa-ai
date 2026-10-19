/// Native view creation and message routing (Pigeon-backed by default).
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../channel.dart';
import 'messages.pigeon.dart';

/// The platform view type registered by the Android and iOS plugins.
const String mcpAppViewType = 'io.github.mihok.sherpa_webview/mcp_app';

/// The shell's virtual origin (never resolves: `.invalid` is reserved).
const String mcpAppShellOrigin = 'https://mcp-view.sherpa.invalid';

/// Whether this platform can host MCP Apps.
@immutable
final class McpAppPlatformSupport {
  const McpAppPlatformSupport({required this.supported, this.reason});
  final bool supported;
  final String? reason;
}

/// What native code needs for one view.
@immutable
final class McpAppNativeViewConfig {
  const McpAppNativeViewConfig({
    required this.csp,
    required this.allowedOrigins,
    required this.profileKey,
    this.debuggable = false,
    this.maxMessageChars = 1024 * 1024 + 256,
  });

  final String csp;
  final List<String> allowedOrigins;
  final String profileKey;
  final bool debuggable;
  final int maxMessageChars;

  /// A stable, non-reversible per-server key (Android profile name part).
  static String profileKeyFor(String serverId) =>
      crypto.sha256.convert(utf8.encode('sherpa-mcp-app:$serverId')).toString().substring(0, 24);
}

/// Something native code reported about a view.
@immutable
final class McpAppNativeEvent {
  const McpAppNativeEvent(this.kind, [this.detail]);
  final NativeViewEventKind kind;
  final String? detail;

  @override
  String toString() => 'McpAppNativeEvent(${kind.name}${detail == null ? '' : ': $detail'})';
}

/// One native WebView hosting one shell page.
abstract interface class McpAppNativeView {
  int get viewId;
  McpAppChannel get channel;
  Stream<McpAppNativeEvent> get events;

  /// The platform view widget. [gestureRecognizers] decides which gestures
  /// the WebView receives (inline: taps and horizontal drags only, so the
  /// chat keeps vertical scrolling).
  Widget build(BuildContext context, {Set<Factory<OneSequenceGestureRecognizer>> gestureRecognizers});

  /// Destroys the WebView. Idempotent.
  Future<void> dispose();
}

/// Creates native views. Swap in `FakeMcpAppPlatform` (testing.dart) for
/// tests and previews.
abstract interface class McpAppPlatform {
  Future<McpAppPlatformSupport> support();
  Future<McpAppNativeView> createView(McpAppNativeViewConfig config);

  /// Wipes the per-server WebView data (Android profile).
  Future<void> clearServerData(String profileKey);
}

/// The real implementation over the Pigeon API.
final class PigeonMcpAppPlatform implements McpAppPlatform, McpAppFlutterApi {
  PigeonMcpAppPlatform._({McpAppHostApi? api}) : _api = api ?? McpAppHostApi() {
    McpAppFlutterApi.setUp(this);
  }

  /// The process-wide instance (one Flutter API handler per engine).
  static final PigeonMcpAppPlatform instance = PigeonMcpAppPlatform._();

  final McpAppHostApi _api;
  final Map<int, _PigeonNativeView> _views = {};
  int _nextId = 1;

  @override
  Future<McpAppPlatformSupport> support() async {
    if (kIsWeb || (defaultTargetPlatform != TargetPlatform.android && defaultTargetPlatform != TargetPlatform.iOS)) {
      return const McpAppPlatformSupport(supported: false, reason: 'Interactive content needs Android or iOS.');
    }
    try {
      final s = await _api.support();
      return McpAppPlatformSupport(supported: s.supported, reason: s.reason);
    } on PlatformException catch (e) {
      return McpAppPlatformSupport(supported: false, reason: e.message);
    } on MissingPluginException {
      return const McpAppPlatformSupport(supported: false, reason: 'The WebView plugin is not available.');
    }
  }

  @override
  Future<McpAppNativeView> createView(McpAppNativeViewConfig config) async {
    final id = _nextId++;
    final view = _PigeonNativeView(this, id);
    _views[id] = view;
    await _api.createView(NativeViewConfig(
      viewId: id,
      csp: config.csp,
      allowedOrigins: config.allowedOrigins,
      profileKey: config.profileKey,
      debuggable: config.debuggable,
      maxMessageChars: config.maxMessageChars,
    ));
    return view;
  }

  @override
  Future<void> clearServerData(String profileKey) async {
    try {
      await _api.clearProfile(profileKey);
    } on PlatformException {
      // Best effort; the profile is wiped again next time.
    }
  }

  @override
  Future<void> onShellMessage(int viewId, String message) async => _views[viewId]?._channel.deliver(message);

  @override
  Future<void> onViewEvent(int viewId, NativeViewEvent event) async =>
      _views[viewId]?._emit(McpAppNativeEvent(event.kind, event.detail));

  Future<void> _dispose(_PigeonNativeView v) async {
    if (_views.remove(v.viewId) == null) return;
    try {
      await _api.disposeView(v.viewId);
    } on PlatformException {
      // Already gone.
    }
  }
}

final class _PigeonNativeView implements McpAppNativeView {
  _PigeonNativeView(this._platform, this.viewId) {
    _channel = CallbackMcpAppChannel((m) {
      unawaited(_platform._api.postToShell(viewId, m).catchError((Object _) {}));
    });
  }

  final PigeonMcpAppPlatform _platform;
  @override
  final int viewId;
  late final CallbackMcpAppChannel _channel;
  final StreamController<McpAppNativeEvent> _events = StreamController<McpAppNativeEvent>.broadcast();

  @override
  McpAppChannel get channel => _channel;

  @override
  Stream<McpAppNativeEvent> get events => _events.stream;

  void _emit(McpAppNativeEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  @override
  Widget build(BuildContext context, {Set<Factory<OneSequenceGestureRecognizer>> gestureRecognizers = const {}}) {
    final params = <String, Object?>{'viewId': viewId};
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidView(
          viewType: mcpAppViewType,
          creationParams: params,
          creationParamsCodec: const StandardMessageCodec(),
          gestureRecognizers: gestureRecognizers,
          layoutDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
        );
      case TargetPlatform.iOS:
        return UiKitView(
          viewType: mcpAppViewType,
          creationParams: params,
          creationParamsCodec: const StandardMessageCodec(),
          gestureRecognizers: gestureRecognizers,
          layoutDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
        );
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Future<void> dispose() async {
    await _channel.close();
    await _platform._dispose(this);
    await _events.close();
  }
}
