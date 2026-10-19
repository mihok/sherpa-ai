import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart';

import '../backend.dart';
import '../memory/pressure_policy.dart';
import '../messages.pigeon.dart';
import '../process_state.dart';

/// How the previous process ended (Android `ApplicationExitInfo`).
enum ExitKind {
  /// Android 17 limiter: `REASON_OTHER` + "MemoryLimiter:AnonSwap".
  memoryLimiter,

  /// `REASON_LOW_MEMORY` (LMK, where the device reports it).
  lowMemory,

  /// SIGKILL on a device without LMK reporting: most likely LMK.
  likelyLowMemory,
  signaled,
  crash,
  nativeCrash,
  anr,
  excessiveResourceUsage,
  userStopped,
  exitSelf,
  freezer,

  /// Package update, permission change, dependency died, …
  system,
  other,
  unknown,
}

/// Kill forensics: the last `ApplicationExitInfo` plus the summary the dead
/// process wrote with [ProcessStateRecorder] (R07 §2.4).
@immutable
final class ExitForensics {
  const ExitForensics({
    required this.reason,
    required this.reasonName,
    required this.kind,
    required this.timestamp,
    this.description,
    this.status,
    this.importance,
    this.pssBytes,
    this.rssBytes,
    this.processName,
    this.processStateSummary,
  });

  factory ExitForensics.fromNative(ExitRecord r) => ExitForensics(
        reason: r.reason,
        reasonName: r.reasonName,
        kind: ExitKind.values.where((k) => k.name == r.classification).firstOrNull ?? ExitKind.unknown,
        timestamp: DateTime.fromMillisecondsSinceEpoch(r.timestampMs, isUtc: true),
        description: r.details,
        status: r.status,
        importance: r.importance,
        pssBytes: r.pssBytes,
        rssBytes: r.rssBytes,
        processName: r.processName,
        processStateSummary: r.processStateSummary,
      );

  factory ExitForensics.fromJson(JsonMap j) => ExitForensics(
        reason: j.req<num>('reason').toInt(),
        reasonName: j.req<String>('reasonName'),
        kind: ExitKind.values.where((k) => k.name == j.opt<String>('kind')).firstOrNull ?? ExitKind.unknown,
        timestamp: DateTime.parse(j.req<String>('timestamp')),
        description: j.opt<String>('description'),
        status: j.optInt('status'),
        importance: j.optInt('importance'),
        pssBytes: j.optInt('pssBytes'),
        rssBytes: j.optInt('rssBytes'),
        processName: j.opt<String>('processName'),
        processStateSummary: switch (j.opt<String>('processStateSummary')) {
          final String b64 => base64Decode(b64),
          null => null,
        },
      );

  /// `ApplicationExitInfo.REASON_*`.
  final int reason;
  final String reasonName;
  final ExitKind kind;
  final DateTime timestamp;
  final String? description;
  final int? status;
  final int? importance;
  final int? pssBytes;
  final int? rssBytes;
  final String? processName;
  final Uint8List? processStateSummary;

  /// The killed process ran out of memory (any of the three memory kinds):
  /// the trigger for an automatic model/context/backend downgrade.
  bool get wasMemoryKill =>
      kind == ExitKind.memoryLimiter || kind == ExitKind.lowMemory || kind == ExitKind.likelyLowMemory;

  String? get summaryText {
    final b = processStateSummary;
    return b == null ? null : utf8.decode(b, allowMalformed: true);
  }

  /// [summaryText] parsed, when it was written by [ProcessStateRecorder.record].
  ProcessStateSummary? get summary => ProcessStateSummary.tryParse(summaryText);

  JsonMap toJson() => compact({
        'reason': reason,
        'reasonName': reasonName,
        'kind': kind.name,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'description': description,
        'status': status,
        'importance': importance,
        'pssBytes': pssBytes,
        'rssBytes': rssBytes,
        'processName': processName,
        'processStateSummary': processStateSummary == null ? null : base64Encode(processStateSummary!),
      });
}

/// CPU facts for thread counts and engine variant selection.
@immutable
final class CpuInfo {
  const CpuInfo({
    required this.cores,
    this.maxFreqKHz = const [],
    this.capacity = const [],
    this.bigCoreIndices = const [],
    this.performanceCores,
    this.features = const {},
  });

  factory CpuInfo.fromJson(JsonMap j) => CpuInfo(
        cores: j.req<num>('cores').toInt(),
        maxFreqKHz: [for (final v in j.opt<List<Object?>>('maxFreqKHz') ?? const <Object?>[]) (v as num?)?.toInt()],
        capacity: [for (final v in j.opt<List<Object?>>('capacity') ?? const <Object?>[]) (v as num?)?.toInt()],
        bigCoreIndices: [for (final v in j.opt<List<Object?>>('bigCoreIndices') ?? const <Object?>[]) (v! as num).toInt()],
        performanceCores: j.optInt('performanceCores'),
        features: {for (final f in j.opt<List<Object?>>('features') ?? const <Object?>[]) '$f'},
      );

  final int cores;

  /// Per core, kHz; null = unknown (Android only).
  final List<int?> maxFreqKHz;

  /// Per core scheduler capacity (0..1024); null = unknown (Android only).
  final List<int?> capacity;

  /// Cores outside the lowest-capacity cluster (Android). Use their count as
  /// llama.cpp `n_threads`; do not pin (R07 §3.4).
  final List<int> bigCoreIndices;

  /// Big/performance core count: iOS `hw.perflevel0.physicalcpu`, Android
  /// `bigCoreIndices.length`.
  final int? performanceCores;

  /// dotprod, i8mm, sve, sve2, sme, sme2, bf16, fp16.
  final Set<String> features;

  /// Highest per-core max frequency, kHz.
  int? get peakFreqKHz {
    final known = [for (final f in maxFreqKHz) if (f != null && f > 0) f];
    return known.isEmpty ? null : known.reduce((a, b) => a > b ? a : b);
  }

  /// Suggested decode thread count: the big cores, or every core when the
  /// topology is unknown.
  int get recommendedThreads => performanceCores != null && performanceCores! > 0 ? performanceCores! : cores;

  JsonMap toJson() => compact({
        'cores': cores,
        'maxFreqKHz': maxFreqKHz.isEmpty ? null : maxFreqKHz,
        'capacity': capacity.isEmpty ? null : capacity,
        'bigCoreIndices': bigCoreIndices.isEmpty ? null : bigCoreIndices,
        'performanceCores': performanceCores,
        'features': features.isEmpty ? null : (features.toList()..sort()),
      });
}

/// A point-in-time device description: pure data, JSON round-trippable
/// (diagnostics export, bug reports), and convertible to sherpa_hub's
/// [DeviceProfile] for device-fit.
@immutable
final class DeviceSnapshot {
  const DeviceSnapshot({
    required this.platform,
    required this.osVersion,
    required this.capturedAt,
    required this.cpu,
    this.apiLevel,
    this.manufacturer,
    this.model,
    this.socManufacturer,
    this.socModel,
    this.hardware,
    this.machine,
    this.totalRamBytes,
    this.advertisedRamBytes,
    this.availableRamBytes,
    this.perProcessLimitHintBytes,
    this.appFootprintBytes,
    this.freeStorageBytes,
    this.totalStorageBytes,
    this.isLowRamDevice = false,
    this.batteryLevel,
    this.charging,
    this.thermal = ThermalLevel.nominal,
    this.lowPowerMode = false,
    this.lastExit,
  });

  /// Maps the raw Pigeon [DeviceInfo]. [foreground] selects the Android 17
  /// limiter budget used for [perProcessLimitHintBytes].
  factory DeviceSnapshot.fromNative(
    DeviceInfo info, {
    PressurePolicy policy = const PressurePolicy(),
    bool foreground = true,
    DateTime? capturedAt,
  }) {
    final m = info.memory;
    int? orNull(int v) => v > 0 ? v : null;
    return DeviceSnapshot(
      platform: switch (info.platform) {
        'android' => DevicePlatform.android,
        'ios' => DevicePlatform.ios,
        _ => DevicePlatform.other,
      },
      osVersion: info.osVersion,
      apiLevel: info.apiLevel,
      manufacturer: info.manufacturer,
      model: info.model,
      socManufacturer: _blankToNull(info.socManufacturer),
      socModel: _blankToNull(info.socModel),
      hardware: info.hardware,
      machine: info.machine,
      totalRamBytes: policy.totalBytes(m),
      advertisedRamBytes: m.advertisedMemBytes,
      availableRamBytes: policy.physicalAvailableBytes(m),
      perProcessLimitHintBytes: policy.perProcessLimitBytes(m, foreground: foreground),
      appFootprintBytes: policy.appFootprintBytes(m),
      freeStorageBytes: info.freeStorageBytes,
      totalStorageBytes: info.totalStorageBytes,
      cpu: CpuInfo(
        cores: info.cpuCores,
        maxFreqKHz: [for (final f in info.cpuMaxFreqKHz) orNull(f)],
        capacity: [for (final c in info.cpuCapacity) orNull(c)],
        bigCoreIndices: info.bigCoreIndices,
        performanceCores: info.performanceCores,
        features: info.cpuFeatures.toSet(),
      ),
      isLowRamDevice: info.isLowRamDevice,
      batteryLevel: info.batteryLevel,
      charging: info.charging,
      thermal: policy.thermal(platform: info.platform, status: m.thermalStatus, headroom: m.thermalHeadroom),
      lowPowerMode: m.lowPowerMode,
      lastExit: info.lastExit == null ? null : ExitForensics.fromNative(info.lastExit!),
      capturedAt: capturedAt ?? DateTime.fromMillisecondsSinceEpoch(m.timestampMs, isUtc: true),
    );
  }

  factory DeviceSnapshot.fromJson(JsonMap j) => DeviceSnapshot(
        platform: DevicePlatform.values.byName(j.req<String>('platform')),
        osVersion: j.req<String>('osVersion'),
        capturedAt: DateTime.parse(j.req<String>('capturedAt')),
        cpu: CpuInfo.fromJson(j.obj('cpu')),
        apiLevel: j.optInt('apiLevel'),
        manufacturer: j.opt<String>('manufacturer'),
        model: j.opt<String>('model'),
        socManufacturer: j.opt<String>('socManufacturer'),
        socModel: j.opt<String>('socModel'),
        hardware: j.opt<String>('hardware'),
        machine: j.opt<String>('machine'),
        totalRamBytes: j.optInt('totalRamBytes'),
        advertisedRamBytes: j.optInt('advertisedRamBytes'),
        availableRamBytes: j.optInt('availableRamBytes'),
        perProcessLimitHintBytes: j.optInt('perProcessLimitHintBytes'),
        appFootprintBytes: j.optInt('appFootprintBytes'),
        freeStorageBytes: j.optInt('freeStorageBytes'),
        totalStorageBytes: j.optInt('totalStorageBytes'),
        isLowRamDevice: j.opt<bool>('isLowRamDevice') ?? false,
        batteryLevel: j.optDouble('batteryLevel'),
        charging: j.opt<bool>('charging'),
        thermal: ThermalLevel.values.byName(j.opt<String>('thermal') ?? 'nominal'),
        lowPowerMode: j.opt<bool>('lowPowerMode') ?? false,
        lastExit: switch (j.optObj('lastExit')) {
          final JsonMap e => ExitForensics.fromJson(e),
          null => null,
        },
      );

  /// Reads the device now.
  static Future<DeviceSnapshot> capture({
    PlatformBackend? backend,
    PressurePolicy policy = const PressurePolicy(),
    bool foreground = true,
  }) async =>
      DeviceSnapshot.fromNative(
        await (backend ?? SherpaPlatform.backend).deviceInfo(),
        policy: policy,
        foreground: foreground,
      );

  final DevicePlatform platform;

  /// Android `Build.VERSION.RELEASE` ("17"), iOS system version ("27.0.1").
  final String osVersion;

  /// Android API level (37 = Android 17).
  final int? apiLevel;
  final String? manufacturer;
  final String? model;

  /// Android 12+ (`Build.SOC_MANUFACTURER`/`SOC_MODEL`), e.g. "QTI"/"SM8650".
  final String? socManufacturer;
  final String? socModel;

  /// Android `Build.HARDWARE`; iOS `hw.model` (board id).
  final String? hardware;

  /// iOS `hw.machine` ("iPhone17,1"); Android `Build.DEVICE`.
  final String? machine;

  /// Kernel-visible RAM (`MemoryInfo.totalMem`, `ProcessInfo.physicalMemory`).
  final int? totalRamBytes;

  /// Android 14+ retail RAM figure (≥ [totalRamBytes]).
  final int? advertisedRamBytes;

  /// Physical headroom: Android `availMem − threshold`, iOS
  /// `os_proc_available_memory()`. Unlike `MemoryState.availableBytes` this
  /// is *not* capped by the Android limiter, because device-fit applies the
  /// limiter to anonymous memory only ([perProcessLimitHintBytes]).
  final int? availableRamBytes;

  /// iOS: `os_proc_available_memory() + phys_footprint` (the jetsam limit);
  /// Android 17+: limiter estimate (UNVERIFIED ratio, see [PressurePolicy]).
  final int? perProcessLimitHintBytes;
  final int? appFootprintBytes;

  /// Android StatFs on `filesDir`; iOS
  /// `volumeAvailableCapacityForImportantUsage`.
  final int? freeStorageBytes;
  final int? totalStorageBytes;
  final CpuInfo cpu;

  /// Android `isLowRamDevice()` ("1 GB or less"): treat as no local LLM.
  final bool isLowRamDevice;

  /// 0..1.
  final double? batteryLevel;
  final bool? charging;
  final ThermalLevel thermal;
  final bool lowPowerMode;

  /// Android 11+: how the previous process ended.
  final ExitForensics? lastExit;
  final DateTime capturedAt;

  /// "Google Pixel 9" / "iPhone17,1".
  String? get displayModel {
    if (platform == DevicePlatform.ios) return machine ?? model;
    final mfr = manufacturer, mdl = model;
    if (mdl == null) return mfr;
    if (mfr == null || mdl.toLowerCase().startsWith(mfr.toLowerCase())) return mdl;
    return '${mfr[0].toUpperCase()}${mfr.substring(1)} $mdl';
  }

  /// Rough speed tier for device-fit advisories. POLICY (no published
  /// table), from the features and clocks llama.cpp's CPU kernels care about:
  /// - high: SME, or i8mm (ARMv8.6+ int8 matmul) with ≥ 2.8 GHz big cores;
  ///   on iOS i8mm alone (A15 and later).
  /// - low: no dot product, < 2.0 GHz peak, or a low-RAM device.
  /// - mid: everything else, and unknowns.
  CpuClass get cpuClass {
    final f = cpu.features;
    final peak = cpu.peakFreqKHz;
    if (isLowRamDevice) return CpuClass.low;
    if (f.contains('sme')) return CpuClass.high;
    if (platform == DevicePlatform.ios) return f.contains('i8mm') ? CpuClass.high : CpuClass.mid;
    if (f.isNotEmpty && !f.contains('dotprod')) return CpuClass.low;
    if (peak != null && peak < 2000000) return CpuClass.low;
    if (f.contains('i8mm') && peak != null && peak >= 2800000) return CpuClass.high;
    return CpuClass.mid;
  }

  /// Android release major ("17") from [osVersion], or from [apiLevel] when
  /// the release string is a codename or a preview (DeviceProfile.osMajor
  /// gates the Android 17 limiter on it).
  String get _profileOsVersion {
    if (platform != DevicePlatform.android) return osVersion;
    if (RegExp(r'^\d').hasMatch(osVersion.trim())) return osVersion;
    final api = apiLevel;
    if (api == null) return osVersion;
    return '${androidReleaseForApi(api)}';
  }

  /// Android API level → release major (29 → 10 … 36 → 16, 37 → 17).
  static int androidReleaseForApi(int api) => switch (api) {
        <= 28 => api - 19, // 28 → 9 (only used for out-of-range input)
        29 => 10,
        30 => 11,
        31 || 32 => 12,
        _ => api - 20,
      };

  /// The sherpa_hub fit profile. Measured values are passed through as-is;
  /// [increasedMemoryLimit] (iOS entitlement in the signed build) cannot be
  /// read at runtime and stays the caller's claim.
  DeviceProfile toDeviceProfile({
    bool increasedMemoryLimit = true,
    bool? separateInferenceProcess,
    Set<Accelerator>? accelerators,
  }) =>
      DeviceProfile(
        platform: platform,
        totalRamBytes: totalRamBytes ?? 0,
        osVersion: _profileOsVersion,
        availableRamBytes: availableRamBytes,
        perProcessCapBytes: perProcessLimitHintBytes,
        freeStorageBytes: freeStorageBytes,
        cpuClass: cpuClass,
        cpuFeatures: cpu.features,
        // Every iOS 17 device has a Metal GPU; Android GPU backends are
        // allow-listed by the engine after a parity check, not guessed here.
        accelerators: accelerators ?? (platform == DevicePlatform.ios ? const {Accelerator.metal} : const {}),
        thermal: thermal,
        lowPowerMode: lowPowerMode,
        increasedMemoryLimit: increasedMemoryLimit,
        separateInferenceProcess: separateInferenceProcess,
        model: displayModel,
      );

  JsonMap toJson() => compact({
        'platform': platform.name,
        'osVersion': osVersion,
        'apiLevel': apiLevel,
        'manufacturer': manufacturer,
        'model': model,
        'socManufacturer': socManufacturer,
        'socModel': socModel,
        'hardware': hardware,
        'machine': machine,
        'totalRamBytes': totalRamBytes,
        'advertisedRamBytes': advertisedRamBytes,
        'availableRamBytes': availableRamBytes,
        'perProcessLimitHintBytes': perProcessLimitHintBytes,
        'appFootprintBytes': appFootprintBytes,
        'freeStorageBytes': freeStorageBytes,
        'totalStorageBytes': totalStorageBytes,
        'cpu': cpu.toJson(),
        'isLowRamDevice': isLowRamDevice,
        'batteryLevel': batteryLevel,
        'charging': charging,
        'thermal': thermal.name,
        'lowPowerMode': lowPowerMode,
        'lastExit': lastExit?.toJson(),
        'capturedAt': capturedAt.toUtc().toIso8601String(),
      });

  static String? _blankToNull(String? s) => s == null || s.trim().isEmpty || s == 'unknown' ? null : s;
}
