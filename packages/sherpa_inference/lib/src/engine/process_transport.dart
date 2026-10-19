import 'package:flutter/services.dart';

import 'process_messages.pigeon.dart';

/// The platform side of [ProcessEngineHost]: the Android plugin
/// (SherpaInferencePlugin + InferenceService) in production, a fake service
/// in tests. Mirrors the Pigeon API in pigeons/inference_api.dart:
/// fire-and-forget [send]s out, one ordered [messages] stream back.
abstract interface class InferenceTransport {
  /// Replies, progress, generation batches and [HostStatus] changes, in the
  /// order the platform produced them. Listened to once per host.
  Stream<InferenceMessage> get messages;

  /// Starts a fresh connection; its outcome arrives as a [HostStatus].
  Future<int> connect(BindPolicy policy);

  /// Ships one call. Throws (a [PlatformException] `not_connected`) when
  /// [connection] is not live.
  Future<void> send(int connection, int requestId, EngineCall call);

  Future<void> setBusy(int connection, bool busy);

  Future<void> disconnect(int connection);
}

/// [InferenceTransport] over the generated Pigeon channels.
final class PigeonInferenceTransport implements InferenceTransport {
  PigeonInferenceTransport({BinaryMessenger? binaryMessenger})
      : _api = InferenceHostApi(binaryMessenger: binaryMessenger);

  final InferenceHostApi _api;
  Stream<InferenceMessage>? _messages;

  @override
  Stream<InferenceMessage> get messages => _messages ??= inferenceMessages();

  @override
  Future<int> connect(BindPolicy policy) => _api.connect(policy);

  @override
  Future<void> send(int connection, int requestId, EngineCall call) => _api.send(connection, requestId, call);

  @override
  Future<void> setBusy(int connection, bool busy) => _api.setBusy(connection, busy);

  @override
  Future<void> disconnect(int connection) => _api.disconnect(connection);
}
