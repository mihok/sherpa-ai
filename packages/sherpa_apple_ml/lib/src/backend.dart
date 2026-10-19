import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:meta/meta.dart';

import 'messages.pigeon.dart';
import 'messages.pigeon.dart' as wire show events;

/// The native boundary: one method per Pigeon host call plus the shared
/// event stream. [PigeonAppleMlBackend] is the real implementation; tests
/// inject a fake (`package:sherpa_apple_ml/testing.dart`).
abstract interface class AppleMlBackend {
  /// False when there is no native side at all (not iOS). Every other call
  /// then throws [UnsupportedError].
  bool get isSupported;

  Future<AmPlatformInfo> platformInfo();

  Future<AmFmAvailability> fmAvailability();

  Future<AmMlxModelInfo> mlxLoad(AmMlxLoadRequest request);

  Future<void> mlxUnload(String modelId);

  Future<void> mlxGenerate(AmMlxGenerateRequest request);

  Future<int> mlxCountTokens(String modelId, String text);

  Future<bool> mlxSavePromptCache(String sessionKey, String path);

  Future<void> fmGenerate(AmFmGenerateRequest request);

  Future<void> fmSubmitToolResults(String generationId, List<AmToolResult> results);

  Future<void> fmPrewarm(String? instructions);

  Future<void> cancel(String generationId);

  Future<void> ack(String generationId, int seq);

  Future<void> interruptAll(String reason);

  Future<void> dropSession(AmEngine engine, String sessionKey);

  /// Event batches for every generation plus global events. Broadcast.
  Stream<AmEventBatch> events();
}

/// Process-wide backend used when a provider is not given one.
abstract final class AppleMl {
  static AppleMlBackend? _backend;

  /// The Pigeon backend on iOS, [UnsupportedAppleMlBackend] elsewhere, so
  /// callers never need a platform check.
  static AppleMlBackend get backend =>
      _backend ??= Platform.isIOS ? PigeonAppleMlBackend() : const UnsupportedAppleMlBackend();

  /// Replaces the shared backend (tests); `null` restores the default.
  @visibleForTesting
  static set backend(AppleMlBackend? value) => _backend = value;
}

/// Pigeon platform-channel implementation.
final class PigeonAppleMlBackend implements AppleMlBackend {
  PigeonAppleMlBackend({BinaryMessenger? binaryMessenger}) : _api = AppleMlHostApi(binaryMessenger: binaryMessenger);

  final AppleMlHostApi _api;

  // One native subscription shared by every Dart listener: a second listen on
  // the generated EventChannel would replace the native sink of the first.
  StreamSubscription<AmEventBatch>? _native;
  late final StreamController<AmEventBatch> _events = StreamController.broadcast(
    onListen: () => _native = nativeEvents().listen(_events.add, onError: _events.addError),
    onCancel: () async {
      final cancel = _native?.cancel();
      _native = null;
      await cancel;
    },
  );

  /// Closes the shared event stream (tests; the app keeps one backend for
  /// the process lifetime).
  Future<void> dispose() => _events.close();

  /// The generated stream, overridable for tests of the sharing logic.
  @visibleForTesting
  Stream<AmEventBatch> Function() nativeEvents = wire.events;

  @override
  bool get isSupported => true;

  @override
  Stream<AmEventBatch> events() => _events.stream;

  @override
  Future<AmPlatformInfo> platformInfo() => _api.platformInfo();

  @override
  Future<AmFmAvailability> fmAvailability() => _api.fmAvailability();

  @override
  Future<AmMlxModelInfo> mlxLoad(AmMlxLoadRequest request) => _api.mlxLoad(request);

  @override
  Future<void> mlxUnload(String modelId) => _api.mlxUnload(modelId);

  @override
  Future<void> mlxGenerate(AmMlxGenerateRequest request) => _api.mlxGenerate(request);

  @override
  Future<int> mlxCountTokens(String modelId, String text) => _api.mlxCountTokens(modelId, text);

  @override
  Future<bool> mlxSavePromptCache(String sessionKey, String path) => _api.mlxSavePromptCache(sessionKey, path);

  @override
  Future<void> fmGenerate(AmFmGenerateRequest request) => _api.fmGenerate(request);

  @override
  Future<void> fmSubmitToolResults(String generationId, List<AmToolResult> results) =>
      _api.fmSubmitToolResults(generationId, results);

  @override
  Future<void> fmPrewarm(String? instructions) => _api.fmPrewarm(instructions);

  @override
  Future<void> cancel(String generationId) => _api.cancel(generationId);

  @override
  Future<void> ack(String generationId, int seq) => _api.ack(generationId, seq);

  @override
  Future<void> interruptAll(String reason) => _api.interruptAll(reason);

  @override
  Future<void> dropSession(AmEngine engine, String sessionKey) => _api.dropSession(engine, sessionKey);
}

/// Android, desktop and host tests: no native side. Availability checks
/// short-circuit on [isSupported]; everything else throws.
final class UnsupportedAppleMlBackend implements AppleMlBackend {
  const UnsupportedAppleMlBackend();

  static Never _no() => throw UnsupportedError('Apple on-device models (MLX, Foundation Models) need iOS.');

  @override
  bool get isSupported => false;

  @override
  Stream<AmEventBatch> events() => const Stream.empty();

  @override
  Future<AmPlatformInfo> platformInfo() async => _no();

  @override
  Future<AmFmAvailability> fmAvailability() async => _no();

  @override
  Future<AmMlxModelInfo> mlxLoad(AmMlxLoadRequest request) async => _no();

  @override
  Future<void> mlxUnload(String modelId) async {}

  @override
  Future<void> mlxGenerate(AmMlxGenerateRequest request) async => _no();

  @override
  Future<int> mlxCountTokens(String modelId, String text) async => _no();

  @override
  Future<bool> mlxSavePromptCache(String sessionKey, String path) async => false;

  @override
  Future<void> fmGenerate(AmFmGenerateRequest request) async => _no();

  @override
  Future<void> fmSubmitToolResults(String generationId, List<AmToolResult> results) async {}

  @override
  Future<void> fmPrewarm(String? instructions) async {}

  @override
  Future<void> cancel(String generationId) async {}

  @override
  Future<void> ack(String generationId, int seq) async {}

  @override
  Future<void> interruptAll(String reason) async {}

  @override
  Future<void> dropSession(AmEngine engine, String sessionKey) async {}
}
