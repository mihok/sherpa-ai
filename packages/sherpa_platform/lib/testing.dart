/// Test doubles for code that depends on sherpa_platform.
library;

import 'dart:async';
import 'dart:typed_data';

import 'sherpa_platform.dart';

/// Scriptable [PlatformBackend]: set [memory] / [device], push [emit]ted
/// signals, and inspect what the code under test asked for.
final class FakePlatformBackend implements PlatformBackend {
  FakePlatformBackend({MemorySample? memory, this.device}) : memory = memory ?? androidSample();

  /// Returned by the next [sampleMemory] calls.
  MemorySample memory;
  DeviceInfo? device;

  /// When set, [sampleMemory] throws it.
  Object? sampleError;

  /// Decides [beginLease]; default grants with the mode matching the request.
  LeaseResult Function(LeaseRequest request)? onBeginLease;

  int sampleCalls = 0;
  final List<Uint8List> summaries = [];
  final List<String> excluded = [];
  final List<LeaseRequest> begun = [];
  final List<({String id, double? progress, String? text})> updates = [];
  final List<String> ended = [];
  bool notifications = true;

  final StreamController<PlatformSignal> _signals = StreamController.broadcast();

  /// Whether anything listens to [signals] (native registration state).
  bool get signalsListened => _signals.hasListener;

  void emit(SignalKind kind, {int level = 0, double? value, String? leaseId, String? detail, int? timestampMs}) =>
      _signals.add(PlatformSignal(
        kind: kind,
        level: level,
        value: value,
        leaseId: leaseId,
        detail: detail,
        timestampMs: timestampMs ?? DateTime.now().millisecondsSinceEpoch,
      ));

  @override
  Stream<PlatformSignal> signals() => _signals.stream;

  @override
  Future<MemorySample> sampleMemory() async {
    sampleCalls++;
    final e = sampleError;
    if (e != null) throw e;
    return memory;
  }

  @override
  Future<DeviceInfo> deviceInfo() async => device ?? (throw StateError('FakePlatformBackend.device not set'));

  @override
  Future<bool> setProcessStateSummary(Uint8List summary) async {
    summaries.add(summary);
    return true;
  }

  @override
  Future<List<String>> excludeFromBackup(String path, {required bool includeSqliteSidecars}) async {
    final paths = [path, if (includeSqliteSidecars) ...['$path-wal', '$path-shm']];
    excluded.addAll(paths);
    return paths;
  }

  @override
  Future<bool> notificationsPermitted() async => notifications;

  @override
  Future<LeaseResult> beginLease(LeaseRequest request) async {
    begun.add(request);
    return onBeginLease?.call(request) ??
        LeaseResult(
          id: request.id,
          mode: request.long ? LeaseMode.androidSpecialUse : LeaseMode.androidShortService,
          granted: true,
          notificationsVisible: notifications,
        );
  }

  @override
  Future<void> updateLease(String id, double? progress, String? text) async =>
      updates.add((id: id, progress: progress, text: text));

  @override
  Future<void> endLease(String id) async => ended.add(id);

  Future<void> close() => _signals.close();

  static const int _mib = 1024 * 1024;

  /// A healthy Android 16 phone with 8 GB.
  static MemorySample androidSample({
    int apiLevel = 36,
    int totalMem = 7680 * _mib,
    int? advertisedMem = 8192 * _mib,
    int availMem = 3072 * _mib,
    int threshold = 256 * _mib,
    bool lowMemory = false,
    int lastTrimLevel = 0,
    int? anonSwap = 400 * _mib,
    int thermalStatus = 0,
    double? thermalHeadroom,
    bool lowPowerMode = false,
    int? timestampMs,
  }) =>
      MemorySample(
        platform: 'android',
        timestampMs: timestampMs ?? DateTime.now().millisecondsSinceEpoch,
        apiLevel: apiLevel,
        availMemBytes: availMem,
        thresholdBytes: threshold,
        totalMemBytes: totalMem,
        advertisedMemBytes: advertisedMem,
        lowMemory: lowMemory,
        lastTrimLevel: lastTrimLevel,
        rssBytes: anonSwap == null ? null : anonSwap + 200 * _mib,
        anonSwapBytes: anonSwap,
        thermalStatus: thermalStatus,
        thermalHeadroom: thermalHeadroom,
        lowPowerMode: lowPowerMode,
      );

  /// An iPhone with ~6 GB of process limit.
  static MemorySample iosSample({
    int procAvailable = 5 * 1024 * _mib,
    int footprint = 300 * _mib,
    int physicalMemory = 8 * 1024 * _mib,
    int thermalStatus = 0,
    bool lowPowerMode = false,
    int? timestampMs,
  }) =>
      MemorySample(
        platform: 'ios',
        timestampMs: timestampMs ?? DateTime.now().millisecondsSinceEpoch,
        procAvailableBytes: procAvailable,
        physFootprintBytes: footprint,
        physicalMemoryBytes: physicalMemory,
        thermalStatus: thermalStatus,
        lowPowerMode: lowPowerMode,
      );
}

/// [ForegroundSource] driven by the test.
final class FakeForegroundSource implements ForegroundSource {
  FakeForegroundSource({bool foreground = true}) : _foreground = foreground;

  bool _foreground;
  final StreamController<bool> _changes = StreamController.broadcast(sync: true);

  @override
  bool get isForeground => _foreground;

  @override
  Stream<bool> get changes => _changes.stream;

  set foreground(bool value) {
    if (value == _foreground) return;
    _foreground = value;
    _changes.add(value);
  }

  Future<void> close() => _changes.close();
}
