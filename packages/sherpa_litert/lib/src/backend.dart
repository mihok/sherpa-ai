import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'messages.pigeon.dart';
import 'messages.pigeon.dart' as wire show events;

/// The native boundary: one method per Pigeon host call plus the event
/// stream (pigeons/litert_api.dart). [PigeonLiteRtBackend] is the real
/// implementation; tests inject `FakeLiteRtBackend`
/// (`package:sherpa_litert/testing.dart`).
abstract interface class LiteRtBackend {
  /// False on iOS, desktop and web: every call throws a
  /// [PlatformException] with code `unsupported`.
  bool get isSupported;

  Future<PlatformInfoMsg> platformInfo();

  Future<ModelInfoMsg> inspectModel(String path);

  Future<LoadResultMsg> loadEngine(LoadRequestMsg request);

  Future<void> releaseEngine(String reason);

  Future<void> openConversation(ConversationSpecMsg spec);

  Future<void> closeConversation(String conversationId);

  Future<void> sendMessage(SendRequestMsg request);

  Future<void> cancel(int streamId, String reason);

  Future<void> credit(int streamId, int batches);

  Future<void> setTrimPolicy(int releaseAtLevel);

  Future<NanoStatusMsg> nanoStatus(NanoConfigMsg config);

  Future<void> nanoDownload(int streamId, NanoConfigMsg config);

  Future<void> nanoWarmup(NanoConfigMsg config);

  Future<void> nanoGenerate(NanoRequestMsg request);

  Future<bool> isAppInForeground();

  /// Event batches, one stream each (0 = global). Broadcast: one native
  /// subscription shared by every listener.
  Stream<EventBatch> events();
}

/// Process-wide backend shared by both providers (they share one event
/// channel).
abstract final class SherpaLitert {
  static LiteRtBackend? _backend;

  /// [PigeonLiteRtBackend] on Android, [UnsupportedLiteRtBackend]
  /// elsewhere, so callers never need a platform check.
  static LiteRtBackend get backend => _backend ??=
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android ? PigeonLiteRtBackend() : const UnsupportedLiteRtBackend();

  /// Replaces the shared backend (tests); `null` restores the default.
  @visibleForTesting
  static set backend(LiteRtBackend? value) => _backend = value;
}

/// Pigeon platform-channel implementation.
final class PigeonLiteRtBackend implements LiteRtBackend {
  PigeonLiteRtBackend({BinaryMessenger? binaryMessenger}) : _api = LiteRtHostApi(binaryMessenger: binaryMessenger);

  final LiteRtHostApi _api;

  // Each call of the generated `events()` opens its own EventChannel listen
  // and a second listen replaces the native sink of the first, so all Dart
  // listeners share this one subscription.
  StreamSubscription<EventBatch>? _native;
  late final StreamController<EventBatch> _events = StreamController.broadcast(
    onListen: () => _native = wire.events().listen(_events.add, onError: _events.addError),
    onCancel: () async {
      final c = _native?.cancel();
      _native = null;
      await c;
    },
  );

  /// Closes the shared event stream (tests; the app keeps one backend for
  /// the process lifetime).
  Future<void> dispose() => _events.close();

  @override
  bool get isSupported => true;

  @override
  Stream<EventBatch> events() => _events.stream;

  @override
  Future<PlatformInfoMsg> platformInfo() => _api.platformInfo();

  @override
  Future<ModelInfoMsg> inspectModel(String path) => _api.inspectModel(path);

  @override
  Future<LoadResultMsg> loadEngine(LoadRequestMsg request) => _api.loadEngine(request);

  @override
  Future<void> releaseEngine(String reason) => _api.releaseEngine(reason);

  @override
  Future<void> openConversation(ConversationSpecMsg spec) => _api.openConversation(spec);

  @override
  Future<void> closeConversation(String conversationId) => _api.closeConversation(conversationId);

  @override
  Future<void> sendMessage(SendRequestMsg request) => _api.sendMessage(request);

  @override
  Future<void> cancel(int streamId, String reason) => _api.cancel(streamId, reason);

  @override
  Future<void> credit(int streamId, int batches) => _api.credit(streamId, batches);

  @override
  Future<void> setTrimPolicy(int releaseAtLevel) => _api.setTrimPolicy(releaseAtLevel);

  @override
  Future<NanoStatusMsg> nanoStatus(NanoConfigMsg config) => _api.nanoStatus(config);

  @override
  Future<void> nanoDownload(int streamId, NanoConfigMsg config) => _api.nanoDownload(streamId, config);

  @override
  Future<void> nanoWarmup(NanoConfigMsg config) => _api.nanoWarmup(config);

  @override
  Future<void> nanoGenerate(NanoRequestMsg request) => _api.nanoGenerate(request);

  @override
  Future<bool> isAppInForeground() => _api.isAppInForeground();
}

/// Answers for platforms without the plugin: nothing is supported.
final class UnsupportedLiteRtBackend implements LiteRtBackend {
  const UnsupportedLiteRtBackend();

  static Never _unsupported() => throw PlatformException(
        code: 'unsupported',
        message: 'LiteRT-LM and Gemini Nano run on Android only.',
      );

  @override
  bool get isSupported => false;

  @override
  Stream<EventBatch> events() => const Stream.empty();

  @override
  Future<PlatformInfoMsg> platformInfo() async => _unsupported();

  @override
  Future<ModelInfoMsg> inspectModel(String path) async => _unsupported();

  @override
  Future<LoadResultMsg> loadEngine(LoadRequestMsg request) async => _unsupported();

  @override
  Future<void> releaseEngine(String reason) async {}

  @override
  Future<void> openConversation(ConversationSpecMsg spec) async => _unsupported();

  @override
  Future<void> closeConversation(String conversationId) async {}

  @override
  Future<void> sendMessage(SendRequestMsg request) async => _unsupported();

  @override
  Future<void> cancel(int streamId, String reason) async {}

  @override
  Future<void> credit(int streamId, int batches) async {}

  @override
  Future<void> setTrimPolicy(int releaseAtLevel) async {}

  @override
  Future<NanoStatusMsg> nanoStatus(NanoConfigMsg config) async => _unsupported();

  @override
  Future<void> nanoDownload(int streamId, NanoConfigMsg config) async => _unsupported();

  @override
  Future<void> nanoWarmup(NanoConfigMsg config) async => _unsupported();

  @override
  Future<void> nanoGenerate(NanoRequestMsg request) async => _unsupported();

  @override
  Future<bool> isAppInForeground() async => false;
}
