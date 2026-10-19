import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:sherpa_core/sherpa_core.dart';

/// A request a fake server received.
final class Seen {
  Seen(this.method, this.path, this.query, this.headers, this.body);

  final String method;
  final String path;
  final Map<String, String> query;
  final Map<String, String> headers;
  final String body;

  Map<String, String> get form => Uri.splitQueryString(body);

  JsonMap get json => (jsonDecode(body) as Map).cast<String, Object?>();

  String? get authorization => headers['authorization'];

  @override
  String toString() => '$method $path';
}

/// A real HTTP server on 127.0.0.1. Routes are `'METHOD /path'` keys;
/// unknown routes answer 404.
final class FakeHttp {
  FakeHttp._(this._server) : root = Uri.parse('http://127.0.0.1:${_server.port}');

  static Future<FakeHttp> start() async {
    late final FakeHttp fake;
    final server = await shelf_io.serve((Request r) => fake._handle(r), InternetAddress.loopbackIPv4, 0);
    fake = FakeHttp._(server);
    return fake;
  }

  final HttpServer _server;
  final Uri root;
  final Map<String, FutureOr<Response> Function(Request r, String body)> _routes = {};
  final List<Seen> requests = [];

  String get origin => root.toString();

  void route(String key, FutureOr<Response> Function(Request r, String body) handler) => _routes[key] = handler;

  void unroute(String key) => _routes.remove(key);

  List<Seen> to(String path) => requests.where((r) => r.path == path).toList();

  List<String> get paths => [for (final r in requests) r.path];

  Future<Response> _handle(Request r) async {
    final body = await r.readAsString();
    final path = '/${r.url.path}';
    requests.add(Seen(r.method, path, r.url.queryParameters, r.headers, body));
    final handler = _routes['${r.method} $path'];
    if (handler == null) return json({'error': 'not_found'}, status: 404);
    return handler(r, body);
  }

  Future<void> close() => _server.close(force: true);
}

Response json(Object body, {int status = 200, Map<String, String> headers = const {}}) =>
    Response(status, body: jsonEncode(body), headers: {'content-type': 'application/json', ...headers});
