/// 2025-03-26 … 2025-11-25 Streamable HTTP
/// (specification/2025-11-25/basic/transports.md; R01 §4.2).
library;

import 'dart:async';
import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart' show CancelledException;
import 'package:sherpa_net/sherpa_net.dart' show Backoff, SseEvent;

import '../era/era.dart';
import '../errors.dart';
import '../protocol/headers.dart';
import '../protocol/jsonrpc.dart';
import 'http.dart';
import 'transport.dart';

/// The session binding.
///
/// * The `Mcp-Session-Id` from the `initialize` response is echoed on every
///   later request (GET and DELETE included); a 404 to a request carrying
///   it throws [McpSessionExpiredException] and the session re-initializes.
/// * `MCP-Protocol-Version: <negotiated>` after `initialize`.
/// * POST responses are JSON or SSE; SSE streams may carry server → client
///   requests, answered by POSTing a response (202).
/// * A POST stream that ends before its response is resumed with
///   `GET` + `Last-Event-ID` after the server's `retry` delay (2025-11-25
///   polling: priming event, server closes the connection, client
///   reconnects); a disconnect is NOT a cancellation.
/// * An optional GET stream carries messages unrelated to any request;
///   405 means the server offers none (TS v1 servers also answer 409 to a
///   second one). It reconnects with `Last-Event-ID` too.
/// * [close] sends `DELETE` (405 tolerated).
final class LegacyStreamableHttpTransport extends MultiplexingTransport {
  LegacyStreamableHttpTransport({required McpHttp http, Uri? endpoint, Backoff? backoff})
      : _http = http,
        endpoint = endpoint ?? http.serverUrl,
        _backoff = backoff ?? Backoff(base: const Duration(seconds: 1), max: const Duration(seconds: 30));

  final McpHttp _http;
  final Uri endpoint;
  final Backoff _backoff;
  final Set<Abort> _open = {};

  /// Set from the `initialize` response.
  String? get sessionId => _sessionId;
  String? _sessionId;

  /// Set by the session once `initialize` negotiated a version.
  String? protocolVersion;

  Abort? _listenAbort;
  bool _listenWanted = false;

  /// Reports the GET stream state (`active`, and the error that ended it).
  void Function(bool active, Object? error)? onListenState;

  /// Default reconnection delay when the server sent no `retry`.
  Duration defaultRetry = const Duration(seconds: 1);

  @override
  McpTransportKind get kind => McpTransportKind.legacyStreamableHttp;

  @override
  bool get cancelsByClosingStream => false;

  @override
  Future<void> start() async {}

  /// Forget the session (before a fresh `initialize`).
  void resetSession() {
    _sessionId = null;
    protocolVersion = null;
  }

  Map<String, String> _headers({bool post = true, String? lastEventId}) => {
        'accept': post ? 'application/json, text/event-stream' : 'text/event-stream',
        if (post) 'content-type': 'application/json',
        McpHeaders.sessionId: ?_sessionId,
        McpHeaders.protocolVersion: ?protocolVersion,
        McpHeaders.lastEventId: ?lastEventId,
      };

  Future<McpHttpResponse> _post(JsonRpcMessage message, Future<void>? abort) async {
    final hadSession = _sessionId != null;
    final r = await _http.send('POST', endpoint,
        headers: _headers(), body: utf8.encode(message.encode()), abort: abort);
    if (r.ok) return r;
    if (r.statusCode == 404 && hadSession) {
      r.discard();
      throw McpSessionExpiredException();
    }
    throw await _http.statusError(r);
  }

  /// GET (SSE). Returns null for 405/409: no (further) GET stream offered.
  Future<McpHttpResponse?> _get({String? lastEventId, Future<void>? abort}) async {
    final hadSession = _sessionId != null;
    final r = await _http.send('GET', endpoint, headers: _headers(post: false, lastEventId: lastEventId), abort: abort);
    if (r.statusCode == 405 || r.statusCode == 409) {
      r.discard();
      return null;
    }
    if (r.statusCode == 404 && hadSession) {
      r.discard();
      throw McpSessionExpiredException();
    }
    if (!r.ok) throw await _http.statusError(r);
    if (!r.isEventStream) {
      r.discard();
      throw McpProtocolException('GET stream answered with "${r.mediaType}", not text/event-stream');
    }
    return r;
  }

  @override
  Future<JsonRpcResponse> request(JsonRpcRequest request, {McpSendOptions options = const McpSendOptions()}) async {
    final completer = register(request.id);
    final abort = Abort()..follow(options.abort);
    _open.add(abort);
    final McpHttpResponse response;
    try {
      response = await _post(request, abort.future);
    } on Object {
      unregister(request.id);
      _open.remove(abort);
      rethrow;
    }
    final result = awaitResponse(request.id, completer, abort.future);
    final sid = request.method == 'initialize' ? response.headers['mcp-session-id'] : null;
    // Session ids MUST be visible ASCII (0x21–0x7E).
    if (sid != null && (sid.isEmpty || sid.codeUnits.any((c) => c < 0x21 || c > 0x7E))) {
      response.discard();
      fail(request.id, McpProtocolException('server sent an invalid Mcp-Session-Id'));
    } else if (response.statusCode == 202) {
      response.discard();
      fail(request.id, McpProtocolException('server answered a request with 202 Accepted'));
    } else {
      if (sid != null) _sessionId = sid;
      if (response.isEventStream) {
        unawaited(_pumpRequestStream(response, request.id, abort));
      } else if (response.isJson) {
        unawaited(_readJson(response, request.id));
      } else {
        response.discard();
        fail(request.id, McpProtocolException('unexpected content type "${response.mediaType}"'));
      }
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
      // A 2025-03-26 peer may batch.
      for (final m in JsonRpcMessage.decodeBody(text, allowBatch: true)) {
        dispatch(m, relatedRequestId: id);
      }
      fail(id, McpProtocolException('JSON response did not answer request $id'));
    } on JsonRpcFormatException catch (e) {
      fail(id, McpProtocolException('invalid JSON-RPC response: ${e.message}'));
    } on Object catch (e) {
      fail(id, mapHttpError(e));
    }
  }

  /// Dispatches SSE events, recording the last event id and `retry` in
  /// [cursor] as they arrive (so they survive a stream that breaks).
  Future<void> _consume(
    McpHttpResponse response,
    _Cursor cursor, {
    JsonRpcId? relatedId,
    Duration? idleTimeout,
  }) async {
    await for (final SseEvent e in response.events(idleTimeout: idleTimeout)) {
      // Progress = the stream advanced (a message, or a new event id); a
      // server that only repeats its priming event exhausts the attempts.
      if (e.data.isNotEmpty || (e.id != null && e.id != cursor.lastId)) cursor.failures = 0;
      if (e.id != null) cursor.lastId = e.id;
      if (e.retry != null) cursor.retry = e.retry;
      if (e.data.isEmpty) continue; // priming / keep-alive event
      List<JsonRpcMessage> messages;
      try {
        messages = JsonRpcMessage.decodeBody(e.data, allowBatch: true);
      } on JsonRpcFormatException {
        continue;
      }
      for (final m in messages) {
        dispatch(m, relatedRequestId: relatedId);
      }
      if (relatedId != null && !isPending(relatedId)) break;
    }
  }

  Future<void> _pumpRequestStream(McpHttpResponse first, JsonRpcId id, Abort abort) async {
    McpHttpResponse? current = first;
    final cursor = _Cursor();
    try {
      while (current != null) {
        Object? error;
        try {
          await _consume(current, cursor, relatedId: id);
        } on CancelledException {
          return;
        } on Object catch (e) {
          error = mapHttpError(e);
        }
        if (!isPending(id) || abort.isAborted) return;
        final lastId = cursor.lastId;
        if (lastId == null || cursor.failures >= _http.limits.maxResumeAttempts) {
          fail(
            id,
            error is McpException && error is! McpTransportException
                ? error
                : McpTransportException('response stream ended before the response', streamInterrupted: true),
          );
          return;
        }
        cursor.failures++;
        // The server's `retry` MUST be honoured before reconnecting.
        await Future.any([Future<void>.delayed(cursor.retry ?? defaultRetry), abort.future]);
        if (abort.isAborted || !isPending(id)) return;
        current = await _get(lastEventId: lastId, abort: abort.future);
        if (current == null) {
          fail(id, McpTransportException('stream lost and the server offers no GET resumption',
              streamInterrupted: true));
        }
      }
    } on CancelledException {
      return;
    } on Object catch (e) {
      fail(id, mapHttpError(e));
    } finally {
      abort.abort();
    }
  }

  /// Opens the GET stream for server messages unrelated to requests.
  /// Returns false when the server offers none (405/409).
  Future<bool> openListenStream() async {
    if (_listenWanted && _listenAbort != null) return true;
    final abort = Abort();
    final r = await _get(abort: abort.future);
    if (r == null) return false;
    _listenWanted = true;
    _listenAbort = abort;
    onListenState?.call(true, null);
    unawaited(_pumpListen(r, abort));
    return true;
  }

  void closeListenStream() {
    _listenWanted = false;
    _listenAbort?.abort();
    _listenAbort = null;
  }

  bool get isListening => _listenWanted && _listenAbort != null;

  Future<void> _pumpListen(McpHttpResponse first, Abort abort) async {
    McpHttpResponse? current = first;
    final cursor = _Cursor();
    Object? lastError;
    final max = _http.limits.maxListenReconnects;
    while (current != null && !abort.isAborted && !isClosed) {
      try {
        await _consume(current, cursor, idleTimeout: _http.timeouts.streamIdle);
      } on CancelledException {
        break;
      } on Object catch (e) {
        lastError = mapHttpError(e);
      }
      current = null;
      while (!abort.isAborted && !isClosed && cursor.failures < max) {
        final delay = cursor.retry ?? _backoff.delay(cursor.failures);
        cursor.failures++;
        await Future.any([Future<void>.delayed(delay), abort.future, done]);
        if (abort.isAborted || isClosed) break;
        try {
          current = await _get(lastEventId: cursor.lastId, abort: abort.future);
          if (current == null) cursor.failures = max; // 405: stop
          break;
        } on CancelledException {
          break;
        } on Object catch (e) {
          lastError = mapHttpError(e);
        }
      }
    }
    if (identical(_listenAbort, abort)) {
      _listenAbort = null;
      _listenWanted = false;
      onListenState?.call(false, abort.isAborted ? null : lastError);
    }
  }

  @override
  Future<void> notify(JsonRpcNotification notification) async => (await _post(notification, null)).discard();

  @override
  Future<void> respond(JsonRpcResponse response) async => (await _post(response, null)).discard();

  /// Ends the session: aborts streams, then `DELETE` (best effort; 405 OK).
  @override
  Future<void> close() async {
    if (isClosed) return;
    closeListenStream();
    for (final a in List.of(_open)) {
      a.abort();
    }
    markClosed();
    final sid = _sessionId;
    if (sid == null) return;
    final abort = Abort();
    try {
      final r = await _http
          .send('DELETE', endpoint, headers: _headers(post: false)..remove('accept'), abort: abort.future)
          .timeout(_http.timeouts.close);
      r.discard();
    } on Object {
      abort.abort(); // Best effort: the server expires the session anyway.
    }
  }
}

/// Resumption state of one SSE stream.
final class _Cursor {
  String? lastId;
  Duration? retry;

  /// Consecutive reconnects without an event in between.
  int failures = 0;
}
