import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_platform/sherpa_platform.dart';
import 'package:sherpa_platform/testing.dart';

const _mib = 1024 * 1024;
const _gib = 1024 * _mib;

void main() {
  const policy = PressurePolicy();

  group('Android trim levels', () {
    test('only UI_HIDDEN/BACKGROUND are live on 34+; legacy levels still map', () {
      expect(policy.trimPressure(0), MemoryPressure.normal);
      expect(policy.trimPressure(5), MemoryPressure.moderate); // RUNNING_MODERATE
      expect(policy.trimPressure(10), MemoryPressure.moderate); // RUNNING_LOW
      expect(policy.trimPressure(15), MemoryPressure.critical); // RUNNING_CRITICAL
      expect(policy.trimPressure(20), MemoryPressure.moderate); // UI_HIDDEN
      expect(policy.trimPressure(40), MemoryPressure.critical); // BACKGROUND
      expect(policy.trimPressure(60), MemoryPressure.critical); // MODERATE
      expect(policy.trimPressure(80), MemoryPressure.critical); // COMPLETE
    });

    test('hidden-UI trim levels in a sample are ignored while in the foreground', () {
      final s = FakePlatformBackend.androidSample(lastTrimLevel: 40);
      expect(policy.samplePressure(s, foreground: true), MemoryPressure.normal);
      expect(policy.samplePressure(s, foreground: false), MemoryPressure.critical);
      // Legacy RUNNING_CRITICAL is a foreground level.
      expect(policy.samplePressure(FakePlatformBackend.androidSample(lastTrimLevel: 15), foreground: true),
          MemoryPressure.critical);
    });
  });

  group('Android headroom', () {
    test('lowMemory is critical regardless of numbers', () {
      final s = FakePlatformBackend.androidSample(lowMemory: true);
      expect(policy.samplePressure(s, foreground: true), MemoryPressure.critical);
    });

    test('availMem − threshold against max(floor, share of RAM)', () {
      // 7.5 GiB total: moderate below max(768 MiB, 768 MiB), critical below max(256 MiB, 307 MiB).
      MemoryPressure at(int availMiB) => policy.samplePressure(
            FakePlatformBackend.androidSample(availMem: (availMiB + 256) * _mib, threshold: 256 * _mib),
            foreground: true,
          );
      expect(at(2000), MemoryPressure.normal);
      expect(at(800), MemoryPressure.normal);
      expect(at(700), MemoryPressure.moderate);
      expect(at(320), MemoryPressure.moderate);
      expect(at(300), MemoryPressure.critical);
      expect(at(0), MemoryPressure.critical);
    });

    test('availableBytes is uncapped before API 37', () {
      final s = FakePlatformBackend.androidSample(apiLevel: 36, availMem: 3 * _gib, threshold: 256 * _mib);
      expect(policy.availableBytes(s, foreground: true), 3 * _gib - 256 * _mib);
      expect(policy.limiterEstimateBytes(s, foreground: true), isNull);
      expect(policy.perProcessLimitBytes(s, foreground: true), isNull);
    });

    test('API 37 caps availableBytes by the limiter headroom (advertised RAM × 0.5 / 0.25)', () {
      // 4 GB device: "2 GB in the foreground and 1 GB in the background".
      final s = FakePlatformBackend.androidSample(
        apiLevel: 37,
        totalMem: 3600 * _mib,
        advertisedMem: 4 * _gib,
        availMem: 1800 * _mib,
        threshold: 200 * _mib,
        anonSwap: 1200 * _mib,
      );
      expect(policy.limiterEstimateBytes(s, foreground: true), 2 * _gib);
      expect(policy.limiterEstimateBytes(s, foreground: false), 1 * _gib);
      // Physical headroom 1600 MiB, limiter headroom 2048 − 1200 = 848 MiB.
      expect(policy.availableBytes(s, foreground: true), 848 * _mib);
      // Background: 1024 − 1200 < 0 → 0.
      expect(policy.availableBytes(s, foreground: false), 0);
      expect(policy.physicalAvailableBytes(s), 1600 * _mib);
      expect(policy.samplePressure(s, foreground: true), MemoryPressure.normal);
      expect(policy.samplePressure(s, foreground: false), MemoryPressure.critical);
    });

    test('limiter falls back to totalMem without advertisedMem, and needs RssAnon', () {
      final s = FakePlatformBackend.androidSample(apiLevel: 37, totalMem: 6 * _gib, advertisedMem: null);
      expect(policy.limiterEstimateBytes(s, foreground: true), 3 * _gib);
      final noAnon = FakePlatformBackend.androidSample(apiLevel: 37, anonSwap: null);
      expect(policy.availableBytes(noAnon, foreground: true), policy.physicalAvailableBytes(noAnon));
    });

    test('footprint prefers anon+swap (the limiter metric) over VmRSS', () {
      final s = FakePlatformBackend.androidSample(anonSwap: 500 * _mib);
      expect(policy.appFootprintBytes(s), 500 * _mib);
      expect(policy.totalBytes(s), 7680 * _mib);
    });
  });

  group('iOS os_proc_available_memory tiers', () {
    MemoryPressure at(int availMiB, {int footprintMiB = 300}) => policy.samplePressure(
          FakePlatformBackend.iosSample(procAvailable: availMiB * _mib, footprint: footprintMiB * _mib),
          foreground: true,
        );

    test('6 GB limit: moderate < max(512 MiB, 15 %), critical < max(192 MiB, 8 %)', () {
      // limit = avail + 300 MiB ≈ 6 GiB → 15 % ≈ 920 MiB, 8 % ≈ 490 MiB.
      expect(at(5800), MemoryPressure.normal);
      expect(at(1000), MemoryPressure.normal);
      expect(at(900, footprintMiB: 5200), MemoryPressure.moderate);
      expect(at(450, footprintMiB: 5650), MemoryPressure.critical);
    });

    test('small 2 GB limit uses the absolute floors', () {
      // limit ≈ 2.1 GB → 15 % = 315 MiB < 512 MiB floor.
      expect(at(700, footprintMiB: 1400), MemoryPressure.normal);
      expect(at(500, footprintMiB: 1600), MemoryPressure.moderate);
      expect(at(180, footprintMiB: 1920), MemoryPressure.critical);
    });

    test('0 means over the limit', () {
      expect(at(0), MemoryPressure.critical);
    });

    test('per-process limit is available + footprint', () {
      final s = FakePlatformBackend.iosSample(procAvailable: 5 * _gib, footprint: 1 * _gib);
      expect(policy.perProcessLimitBytes(s, foreground: true), 6 * _gib);
      expect(policy.availableBytes(s, foreground: true), 5 * _gib);
      expect(policy.appFootprintBytes(s), 1 * _gib);
      expect(policy.totalBytes(s), 8 * _gib);
    });

    test('dispatch levels', () {
      expect(policy.dispatchPressure(0), MemoryPressure.normal);
      expect(policy.dispatchPressure(1), MemoryPressure.moderate);
      expect(policy.dispatchPressure(2), MemoryPressure.critical);
    });
  });

  group('thermal', () {
    test('iOS ThermalState maps 1:1', () {
      expect([for (var i = 0; i < 4; i++) policy.thermal(platform: 'ios', status: i)], ThermalLevel.values);
      expect(policy.thermal(platform: 'ios', status: 9), ThermalLevel.critical);
    });

    test('Android status: MODERATE throttles, SEVERE and above pause', () {
      ThermalLevel s(int status) => policy.thermal(platform: 'android', status: status);
      expect(s(0), ThermalLevel.nominal); // NONE
      expect(s(1), ThermalLevel.fair); // LIGHT
      expect(s(2), ThermalLevel.serious); // MODERATE
      expect(s(3), ThermalLevel.critical); // SEVERE
      expect(s(4), ThermalLevel.critical); // CRITICAL
      expect(s(6), ThermalLevel.critical); // SHUTDOWN
    });

    test('Android headroom forecast raises but never lowers the status level', () {
      ThermalLevel h(double? v, {int status = 0}) => policy.thermal(platform: 'android', status: status, headroom: v);
      expect(h(null), ThermalLevel.nominal);
      expect(h(double.nan), ThermalLevel.nominal);
      expect(h(0.5), ThermalLevel.nominal);
      expect(h(0.75), ThermalLevel.fair);
      expect(h(0.9), ThermalLevel.serious);
      expect(h(1.0), ThermalLevel.critical); // 1.0 = SEVERE
      expect(h(0.2, status: 3), ThermalLevel.critical);
    });
  });
}
