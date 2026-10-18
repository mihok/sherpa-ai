import 'dart:async';

import 'package:meta/meta.dart';

/// Normalized device memory pressure. iOS memory warnings and Android
/// `onTrimMemory`/`ActivityManager` signals both map onto these levels.
enum MemoryPressure {
  normal,

  /// Headroom is shrinking: prefer smaller contexts, defer companion models.
  moderate,

  /// The OS is about to kill something: shrink KV cache, unload idle models.
  critical,
}

enum ThermalLevel { nominal, fair, serious, critical }

@immutable
final class MemoryState {
  const MemoryState({
    required this.pressure,
    this.availableBytes,
    this.totalBytes,
    this.appFootprintBytes,
    this.thermal = ThermalLevel.nominal,
    this.lowPowerMode = false,
    this.source = 'unknown',
  });

  static const unknown = MemoryState(pressure: MemoryPressure.normal);

  final MemoryPressure pressure;

  /// Memory the app can still allocate before the OS intervenes
  /// (iOS `os_proc_available_memory`, Android `availMem - threshold`).
  final int? availableBytes;
  final int? totalBytes;
  final int? appFootprintBytes;
  final ThermalLevel thermal;
  final bool lowPowerMode;

  /// Which signal produced this state (for diagnostics).
  final String source;

  MemoryState copyWith({
    MemoryPressure? pressure,
    int? availableBytes,
    ThermalLevel? thermal,
    bool? lowPowerMode,
    String? source,
  }) =>
      MemoryState(
        pressure: pressure ?? this.pressure,
        availableBytes: availableBytes ?? this.availableBytes,
        totalBytes: totalBytes,
        appFootprintBytes: appFootprintBytes,
        thermal: thermal ?? this.thermal,
        lowPowerMode: lowPowerMode ?? this.lowPowerMode,
        source: source ?? this.source,
      );
}

/// Device memory/thermal signal source. The platform plugin implements it;
/// tests use [FakeMemoryMonitor].
abstract interface class MemoryMonitor {
  MemoryState get current;

  /// Emits on every pressure/thermal transition and periodic samples.
  Stream<MemoryState> get changes;

  /// Forces a fresh sample (e.g. right before loading a model).
  Future<MemoryState> sample();
}

final class FakeMemoryMonitor implements MemoryMonitor {
  FakeMemoryMonitor([MemoryState initial = MemoryState.unknown]) : _current = initial;

  final StreamController<MemoryState> _controller = StreamController.broadcast();
  MemoryState _current;

  @override
  MemoryState get current => _current;

  @override
  Stream<MemoryState> get changes => _controller.stream;

  @override
  Future<MemoryState> sample() async => _current;

  void emit(MemoryState state) {
    _current = state;
    _controller.add(state);
  }

  Future<void> dispose() => _controller.close();
}
