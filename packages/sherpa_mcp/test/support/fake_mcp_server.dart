/// A real HTTP MCP server on 127.0.0.1 for tests, speaking both eras:
///
/// * 2026-07-28 POST-only Streamable HTTP (validates `MCP-Protocol-Version`,
///   `Mcp-Method`, `Mcp-Name` and `Mcp-Param-*` like a strict server, so a
///   client header bug surfaces as `400 -32020`), MRTR, listen, tasks;
/// * 2025-era Streamable HTTP with sessions, server → client requests over
///   POST SSE streams, a GET stream, `Last-Event-ID` replay, 404 expiry,
///   DELETE;
/// * the 2024-11-05 HTTP+SSE transport at `/sse` + `/messages`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:sherpa_core/sherpa_core.dart' show JsonMap;
import 'package:sherpa_mcp/sherpa_mcp.dart';

/// A request the fake received.
final class Recorded {
  Recorded(this.method, this.path, this.headers, this.body);

  final String method;
  final String path;
  final Map<String, String> headers;
  final String body;

  JsonMap? get json {
    try {
      final j = jsonDecode(body);
      return j is Map ? j.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }

  String? get rpcMethod => json?['method'] as String?;

  JsonMap? get params => (json?['params'] as Map?)?.cast<String, Object?>();

  JsonMap? get meta => (params?['_meta'] as Map?)?.cast<String, Object?>();

  Object? get id => json?['id'];

  @override
  String toString() => '$method $path ${rpcMethod ?? ''}';
}

/// What a tool implementation sees.
final class FakeCall {
  FakeCall._(this.era, this.params, this._out, this._server, this.headers);

  final McpEra era;
  final JsonMap params;
  final _Out _out;
  final FakeMcpServer _server;
  final Map<String, String> headers;

  JsonMap get arguments => (params['arguments'] as Map?)?.cast<String, Object?>() ?? const {};

  JsonMap? get inputResponses => (params['inputResponses'] as Map?)?.cast<String, Object?>();

  Object? get requestState => params['requestState'];

  JsonMap get meta => (params['_meta'] as Map?)?.cast<String, Object?>() ?? const {};

  void progress(num progress, {num? total, String? message}) {
    final token = meta['progressToken'];
    if (token == null) return;
    _out.send({
      'jsonrpc': '2.0',
      'method': 'notifications/progress',
      'params': {'progressToken': token, 'progress': progress, 'total': ?total, 'message': ?message},
    });
  }

  void log(String level, Object data) {
    if (era == McpEra.modern && meta[McpMetaKeys.logLevel] == null) return; // M: only when asked
    _out.send({
      'jsonrpc': '2.0',
      'method': 'notifications/message',
      'params': {'level': level, 'data': data, 'logger': 'fake'},
    });
  }

  /// Legacy only: a server → client request on this request's stream.
  Future<Object?> request(String method, [JsonMap? params]) => _server._serverRequest(_out, method, params);
}

typedef FakeTool = FutureOr<JsonMap> Function(FakeCall call);

abstract interface class _Out {
  void send(JsonMap message);
}

final class _SseOut implements _Out {
  _SseOut(this._c, {this.streamId});

  final StreamController<List<int>> _c;
  final String? streamId;
  final List<(String, String)> events = [];
  var _n = 0;
  bool dropped = false;

  /// Sends a message as an SSE event (with an id when resumable).
  @override
  void send(JsonMap message) {
    final data = jsonEncode(message);
    final id = streamId == null ? null : '$streamId-${++_n}';
    if (id != null) events.add((id, data));
    if (dropped || _c.isClosed) return;
    _c.add(utf8.encode('${id == null ? '' : 'id: $id\n'}data: $data\n\n'));
  }

  void raw(String text) {
    if (!_c.isClosed) _c.add(utf8.encode(text));
  }

  /// No-op for a dropped stream: whoever dropped it owns the controller.
  Future<void> close() async {
    if (!dropped && !_c.isClosed) await _c.close();
  }
}

final class _ListenStream {
  _ListenStream(this.out, this.id, this.filter);

  final _SseOut out;
  final Object? id;
  final JsonMap filter;
}

final class FakeTask {
  FakeTask(this.id);

  final String id;
  String status = 'working';
  JsonMap? result;
  JsonMap? inputRequests;
  JsonMap? receivedInput;
  bool cancelled = false;
  int polls = 0;
}

/// See the library doc.
final class FakeMcpServer {
  FakeMcpServer._(this._server) : root = Uri.parse('http://127.0.0.1:${_server.port}');

  static Future<FakeMcpServer> start() async {
    late final FakeMcpServer fake;
    final server = await shelf_io.serve((Request r) => fake._handle(r), InternetAddress.loopbackIPv4, 0);
    return fake = FakeMcpServer._(server);
  }

  final HttpServer _server;
  final Uri root;
  final List<Recorded> requests = [];

  Uri get url => root.replace(path: '/mcp');

  Uri get sseUrl => root.replace(path: '/sse');

  // ---- configuration ----
  bool modern = true;
  bool legacy = true;
  bool legacyGetStream = true;
  List<String> modernVersions = [McpVersions.firstModern];
  List<String> legacyVersions = McpVersions.legacyStreamable;
  int ttlMs = 60000;
  String cacheScope = 'public';
  int pageSize = 100;
  bool sendSessionId = true;
  JsonMap capabilities = {
    'tools': {'listChanged': true},
    'prompts': {'listChanged': true},
    'resources': {'subscribe': true, 'listChanged': true},
    'logging': <String, Object?>{},
    'completions': <String, Object?>{},
  };

  /// Answer the modern probe/requests with this instead (status, body).
  (int, Object?)? modernOverride;

  /// First-chance hook over every request.
  FutureOr<Response?> Function(Recorded r)? intercept;

  /// Make legacy POST streams drop after a priming event (2025-11-25
  /// polling), so the client must resume with Last-Event-ID.
  bool dropPostStreamsAfterPriming = false;

  List<JsonMap> tools = [
    {
      'name': 'echo',
      'description': 'Echoes its input',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
      },
    },
  ];
  final Map<String, FakeTool> toolImpls = {
    'echo': (c) => {
          'content': [
            {'type': 'text', 'text': '${c.arguments['text']}'},
          ],
        },
  };
  List<JsonMap> resources = [
    {'uri': 'file:///a.txt', 'name': 'a.txt', 'mimeType': 'text/plain'},
  ];
  Map<String, String> resourceTexts = {'file:///a.txt': 'hello'};
  List<JsonMap> prompts = [
    {
      'name': 'greet',
      'arguments': [
        {'name': 'who', 'required': true},
      ],
    },
  ];

  // ---- state ----
  final Map<String, String> _sessions = {}; // id → protocolVersion
  final Map<String, Completer<Object?>> _pendingServerRequests = {};
  final Map<String, _SseOut> _resumable = {};
  final List<_SseOut> _getStreams = [];
  final List<_ListenStream> _listens = [];
  final Map<String, FakeTask> tasks = {};
  final List<String> deletedSessions = [];

  /// Modern tools/call streams the client closed before the server ended them.
  int toolStreamDisconnects = 0;
  final List<String> legacyLogLevels = [];
  final Set<String> legacySubscribed = {};
  int _seq = 0;
  _SseOut? _sseChannel;
  final Map<String, _SseOut> _sseSessions = {};

  List<Recorded> rpc(String method) => requests.where((r) => r.rpcMethod == method).toList();

  int get openListenStreams => _listens.length;

  /// Expire every legacy session (next request gets 404).
  void expireSessions() => _sessions.clear();

  /// Push a notification on legacy GET streams / HTTP+SSE channels.
  void pushLegacy(String method, [JsonMap? params]) {
    final msg = {'jsonrpc': '2.0', 'method': method, 'params': ?params};
    for (final s in _getStreams) {
      s.send(msg);
    }
    for (final s in _sseSessions.values) {
      s.send(msg);
    }
  }

  /// Push a notification on modern listen streams that asked for it.
  void pushModern(String method, {String? uri}) {
    for (final l in _listens) {
      final f = l.filter;
      final wanted = switch (method) {
        'notifications/tools/list_changed' => f['toolsListChanged'] == true,
        'notifications/prompts/list_changed' => f['promptsListChanged'] == true,
        'notifications/resources/list_changed' => f['resourcesListChanged'] == true,
        'notifications/resources/updated' => (f['resourceSubscriptions'] as List? ?? const []).contains(uri),
        _ => true,
      };
      if (!wanted) continue;
      l.out.send({
        'jsonrpc': '2.0',
        'method': method,
        'params': {
          '_meta': {McpMetaKeys.subscriptionId: l.id},
          'uri': ?uri,
        },
      });
    }
  }

  /// Ends every modern listen stream abruptly (transport drop).
  Future<void> dropListenStreams() async {
    for (final l in List.of(_listens)) {
      await l.out.close();
    }
    _listens.clear();
  }

  Future<void> close() => _server.close(force: true);

  // ---- HTTP entry ----

  Future<Response> _handle(Request r) async {
    final body = await r.readAsString();
    final rec = Recorded(r.method, '/${r.url.path}', r.headers, body);
    requests.add(rec);
    final hook = await intercept?.call(rec);
    if (hook != null) return hook;
    final path = '/${r.url.path}';
    if (path == '/sse' && r.method == 'GET') return _openSse();
    if (path == '/messages' && r.method == 'POST') return _sseMessage(r, rec);
    if (path != '/mcp') return Response.notFound('nope');
    switch (r.method) {
      case 'POST':
        final json = rec.json;
        if (json == null) return _rpcError(null, -32700, 'parse error', status: 400);
        final meta = rec.meta;
        final claim = meta?[McpMetaKeys.protocolVersion];
        if (claim != null || McpVersions.isModern(r.headers['mcp-protocol-version'] ?? '')) {
          if (!modern) return _rpcError(json['id'], -32000, 'Bad Request: Server not initialized', status: 400);
          return _modern(rec, json);
        }
        if (!legacy) {
          return _rpcError(json['id'], -32022, 'Unsupported protocol version',
              status: 400, data: {'supported': modernVersions, 'requested': '2025-11-25'});
        }
        return _legacyPost(rec, json);
      case 'GET':
        return _legacyGet(rec);
      case 'DELETE':
        final sid = r.headers['mcp-session-id'];
        if (sid != null && _sessions.remove(sid) != null) deletedSessions.add(sid);
        return Response(sid == null ? 400 : 200);
      default:
        return Response(405);
    }
  }

  Response _json(Object body, {int status = 200, Map<String, String> headers = const {}}) =>
      Response(status, body: jsonEncode(body), headers: {'content-type': 'application/json', ...headers});

  Response _rpcError(Object? id, int code, String message, {int status = 200, Object? data}) => _json(
        {
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': code, 'message': message, 'data': ?data},
        },
        status: status,
      );

  /// Keep-alive interval: like real servers, the fake writes SSE comments
  /// on idle streams, which is also how it notices a client that went away.
  Duration keepAlive = const Duration(milliseconds: 25);

  Response _sse(_SseOut out, StreamController<List<int>> c) {
    final timer = Timer.periodic(keepAlive, (t) {
      if (c.isClosed) {
        t.cancel();
      } else {
        out.raw(':\n\n');
      }
    });
    unawaited(c.done.whenComplete(timer.cancel));
    return Response.ok(
      c.stream,
      headers: {'content-type': 'text/event-stream', 'cache-control': 'no-cache'},
      context: {'shelf.io.buffer_output': false},
    );
  }

  // ---- modern ----

  Response? _validateModern(Recorded rec, JsonMap json) {
    final h = rec.headers;
    final id = json['id'];
    final method = json['method'] as String?;
    final params = (json['params'] as Map?)?.cast<String, Object?>() ?? const {};
    final meta = (params['_meta'] as Map?)?.cast<String, Object?>();
    final version = meta?[McpMetaKeys.protocolVersion];
    if (meta == null || version == null || meta[McpMetaKeys.clientCapabilities] is! Map) {
      return _rpcError(id, -32602, 'missing required _meta', status: 400);
    }
    final accept = h['accept'] ?? '';
    if (!accept.contains('application/json') || !accept.contains('text/event-stream')) {
      return Response(406);
    }
    if (h['mcp-protocol-version'] != version) return _rpcError(id, -32020, 'Header mismatch: version', status: 400);
    if (!modernVersions.contains(version)) {
      return _rpcError(id, -32022, 'Unsupported protocol version',
          status: 400, data: {'supported': [...modernVersions, ...legacyVersions], 'requested': version});
    }
    if (id != null && h['mcp-method'] != method) return _rpcError(id, -32020, 'Header mismatch: Mcp-Method', status: 400);
    final field = McpHeaders.nameSource[method];
    if (field != null) {
      final raw = h['mcp-name'];
      if (raw == null || decodeMcpHeaderValue(raw) != params[field]) {
        return _rpcError(id, -32020, 'Header mismatch: Mcp-Name', status: 400);
      }
    }
    if (method == 'tools/call') {
      final tool = tools.where((t) => t['name'] == params['name']).firstOrNull;
      if (tool != null) {
        final scan = scanMcpHeaderParams((tool['inputSchema']! as Map).cast<String, Object?>());
        final args = (params['arguments'] as Map?)?.cast<String, Object?>();
        for (final p in scan.params) {
          Object? v = args;
          for (final k in p.path) {
            v = v is Map ? v[k] : null;
          }
          final header = h['mcp-param-${p.headerName.toLowerCase()}'];
          if (v == null && header == null) continue;
          final decoded = header == null ? null : decodeMcpHeaderValue(header);
          // Integers compare numerically (42.0 == 42), everything else as text.
          final same = v is num ? num.tryParse(decoded ?? '') == v : decoded == '$v';
          if (!same) {
            return _rpcError(id, -32020, 'Header mismatch: Mcp-Param-${p.headerName}', status: 400);
          }
        }
      }
    }
    return null;
  }

  JsonMap _cache(JsonMap m) => {...m, 'resultType': 'complete', 'ttlMs': ttlMs, 'cacheScope': cacheScope};

  JsonMap _page(List<JsonMap> all, String field, JsonMap params) {
    final cursor = params['cursor'];
    final start = cursor == null ? 0 : int.tryParse('$cursor') ?? -1;
    if (start < 0 || start > all.length) throw const _RpcFault(-32602, 'invalid cursor');
    final end = (start + pageSize).clamp(0, all.length);
    return {field: all.sublist(start, end), if (end < all.length) 'nextCursor': '$end'};
  }

  Future<Response> _modern(Recorded rec, JsonMap json) async {
    final o = modernOverride;
    if (o != null) return o.$2 == null ? Response(o.$1) : _json(o.$2!, status: o.$1);
    final invalid = _validateModern(rec, json);
    if (invalid != null) return invalid;
    final id = json['id'];
    final method = json['method']! as String;
    final params = (json['params'] as Map?)?.cast<String, Object?>() ?? const {};
    if (id == null) return Response(202);
    try {
      switch (method) {
        case 'server/discover':
          return _result(id, _cache({
            'supportedVersions': modernVersions,
            'capabilities': capabilities,
            'instructions': 'Use the echo tool.',
            '_meta': {
              McpMetaKeys.serverInfo: {'name': 'fake', 'version': '1.0'},
            },
          }));
        case 'tools/list':
          return _result(id, _cache(_page(tools, 'tools', params)));
        case 'prompts/list':
          return _result(id, _cache(_page(prompts, 'prompts', params)));
        case 'resources/list':
          return _result(id, _cache(_page(resources, 'resources', params)));
        case 'resources/templates/list':
          return _result(id, _cache({'resourceTemplates': <Object?>[]}));
        case 'resources/read':
          final uri = params['uri'];
          final text = resourceTexts[uri];
          if (text == null) throw _RpcFault(-32602, 'Resource not found', data: {'uri': uri});
          return _result(id, _cache({
            'contents': [
              {'uri': uri, 'mimeType': 'text/plain', 'text': text},
            ],
          }));
        case 'prompts/get':
          return _result(id, {
            'resultType': 'complete',
            'messages': [
              {
                'role': 'user',
                'content': {'type': 'text', 'text': 'Hello ${(params['arguments'] as Map?)?['who']}'},
              },
            ],
          });
        case 'completion/complete':
          final value = (params['argument'] as Map?)?['value'] as String? ?? '';
          return _result(id, {
            'resultType': 'complete',
            'completion': {
              'values': [for (final v in ['alice', 'bob', 'carol']) if (v.startsWith(value)) v],
              'total': 3,
            },
          });
        case 'tools/call':
          return await _modernToolCall(rec, id, params);
        case 'subscriptions/listen':
          return _listen(id, params);
        case 'tasks/get':
          final t = tasks[params['taskId']];
          if (t == null) throw const _RpcFault(-32602, 'no such task');
          t.polls++;
          return _result(id, {
            'resultType': 'complete',
            'taskId': t.id,
            'status': t.status,
            'createdAt': '2026-01-01T00:00:00Z',
            'lastUpdatedAt': '2026-01-01T00:00:00Z',
            'ttlMs': null,
            'pollIntervalMs': 20,
            if (t.status == 'completed') 'result': t.result,
            if (t.status == 'input_required') 'inputRequests': t.inputRequests,
            if (t.status == 'failed') 'error': {'code': -32603, 'message': 'boom'},
          });
        case 'tasks/update':
          final t = tasks[params['taskId']]!;
          t.receivedInput = (params['inputResponses'] as Map?)?.cast<String, Object?>();
          t.status = 'working';
          return _result(id, {'resultType': 'complete'});
        case 'tasks/cancel':
          final t = tasks[params['taskId']]!;
          t
            ..cancelled = true
            ..status = 'cancelled';
          return _result(id, {'resultType': 'complete'});
        default:
          return _rpcError(id, -32601, 'Method not found', status: 404);
      }
    } on _RpcFault catch (f) {
      return _rpcError(id, f.code, f.message, data: f.data);
    }
  }

  Response _result(Object? id, JsonMap result) => _json({'jsonrpc': '2.0', 'id': id, 'result': result});

  Future<Response> _modernToolCall(Recorded rec, Object? id, JsonMap params) async {
    final impl = toolImpls[params['name']];
    if (impl == null) return _rpcError(id, -32602, 'Unknown tool');
    late final StreamController<List<int>> c;
    c = StreamController<List<int>>(onCancel: () {
      if (!c.isClosed) toolStreamDisconnects++;
    });
    final out = _SseOut(c);
    final call = FakeCall._(McpEra.modern, params, out, this, rec.headers);
    unawaited(() async {
      try {
        final r = await impl(call);
        out.send({
          'jsonrpc': '2.0',
          'id': id,
          'result': {'resultType': 'complete', ...r},
        });
      } on _RpcFault catch (f) {
        out.send({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': f.code, 'message': f.message},
        });
      } on _Hang {
        return; // keep the stream open until the client goes away
      }
      await out.close();
    }());
    return _sse(out, c);
  }

  Response _listen(Object? id, JsonMap params) {
    final filter = (params['notifications'] as Map?)?.cast<String, Object?>() ?? const {};
    late final _ListenStream l;
    final c = StreamController<List<int>>(onCancel: () => _listens.remove(l));
    final out = _SseOut(c);
    l = _ListenStream(out, id, filter);
    _listens.add(l);
    out.send({
      'jsonrpc': '2.0',
      'method': 'notifications/subscriptions/acknowledged',
      'params': {
        '_meta': {McpMetaKeys.subscriptionId: id},
        'notifications': filter,
      },
    });
    return _sse(out, c);
  }

  /// Creates a task a tool can return (`return server.createTask(...)`).
  JsonMap createTask({String status = 'working'}) {
    final t = FakeTask('task-${++_seq}')..status = status;
    tasks[t.id] = t;
    return {
      'resultType': 'task',
      'taskId': t.id,
      'status': status,
      'createdAt': '2026-01-01T00:00:00Z',
      'lastUpdatedAt': '2026-01-01T00:00:00Z',
      'ttlMs': 60000,
      'pollIntervalMs': 20,
    };
  }

  // ---- legacy streamable ----

  JsonMap _initResult(String version) => {
        'protocolVersion': version,
        'capabilities': capabilities,
        'serverInfo': {'name': 'fake-legacy', 'version': '1.0'},
        'instructions': 'legacy instructions',
      };

  Future<Response> _legacyPost(Recorded rec, JsonMap json) async {
    final id = json['id'];
    final method = json['method'] as String?;
    final sid = rec.headers['mcp-session-id'];
    if (method == 'initialize') {
      final asked = (json['params'] as Map?)?['protocolVersion'] as String?;
      final version = legacyVersions.contains(asked) ? asked! : legacyVersions.first;
      final newSid = 'sess-${++_seq}';
      _sessions[newSid] = version;
      return _json({'jsonrpc': '2.0', 'id': id, 'result': _initResult(version)},
          headers: {if (sendSessionId) 'mcp-session-id': newSid});
    }
    if (sendSessionId) {
      if (sid == null) return _rpcError(id, -32000, 'Bad Request: Server not initialized', status: 400);
      if (!_sessions.containsKey(sid)) return _rpcError(id, -32001, 'Session not found', status: 404);
    }
    // A client response to a server request, or a notification.
    if (method == null) {
      final c = _pendingServerRequests.remove('${json['id']}');
      c?.complete(json.containsKey('error') ? {'error': json['error']} : json['result']);
      return Response(202);
    }
    if (id == null) return Response(202);
    final params = (json['params'] as Map?)?.cast<String, Object?>() ?? const {};
    if (method == 'tools/call') {
      final c = StreamController<List<int>>();
      final streamId = 'st${++_seq}';
      final out = _SseOut(c, streamId: streamId);
      _resumable[streamId] = out;
      unawaited(_legacyRun(rec, id, method, params, out));
      if (dropPostStreamsAfterPriming) {
        out
          ..raw('id: $streamId-0\nretry: 30\ndata:\n\n')
          ..dropped = true;
        unawaited(c.close());
      }
      return _sse(out, c);
    }
    return _legacyRunJson(rec, id, method, params);
  }

  Future<void> _legacyRun(Recorded rec, Object? id, String method, JsonMap params, _SseOut out) async {
    try {
      final impl = toolImpls[params['name']];
      if (impl == null) throw const _RpcFault(-32602, 'Unknown tool');
      final r = await impl(FakeCall._(McpEra.legacy, params, out, this, rec.headers));
      out.send({'jsonrpc': '2.0', 'id': id, 'result': r});
    } on _RpcFault catch (f) {
      out.send({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': f.code, 'message': f.message, 'data': ?f.data},
      });
    } on _Hang {
      return;
    }
    await out.close();
  }

  Future<Response> _legacyRunJson(Recorded rec, Object? id, String method, JsonMap params) async {
    try {
      final JsonMap result = switch (method) {
        'ping' => {},
        'tools/list' => _page(tools, 'tools', params),
        'prompts/list' => _page(prompts, 'prompts', params),
        'resources/list' => _page(resources, 'resources', params),
        'resources/templates/list' => {'resourceTemplates': <Object?>[]},
        'resources/read' => () {
            final text = resourceTexts[params['uri']];
            if (text == null) throw _RpcFault(-32002, 'Resource not found', data: {'uri': params['uri']});
            return <String, Object?>{
              'contents': [
                {'uri': params['uri'], 'text': text},
              ],
            };
          }(),
        'resources/subscribe' => () {
            legacySubscribed.add('${params['uri']}');
            return <String, Object?>{};
          }(),
        'resources/unsubscribe' => () {
            legacySubscribed.remove('${params['uri']}');
            return <String, Object?>{};
          }(),
        'logging/setLevel' => () {
            legacyLogLevels.add('${params['level']}');
            return <String, Object?>{};
          }(),
        'prompts/get' => {
            'messages': [
              {
                'role': 'user',
                'content': {'type': 'text', 'text': 'Hello ${(params['arguments'] as Map?)?['who']}'},
              },
            ],
          },
        'completion/complete' => {
            'completion': {
              'values': ['alice'],
            },
          },
        _ => throw const _RpcFault(-32601, 'Method not found'),
      };
      return _result(id, result);
    } on _RpcFault catch (f) {
      return _rpcError(id, f.code, f.message, data: f.data);
    }
  }

  Future<Object?> _serverRequest(_Out out, String method, JsonMap? params) {
    final id = 'srv-${++_seq}';
    final c = _pendingServerRequests[id] = Completer<Object?>();
    out.send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': ?params});
    return c.future;
  }

  Future<Response> _legacyGet(Recorded rec) async {
    final sid = rec.headers['mcp-session-id'];
    if (!legacyGetStream) return Response(405);
    if (sendSessionId && (sid == null || !_sessions.containsKey(sid))) {
      return sid == null ? Response(400) : _rpcError(null, -32001, 'Session not found', status: 404);
    }
    final last = rec.headers['last-event-id'];
    final c = StreamController<List<int>>();
    if (last != null) {
      // Replay the rest of the stream that event belonged to, then end.
      final streamId = last.split('-').first;
      final src = _resumable[streamId];
      final out = _SseOut(c);
      if (src == null) return Response(404);
      final n = int.tryParse(last.split('-').last) ?? 0;
      unawaited(() async {
        // Wait until the original handler produced its events.
        for (var i = 0; i < 100 && src.events.length <= n; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        for (final (eid, data) in src.events.skip(n)) {
          out.raw('id: $eid\ndata: $data\n\n');
        }
        await out.close();
      }());
      return _sse(out, c);
    }
    late final _SseOut out;
    final cc = StreamController<List<int>>(onCancel: () => _getStreams.remove(out));
    out = _SseOut(cc);
    _getStreams.add(out);
    out.raw(': connected\n\n');
    return _sse(out, cc);
  }

  // ---- HTTP+SSE (2024-11-05) ----

  Response _openSse() {
    final sid = 'sse-${++_seq}';
    late final _SseOut out;
    final c = StreamController<List<int>>(onCancel: () => _sseSessions.remove(sid));
    out = _SseOut(c);
    _sseSessions[sid] = out;
    _sseChannel = out;
    out.raw('event: endpoint\ndata: /messages?sessionId=$sid\n\n');
    return _sse(out, c);
  }

  Future<Response> _sseMessage(Request r, Recorded rec) async {
    final sid = r.url.queryParameters['sessionId'];
    final out = _sseSessions[sid];
    if (out == null) return Response.notFound('no session');
    final json = rec.json!;
    final id = json['id'];
    final method = json['method'] as String?;
    if (method == null) {
      _pendingServerRequests.remove('${json['id']}')?.complete(json['result']);
      return Response(202, body: 'Accepted');
    }
    if (id == null) return Response(202, body: 'Accepted');
    final params = (json['params'] as Map?)?.cast<String, Object?>() ?? const {};
    unawaited(() async {
      if (method == 'initialize') {
        out.send({'jsonrpc': '2.0', 'id': id, 'result': _initResult('2024-11-05')});
        return;
      }
      if (method == 'tools/call') {
        final impl = toolImpls[params['name']]!;
        final res = await impl(FakeCall._(McpEra.legacy, params, _MessageOut(out), this, rec.headers));
        out.send({'jsonrpc': '2.0', 'id': id, 'result': res});
        return;
      }
      final resp = await _legacyRunJson(rec, id, method, params);
      out.send((jsonDecode(await resp.readAsString()) as Map).cast<String, Object?>());
    }());
    return Response(202, body: 'Accepted');
  }

  /// Closes the HTTP+SSE stream (server restart).
  Future<void> dropSse() async => _sseChannel?.close();
}

/// HTTP+SSE carries server messages as `event: message`.
final class _MessageOut implements _Out {
  _MessageOut(this._out);

  final _SseOut _out;

  @override
  void send(JsonMap message) => _out.send(message);
}

final class _RpcFault implements Exception {
  const _RpcFault(this.code, this.message, {this.data});

  final int code;
  final String message;
  final Object? data;
}

/// Thrown by a tool to leave its stream open (cancellation tests).
final class _Hang implements Exception {
  const _Hang();
}

/// Tool helpers.
Never hang() => throw const _Hang();

Never rpcFault(int code, String message, [Object? data]) => throw _RpcFault(code, message, data: data);
