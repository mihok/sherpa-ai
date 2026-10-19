/// The deprecated 2024-11-05 HTTP+SSE transport
/// (specification/2024-11-05/basic/transports.md; R01 §4.4).
library;

import 'dart:async';
import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart' show CancelledException;

import '../era/era.dart';
import '../errors.dart';
import '../protocol/jsonrpc.dart';
import 'http.dart';
import 'transport.dart';

/// Two endpoints: `GET` the SSE URL; the FIRST event must be
/// `event: endpoint` whose data is the URI to POST messages to (resolved
/// against the SSE URL and required to be same-origin, as the TS client
/// does). Every server message then arrives as `event: message` on the
/// stream; POSTs are answered 202. There is no resumption: when the stream
/// ends the transport is [done] and the connection must be re-established.
final class LegacySseTransport extends MultiplexingTransport {
  LegacySseTransport({required McpHttp http, Uri? sseUrl})
      : _http = http,
        sseUrl = sseUrl ?? http.serverUrl;

  final McpHttp _http;
  final Uri sseUrl;
  final Abort _stream = Abort();
  Uri? _endpoint;

  /// The POST endpoint announced by the server (after [start]).
  Uri? get endpoint => _endpoint;

  @override
  McpTransportKind get kind => McpTransportKind.legacySse;

  @override
  bool get cancelsByClosingStream => false;

  @override
  Future<void> start() async {
    if (_endpoint != null) return;
    final r = await _http.send('GET', sseUrl, headers: const {'accept': 'text/event-stream'}, abort: _stream.future);
    if (!r.ok) throw await _http.statusError(r);
    if (!r.isEventStream) {
      r.discard();
      throw McpProtocolException('GET answered "${r.mediaType}", not an HTTP+SSE event stream');
    }
    final endpoint = Completer<Uri>();
    unawaited(_pump(r, endpoint));
    try {
      _endpoint = await endpoint.future.timeout(_http.timeouts.sseEndpoint, onTimeout: () {
        throw McpTimeoutException('no endpoint event within ${_http.timeouts.sseEndpoint}');
      });
    } on Object {
      _stream.abort();
      markClosed();
      rethrow;
    }
  }

  Future<void> _pump(McpHttpResponse r, Completer<Uri> endpoint) async {
    Object? error;
    try {
      await for (final e in r.events()) {
        if (!endpoint.isCompleted) {
          if (e.event != 'endpoint') {
            if (e.data.isEmpty) continue;
            endpoint.completeError(McpProtocolException('first SSE event was "${e.event}", not "endpoint"'));
            return;
          }
          final uri = Uri.tryParse(e.data.trim());
          final resolved = uri == null ? null : sseUrl.resolveUri(uri);
          if (resolved == null ||
              resolved.scheme != sseUrl.scheme ||
              resolved.host.toLowerCase() != sseUrl.host.toLowerCase() ||
              resolved.port != sseUrl.port) {
            endpoint.completeError(McpProtocolException('endpoint event is not same-origin with the SSE URL'));
            return;
          }
          endpoint.complete(resolved);
          continue;
        }
        if (e.event != 'message' || e.data.isEmpty) continue;
        try {
          for (final m in JsonRpcMessage.decodeBody(e.data, allowBatch: true)) {
            dispatch(m);
          }
        } on JsonRpcFormatException {
          continue;
        }
      }
    } on CancelledException {
      // close()
    } on Object catch (e) {
      error = mapHttpError(e);
    } finally {
      _stream.abort();
      if (!endpoint.isCompleted) {
        endpoint.completeError(error ?? McpProtocolException('SSE stream ended before the endpoint event'));
      }
      markClosed(McpConnectionClosedException('HTTP+SSE stream ended${error == null ? '' : ': $error'}'));
    }
  }

  Future<void> _post(JsonRpcMessage message) async {
    final target = _endpoint;
    if (target == null) throw StateError('start() first');
    final r = await _http.send('POST', target,
        headers: const {'content-type': 'application/json'}, body: utf8.encode(message.encode()));
    if (!r.ok) throw await _http.statusError(r);
    r.discard();
  }

  @override
  Future<JsonRpcResponse> request(JsonRpcRequest request, {McpSendOptions options = const McpSendOptions()}) async {
    final completer = register(request.id);
    final result = awaitResponse(request.id, completer, options.abort);
    try {
      await _post(request);
    } on Object catch (e) {
      fail(request.id, e);
    }
    return result;
  }

  @override
  Future<void> notify(JsonRpcNotification notification) => _post(notification);

  @override
  Future<void> respond(JsonRpcResponse response) => _post(response);

  @override
  Future<void> close() async {
    _stream.abort();
    markClosed();
  }
}
