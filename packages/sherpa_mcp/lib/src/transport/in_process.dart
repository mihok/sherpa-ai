/// In-process transport for on-device servers the app hosts in Dart.
///
/// iOS forbids subprocess servers in practice and Android forbids exec of
/// non-APK binaries, so stdio is effectively in-process for Sherpa (R01
/// §4.5). The channel uses stdio framing semantics — one JSON-RPC message
/// per string, no batching, `notifications/cancelled` for cancellation —
/// so built-in servers exercise the same protocol path as remote ones, in
/// either era.
library;

import 'dart:async';

import '../era/era.dart';
import '../errors.dart';
import '../protocol/jsonrpc.dart';
import 'transport.dart';

/// The server end (or any duplex string channel, e.g. an isolate port).
abstract interface class McpMessageChannel {
  /// Encoded JSON-RPC messages from the peer.
  Stream<String> get messages;

  void send(String message);

  Future<void> close();
}

final class _Pipe implements McpMessageChannel {
  _Pipe(this._in, this._out);

  final StreamController<String> _in;
  final StreamController<String> _out;

  @override
  Stream<String> get messages => _in.stream;

  @override
  void send(String message) {
    if (!_out.isClosed) _out.add(message);
  }

  @override
  Future<void> close() async {
    // Not awaited: a controller's close() future only completes once its
    // done event was delivered, which never happens without a listener.
    unawaited(_in.close());
    unawaited(_out.close());
  }
}

/// Client side of an in-memory duplex channel.
final class InProcessTransport extends MultiplexingTransport {
  InProcessTransport(this._channel, {this.maxMessageBytes = 8 << 20});

  /// A connected pair: give the [McpMessageChannel] to the Dart server.
  static (InProcessTransport, McpMessageChannel) pair({int maxMessageBytes = 8 << 20}) {
    // Both are closed by either end's _Pipe.close().
    // ignore: close_sinks
    final toServer = StreamController<String>();
    // ignore: close_sinks
    final toClient = StreamController<String>();
    final client = _Pipe(toClient, toServer);
    final server = _Pipe(toServer, toClient);
    return (InProcessTransport(client, maxMessageBytes: maxMessageBytes), server);
  }

  final McpMessageChannel _channel;
  final int maxMessageBytes;
  StreamSubscription<String>? _sub;

  @override
  McpTransportKind get kind => McpTransportKind.inProcess;

  @override
  bool get cancelsByClosingStream => false;

  @override
  Future<void> start() async {
    _sub ??= _channel.messages.listen(
      (text) {
        if (text.length > maxMessageBytes) return; // over the cap: dropped
        try {
          dispatch(JsonRpcMessage.decode(text));
        } on JsonRpcFormatException {
          // Garbage on the channel is ignored, as on stdio.
        }
      },
      onDone: () => markClosed(const McpConnectionClosedException('in-process channel closed')),
      onError: (Object _) {},
    );
  }

  void _send(JsonRpcMessage m) {
    if (isClosed) throw const McpConnectionClosedException();
    _channel.send(m.encode());
  }

  @override
  Future<JsonRpcResponse> request(JsonRpcRequest request, {McpSendOptions options = const McpSendOptions()}) {
    final completer = register(request.id);
    final result = awaitResponse(request.id, completer, options.abort);
    _send(request);
    return result;
  }

  @override
  Future<void> notify(JsonRpcNotification notification) async => _send(notification);

  @override
  Future<void> respond(JsonRpcResponse response) async => _send(response);

  @override
  Future<void> close() async {
    markClosed();
    await _sub?.cancel();
    await _channel.close();
  }
}
