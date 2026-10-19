import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:meta/meta.dart';

import 'messages.pigeon.dart';
import 'messages.pigeon.dart' as wire show signals;

/// The native boundary: one method per Pigeon host call plus the signal
/// stream. [PigeonPlatformBackend] is the real implementation; tests inject
/// a fake (see `package:sherpa_platform/testing.dart`).
abstract interface class PlatformBackend {
  Future<MemorySample> sampleMemory();

  Future<DeviceInfo> deviceInfo();

  /// OS events. Must be a broadcast stream: several components listen.
  Stream<PlatformSignal> signals();

  Future<bool> setProcessStateSummary(Uint8List summary);

  Future<List<String>> excludeFromBackup(String path, {required bool includeSqliteSidecars});

  Future<bool> notificationsPermitted();

  Future<LeaseResult> beginLease(LeaseRequest request);

  Future<void> updateLease(String id, double? progress, String? text);

  Future<void> endLease(String id);
}

/// Process-wide backend used when a component is not given one.
abstract final class SherpaPlatform {
  static PlatformBackend? _backend;

  /// The Pigeon backend on Android/iOS, [UnsupportedPlatformBackend]
  /// elsewhere (host tests, desktop dev runs), so callers never need a
  /// platform check.
  static PlatformBackend get backend =>
      _backend ??= (Platform.isAndroid || Platform.isIOS) ? PigeonPlatformBackend() : const UnsupportedPlatformBackend();

  /// Replaces the shared backend (tests); `null` restores the default.
  @visibleForTesting
  static set backend(PlatformBackend? value) => _backend = value;
}

/// Pigeon platform-channel implementation.
final class PigeonPlatformBackend implements PlatformBackend {
  PigeonPlatformBackend({BinaryMessenger? binaryMessenger})
      : _api = SherpaPlatformHostApi(binaryMessenger: binaryMessenger);

  final SherpaPlatformHostApi _api;

  // One native subscription shared by every Dart listener. Each call to the
  // generated `signals()` opens its own EventChannel listen, and a second
  // listen replaces the native sink of the first, so callers must never
  // subscribe to it twice.
  StreamSubscription<PlatformSignal>? _native;
  late final StreamController<PlatformSignal> _signals = StreamController.broadcast(
    onListen: () => _native = nativeSignals().listen(_signals.add, onError: _signals.addError),
    onCancel: () async {
      final cancel = _native?.cancel();
      _native = null;
      await cancel;
    },
  );

  /// Closes the shared signal stream (tests; the app keeps one backend for
  /// the process lifetime).
  Future<void> dispose() => _signals.close();

  /// The generated stream, overridable for tests of the sharing logic.
  @visibleForTesting
  Stream<PlatformSignal> Function() nativeSignals = wire.signals;

  @override
  Stream<PlatformSignal> signals() => _signals.stream;

  @override
  Future<MemorySample> sampleMemory() => _api.sampleMemory();

  @override
  Future<DeviceInfo> deviceInfo() => _api.deviceInfo();

  @override
  Future<bool> setProcessStateSummary(Uint8List summary) => _api.setProcessStateSummary(summary);

  @override
  Future<List<String>> excludeFromBackup(String path, {required bool includeSqliteSidecars}) =>
      _api.excludeFromBackup(path, includeSqliteSidecars);

  @override
  Future<bool> notificationsPermitted() => _api.notificationsPermitted();

  @override
  Future<LeaseResult> beginLease(LeaseRequest request) => _api.beginLease(request);

  @override
  Future<void> updateLease(String id, double? progress, String? text) => _api.updateLease(id, progress, text);

  @override
  Future<void> endLease(String id) => _api.endLease(id);
}

/// Neutral answers for platforms without the plugin: no readings, no
/// signals, leases refused.
final class UnsupportedPlatformBackend implements PlatformBackend {
  const UnsupportedPlatformBackend();

  static MemorySample _sample() => MemorySample(
        platform: 'other',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        thermalStatus: 0,
        lowPowerMode: false,
      );

  @override
  Future<MemorySample> sampleMemory() async => _sample();

  @override
  Future<DeviceInfo> deviceInfo() async => DeviceInfo(
        platform: 'other',
        osVersion: Platform.operatingSystemVersion,
        memory: _sample(),
        cpuCores: Platform.numberOfProcessors,
        cpuMaxFreqKHz: const [],
        cpuCapacity: const [],
        bigCoreIndices: const [],
        cpuFeatures: const [],
        isLowRamDevice: false,
      );

  @override
  Stream<PlatformSignal> signals() => const Stream.empty();

  @override
  Future<bool> setProcessStateSummary(Uint8List summary) async => false;

  @override
  Future<List<String>> excludeFromBackup(String path, {required bool includeSqliteSidecars}) async => const [];

  @override
  Future<bool> notificationsPermitted() async => false;

  @override
  Future<LeaseResult> beginLease(LeaseRequest request) async => LeaseResult(
        id: request.id,
        mode: LeaseMode.none,
        granted: false,
        error: 'background leases are not supported on ${Platform.operatingSystem}',
        notificationsVisible: false,
      );

  @override
  Future<void> updateLease(String id, double? progress, String? text) async {}

  @override
  Future<void> endLease(String id) async {}
}
