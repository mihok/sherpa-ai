/// The string pipe between the Dart bridge and one shell page.
library;

import 'dart:async';

/// Native code implements this as a dumb pipe (origin- and frame-checked);
/// tests use `FakeMcpAppChannel` from `package:sherpa_webview/testing.dart`.
abstract interface class McpAppChannel {
  /// Shell envelopes (JSON strings), in order.
  Stream<String> get fromShell;

  /// Sends one envelope to the shell. Must not throw after [close].
  void toShell(String envelope);

  /// Stops delivery in both directions.
  Future<void> close();
}

/// A [McpAppChannel] backed by a stream controller and a send callback.
final class CallbackMcpAppChannel implements McpAppChannel {
  CallbackMcpAppChannel(this._send);

  final void Function(String envelope) _send;
  final StreamController<String> _incoming = StreamController<String>();
  bool _closed = false;

  bool get isClosed => _closed;

  @override
  Stream<String> get fromShell => _incoming.stream;

  /// Called by the platform layer for every shell message.
  void deliver(String envelope) {
    if (!_closed) _incoming.add(envelope);
  }

  @override
  void toShell(String envelope) {
    if (!_closed) _send(envelope);
  }

  @override
  Future<void> close() {
    if (!_closed) {
      _closed = true;
      // Not awaited: a single-subscription controller's close() only
      // completes once a listener has seen the done event.
      unawaited(_incoming.close());
    }
    return Future<void>.value();
  }
}
