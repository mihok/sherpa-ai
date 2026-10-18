import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

enum DevicePlatform { android, ios, other }

/// Rough CPU tier for speed advisories (big-core generation, not RAM).
enum CpuClass { low, mid, high }

/// Inference accelerators the engine may use (feature-detected and
/// parity-checked before use, PLAN §2).
enum Accelerator {
  /// Apple GPU via Metal (iOS).
  metal,

  /// llama.cpp OpenCL backend; in practice Qualcomm Adreno 7xx/8xx (R07 §1.7).
  openclAdreno,

  /// Vulkan; often slower than CPU on phones, off by default (R07 §1.7).
  vulkan,

  /// Vendor NPU (LiteRT / Hexagon), not used by llama.cpp here.
  npu,
}

/// What the platform plugin reports about the device right before a fit
/// decision. Measured values beat estimates: pass `availableRamBytes` from
/// iOS `os_proc_available_memory()` or Android `availMem − threshold`
/// (R06 §5, R07 §2.2) whenever possible.
@immutable
final class DeviceProfile {
  const DeviceProfile({
    required this.platform,
    required this.totalRamBytes,
    this.osVersion,
    this.availableRamBytes,
    this.perProcessCapBytes,
    this.freeStorageBytes,
    this.cpuClass = CpuClass.mid,
    this.cpuFeatures = const {},
    this.accelerators = const {},
    this.thermal = ThermalLevel.nominal,
    this.lowPowerMode = false,
    this.increasedMemoryLimit = true,
    this.separateInferenceProcess,
    this.model,
  });

  /// Builds a profile from the platform plugin's [MemoryState] (sherpa_core
  /// `MemoryMonitor`), whose `availableBytes` is already
  /// `os_proc_available_memory` / `availMem − threshold`.
  factory DeviceProfile.fromMemoryState(
    MemoryState state, {
    required DevicePlatform platform,
    required int totalRamBytes,
    String? osVersion,
    int? perProcessCapBytes,
    int? freeStorageBytes,
    CpuClass cpuClass = CpuClass.mid,
    Set<String> cpuFeatures = const {},
    Set<Accelerator> accelerators = const {},
    bool increasedMemoryLimit = true,
    String? model,
  }) =>
      DeviceProfile(
        platform: platform,
        totalRamBytes: state.totalBytes ?? totalRamBytes,
        osVersion: osVersion,
        availableRamBytes: state.availableBytes,
        perProcessCapBytes: perProcessCapBytes,
        freeStorageBytes: freeStorageBytes,
        cpuClass: cpuClass,
        cpuFeatures: cpuFeatures,
        accelerators: accelerators,
        thermal: state.thermal,
        lowPowerMode: state.lowPowerMode,
        increasedMemoryLimit: increasedMemoryLimit,
        model: model,
      );

  factory DeviceProfile.fromJson(JsonMap j) => DeviceProfile(
        platform: DevicePlatform.values.byName(j.req<String>('platform')),
        totalRamBytes: j.req<num>('totalRamBytes').toInt(),
        osVersion: j.opt<String>('osVersion'),
        availableRamBytes: j.optInt('availableRamBytes'),
        perProcessCapBytes: j.optInt('perProcessCapBytes'),
        freeStorageBytes: j.optInt('freeStorageBytes'),
        cpuClass: CpuClass.values.byName(j.opt<String>('cpuClass') ?? 'mid'),
        cpuFeatures: {for (final f in j.opt<List<Object?>>('cpuFeatures') ?? const <Object?>[]) '$f'},
        accelerators: {
          for (final a in j.opt<List<Object?>>('accelerators') ?? const <Object?>[]) Accelerator.values.byName('$a'),
        },
        thermal: ThermalLevel.values.byName(j.opt<String>('thermal') ?? 'nominal'),
        lowPowerMode: j.opt<bool>('lowPowerMode') ?? false,
        increasedMemoryLimit: j.opt<bool>('increasedMemoryLimit') ?? true,
        separateInferenceProcess: j.opt<bool>('separateInferenceProcess'),
        model: j.opt<String>('model'),
      );

  final DevicePlatform platform;

  /// "17", "26.1", ... Major version gates the Android 17 memory limiter.
  final String? osVersion;

  /// Kernel-visible RAM (`ActivityManager.MemoryInfo.totalMem`,
  /// `ProcessInfo.physicalMemory`).
  final int totalRamBytes;

  /// Memory this app can still use right now: iOS
  /// `os_proc_available_memory()` (already net of the app footprint and the
  /// jetsam limit), Android `availMem − threshold`.
  final int? availableRamBytes;

  /// Known per-process ceiling (iOS jetsam limit, Android 17 limiter value
  /// from `am memory-limiter status`); estimated when null.
  final int? perProcessCapBytes;
  final int? freeStorageBytes;
  final CpuClass cpuClass;

  /// `dotprod`, `i8mm`, `sve`, `sme` (runtime-detected ARM features).
  final Set<String> cpuFeatures;
  final Set<Accelerator> accelerators;
  final ThermalLevel thermal;
  final bool lowPowerMode;

  /// iOS `com.apple.developer.kernel.increased-memory-limit` is in the
  /// signed build (R06 §5: it must be in the provisioning profile).
  final bool increasedMemoryLimit;

  /// Android: inference runs in the isolated `:inference` process (PLAN §2
  /// default), so the app's own heap does not share its memory limit.
  /// Null = platform default (true on Android).
  final bool? separateInferenceProcess;

  /// Marketing name for diagnostics ("Pixel 9", "iPhone 16 Pro").
  final String? model;

  int? get osMajor {
    final v = osVersion;
    if (v == null) return null;
    return int.tryParse(RegExp(r'^\d+').firstMatch(v.trim())?.group(0) ?? '');
  }

  DeviceProfile copyWith({
    int? totalRamBytes,
    int? availableRamBytes,
    int? perProcessCapBytes,
    int? freeStorageBytes,
    ThermalLevel? thermal,
    bool? lowPowerMode,
  }) =>
      DeviceProfile(
        platform: platform,
        totalRamBytes: totalRamBytes ?? this.totalRamBytes,
        osVersion: osVersion,
        availableRamBytes: availableRamBytes ?? this.availableRamBytes,
        perProcessCapBytes: perProcessCapBytes ?? this.perProcessCapBytes,
        freeStorageBytes: freeStorageBytes ?? this.freeStorageBytes,
        cpuClass: cpuClass,
        cpuFeatures: cpuFeatures,
        accelerators: accelerators,
        thermal: thermal ?? this.thermal,
        lowPowerMode: lowPowerMode ?? this.lowPowerMode,
        increasedMemoryLimit: increasedMemoryLimit,
        separateInferenceProcess: separateInferenceProcess,
        model: model,
      );

  JsonMap toJson() => compact({
        'platform': platform.name,
        'osVersion': osVersion,
        'totalRamBytes': totalRamBytes,
        'availableRamBytes': availableRamBytes,
        'perProcessCapBytes': perProcessCapBytes,
        'freeStorageBytes': freeStorageBytes,
        'cpuClass': cpuClass.name,
        'cpuFeatures': cpuFeatures.isEmpty ? null : (cpuFeatures.toList()..sort()),
        'accelerators': accelerators.isEmpty ? null : [for (final a in accelerators) a.name],
        'thermal': thermal.name,
        'lowPowerMode': lowPowerMode,
        'increasedMemoryLimit': increasedMemoryLimit,
        'separateInferenceProcess': separateInferenceProcess,
        'model': model,
      });
}
