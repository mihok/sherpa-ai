/// The message-level transport contract the era sessions run on.
library;

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart' show CancelledException;

import '../era/era.dart';
import '../errors.dart';
import '../protocol/jsonrpc.dart';

/// A server message that is not the response a [McpTransport.request]
/// call is waiting for: notifications, server → client requests (legacy
/// era only), and stray responses.
@immutable
final class McpInbound {
  const McpInbound(this.message, {this.relatedRequestId});

  final JsonRpcMessage message;

  /// The request whose response stream carried it, when the binding can
  /// tell (Streamable HTTP POST streams can; multiplexed channels cannot).
  final JsonRpcId? relatedRequestId;
}

/// Per-request transport options.
@immutable
final class McpSendOptions {
  const McpSendOptions({this.abort, this.headers = const {}, this.longLived = false});

  /// Completes to abandon the request. On 2026-07-28 HTTP this closes the
  /// response stream, which IS the cancellation signal; elsewhere the
  /// session also sends `notifications/cancelled`.
  final Future<void>? abort;

  /// Extra headers (`Mcp-Param-*`); only modern HTTP sends them.
  final Map<String, String> headers;

  /// A `subscriptions/listen`-style stream: no idle timeout on bytes beyond
  /// keep-alive detection.
  final bool longLived;
}

/// One bidirectional MCP message channel to a server.
abstract interface class McpTransport {
  McpTransportKind get kind;

  /// Notifications and server requests (see [McpInbound]). Broadcast.
  Stream<McpInbound> get inbound;

  /// Opens the channel (HTTP+SSE: GET and wait for `endpoint`).
  Future<void> start();

  /// Sends [request] and completes with its response (a result or a
  /// JSON-RPC error). Throws [McpTransportException] /
  /// [McpAuthRequiredException] for transport failures and
  /// [CancelledException] once [McpSendOptions.abort] fired.
  Future<JsonRpcResponse> request(JsonRpcRequest request, {McpSendOptions options = const McpSendOptions()});

  Future<void> notify(JsonRpcNotification notification);

  /// Answers a server → client request (legacy era).
  Future<void> respond(JsonRpcResponse response);

  /// Whether aborting a request's stream is itself the cancellation (M
  /// HTTP). When false the session sends `notifications/cancelled`.
  bool get cancelsByClosingStream;

  /// Completes when the channel is gone (closed or lost).
  Future<void> get done;

  Future<void> close();
}

/// Pending-request bookkeeping shared by the transports: responses may
/// arrive on the request's own stream, a resumed stream or a shared
/// channel, so they are matched by id here.
abstract base class MultiplexingTransport implements McpTransport {
  final StreamController<McpInbound> _inbound = StreamController<McpInbound>.broadcast(sync: true);
  final Map<JsonRpcId, Completer<JsonRpcResponse>> _pending = {};
  final Completer<void> _done = Completer<void>();

  @override
  Stream<McpInbound> get inbound => _inbound.stream;

  @override
  Future<void> get done => _done.future;

  bool get isClosed => _done.isCompleted;

  /// Registers [id] before anything is sent, so an early response is caught.
  @protected
  Completer<JsonRpcResponse> register(JsonRpcId id) {
    if (isClosed) throw const McpConnectionClosedException();
    if (_pending.containsKey(id)) throw StateError('request id $id is already in flight');
    return _pending[id] = Completer<JsonRpcResponse>();
  }

  @protected
  void unregister(JsonRpcId id) => _pending.remove(id);

  @protected
  bool isPending(JsonRpcId id) => _pending.containsKey(id);

  /// Routes one decoded server message.
  @protected
  void dispatch(JsonRpcMessage message, {JsonRpcId? relatedRequestId}) {
    if (message is JsonRpcResponse) {
      final id = message.id;
      final c = id == null ? null : _pending.remove(id);
      if (c != null && !c.isCompleted) {
        c.complete(message);
        return;
      }
      // An id-less error with exactly one request in flight on this stream.
      if (id == null && relatedRequestId != null) {
        final r = _pending.remove(relatedRequestId);
        if (r != null && !r.isCompleted) {
          r.complete(message);
          return;
        }
      }
    }
    if (!_inbound.isClosed) _inbound.add(McpInbound(message, relatedRequestId: relatedRequestId));
  }

  /// Fails one pending request.
  @protected
  void fail(JsonRpcId id, Object error) {
    final c = _pending.remove(id);
    if (c != null && !c.isCompleted) c.completeError(error);
  }

  /// Waits for [c], abandoning it when [abort] fires.
  @protected
  Future<JsonRpcResponse> awaitResponse(JsonRpcId id, Completer<JsonRpcResponse> c, Future<void>? abort) {
    if (abort == null) return c.future;
    unawaited(abort.then((_) => fail(id, const CancelledException('request aborted'))));
    return c.future;
  }

  /// Marks the channel gone and fails everything still pending.
  @protected
  void markClosed([Object? error]) {
    if (_done.isCompleted) return;
    final e = error ?? const McpConnectionClosedException();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(e);
    }
    _pending.clear();
    _done.complete();
    unawaited(_inbound.close());
  }
}
