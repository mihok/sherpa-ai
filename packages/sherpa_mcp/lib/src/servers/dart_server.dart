/// A tiny MCP server framework for on-device servers written in Dart.
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart' show CancellationToken, CancelledException, JsonMap, ToolAnnotations, compact;

import '../protocol/content.dart';
import '../protocol/json_read.dart';
import '../protocol/jsonrpc.dart';
import '../protocol/primitives.dart';
import '../protocol/types.dart';
import '../protocol/versions.dart';
import '../router/schema_normalizer.dart';
import '../transport/in_process.dart';

/// What a tool handler gets besides its arguments.
final class DartToolContext {
  DartToolContext._(this._session, this.cancel, this.meta, this._progressToken, this._logLevel);

  final DartMcpSession _session;

  /// Fires when the client sends `notifications/cancelled` (or disconnects).
  final CancellationToken cancel;

  /// The request's `_meta` (protocol keys included).
  final JsonMap meta;
  final Object? _progressToken;
  final McpLogLevel? _logLevel;

  /// Sherpa's advisory idempotency key (`<session>:<callId>`), if sent: a
  /// handler with side effects can use it to dedupe a re-sent call.
  String? get idempotencyKey => asString(meta[McpMetaKeys.idempotencyKey]);

  /// Sends `notifications/progress` when the client asked for progress.
  /// [progress] must increase between calls (MCP rule).
  void progress(double progress, {double? total, String? message}) {
    final token = _progressToken;
    if (token == null || cancel.isCancelled) return;
    _session._notify('notifications/progress', {
      'progressToken': token,
      'progress': progress,
      'total': ?total,
      'message': ?message,
    });
  }

  /// Sends a request-scoped `notifications/message`, only when the client
  /// asked for this level or more severe (2026-07-28: no level, no logs).
  void log(McpLogLevel level, Object? data, {String? logger}) {
    final min = _logLevel;
    if (min == null || level.index < min.index) return;
    _session._notify('notifications/message', {'level': level.name, 'data': data, 'logger': ?logger});
  }
}

/// The result of a tool handler.
@immutable
final class DartToolResult {
  const DartToolResult({this.content = const [], this.structuredContent, this.isError = false});

  factory DartToolResult.text(String text, {Object? structuredContent}) =>
      DartToolResult(content: [McpTextContent(text)], structuredContent: structuredContent);

  /// [value] as `structuredContent`, serialized into a text block too (the
  /// spec's backward-compatibility SHOULD).
  factory DartToolResult.json(Object? value, {String? text}) =>
      DartToolResult(content: [McpTextContent(text ?? jsonEncode(value))], structuredContent: value);

  /// A tool-level failure the model should see and correct.
  factory DartToolResult.error(String message) => DartToolResult(content: [McpTextContent(message)], isError: true);

  final List<McpContent> content;
  final Object? structuredContent;
  final bool isError;

  JsonMap toJson() => {
        'resultType': 'complete',
        'content': [for (final c in content) c.toJson()],
        if (structuredContent != null) 'structuredContent': structuredContent,
        if (isError) 'isError': true,
      };
}

typedef DartToolHandler = Future<DartToolResult> Function(JsonMap arguments, DartToolContext context);

/// One tool: its definition and handler.
@immutable
final class DartMcpTool {
  const DartMcpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.handler,
    this.title,
    this.outputSchema,
    this.annotations = const ToolAnnotations(),
    this.meta,
    this.validateInput = true,
  });

  final String name;
  final String? title;
  final String description;

  /// MUST have an object root (`type: object`).
  final JsonMap inputSchema;
  final JsonMap? outputSchema;

  /// Declare these honestly: the host trusts them only if the user trusts
  /// this server, but a trusted server's hints drive auto-approval.
  final ToolAnnotations annotations;

  /// `_meta`, e.g. MCP Apps `{'ui': {'resourceUri': 'ui://…', 'visibility': ['app']}}`.
  final JsonMap? meta;
  final DartToolHandler handler;

  /// Validate (and safely coerce) arguments against [inputSchema] before
  /// the handler runs; failures become `isError` results.
  final bool validateInput;

  JsonMap toJson() {
    final a = annotations.toJson();
    return compact({
      'name': name,
      'title': title,
      'description': description,
      'inputSchema': inputSchema,
      'outputSchema': outputSchema,
      'annotations': a.isEmpty ? null : a,
      '_meta': meta,
    });
  }
}

/// A readable resource.
@immutable
final class DartMcpResource {
  const DartMcpResource({
    required this.uri,
    required this.name,
    required this.read,
    this.title,
    this.description,
    this.mimeType,
  });

  final String uri;
  final String name;
  final String? title;
  final String? description;
  final String? mimeType;
  final Future<List<McpResourceContents>> Function() read;

  JsonMap toJson() =>
      compact({'uri': uri, 'name': name, 'title': title, 'description': description, 'mimeType': mimeType});
}

/// A prompt (user-controlled template).
@immutable
final class DartMcpPrompt {
  const DartMcpPrompt({
    required this.name,
    required this.get,
    this.title,
    this.description,
    this.arguments = const [],
  });

  final String name;
  final String? title;
  final String? description;
  final List<McpPromptArgument> arguments;
  final Future<List<McpPromptMessage>> Function(Map<String, String> arguments) get;

  JsonMap toJson() => compact({
        'name': name,
        'title': title,
        'description': description,
        'arguments': arguments.isEmpty
            ? null
            : [
                for (final a in arguments)
                  compact({
                    'name': a.name,
                    'title': a.title,
                    'description': a.description,
                    'required': a.required ? true : null,
                  }),
              ],
      });
}

/// Thrown by a handler to answer with a JSON-RPC error instead of an
/// `isError` result (protocol errors only: unknown names, bad requests).
final class DartMcpError implements Exception {
  const DartMcpError(this.code, this.message, {this.data});

  final int code;
  final String message;
  final Object? data;

  @override
  String toString() => 'DartMcpError($code, $message)';
}

/// An MCP server implemented in Dart and served over an in-process
/// [McpMessageChannel] (`InProcessTransport.pair`).
///
/// Why a server and not plain `LocalTool`s: built-in tools then take the
/// SAME path as remote ones — era probe, `_meta` envelope, cancellation,
/// progress, list-changed notifications, hygiene, namespacing, approvals —
/// so the protocol code is exercised on every device and the built-ins get
/// no privileged shortcut (R01 rec. 11).
///
/// Speaks the 2026-07-28 (stateless) era: `server/discover`,
/// `tools/list|call`, `resources/list|templates/list|read`,
/// `prompts/list|get`, `subscriptions/listen` (list-changed and
/// resource-updated notifications), `notifications/cancelled` and
/// progress. `initialize` is answered with "method not found", which is
/// how a legacy-only client learns it cannot use this server.
final class DartMcpServer {
  DartMcpServer({
    required this.info,
    this.instructions,
    Iterable<DartMcpTool> tools = const [],
    Iterable<DartMcpResource> resources = const [],
    Iterable<DartMcpPrompt> prompts = const [],
    this.listTtl = Duration.zero,
  }) {
    _setTools(tools);
    _resources = [...resources];
    _prompts = [...prompts];
  }

  final McpImplementation info;

  /// Server instructions (system-prompt material for the host).
  final String? instructions;

  /// `ttlMs` on list results (0: the client re-lists every time, which is
  /// free in-process).
  final Duration listTtl;

  List<DartMcpTool> _tools = const [];
  Map<String, DartMcpTool> _toolsByName = const {};
  List<DartMcpResource> _resources = const [];
  List<DartMcpPrompt> _prompts = const [];
  final Set<DartMcpSession> _sessions = {};

  List<DartMcpTool> get tools => List.unmodifiable(_tools);

  List<DartMcpResource> get resources => List.unmodifiable(_resources);

  List<DartMcpPrompt> get prompts => List.unmodifiable(_prompts);

  int get sessionCount => _sessions.length;

  void _setTools(Iterable<DartMcpTool> tools) {
    final list = [...tools];
    final byName = <String, DartMcpTool>{};
    for (final t in list) {
      if (t.inputSchema['type'] != 'object') throw ArgumentError.value(t.name, 'tools', 'inputSchema root must be an object');
      if (byName.containsKey(t.name)) throw ArgumentError.value(t.name, 'tools', 'duplicate tool name');
      byName[t.name] = t;
    }
    _tools = list;
    _toolsByName = byName;
  }

  /// Replaces the tool list and notifies listening clients.
  void setTools(Iterable<DartMcpTool> tools) {
    _setTools(tools);
    for (final s in _sessions) {
      s._listChanged('toolsListChanged', 'notifications/tools/list_changed');
    }
  }

  void setResources(Iterable<DartMcpResource> resources) {
    _resources = [...resources];
    for (final s in _sessions) {
      s._listChanged('resourcesListChanged', 'notifications/resources/list_changed');
    }
  }

  void setPrompts(Iterable<DartMcpPrompt> prompts) {
    _prompts = [...prompts];
    for (final s in _sessions) {
      s._listChanged('promptsListChanged', 'notifications/prompts/list_changed');
    }
  }

  /// `notifications/resources/updated` to clients subscribed to [uri].
  void notifyResourceUpdated(String uri) {
    for (final s in _sessions) {
      s._resourceUpdated(uri);
    }
  }

  /// Serves one client connection on [channel].
  DartMcpSession serve(McpMessageChannel channel) {
    final s = DartMcpSession._(this, channel);
    _sessions.add(s);
    return s;
  }

  /// Ends every session.
  Future<void> close() async {
    for (final s in List.of(_sessions)) {
      await s.close();
    }
  }

  JsonMap _capabilities() => {
        'tools': {'listChanged': true},
        if (_resources.isNotEmpty) 'resources': {'listChanged': true, 'subscribe': true},
        if (_prompts.isNotEmpty) 'prompts': {'listChanged': true},
      };
}

final class _Listen {
  _Listen(this.id, this.filter);

  final JsonRpcId id;
  final JsonMap filter;

  bool wants(String key) => filter[key] == true;

  bool subscribed(String uri) => stringList(filter['resourceSubscriptions']).contains(uri);
}

/// One client connection of a [DartMcpServer].
final class DartMcpSession {
  DartMcpSession._(this.server, this._channel) {
    _sub = _channel.messages.listen(_onMessage, onDone: _onDone, onError: (Object _) {});
  }

  final DartMcpServer server;
  final McpMessageChannel _channel;
  late final StreamSubscription<String> _sub;
  final Map<JsonRpcId, CancellationToken> _inFlight = {};
  final Map<JsonRpcId, _Listen> _listens = {};
  final Completer<void> _done = Completer<void>();
  bool _closed = false;

  /// Completes when the client went away or [close] was called.
  Future<void> get done => _done.future;

  bool get isClosed => _closed;

  void _send(JsonRpcMessage m) {
    if (!_closed) _channel.send(m.encode());
  }

  void _notify(String method, JsonMap params) => _send(JsonRpcNotification(method, params));

  void _listChanged(String key, String method) {
    for (final l in _listens.values) {
      if (l.wants(key)) {
        _notify(method, {
          '_meta': {McpMetaKeys.subscriptionId: l.id.toJson()},
        });
      }
    }
  }

  void _resourceUpdated(String uri) {
    for (final l in _listens.values) {
      if (l.subscribed(uri)) {
        _notify('notifications/resources/updated', {
          'uri': uri,
          '_meta': {McpMetaKeys.subscriptionId: l.id.toJson()},
        });
      }
    }
  }

  void _onMessage(String text) {
    final JsonRpcMessage m;
    try {
      m = JsonRpcMessage.decode(text);
    } on JsonRpcFormatException catch (e) {
      _send(JsonRpcErrorResponse(null, JsonRpcError(JsonRpcError.parseError, e.message)));
      return;
    }
    switch (m) {
      case JsonRpcNotification(:final method, :final params):
        if (method == 'notifications/cancelled') {
          final id = JsonRpcId.tryParse(params?['requestId']);
          if (id == null) return;
          _inFlight[id]?.cancel(asString(params?['reason']) ?? 'cancelled by the client');
          _listens.remove(id);
        }
      case final JsonRpcRequest r:
        unawaited(_handle(r));
      case JsonRpcResponse():
        break; // a 2026-07-28 server sends no requests, so expects no responses
    }
  }

  Future<void> _handle(JsonRpcRequest r) async {
    final params = r.params ?? const <String, Object?>{};
    final meta = asMap(params['_meta']) ?? const <String, Object?>{};
    final version = asString(meta[McpMetaKeys.protocolVersion]);
    if (version != null && !McpVersions.modern.contains(version)) {
      _send(JsonRpcErrorResponse(
        r.id,
        JsonRpcError(JsonRpcError.unsupportedProtocolVersion, 'Unsupported protocol version',
            data: {'supported': McpVersions.modern, 'requested': version}),
      ));
      return;
    }
    if (r.method == 'subscriptions/listen') {
      _listen(r, params);
      return;
    }
    final token = CancellationToken();
    _inFlight[r.id] = token;
    try {
      final result = await switch (r.method) {
        'server/discover' => Future.value(_discover()),
        'tools/list' => Future.value(_list('tools', [for (final t in server._tools) t.toJson()])),
        'tools/call' => _callTool(params, meta, token),
        'resources/list' => Future.value(_list('resources', [for (final x in server._resources) x.toJson()])),
        'resources/templates/list' => Future.value(_list('resourceTemplates', const [])),
        'resources/read' => _readResource(params),
        'prompts/list' => Future.value(_list('prompts', [for (final p in server._prompts) p.toJson()])),
        'prompts/get' => _getPrompt(params),
        'ping' => Future.value(const <String, Object?>{}),
        _ => throw DartMcpError(JsonRpcError.methodNotFound, 'Method not found: ${r.method}'),
      };
      if (!token.isCancelled) _send(JsonRpcResult(r.id, result));
    } on DartMcpError catch (e) {
      if (!token.isCancelled) _send(JsonRpcErrorResponse(r.id, JsonRpcError(e.code, e.message, data: e.data)));
    } on CancelledException {
      // Cancelled requests get no response (the client ignores late ones).
    } on Object {
      if (!token.isCancelled) {
        _send(JsonRpcErrorResponse(r.id, const JsonRpcError(JsonRpcError.internalError, 'Internal error')));
      }
    } finally {
      _inFlight.remove(r.id);
    }
  }

  JsonMap _discover() => {
        'resultType': 'complete',
        'supportedVersions': McpVersions.modern,
        'capabilities': server._capabilities(),
        if (server.instructions != null) 'instructions': server.instructions,
        'ttlMs': server.listTtl.inMilliseconds,
        'cacheScope': 'private',
        '_meta': {McpMetaKeys.serverInfo: server.info.toJson()},
      };

  JsonMap _list(String field, List<JsonMap> items) => {
        'resultType': 'complete',
        field: items,
        'ttlMs': server.listTtl.inMilliseconds,
        'cacheScope': 'private',
      };

  void _listen(JsonRpcRequest r, JsonMap params) {
    final wanted = asMap(params['notifications']) ?? const <String, Object?>{};
    final caps = server._capabilities();
    final honoured = <String, Object?>{
      if (wanted['toolsListChanged'] == true) 'toolsListChanged': true,
      if (wanted['promptsListChanged'] == true && caps.containsKey('prompts')) 'promptsListChanged': true,
      if (wanted['resourcesListChanged'] == true && caps.containsKey('resources')) 'resourcesListChanged': true,
      if (caps.containsKey('resources') && stringList(wanted['resourceSubscriptions']).isNotEmpty)
        'resourceSubscriptions': [
          for (final u in stringList(wanted['resourceSubscriptions']))
            if (server._resources.any((x) => x.uri == u)) u,
        ],
    };
    _listens[r.id] = _Listen(r.id, honoured);
    _notify('notifications/subscriptions/acknowledged', {
      '_meta': {McpMetaKeys.subscriptionId: r.id.toJson()},
      'notifications': honoured,
    });
    // No response: the stream stays open until the client cancels it.
  }

  Future<JsonMap> _callTool(JsonMap params, JsonMap meta, CancellationToken token) async {
    final name = asString(params['name']);
    final tool = name == null ? null : server._toolsByName[name];
    if (tool == null) throw DartMcpError(JsonRpcError.invalidParams, 'Unknown tool: ${name ?? '(none)'}');
    final rawArgs = params['arguments'];
    if (rawArgs != null && rawArgs is! Map) throw const DartMcpError(JsonRpcError.invalidParams, 'arguments must be an object');
    var args = asMap(rawArgs) ?? const <String, Object?>{};
    if (tool.validateInput) {
      final v = validateArguments(tool.inputSchema, args);
      if (!v.isValid) return DartToolResult.error('Invalid arguments: ${v.errors.join('; ')}').toJson();
      args = v.value;
    }
    final ctx = DartToolContext._(
      this,
      token,
      meta,
      meta[McpMetaKeys.progressToken],
      McpLogLevel.tryParse(meta[McpMetaKeys.logLevel]),
    );
    try {
      final result = await tool.handler(args, ctx);
      token.throwIfCancelled();
      return result.toJson();
    } on DartMcpError {
      rethrow;
    } on CancelledException {
      rethrow;
    } on Object catch (e) {
      // A business failure: tell the model (isError), not the protocol.
      return DartToolResult.error('${tool.name} failed: ${e is Exception ? _message(e) : 'internal error'}').toJson();
    }
  }

  static String _message(Exception e) {
    final s = e.toString();
    const prefixes = ['Exception: ', 'FormatException: ', 'StateError: ', 'ArgumentError: '];
    for (final p in prefixes) {
      if (s.startsWith(p)) return s.substring(p.length);
    }
    return s;
  }

  Future<JsonMap> _readResource(JsonMap params) async {
    final uri = asString(params['uri']);
    final r = uri == null ? null : server._resources.where((x) => x.uri == uri).firstOrNull;
    if (r == null) throw DartMcpError(JsonRpcError.invalidParams, 'Resource not found', data: {'uri': uri});
    final contents = await r.read();
    return {
      'resultType': 'complete',
      'contents': [for (final c in contents) c.toJson()],
      'ttlMs': 0,
      'cacheScope': 'private',
    };
  }

  Future<JsonMap> _getPrompt(JsonMap params) async {
    final name = asString(params['name']);
    final p = name == null ? null : server._prompts.where((x) => x.name == name).firstOrNull;
    if (p == null) throw DartMcpError(JsonRpcError.invalidParams, 'Unknown prompt: ${name ?? '(none)'}');
    final raw = asMap(params['arguments']) ?? const <String, Object?>{};
    final args = {for (final e in raw.entries) if (e.value is String) e.key: e.value! as String};
    for (final a in p.arguments) {
      if (a.required && !args.containsKey(a.name)) {
        throw DartMcpError(JsonRpcError.invalidParams, 'Missing required argument: ${a.name}');
      }
    }
    final messages = await p.get(args);
    return {
      'resultType': 'complete',
      if (p.description != null) 'description': p.description,
      'messages': [
        for (final m in messages) {'role': m.role, 'content': m.content.toJson()},
      ],
    };
  }

  void _onDone() {
    _closed = true;
    for (final t in _inFlight.values) {
      t.cancel('client disconnected');
    }
    _inFlight.clear();
    _listens.clear();
    server._sessions.remove(this);
    if (!_done.isCompleted) _done.complete();
  }

  /// Ends this session (the client sees `McpConnectionLost`).
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sub.cancel();
    await _channel.close();
    _onDone();
  }
}
