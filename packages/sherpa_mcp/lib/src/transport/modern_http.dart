/// 2026-07-28 Streamable HTTP (basic/transports/streamable-http.md).
library;

import 'dart:async';
import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart' show CancelledException;

import '../era/era.dart';
import '../errors.dart';
import '../protocol/headers.dart';
import '../protocol/jsonrpc.dart';
import '../protocol/versions.dart';
import 'http.dart';
import 'transport.dart';

/// The stateless binding: one POST per message to a single endpoint.
///
/// Every POST carries `Accept: application/json, text/event-stream`,
/// `MCP-Protocol-Version` (equal to the body's `_meta` version),
/// `Mcp-Method`, `Mcp-Name` for `tools/call` / `prompts/get` /
/// `resources/read` / `tasks/*`, and the `Mcp-Param-*` headers the session
/// computed from the tool's `x-mcp-header` declarations. Responses are a
/// single JSON object or a request-scoped SSE stream of notifications
/// followed by the response. There are no sessions, no GET stream and no
/// resumability: closing the stream is the cancellation, and a broken
/// stream loses the request ([McpTransportException.streamInterrupted]).
final class ModernHttpTransport extends MultiplexingTransport {
  ModernHttpTransport({required McpHttp http, Uri? endpoint, this.defaultProtocolVersion = McpVersions.firstModern})
      : _http = http,
        endpoint = endpoint ?? http.serverUrl;

  final McpHttp _http;
  final Uri endpoint;

  /// Used for the header when a message carries no `_meta` version.
  final String defaultProtocolVersion;
  final Set<Abort> _open = {};

  @override
  McpTransportKind get kind => McpTransportKind.modernHttp;

  @override
  bool get cancelsByClosingStream => true;

  @override
  Future<void> start() async {}

  /// The headers the spec derives from [message] (exposed for tests).
  Map<String, String> headersFor(JsonRpcMessage message) {
    final (method, params) = switch (message) {
      JsonRpcRequest(:final method, :final params) => (method, params),
      JsonRpcNotification(:final method, :final params) => (method, params),
      _ => (null, null),
    };
    final meta = params?['_meta'];
    final version = meta is Map ? meta[McpMetaKeys.protocolVersion] : null;
    final nameField = method == null ? null : McpHeaders.nameSource[method];
    final name = nameField == null ? null : params?[nameField];
    return {
      'accept': 'application/json, text/event-stream',
      'content-type': 'application/json',
      McpHeaders.protocolVersion: version is String ? version : defaultProtocolVersion,
      if (method != null && message is JsonRpcRequest) McpHeaders.method: method,
      if (name is String) McpHeaders.name: encodeMcpHeaderValue(name),
    };
  }

  @override
  Future<JsonRpcResponse> request(JsonRpcRequest request, {McpSendOptions options = const McpSendOptions()}) async {
    final completer = register(request.id);
    final abort = Abort()..follow(options.abort);
    _open.add(abort);
    final McpHttpResponse response;
    try {
      response = await _http.send(
        'POST',
        endpoint,
        headers: {
          for (final e in options.headers.entries)
            if (!McpHeaders.reserved.contains(e.key.toLowerCase())) e.key: e.value,
          ...headersFor(request),
        },
        body: utf8.encode(request.encode()),
        abort: abort.future,
      );
    } on Object {
      unregister(request.id);
      _open.remove(abort);
      rethrow;
    }
    final result = awaitResponse(request.id, completer, abort.future);
    if (!response.ok) {
      final error = await _http.statusError(response);
      fail(request.id, error);
    } else if (response.statusCode == 202) {
      response.discard();
      fail(request.id, McpProtocolException('server answered a request with 202 Accepted'));
    } else if (response.isEventStream) {
      unawaited(_pump(response, request.id, abort, longLived: options.longLived));
    } else if (response.isJson) {
      unawaited(_readJson(response, request.id));
    } else {
      response.discard();
      fail(request.id, McpProtocolException('unexpected content type "${response.mediaType}"'));
    }
    try {
      return await result;
    } finally {
      _open.remove(abort);
      abort.abort();
    }
  }

  Future<void> _readJson(McpHttpResponse response, JsonRpcId id) async {
    try {
      final text = await response.readText();
      for (final m in JsonRpcMessage.decodeBody(text)) {
        dispatch(m, relatedRequestId: id);
      }
      fail(id, McpProtocolException('JSON response did not answer request $id'));
    } on JsonRpcFormatException catch (e) {
      fail(id, McpProtocolException('invalid JSON-RPC response: ${e.message}'));
    } on Object catch (e) {
      fail(id, mapHttpError(e));
    }
  }

  Future<void> _pump(McpHttpResponse response, JsonRpcId id, Abort abort, {required bool longLived}) async {
    try {
      await for (final event in response.events(idleTimeout: longLived ? _http.timeouts.streamIdle : null)) {
        if (event.data.isEmpty) continue;
        final JsonRpcMessage message;
        try {
          message = JsonRpcMessage.decode(event.data);
        } on JsonRpcFormatException {
          continue; // Not a message; a hostile or buggy event is skipped.
        }
        // A 2026-07-28 server MUST NOT send requests; the session reports it.
        dispatch(message, relatedRequestId: id);
        if (!isPending(id)) return; // Response in: stop reading (closes the stream).
      }
      fail(id, McpTransportException('response stream ended before the response', streamInterrupted: true));
    } on CancelledException catch (e) {
      fail(id, e);
    } on Object catch (e) {
      final mapped = mapHttpError(e);
      fail(
        id,
        mapped is McpTransportException && mapped is! McpHttpStatusException
            ? McpTransportException(mapped.message, cause: e, streamInterrupted: true)
            : mapped,
      );
    } finally {
      abort.abort();
    }
  }

  @override
  Future<void> notify(JsonRpcNotification notification) async {
    final r = await _http.send(
      'POST',
      endpoint,
      headers: headersFor(notification),
      body: utf8.encode(notification.encode()),
    );
    if (!r.ok) throw await _http.statusError(r);
    r.discard();
  }

  @override
  Future<void> respond(JsonRpcResponse response) =>
      throw StateError('2026-07-28 clients never send JSON-RPC responses');

  @override
  Future<void> close() async {
    for (final a in List.of(_open)) {
      a.abort();
    }
    markClosed();
  }
}
