/// Owns one MCP App view: consent, native view, bridge, tool data, sizing
/// and display mode. The [McpAppView] widget renders it.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../bridge.dart';
import '../platform/messages.pigeon.dart' show NativeViewEventKind;
import '../platform/platform.dart';
import '../policy/csp.dart';
import '../policy/limits.dart';
import '../protocol/host_context.dart';
import '../types.dart';

/// What [McpAppView] shows.
enum McpAppViewStatus {
  /// [McpAppController.start] not called yet.
  idle,

  /// Waiting for the user's network decision.
  consent,

  /// Creating the native view.
  starting,

  /// The WebView exists; the View is loading.
  loading,

  /// The View's frame loaded (or it initialized).
  ready,

  /// The native view was released (scrolled away, [McpAppController.suspend]).
  suspended,

  /// Failed; [McpAppController.errorMessage] says why.
  error,

  /// Disposed.
  closed,
}

/// Controller for one View. Feed it the tool data as it arrives
/// ([setToolInput], [setToolResult], …): it is buffered and replayed to
/// every (re)created native view, so a View can be torn down off-screen and
/// re-rendered from history.
class McpAppController extends ChangeNotifier {
  McpAppController({
    required this.session,
    required this.callbacks,
    McpAppPlatform? platform,
    this.limits = const McpAppLimits(),
    McpAppHostContext hostContext = const McpAppHostContext(),
    Set<String>? grantedOrigins,
    this.debuggable = false,
    this.hostInfo = const {'name': 'sherpa', 'version': '0.1.0'},
    this.loadTimeout = const Duration(seconds: 20),
    Clock clock = const SystemClock(),
  })  : _platform = platform,
        _baseContext = hostContext,
        _grantedOrigins = grantedOrigins,
        _clock = clock;

  final McpAppSession session;
  final McpAppHostCallbacks callbacks;
  final McpAppLimits limits;
  final bool debuggable;
  final Map<String, Object?> hostInfo;

  /// Error when the View's frame has not loaded by then.
  final Duration loadTimeout;

  McpAppPlatform? _platform;
  McpAppPlatform get platform => _platform ??= PigeonMcpAppPlatform.instance;
  final Clock _clock;

  McpAppHostContext _baseContext;
  McpAppTheme? _theme;
  String? _locale;
  McpAppDisplayMode _displayMode = McpAppDisplayMode.inline;
  McpAppContainerDimensions? _dimensions;
  McpAppInsets? _insets;

  Set<String>? _grantedOrigins;
  McpAppCsp? _csp;
  McpAppViewStatus _status = McpAppViewStatus.idle;
  String? _error;
  McpAppNativeView? _native;
  McpAppsBridge? _bridge;
  StreamSubscription<McpAppEvent>? _bridgeSub;
  StreamSubscription<McpAppNativeEvent>? _nativeSub;
  Timer? _loadTimer;
  int _generation = 0;
  double? _contentHeight;
  int _surfaces = 0;
  final StreamController<McpAppEvent> _events = StreamController<McpAppEvent>.broadcast();

  // Tool data, replayed to every bridge.
  Map<String, Object?>? _partial;
  Map<String, Object?>? _input;
  ToolResult? _result;
  String? _cancelled;

  /// Installed by the mounted inline [McpAppView]: presents / dismisses the
  /// fullscreen route. Without it the View stays inline.
  Future<bool> Function(McpAppDisplayMode mode)? displayModePresenter;

  /// Moves the one platform view between the inline slot and the
  /// fullscreen route without recreating the WebView.
  final GlobalKey surfaceKey = GlobalKey(debugLabel: 'mcp-app-surface');

  /// Live native views per server profile, so the profile is wiped when the
  /// last one closes ("clear storage per server").
  static final Map<String, int> _liveByProfile = {};

  McpAppViewStatus get status => _status;
  String? get errorMessage => _error;
  McpAppCsp? get csp => _csp;
  McpAppsBridge? get bridge => _bridge;
  McpAppNativeView? get nativeView => _native;
  McpAppDisplayMode get displayMode => _displayMode;

  /// Height the View asked for (`size-changed`), before clamping.
  double? get contentHeight => _contentHeight;

  /// Bridge events (re-emitted across recreated views).
  Stream<McpAppEvent> get events => _events.stream;

  String get profileKey => McpAppNativeViewConfig.profileKeyFor(session.serverId);

  bool get _closed => _status == McpAppViewStatus.closed;

  /// Origins the user allowed (after consent), for persistence.
  Set<String>? get grantedOrigins => _grantedOrigins;

  /// The effective host context.
  McpAppHostContext get hostContext => _baseContext.copyWith(
        theme: _theme,
        locale: _locale,
        displayMode: _displayMode,
        containerDimensions: _dimensions,
        safeAreaInsets: _insets ?? McpAppInsets.zero,
      );

  // ------------------------------------------------------------ tool data

  void setToolInputPartial(Map<String, Object?> arguments) {
    if (_input != null) return;
    _partial = arguments;
    _bridge?.sendToolInputPartial(arguments);
  }

  void setToolInput(Map<String, Object?> arguments) {
    if (_input != null) return;
    _input = arguments;
    _bridge?.sendToolInput(arguments);
  }

  void setToolResult(ToolResult result) {
    if (_result != null || _cancelled != null) return;
    _result = result;
    _bridge?.sendToolResult(result);
  }

  void setToolResultPart(ToolResultPart part) => setToolResult(ToolResult(
        content: part.content,
        structured: part.structured,
        isError: part.isError,
        uiResourceUri: part.uiResourceUri,
        meta: part.meta,
      ));

  void setToolCancelled(String reason) {
    if (_result != null || _cancelled != null) return;
    _cancelled = reason;
    _bridge?.sendToolCancelled(reason);
  }

  void _replay(McpAppsBridge b) {
    if (_partial != null && _input == null) b.sendToolInputPartial(_partial!);
    if (_input != null) b.sendToolInput(_input!);
    if (_result != null) b.sendToolResult(_result!);
    if (_cancelled != null) b.sendToolCancelled(_cancelled!);
  }

  // ------------------------------------------------------------- context

  /// Replaces the app-provided part of the host context (styles, time zone,
  /// user agent, …). Theme, locale, display mode, dimensions and insets are
  /// filled by the widget.
  set baseHostContext(McpAppHostContext value) {
    _baseContext = value;
    _pushContext();
  }

  /// Called by the widget from its BuildContext.
  void updateEnvironment({McpAppTheme? theme, String? locale}) {
    if (theme == _theme && locale == _locale) return;
    _theme = theme;
    _locale = locale;
    _pushContext();
  }

  /// Called by the widget after layout.
  void reportLayout({required McpAppContainerDimensions dimensions, McpAppInsets insets = McpAppInsets.zero}) {
    if (_sameDims(dimensions, _dimensions) && _sameInsets(insets, _insets)) return;
    _dimensions = dimensions;
    _insets = insets;
    _pushContext();
  }

  static bool _sameDims(McpAppContainerDimensions a, McpAppContainerDimensions? b) =>
      b != null && a.width == b.width && a.maxWidth == b.maxWidth && a.height == b.height && a.maxHeight == b.maxHeight;

  static bool _sameInsets(McpAppInsets a, McpAppInsets? b) =>
      b != null && a.top == b.top && a.right == b.right && a.bottom == b.bottom && a.left == b.left;

  void _pushContext() => _bridge?.updateHostContext(hostContext);

  // --------------------------------------------------------- display mode

  /// Switches display mode (expand button, or the View's
  /// `ui/request-display-mode`). Returns the mode in effect.
  Future<McpAppDisplayMode> requestDisplayMode(McpAppDisplayMode mode) async {
    if (mode == _displayMode || _closed) return _displayMode;
    if (!hostContext.availableDisplayModes.contains(mode)) return _displayMode;
    final presenter = displayModePresenter;
    if (presenter == null) return _displayMode;
    try {
      await presenter(mode);
    } on Object {
      // Stay in the current mode.
    }
    return _displayMode;
  }

  /// Called by the presenter once a mode is (or stops being) on screen.
  void setDisplayMode(McpAppDisplayMode mode) {
    if (mode == _displayMode || _closed) return;
    _displayMode = mode;
    if (mode == McpAppDisplayMode.inline) _insets = McpAppInsets.zero;
    notifyListeners();
    _pushContext();
  }

  // ----------------------------------------------------------- lifecycle

  /// Asks for network consent if needed, creates the native view and the
  /// bridge. Idempotent while running; restarts from [McpAppViewStatus.error]
  /// and [McpAppViewStatus.suspended].
  Future<void> start() async {
    if (_closed) return;
    if (_status != McpAppViewStatus.idle &&
        _status != McpAppViewStatus.suspended &&
        _status != McpAppViewStatus.error) {
      return;
    }
    final gen = ++_generation;
    _error = null;
    if (_csp == null) {
      final declared = session.resource.declared;
      var granted = _grantedOrigins ?? const <String>{};
      if (_grantedOrigins == null && !declared.isEmpty && callbacks.requestNetworkAccess != null) {
        _setStatus(McpAppViewStatus.consent);
        try {
          granted = await callbacks.requestNetworkAccess!(McpAppNetworkRequest(
            serverId: session.serverId,
            serverName: session.serverName,
            resourceUri: session.resource.uri,
            resourceSha256: session.resource.sha256,
            declared: declared,
          ));
        } on Object {
          granted = const {};
        }
        if (gen != _generation || _closed) return;
      }
      _grantedOrigins = granted;
      _csp = McpAppCsp.build(declared.grant(granted));
    }
    _setStatus(McpAppViewStatus.starting);
    final support = await platform.support();
    if (gen != _generation || _closed) return;
    if (!support.supported) return _fail(support.reason ?? 'Interactive content is not supported here.');
    final McpAppNativeView native;
    try {
      native = await platform.createView(McpAppNativeViewConfig(
        csp: _csp!.policy,
        allowedOrigins: _csp!.allowedOrigins,
        profileKey: profileKey,
        debuggable: debuggable,
        maxMessageChars: limits.effectiveMaxMessageBytes + 256,
      ));
    } on Object catch (e) {
      if (gen == _generation) _fail('Could not create the view ($e).');
      return;
    }
    if (gen != _generation || _closed) {
      await native.dispose();
      return;
    }
    _liveByProfile[profileKey] = (_liveByProfile[profileKey] ?? 0) + 1;
    _native = native;
    final bridge = McpAppsBridge(
      channel: native.channel,
      session: session,
      callbacks: callbacks,
      csp: _csp!,
      hostContext: hostContext,
      limits: limits,
      hostInfo: hostInfo,
      clock: _clock,
    )..onRequestDisplayMode = requestDisplayMode;
    _bridge = bridge;
    _replay(bridge);
    _bridgeSub = bridge.events.listen((e) => _onBridgeEvent(gen, e));
    _nativeSub = native.events.listen((e) => _onNativeEvent(gen, e));
    _loadTimer = Timer(loadTimeout, () {
      if (gen == _generation && _status == McpAppViewStatus.loading) _fail('The interactive view did not load.');
    });
    _setStatus(McpAppViewStatus.loading);
  }

  void _onBridgeEvent(int gen, McpAppEvent e) {
    if (gen != _generation) return;
    switch (e) {
      case McpAppFrameLoaded() || McpAppInitialized():
        _loadTimer?.cancel();
        if (_status == McpAppViewStatus.loading) _setStatus(McpAppViewStatus.ready);
      case McpAppSizeChanged(:final height):
        if (height != null && height != _contentHeight && !_closed) {
          _contentHeight = height;
          notifyListeners();
        }
      case McpAppFailed(:final reason):
        _fail('The interactive view failed ($reason).');
      case McpAppTeardownRequested() || McpAppDropped():
        break;
    }
    if (!_events.isClosed) _events.add(e);
  }

  void _onNativeEvent(int gen, McpAppNativeEvent e) {
    if (gen != _generation) return;
    switch (e.kind) {
      case NativeViewEventKind.renderProcessGone:
        _fail('The interactive view stopped.');
      case NativeViewEventKind.loadFailed:
        _fail('The interactive view could not be loaded${e.detail == null ? '' : ' (${e.detail})'}.');
      case NativeViewEventKind.navigationBlocked ||
            NativeViewEventKind.permissionDenied ||
            NativeViewEventKind.bridgeRejected:
        if (!_events.isClosed) _events.add(McpAppDropped('native: ${e.kind.name}${e.detail == null ? '' : ' ${e.detail}'}'));
    }
  }

  void _fail(String message) {
    if (_closed) return;
    _generation++;
    _error = message;
    unawaited(_release(teardown: false));
    _setStatus(McpAppViewStatus.error);
  }

  /// Retries after an error.
  Future<void> retry() => start();

  /// Sends `ui/resource-teardown`, releases the native view and shows a
  /// placeholder; [start] (or re-attaching the widget) re-renders it from
  /// the stored tool data. Use this for off-screen Views.
  Future<void> suspend() async {
    if (_status != McpAppViewStatus.loading && _status != McpAppViewStatus.ready) return;
    _generation++;
    _setStatus(McpAppViewStatus.suspended);
    await _release(teardown: true);
  }

  Future<void> _release({required bool teardown}) async {
    _loadTimer?.cancel();
    _loadTimer = null;
    final bridge = _bridge;
    final native = _native;
    _bridge = null;
    _native = null;
    // Not awaited: a cancel() future may complete in the root zone only.
    for (final f in [_bridgeSub?.cancel(), _nativeSub?.cancel()].nonNulls) {
      unawaited(f);
    }
    _bridgeSub = null;
    _nativeSub = null;
    if (bridge != null) {
      if (teardown) {
        await bridge.dispose();
      } else {
        unawaited(bridge.dispose());
      }
    }
    if (native != null) {
      await native.dispose();
      final left = (_liveByProfile[profileKey] ?? 1) - 1;
      if (left <= 0) {
        _liveByProfile.remove(profileKey);
        await platform.clearServerData(profileKey);
      } else {
        _liveByProfile[profileKey] = left;
      }
    }
  }

  /// Tears the View down properly (teardown request answered or timed out)
  /// and closes the controller. Prefer awaiting this over [dispose] while
  /// the widget is still on screen.
  Future<void> close() async {
    if (_closed) return;
    _generation++;
    _status = McpAppViewStatus.closed;
    await _release(teardown: true);
    await _events.close();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }

  // ------------------------------------------------------------- surface

  /// The widget's platform-view slot mounted (not called on GlobalKey moves).
  void attachSurface() => _surfaces++;

  /// The slot unmounted: Flutter disposed the platform view, so the WebView
  /// is gone and the bridge is released (no teardown can be delivered).
  void detachSurface() {
    _surfaces = (_surfaces - 1).clamp(0, 1 << 30);
    if (_surfaces == 0 && (_status == McpAppViewStatus.loading || _status == McpAppViewStatus.ready)) {
      _generation++;
      _status = McpAppViewStatus.suspended;
      unawaited(_release(teardown: false));
      // No notifyListeners: called from State.dispose during unmount.
    }
  }

  void _setStatus(McpAppViewStatus s) {
    if (_status == s) return;
    _status = s;
    if (!_closed) notifyListeners();
  }

  @visibleForTesting
  static void resetProfileCountsForTest() => _liveByProfile.clear();
}
