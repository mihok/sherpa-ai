import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:sherpa_core/sherpa_core.dart';

/// A request the fake server received.
final class RecordedRequest {
  RecordedRequest(this.method, this.path, this.query, this.headers, this.body);

  final String method;
  final String path;
  final Map<String, String> query;
  final Map<String, String> headers;
  final String body;

  JsonMap get json => (jsonDecode(body) as Map).cast<String, Object?>();

  @override
  String toString() => '$method $path';
}

/// A real HTTP server on 127.0.0.1 for provider tests: routes are
/// `'METHOD /path'` keys; unknown routes answer 404 JSON.
final class FakeServer {
  FakeServer._(this._server, this._routes) : root = Uri.parse('http://127.0.0.1:${_server.port}');

  static Future<FakeServer> start([Map<String, Handler> routes = const {}]) async {
    late final FakeServer fake;
    final server = await shelf_io.serve((Request r) => fake._handle(r), InternetAddress.loopbackIPv4, 0);
    fake = FakeServer._(server, {...routes});
    return fake;
  }

  final HttpServer _server;
  final Map<String, Handler> _routes;
  final List<RecordedRequest> requests = [];

  /// Stays valid after [close], so tests can point at a dead port.
  final Uri root;

  Uri get v1 => root.replace(path: '/v1');

  void route(String key, Handler handler) => _routes[key] = handler;

  List<RecordedRequest> requestsTo(String path) => requests.where((r) => r.path == path).toList();

  Future<Response> _handle(Request r) async {
    final body = await r.readAsString();
    requests.add(RecordedRequest(r.method, '/${r.url.path}', r.url.queryParameters, r.headers, body));
    final handler = _routes['${r.method} /${r.url.path}'];
    if (handler == null) return jsonResponse({'error': 'not found'}, status: 404);
    // Handlers see the body again (it was consumed for recording).
    return handler(Request(r.method, r.requestedUri, headers: r.headers, body: body, context: r.context));
  }

  Future<void> close() => _server.close(force: true);
}

Response jsonResponse(Object body, {int status = 200, Map<String, String> headers = const {}}) =>
    Response(status, body: jsonEncode(body), headers: {'content-type': 'application/json', ...headers});

/// A streamed SSE response whose chunks the test controls. [onCancel]
/// fires when the server notices the client went away.
final class SseScript {
  SseScript() {
    _controller = StreamController<List<int>>(onCancel: () {
      if (!disconnected.isCompleted) disconnected.complete();
    });
  }

  late final StreamController<List<int>> _controller;

  /// Completes when the client disconnected before the script closed.
  final Completer<void> disconnected = Completer<void>();

  bool get isClosed => _controller.isClosed;

  void send(String text) {
    if (!_controller.isClosed) _controller.add(utf8.encode(text));
  }

  void data(Object json) => send('data: ${json is String ? json : jsonEncode(json)}\n\n');

  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
  }

  Response response({Map<String, String> headers = const {}}) => Response.ok(
        _controller.stream,
        headers: {'content-type': 'text/event-stream', 'cache-control': 'no-cache', ...headers},
        // Flush every chunk immediately instead of buffering the body.
        context: {'shelf.io.buffer_output': false},
      );
}

/// Streams [text] (e.g. a fixture) in [chunkSize]-byte pieces spaced by
/// [delay], as a real server would.
Response sseFromText(String text, {int chunkSize = 64, Duration delay = Duration.zero}) {
  final bytes = utf8.encode(text);
  Stream<List<int>> body() async* {
    for (var i = 0; i < bytes.length; i += chunkSize) {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      yield bytes.sublist(i, i + chunkSize > bytes.length ? bytes.length : i + chunkSize);
    }
  }

  return Response.ok(body(), headers: {'content-type': 'text/event-stream'}, context: {'shelf.io.buffer_output': false});
}
