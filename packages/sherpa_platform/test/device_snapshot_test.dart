import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart';
import 'package:sherpa_platform/sherpa_platform.dart';
import 'package:sherpa_platform/testing.dart';

const _mib = 1024 * 1024;
const _gib = 1024 * _mib;

DeviceInfo _android({
  int apiLevel = 37,
  String release = '17',
  List<String> features = const ['bf16', 'dotprod', 'fp16', 'i8mm', 'sve', 'sve2'],
  List<int> freq = const [2016000, 2016000, 2016000, 2803200, 2803200, 2803200, 2803200, 3187200],
  ExitRecord? lastExit,
  bool lowRam = false,
}) =>
    DeviceInfo(
      platform: 'android',
      osVersion: release,
      apiLevel: apiLevel,
      manufacturer: 'Google',
      model: 'Pixel 9',
      socManufacturer: 'Google',
      socModel: 'Tensor G4',
      hardware: 'caiman',
      machine: 'caiman',
      memory: FakePlatformBackend.androidSample(
        apiLevel: apiLevel,
        totalMem: 11 * _gib,
        advertisedMem: 12 * _gib,
        availMem: 5 * _gib,
        threshold: 512 * _mib,
        anonSwap: 600 * _mib,
        thermalStatus: 2,
        timestampMs: DateTime.utc(2026, 10, 18, 9).millisecondsSinceEpoch,
      ),
      freeStorageBytes: 40 * _gib,
      totalStorageBytes: 128 * _gib,
      cpuCores: freq.length,
      cpuMaxFreqKHz: freq,
      cpuCapacity: List.filled(freq.length, 0),
      bigCoreIndices: const [3, 4, 5, 6, 7],
      performanceCores: 5,
      cpuFeatures: features,
      isLowRamDevice: lowRam,
      batteryLevel: 0.82,
      charging: false,
      lastExit: lastExit,
    );

DeviceInfo _ios() => DeviceInfo(
      platform: 'ios',
      osVersion: '27.0.1',
      model: 'iPhone',
      hardware: 'D93AP',
      machine: 'iPhone17,1',
      memory: FakePlatformBackend.iosSample(
        procAvailable: 5 * _gib,
        footprint: 1 * _gib,
        physicalMemory: 8 * _gib,
        thermalStatus: 1,
        lowPowerMode: true,
        timestampMs: DateTime.utc(2026, 10, 18, 9).millisecondsSinceEpoch,
      ),
      freeStorageBytes: 64 * _gib,
      totalStorageBytes: 256 * _gib,
      cpuCores: 6,
      cpuMaxFreqKHz: const [],
      cpuCapacity: const [],
      bigCoreIndices: const [],
      performanceCores: 2,
      cpuFeatures: const ['bf16', 'dotprod', 'fp16', 'i8mm', 'sme', 'sme2'],
      isLowRamDevice: false,
      batteryLevel: 0.5,
      charging: true,
    );

ExitRecord _memoryKill() => ExitRecord(
      reason: 13,
      reasonName: 'OTHER',
      classification: 'memoryLimiter',
      details: 'MemoryLimiter:AnonSwap',
      timestampMs: DateTime.utc(2026, 10, 17, 22).millisecondsSinceEpoch,
      status: 9,
      importance: 125,
      pssBytes: 1900 * _mib,
      rssBytes: 2100 * _mib,
      processName: 'io.github.mihok.sherpa',
      processStateSummary: Uint8List.fromList(utf8.encode('v1 p=decode m=1a2b3c4d b=cpu c=8192 fg=0')),
    );

void main() {
  group('Android snapshot', () {
    final snap = DeviceSnapshot.fromNative(_android(lastExit: _memoryKill()));

    test('maps memory: physical headroom stays uncapped, limiter goes to the hint', () {
      expect(snap.platform, DevicePlatform.android);
      expect(snap.totalRamBytes, 11 * _gib);
      expect(snap.advertisedRamBytes, 12 * _gib);
      expect(snap.availableRamBytes, 5 * _gib - 512 * _mib);
      // API 37: limiter estimate = advertised × 0.5 (foreground).
      expect(snap.perProcessLimitHintBytes, 6 * _gib);
      expect(snap.appFootprintBytes, 600 * _mib);
      expect(snap.thermal, ThermalLevel.serious);
      expect(snap.capturedAt, DateTime.utc(2026, 10, 18, 9));
    });

    test('maps CPU and device facts', () {
      expect(snap.cpu.cores, 8);
      expect(snap.cpu.bigCoreIndices, [3, 4, 5, 6, 7]);
      expect(snap.cpu.recommendedThreads, 5);
      expect(snap.cpu.peakFreqKHz, 3187200);
      expect(snap.cpu.capacity, everyElement(isNull), reason: '0 = unknown');
      expect(snap.cpu.features, containsAll(['dotprod', 'i8mm', 'sve2']));
      expect(snap.displayModel, 'Google Pixel 9');
      expect(snap.cpuClass, CpuClass.high);
      expect(snap.batteryLevel, 0.82);
    });

    test('exit forensics decode the summary written before the kill', () {
      final e = snap.lastExit!;
      expect(e.kind, ExitKind.memoryLimiter);
      expect(e.wasMemoryKill, isTrue);
      expect(e.summaryText, 'v1 p=decode m=1a2b3c4d b=cpu c=8192 fg=0');
      expect(e.summary, const ProcessStateSummary(
        phase: ProcessPhase.decode,
        modelHash: '1a2b3c4d',
        backend: 'cpu',
        contextTokens: 8192,
        foreground: false,
      ));
      expect(e.timestamp, DateTime.utc(2026, 10, 17, 22));
    });

    test('unknown classifications degrade to ExitKind.unknown', () {
      final r = _memoryKill()..classification = 'somethingNew';
      expect(ExitForensics.fromNative(r).kind, ExitKind.unknown);
      expect(ExitForensics.fromNative(r).wasMemoryKill, isFalse);
    });

    test('toDeviceProfile feeds sherpa_hub device-fit', () {
      final p = snap.toDeviceProfile();
      expect(p.platform, DevicePlatform.android);
      expect(p.totalRamBytes, 11 * _gib);
      expect(p.osVersion, '17');
      expect(p.osMajor, 17, reason: 'gates the Android 17 limiter in device-fit');
      expect(p.availableRamBytes, 5 * _gib - 512 * _mib);
      expect(p.perProcessCapBytes, 6 * _gib);
      expect(p.freeStorageBytes, 40 * _gib);
      expect(p.cpuClass, CpuClass.high);
      expect(p.cpuFeatures, contains('dotprod'));
      expect(p.accelerators, isEmpty, reason: 'GPU backends are allow-listed by the engine, not guessed');
      expect(p.thermal, ThermalLevel.serious);
      expect(p.model, 'Google Pixel 9');
      expect(p.separateInferenceProcess, isNull);
      // Survives sherpa_hub's own JSON.
      final back = DeviceProfile.fromJson(p.toJson());
      expect(back.toJson(), p.toJson());
    });

    test('toDeviceProfile passes caller claims through', () {
      final p = snap.toDeviceProfile(separateInferenceProcess: false, accelerators: {Accelerator.openclAdreno});
      expect(p.separateInferenceProcess, isFalse);
      expect(p.accelerators, {Accelerator.openclAdreno});
    });

    test('a preview release string falls back to the API level', () {
      final p = DeviceSnapshot.fromNative(_android(release: 'CinnamonBun')).toDeviceProfile();
      expect(p.osVersion, '17');
      expect(DeviceSnapshot.androidReleaseForApi(29), 10);
      expect(DeviceSnapshot.androidReleaseForApi(32), 12);
      expect(DeviceSnapshot.androidReleaseForApi(36), 16);
    });

    test('no limiter hint before API 37', () {
      final s = DeviceSnapshot.fromNative(_android(apiLevel: 36, release: '16'));
      expect(s.perProcessLimitHintBytes, isNull);
      expect(s.toDeviceProfile().perProcessCapBytes, isNull);
    });

    test('background capture uses the background limiter budget', () {
      final s = DeviceSnapshot.fromNative(_android(), foreground: false);
      expect(s.perProcessLimitHintBytes, 3 * _gib);
    });
  });

  group('cpuClass policy', () {
    CpuClass cls(List<String> features, List<int> freq, {bool lowRam = false}) =>
        DeviceSnapshot.fromNative(_android(features: features, freq: freq, lowRam: lowRam)).cpuClass;

    test('tiers', () {
      expect(cls(['dotprod', 'i8mm'], [2000000, 3200000]), CpuClass.high);
      expect(cls(['dotprod', 'i8mm'], [1800000, 2400000]), CpuClass.mid);
      expect(cls(['dotprod'], [1800000, 2400000]), CpuClass.mid);
      expect(cls(['dotprod'], [1500000, 1900000]), CpuClass.low);
      expect(cls(['fp16'], [2000000, 2800000]), CpuClass.low, reason: 'no dot product');
      expect(cls(['sme'], [2000000]), CpuClass.high);
      expect(cls(const [], const []), CpuClass.mid, reason: 'unknown stays mid');
      expect(cls(['dotprod', 'i8mm'], [2000000, 3200000], lowRam: true), CpuClass.low);
    });
  });

  group('iOS snapshot', () {
    final snap = DeviceSnapshot.fromNative(_ios());

    test('maps os_proc_available_memory and the jetsam limit', () {
      expect(snap.platform, DevicePlatform.ios);
      expect(snap.totalRamBytes, 8 * _gib);
      expect(snap.availableRamBytes, 5 * _gib);
      expect(snap.perProcessLimitHintBytes, 6 * _gib);
      expect(snap.appFootprintBytes, 1 * _gib);
      expect(snap.thermal, ThermalLevel.fair);
      expect(snap.lowPowerMode, isTrue);
      expect(snap.displayModel, 'iPhone17,1');
      expect(snap.cpu.recommendedThreads, 2);
      expect(snap.lastExit, isNull);
    });

    test('toDeviceProfile', () {
      final p = snap.toDeviceProfile(increasedMemoryLimit: false);
      expect(p.platform, DevicePlatform.ios);
      expect(p.osVersion, '27.0.1');
      expect(p.availableRamBytes, 5 * _gib);
      expect(p.perProcessCapBytes, 6 * _gib);
      expect(p.accelerators, {Accelerator.metal});
      expect(p.cpuClass, CpuClass.high);
      expect(p.increasedMemoryLimit, isFalse);
      expect(p.lowPowerMode, isTrue);
    });

    test('device-fit runs on the profile (Qwen3-0.6B Q4_K_M fits, 8B does not)', () {
      final p = snap.toDeviceProfile();
      expect(p.osMajor, 27);
      ModelFootprintInput qwen(int layers, int embd, int ff, int bytes) => ModelFootprintInput(
            architecture: ModelArchitecture.dense(
                layers: layers, kvHeads: 8, headDim: 128, embeddingLength: embd, feedForwardLength: ff,
                vocabSize: 151936, headCount: 16, trainContextLength: 40960),
            weightBytes: bytes,
            quant: QuantTypes.q4_k_m);
      final small = assessFit(p, qwen(28, 1024, 3072, 396705472));
      expect(small.verdict, FitVerdict.fits);
      expect(small.budgetEstimated, isFalse, reason: 'measured os_proc_available_memory');
      final big = assessFit(p.copyWith(availableRamBytes: 2 * _gib), qwen(36, 4096, 12288, 5027783488));
      expect(big.verdict, FitVerdict.wontFit);
    });

    test('Android profile: device-fit applies the limiter hint as the process cap', () {
      final p = DeviceSnapshot.fromNative(_android()).toDeviceProfile();
      final r = assessFit(
        p,
        ModelFootprintInput(
          architecture: ModelArchitecture.dense(
              layers: 28, kvHeads: 8, headDim: 128, embeddingLength: 1024, feedForwardLength: 3072,
              vocabSize: 151936, headCount: 16, trainContextLength: 40960),
          weightBytes: 396705472,
          quant: QuantTypes.q4_k_m,
        ),
      );
      expect(r.processCapBytes, 6 * _gib);
      expect(r.verdict, FitVerdict.fits);
    });
  });

  group('JSON', () {
    test('Android round trip including exit forensics bytes', () {
      final snap = DeviceSnapshot.fromNative(_android(lastExit: _memoryKill()));
      final json = jsonDecode(jsonEncode(snap.toJson())) as Map<String, Object?>;
      final back = DeviceSnapshot.fromJson(json);
      expect(back.toJson(), snap.toJson());
      expect(back.lastExit!.summaryText, snap.lastExit!.summaryText);
      expect(back.cpu.maxFreqKHz, snap.cpu.maxFreqKHz);
      expect(json['thermal'], 'serious');
      expect((json['lastExit']! as Map)['kind'], 'memoryLimiter');
    });

    test('iOS round trip; nulls are omitted', () {
      final snap = DeviceSnapshot.fromNative(_ios());
      final json = snap.toJson();
      expect(json.containsKey('apiLevel'), isFalse);
      expect(json.containsKey('lastExit'), isFalse);
      expect(DeviceSnapshot.fromJson(json).toJson(), json);
    });

    test('capture() goes through the backend', () async {
      final backend = FakePlatformBackend(device: _ios());
      final snap = await DeviceSnapshot.capture(backend: backend);
      expect(snap.machine, 'iPhone17,1');
    });
  });
}
