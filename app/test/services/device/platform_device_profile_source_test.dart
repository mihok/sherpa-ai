import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/services/device/device_profile_source.dart';
import 'package:sherpa/services/device/platform_device_profile_source.dart';
import 'package:sherpa_hub/sherpa_hub.dart';
import 'package:sherpa_platform/sherpa_platform.dart';

const _gib = 1024 * 1024 * 1024;

void main() {
  final fallback = FixedDeviceProfileSource(const DeviceProfile(platform: DevicePlatform.other, totalRamBytes: 4 * _gib));

  test('uses the measured snapshot', () async {
    final source = PlatformDeviceProfileSource(backend: _Backend(total: 8 * _gib, procAvailable: 3 * _gib), fallback: fallback);
    final profile = await source.current();
    expect(profile.platform, DevicePlatform.ios);
    expect(profile.totalRamBytes, 8 * _gib);
    expect(profile.availableRamBytes, isNotNull);
  });

  test('falls back when the plugin fails or reports no RAM', () async {
    final failing = PlatformDeviceProfileSource(backend: _Backend(fail: true), fallback: fallback);
    expect((await failing.current()).totalRamBytes, 4 * _gib);
    final empty = PlatformDeviceProfileSource(backend: _Backend(), fallback: fallback);
    expect((await empty.current()).totalRamBytes, 4 * _gib);
  });
}

final class _Backend implements PlatformBackend {
  _Backend({this.total, this.procAvailable, this.fail = false});

  final int? total;
  final int? procAvailable;
  final bool fail;

  MemorySample _sample() => MemorySample(
        platform: 'ios',
        timestampMs: 0,
        physicalMemoryBytes: total,
        procAvailableBytes: procAvailable,
        thermalStatus: 0,
        lowPowerMode: false,
      );

  @override
  Future<DeviceInfo> deviceInfo() async {
    if (fail) throw StateError('no plugin');
    return DeviceInfo(
      platform: 'ios',
      osVersion: '27.0',
      memory: _sample(),
      cpuCores: 6,
      cpuMaxFreqKHz: const [],
      cpuCapacity: const [],
      bigCoreIndices: const [],
      cpuFeatures: const [],
      isLowRamDevice: false,
    );
  }

  @override
  Future<MemorySample> sampleMemory() async => _sample();

  @override
  Stream<PlatformSignal> signals() => const Stream.empty();

  @override
  Future<bool> setProcessStateSummary(Uint8List summary) async => false;

  @override
  Future<List<String>> excludeFromBackup(String path, {required bool includeSqliteSidecars}) async => const [];

  @override
  Future<bool> notificationsPermitted() async => false;

  @override
  Future<LeaseResult> beginLease(LeaseRequest request) => throw UnimplementedError();

  @override
  Future<void> updateLease(String id, double? progress, String? text) async {}

  @override
  Future<void> endLease(String id) async {}
}
