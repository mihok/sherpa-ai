/// The host side of the MCP Apps View protocol (R03 §6, §7, §10).
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import 'channel.dart';
import 'policy/csp.dart';
import 'policy/limits.dart';
import 'protocol/host_context.dart';
import 'protocol/jsonrpc.dart';
import 'protocol/shell_envelope.dart';
import 'protocol/tool_result_json.dart';
import 'types.dart';

/// Lifecycle of one bridge (one shell page, one View document).
enum McpAppBridgeState {
  /// Waiting for the shell's `ready`.
  starting,

  /// `load` sent; the View is loading or handshaking.
  loading,

  /// The View sent `ui/notifications/initialized`.
  initialized,

  /// `ui/resource-teardown` sent / the iframe was removed.
  tornDown,

  /// The shell refused to run or reported an error.
  failed,
}

/// Something the controller or app may react to.
@immutable
sealed class McpAppEvent {
  const McpAppEvent();
}

/// The View's iframe fired `load` (static Views never initialize).
final class McpAppFrameLoaded extends McpAppEvent {
  const McpAppFrameLoaded();
}

final class McpAppInitialized extends McpAppEvent {
  const McpAppInitialized(this.identity);
  final McpAppIdentity identity;
}

/// `ui/notifications/size-changed` (validated; missing axes = unchanged).
final class McpAppSizeChanged extends McpAppEvent {
  const McpAppSizeChanged({this.width, this.height});
  final double? width;
  final double? height;
}

/// The View asked to be closed (Draft `request-teardown`).
final class McpAppTeardownRequested extends McpAppEvent {
  const McpAppTeardownRequested();
}

final class McpAppFailed extends McpAppEvent {
  const McpAppFailed(this.reason);
  final String reason;
}

/// Messages the shell or the bridge dropped (diagnostics; also logged).
final class McpAppDropped extends McpAppEvent {
  const McpAppDropped(this.reason, {this.count = 1});
  final String reason;
  final int count;
}

/// Speaks the View protocol over a [McpAppChannel] and enforces the
/// host's rules:
///
/// - **Nothing reaches the View before `initialized`**; tool input/result
///   are buffered and delivered in spec order (partial* → input → result |
///   cancelled), each at most once.
/// - **`tools/call`**: only tools of the session's own server
///   ([McpAppHostCallbacks.lookupTool]) whose visibility includes `app`,
///   only after [McpAppHostCallbacks.approveToolCall]; the View's `_meta`
///   is never forwarded; progress is relayed with the View's token.
/// - **`ui/open-link`** and plain `<a href>` activations: [LinkPolicy],
///   then the user's confirmation, then launch. Never navigated in place.
/// - **`ui/message`**: text only, size-capped, inserted only after the
///   user confirms. One confirmation prompt at a time.
/// - Every message is size-checked and shape-validated; requests are
///   rate-limited; unknown methods get -32601.
final class McpAppsBridge {
  McpAppsBridge({
    required McpAppChannel channel,
    required this.session,
    required this.callbacks,
    required this.csp,
    McpAppHostContext hostContext = const McpAppHostContext(),
    this.limits = const McpAppLimits(),
    this.hostInfo = const {'name': 'sherpa', 'version': '0.1.0'},
    Clock clock = const SystemClock(),
  })  : _channel = channel,
        _clock = clock,
        _hostContext = hostContext.copyWith(toolInfo: session.toolInfo),
        _requests = TokenBucket(capacity: limits.requestBurst, perSecond: limits.requestsPerSecond, clock: clock) {
    _sub = _channel.fromShell.listen(_onShell);
  }

  final McpAppSession session;
  final McpAppHostCallbacks callbacks;
  final McpAppCsp csp;
  final McpAppLimits limits;
  final Map<String, Object?> hostInfo;

  final McpAppChannel _channel;
  final Clock _clock;
  final TokenBucket _requests;
  late final StreamSubscription<String> _sub;
  final StreamController<McpAppEvent> _events = StreamController<McpAppEvent>.broadcast();

  McpAppBridgeState _state = McpAppBridgeState.starting;
  McpAppHostContext _hostContext;
  Map<String, Object?>? _sentContext;
  McpAppIdentity? _identity;
  List<McpAppDisplayMode> _appDisplayModes = const [];
  bool _initializeAnswered = false;

  // Tool data, delivered in order once initialized.
  Map<String, Object?>? _partial;
  Map<String, Object?>? _input;
  Map<String, Object?>? _result;
  String? _cancelledReason;
  bool _inputSent = false;
  bool _resultSent = false;

  final Map<String, CancellationToken> _inflight = {};
  bool _prompting = false;
  int _hostIds = 0;
  final Map<String, Completer<void>> _pendingHost = {};
  String? _shellTheme;
  double? _lastWidth;
  double? _lastHeight;
  DateTime? _logWindow;
  int _logCount = 0;

  /// Called by the controller for `ui/request-display-mode`; returns the
  /// mode actually in effect. Without it the bridge keeps the current mode.
  Future<McpAppDisplayMode> Function(McpAppDisplayMode requested)? onRequestDisplayMode;

  McpAppBridgeState get state => _state;
  Stream<McpAppEvent> get events => _events.stream;
  McpAppHostContext get hostContext => _hostContext;

  /// Who the View says it is (after `ui/initialize`).
  McpAppIdentity get identity =>
      _identity ?? McpAppIdentity(serverId: session.serverId, serverName: session.serverName);

  /// Display modes the View declared in `ui/initialize`.
  List<McpAppDisplayMode> get appDisplayModes => _appDisplayModes;

  bool get _closed => _state == McpAppBridgeState.tornDown || _state == McpAppBridgeState.failed;

  // ------------------------------------------------------------ tool data

  /// Streaming arguments; only the latest is kept, and none after
  /// [sendToolInput].
  void sendToolInputPartial(Map<String, Object?> arguments) {
    if (_input != null) return;
    _partial = arguments;
    if (_state == McpAppBridgeState.initialized) {
      _notify(McpAppMethods.toolInputPartial, {'arguments': arguments});
      _partial = null;
    }
  }

  /// The complete arguments, at most once.
  void sendToolInput(Map<String, Object?> arguments) {
    if (_input != null) return;
    _input = arguments;
    _flush();
  }

  /// The tool's result, at most once (after the input).
  void sendToolResult(ToolResult result) => _setResult(callToolResultJson(result));

  /// The same, from a stored transcript part.
  void sendToolResultPart(ToolResultPart part) => _setResult(callToolResultFromPart(part));

  /// The call was cancelled (user stop, error, …); instead of a result.
  void sendToolCancelled(String reason) {
    if (_result != null || _cancelledReason != null) return;
    _cancelledReason = reason.isEmpty ? 'cancelled' : reason;
    _flush();
  }

  void _setResult(Map<String, Object?> json) {
    if (_result != null || _cancelledReason != null) return;
    _result = json;
    _flush();
  }

  void _flush() {
    if (_state != McpAppBridgeState.initialized) return;
    if (!_inputSent) {
      if (_input == null) {
        if (_partial != null) {
          _notify(McpAppMethods.toolInputPartial, {'arguments': _partial});
          _partial = null;
        }
        return; // tool-input is required before tool-result
      }
      _partial = null;
      _inputSent = true;
      _notify(McpAppMethods.toolInput, {'arguments': _input});
    }
    if (_resultSent) return;
    if (_result != null) {
      _resultSent = true;
      _notify(McpAppMethods.toolResult, _result);
    } else if (_cancelledReason != null) {
      _resultSent = true;
      _notify(McpAppMethods.toolCancelled, {'reason': _cancelledReason});
    }
  }

  /// Updates the host context; after `initialized` the changed keys go to
  /// the View as `ui/notifications/host-context-changed`.
  void updateHostContext(McpAppHostContext next) {
    _hostContext = next.copyWith(toolInfo: session.toolInfo);
    final theme = next.theme?.name;
    if (theme != null &&
        theme != _shellTheme &&
        (_state == McpAppBridgeState.loading || _state == McpAppBridgeState.initialized)) {
      _shellTheme = theme;
      _channel.toShell(ShellCommand.context(theme: theme));
    }
    if (_state != McpAppBridgeState.initialized) return;
    final json = _hostContext.toJson();
    final changed = McpAppHostContext.diff(_sentContext ?? const {}, json);
    _sentContext = json;
    if (changed.isNotEmpty) _notify(McpAppMethods.hostContextChanged, changed);
  }

  // ------------------------------------------------------------- teardown

  /// Sends `ui/resource-teardown` (when initialized), waits up to
  /// [McpAppLimits.teardownTimeout] for the answer, removes the iframe and
  /// cancels the View's in-flight calls. Idempotent.
  Future<void> teardown() async {
    if (_closed) return;
    final wasInitialized = _state == McpAppBridgeState.initialized;
    _state = McpAppBridgeState.tornDown;
    if (wasInitialized) {
      final id = 'h${++_hostIds}';
      final done = Completer<void>();
      _pendingHost[id] = done;
      _post(Rpc.request(id, McpAppMethods.resourceTeardown));
      try {
        await done.future.timeout(limits.teardownTimeout);
      } on TimeoutException {
        // SHOULD wait, not MUST: destroy anyway.
      }
      _pendingHost.remove(id);
    }
    _channel.toShell(ShellCommand.teardown());
    _cancelAll('view closed');
  }

  /// [teardown], then closes the channel and the event stream.
  Future<void> dispose() async {
    await teardown();
    // Not awaited: a cancel() future may complete in the root zone only.
    unawaited(_sub.cancel());
    await _channel.close();
    await _events.close();
  }

  void _cancelAll(String reason) {
    for (final t in _inflight.values) {
      t.cancel(reason);
    }
    _inflight.clear();
  }

  void _fail(String reason) {
    if (_closed) return;
    _state = McpAppBridgeState.failed;
    _cancelAll(reason);
    _emit(McpAppFailed(reason));
  }

  // ---------------------------------------------------------- shell input

  void _onShell(String raw) {
    if (_closed && _pendingHost.isEmpty) return;
    // The shell already capped the View message; native capped the string.
    if (raw.length > limits.effectiveMaxMessageBytes + 256) {
      _emit(const McpAppDropped('oversized'));
      return;
    }
    final event = ShellEvent.decode(raw);
    switch (event) {
      case null:
        _emit(const McpAppDropped('malformed shell envelope'));
      case ShellReady(:final version, :final cspOk):
        if (_state != McpAppBridgeState.starting) return; // a second ready is ignored
        if (version != shellProtocolVersion) return _fail('shell protocol $version unsupported');
        if (!cspOk) return _fail('shell has no valid Content-Security-Policy');
        _state = McpAppBridgeState.loading;
        _shellTheme = _hostContext.theme?.name;
        _channel.toShell(ShellCommand.load(
          html: session.resource.html,
          limits: limits.toShellJson(),
          theme: _hostContext.theme?.name,
          title: 'Content from ${session.serverName}',
        ));
      case ShellFrameLoaded():
        _emit(const McpAppFrameLoaded());
      case final ShellStats st:
        final n = st.forged + st.malformed + st.oversized + st.rateLimited;
        if (n > 0) {
          _emit(McpAppDropped(
            'shell dropped: forged ${st.forged}, malformed ${st.malformed}, '
            'oversized ${st.oversized}, rate-limited ${st.rateLimited}',
            count: n,
          ));
        }
      case ShellError(:final reason):
        _fail('shell: $reason');
      case ShellViewMessage(:final message):
        _onView(message);
    }
  }

  void _onView(Map<String, Object?> raw) {
    if (_state == McpAppBridgeState.starting || _state == McpAppBridgeState.failed) return;
    final m = ViewMessage.parse(raw);
    switch (m) {
      case null:
        _emit(const McpAppDropped('malformed JSON-RPC'));
      case final ViewResponse res:
        final id = res.id;
        final done = id is String ? _pendingHost[id] : null;
        if (done != null && !done.isCompleted) done.complete();
      case final ViewNotification n:
        if (_state == McpAppBridgeState.tornDown) return;
        _onNotification(n);
      case final ViewRequest req:
        if (_state == McpAppBridgeState.tornDown) return;
        if (!_requests.take()) {
          _emit(const McpAppDropped('rate-limited request'));
          return _error(req.id, RpcCode.hostError, 'Rate limit exceeded');
        }
        unawaited(_onRequest(req));
    }
  }

  // --------------------------------------------------------- notifications

  void _onNotification(ViewNotification n) {
    switch (n.method) {
      case McpAppMethods.initialized:
        if (!_initializeAnswered || _state != McpAppBridgeState.loading) return;
        _state = McpAppBridgeState.initialized;
        _sentContext = _hostContext.toJson();
        _emit(McpAppInitialized(identity));
        _flush();
      case McpAppMethods.sizeChanged:
        final w = _dimension(n.params['width']) ?? _lastWidth;
        final h = _dimension(n.params['height']) ?? _lastHeight;
        if (w == _lastWidth && h == _lastHeight) return;
        _lastWidth = w;
        _lastHeight = h;
        _emit(McpAppSizeChanged(width: w, height: h));
      case McpAppMethods.requestTeardown:
        _emit(const McpAppTeardownRequested());
      case McpAppMethods.log:
        _log(n.params);
      case McpAppMethods.cancelled:
        final id = n.params['requestId'];
        _inflight.remove(_key(id))?.cancel('cancelled by the app');
      case McpAppMethods.linkActivated:
        if (!_requests.take()) return _emit(const McpAppDropped('rate-limited link'));
        unawaited(_openLink(n.params['url'], fromAnchor: true));
      default:
        // Unknown notifications are ignored (JSON-RPC: no response).
        break;
    }
  }

  static double? _dimension(Object? v) {
    if (v is! num || !v.isFinite || v < 0 || v > 100000) return null;
    return v.toDouble();
  }

  void _log(Map<String, Object?> p) {
    final now = _clock.now();
    if (_logWindow == null || now.difference(_logWindow!) >= const Duration(minutes: 1)) {
      _logWindow = now;
      _logCount = 0;
    }
    if (++_logCount > limits.maxLogsPerMinute) return;
    final level = p['level'] is String ? _clip(p['level']! as String, 16) : 'info';
    final logger = p['logger'] is String ? _clip(p['logger']! as String, 64) : null;
    String data;
    try {
      data = p['data'] is String ? p['data']! as String : jsonEncode(p['data']);
    } on Object {
      data = '<unencodable>';
    }
    callbacks.onLog?.call(McpAppLogEntry(level: level, logger: logger, data: _clip(data, limits.maxLogChars)));
  }

  // -------------------------------------------------------------- requests

  Future<void> _onRequest(ViewRequest r) async {
    try {
      switch (r.method) {
        case McpAppMethods.initialize:
          return _initialize(r);
        case McpAppMethods.ping:
          return _respond(r.id, const {});
      }
      if (!_initializeAnswered) return _error(r.id, RpcCode.invalidRequest, 'Send ui/initialize first');
      switch (r.method) {
        case McpAppMethods.toolsCall:
          return await _toolsCall(r);
        case McpAppMethods.openLink:
          final ok = await _openLink(r.params['url']);
          return _respond(r.id, ok ? const {} : const {'isError': true});
        case McpAppMethods.message:
          return await _message(r);
        case McpAppMethods.updateModelContext when callbacks.updateModelContext != null:
          return _modelContext(r);
        case McpAppMethods.requestDisplayMode:
          return await _displayMode(r);
        case McpAppMethods.resourcesRead when callbacks.readResource != null:
          return await _readResource(r);
        default:
          // ui/download-file, sampling/createMessage, resources/list,
          // prompts/list, app tools (Draft) …: not offered.
          return _error(r.id, RpcCode.methodNotFound, 'Method not found: ${_clip(r.method, 64)}');
      }
    } on Object catch (e) {
      if (e is CancelledException) return; // no response for cancelled requests
      _error(r.id, RpcCode.internalError, 'Host error');
    }
  }

  void _initialize(ViewRequest r) {
    final p = r.params;
    final info = p['appInfo'] is Map ? (p['appInfo']! as Map).cast<String, Object?>() : const <String, Object?>{};
    _identity = McpAppIdentity(
      serverId: session.serverId,
      serverName: session.serverName,
      appName: info['name'] is String ? _clip(_plain(info['name']! as String), 80) : null,
      appVersion: info['version'] is String ? _clip(_plain(info['version']! as String), 32) : null,
    );
    final caps = p['appCapabilities'];
    final modes = caps is Map ? caps['availableDisplayModes'] : null;
    _appDisplayModes = [
      if (modes is List)
        for (final m in modes)
          ?McpAppDisplayMode.tryParse(m),
    ];
    final v = p['protocolVersion'];
    if (_state == McpAppBridgeState.initialized) {
      // A reloaded View document (or a StrictMode double mount): it gets
      // the tool data again after its next `initialized`.
      _state = McpAppBridgeState.loading;
      _inputSent = false;
      _resultSent = false;
    }
    _initializeAnswered = true;
    _respond(r.id, {
      'protocolVersion': v is String && supportedProtocolVersions.contains(v) ? v : latestProtocolVersion,
      'hostInfo': hostInfo,
      'hostCapabilities': _hostCapabilities(),
      'hostContext': _hostContext.toJson(),
    });
  }

  Map<String, Object?> _hostCapabilities() => {
        if (callbacks.supportsLinks) 'openLinks': const <String, Object?>{},
        'serverTools': const <String, Object?>{},
        if (callbacks.readResource != null) 'serverResources': const <String, Object?>{},
        'logging': const <String, Object?>{},
        if (callbacks.updateModelContext != null) 'updateModelContext': const {'text': <String, Object?>{}},
        if (callbacks.supportsMessages) 'message': const {'text': <String, Object?>{}},
        'sandbox': {
          // None granted in this version (R03 §13.4).
          'permissions': const <String, Object?>{},
          'csp': csp.granted.toSandboxCsp(),
        },
      };

  Future<void> _toolsCall(ViewRequest r) async {
    final name = r.params['name'];
    final args = r.params['arguments'] ?? const <String, Object?>{};
    if (name is! String || name.isEmpty || name.length > 128 || args is! Map) {
      return _error(r.id, RpcCode.invalidParams, 'tools/call needs a name and object arguments');
    }
    if (_inflight.length >= limits.maxConcurrentToolCalls) {
      return _error(r.id, RpcCode.hostError, 'Too many concurrent tool calls');
    }
    final key = _key(r.id);
    if (_inflight.containsKey(key)) return _error(r.id, RpcCode.invalidRequest, 'Duplicate request id');
    final token = CancellationToken();
    _inflight[key] = token;
    try {
      McpAppTool? tool;
      try {
        tool = await callbacks.lookupTool(name);
      } on Object {
        tool = null;
      }
      if (token.isCancelled || _closed) return;
      // Visibility is enforced HERE, whatever the lookup returned: a tool
      // whose visibility lacks "app" (including []) is never callable.
      if (tool == null || tool.name != name || !tool.appCallable) {
        return _error(r.id, RpcCode.invalidParams, 'Tool not callable from this app');
      }
      final arguments = args.cast<String, Object?>();
      bool approved;
      try {
        approved = await callbacks.approveToolCall(
            McpAppToolCallRequest(identity: identity, tool: tool, arguments: arguments));
      } on Object {
        approved = false;
      }
      if (token.isCancelled || _closed) return;
      if (!approved) {
        return _respond(r.id, const {
          'content': [
            {'type': 'text', 'text': 'The user did not allow this action.'},
          ],
          'isError': true,
        });
      }
      final progressToken = _progressToken(r.params['_meta']);
      final result = await callbacks
          .callTool(McpAppToolCall(
            serverId: session.serverId,
            tool: tool,
            arguments: arguments,
            cancel: token,
            timeout: limits.toolCallTimeout,
            onProgress: progressToken == null
                ? null
                : (p) {
                    if (token.isCancelled || _closed) return;
                    _notify(McpAppMethods.progress, {
                      'progressToken': progressToken,
                      'progress': p.progress,
                      'total': ?p.total,
                      'message': ?p.message,
                    });
                  },
          ))
          .timeout(limits.toolCallTimeout, onTimeout: () {
        token.cancel('timed out');
        throw TimeoutException('tool call');
      });
      if (token.isCancelled || _closed) return;
      _respond(r.id, callToolResultJson(result));
    } on TimeoutException {
      if (!_closed) _error(r.id, RpcCode.hostError, 'Tool call timed out');
    } on CancelledException {
      // The View cancelled or the view closed: no response.
    } on Object {
      if (!_closed && !token.isCancelled) _error(r.id, RpcCode.internalError, 'Tool call failed');
    } finally {
      _inflight.remove(key);
    }
  }

  static Object? _progressToken(Object? meta) {
    if (meta is! Map) return null;
    final t = meta['progressToken'];
    if (t is String && t.isNotEmpty && t.length <= 128) return t;
    if (t is int) return t;
    return null;
  }

  /// Shared by `ui/open-link` and anchor activations. True only when the
  /// user confirmed and the launch succeeded.
  Future<bool> _openLink(Object? url, {bool fromAnchor = false}) async {
    if (!callbacks.supportsLinks) return false;
    final check = callbacks.linkPolicy.check(url);
    if (!check.isAllowed) {
      _emit(McpAppDropped('link refused (${check.refusal!.name})'));
      return false;
    }
    if (_prompting) return false;
    _prompting = true;
    try {
      final req = McpAppLinkRequest(identity: identity, uri: check.uri!, fromAnchor: fromAnchor);
      final confirmed = await _safeBool(() => callbacks.confirmOpenLink!(req));
      if (!confirmed || _closed) return false;
      return await _safeBool(() => callbacks.launchLink!(check.uri!));
    } finally {
      _prompting = false;
    }
  }

  Future<void> _message(ViewRequest r) async {
    if (!callbacks.supportsMessages) return _error(r.id, RpcCode.methodNotFound, 'Method not found: ui/message');
    if (r.params['role'] != 'user') return _error(r.id, RpcCode.invalidParams, 'role must be "user"');
    final rawContent = r.params['content'];
    // Spec prose shows one block, the SDK sends an array: accept both.
    final blocks = rawContent is List ? rawContent : (rawContent is Map ? [rawContent] : const <Object?>[]);
    final content = <Map<String, Object?>>[];
    final texts = <String>[];
    for (final b in blocks) {
      if (b is! Map || b['type'] != 'text' || b['text'] is! String) {
        return _error(r.id, RpcCode.invalidParams, 'Only text content is supported');
      }
      final t = b['text']! as String;
      texts.add(t);
      content.add({'type': 'text', 'text': t});
    }
    final text = texts.join('\n\n');
    if (text.trim().isEmpty) return _error(r.id, RpcCode.invalidParams, 'Empty message');
    if (text.length > limits.maxMessageTextChars) return _error(r.id, RpcCode.invalidParams, 'Message too long');
    if (_prompting) return _respond(r.id, const {'isError': true});
    _prompting = true;
    try {
      final req = McpAppMessageRequest(identity: identity, text: text, content: content);
      final confirmed = await _safeBool(() => callbacks.confirmMessage!(req));
      if (_closed) return;
      if (!confirmed) return _respond(r.id, const {'isError': true});
      await callbacks.insertMessage!(req);
      _respond(r.id, const {});
    } finally {
      _prompting = false;
    }
  }

  void _modelContext(ViewRequest r) {
    final String encoded;
    try {
      encoded = jsonEncode(r.params);
    } on Object {
      return _error(r.id, RpcCode.invalidParams, 'Unencodable model context');
    }
    if (utf8.encode(encoded).length > limits.maxModelContextBytes) {
      return _error(r.id, RpcCode.invalidParams, 'Model context too large');
    }
    final c = r.params['content'];
    final s = r.params['structuredContent'];
    if ((c != null && c is! List) || (s != null && s is! Map)) {
      return _error(r.id, RpcCode.invalidParams, 'Invalid model context');
    }
    final content = <Map<String, Object?>>[
      if (c is List)
        for (final b in c)
          if (b is Map && b['type'] == 'text' && b['text'] is String) {'type': 'text', 'text': b['text']},
    ];
    callbacks.updateModelContext!(McpAppModelContext(
      identity: identity,
      content: content,
      structuredContent: s is Map ? s.cast<String, Object?>() : null,
    ));
    _respond(r.id, const {});
  }

  Future<void> _displayMode(ViewRequest r) async {
    final requested = McpAppDisplayMode.tryParse(r.params['mode']);
    final current = _hostContext.displayMode;
    if (requested == null) return _error(r.id, RpcCode.invalidParams, 'Unknown display mode');
    var actual = current;
    // MUST NOT switch to a mode the View did not declare, nor one the host
    // does not offer.
    if (requested != current &&
        _appDisplayModes.contains(requested) &&
        _hostContext.availableDisplayModes.contains(requested) &&
        onRequestDisplayMode != null) {
      try {
        actual = await onRequestDisplayMode!(requested);
      } on Object {
        actual = current;
      }
    }
    if (_closed) return;
    _respond(r.id, {'mode': actual.name});
    if (actual != _hostContext.displayMode) updateHostContext(_hostContext.copyWith(displayMode: actual));
  }

  Future<void> _readResource(ViewRequest r) async {
    final uri = r.params['uri'];
    if (uri is! String || uri.isEmpty || uri.length > 2048) {
      return _error(r.id, RpcCode.invalidParams, 'resources/read needs a uri');
    }
    final Map<String, Object?> result;
    try {
      result = await callbacks.readResource!(uri);
    } on Object {
      if (!_closed) _error(r.id, RpcCode.internalError, 'Resource read failed');
      return;
    }
    if (_closed) return;
    _respond(r.id, result);
  }

  // --------------------------------------------------------------- output

  void _notify(String method, Map<String, Object?>? params) => _post(Rpc.notification(method, params));

  void _respond(Object id, Map<String, Object?> result) {
    if (_state == McpAppBridgeState.failed) return;
    _post(Rpc.result(id, result));
  }

  void _error(Object id, int code, String message) {
    if (_state == McpAppBridgeState.failed) return;
    _post(Rpc.error(id, code, message));
  }

  void _post(Map<String, Object?> message) {
    if (_state == McpAppBridgeState.starting || _state == McpAppBridgeState.failed) return;
    _channel.toShell(ShellCommand.post(message));
  }

  void _emit(McpAppEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  static Future<bool> _safeBool(Future<bool> Function() f) async {
    try {
      return await f();
    } on Object {
      return false;
    }
  }

  static String _key(Object? id) => id is String ? 's:$id' : 'n:$id';

  static String _clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';

  /// Strips control and bidi characters from View-supplied display text.
  static String _plain(String s) =>
      s.replaceAll(RegExp(r'[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2066-\u2069]'), '').trim();
}
