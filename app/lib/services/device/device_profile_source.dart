import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sherpa_hub/sherpa_hub.dart';

/// Where the device-fit engine gets its facts about this phone.
///
/// The real implementation comes from the `sherpa_platform` plugin
/// (`DeviceSnapshot.toDeviceProfile()`: measured `os_proc_available_memory`
/// / `availMem − threshold`, jetsam / Android 17 limiter values, free
/// storage, thermal state). Until the integrator plugs it in, the app uses
/// [FallbackDeviceProfileSource], which is deliberately pessimistic.
///
/// Called right before every fit or storage decision rather than cached:
/// available memory and free space change while the app runs (PLAN finding
/// 12, R07 §2.2), and a stale "fits" is exactly the silent failure R12 §2
/// warns about ("Silent model fallback when a local model doesn't fit RAM").
abstract interface class DeviceProfileSource {
  Future<DeviceProfile> current();
}

/// Conservative profile from `dart:io` alone.
///
/// - Platform from [Platform]; OS version from [Platform.operatingSystemVersion].
/// - Total RAM from `/proc/meminfo` where the kernel exposes it to apps
///   (Android, Linux hosts); [defaultTotalRamBytes] elsewhere (iOS has no
///   `/proc`). `MemAvailable` is deliberately **not** used as the available
///   budget: on Android the low-memory killer acts well above zero, so
///   `MemAvailable` over-states what an app can take (R07 §2.2). Leaving
///   `availableRamBytes` null makes `assessFit` estimate from total RAM and
///   say so ("Available memory was estimated…").
/// - Free storage is unknown without a platform call; [freeStorageBytes]
///   lets the caller supply it. Unknown free space never blocks a
///   download (the OS will refuse a full disk), but the UI says it was not
///   checked.
final class FallbackDeviceProfileSource implements DeviceProfileSource {
  FallbackDeviceProfileSource({
    this.defaultTotalRamBytes = 4 * _gib,
    this.freeStorageBytes,
    this.meminfoPath = '/proc/meminfo',
    DevicePlatform? platform,
  }) : _platform = platform;

  static const int _gib = 1024 * 1024 * 1024;

  /// Used when RAM can't be read. 4 GB is the low end of phones that can
  /// run a 1–2B model; guessing low means "Tight" rather than an OOM kill.
  final int defaultTotalRamBytes;

  final Future<int?> Function()? freeStorageBytes;
  final String meminfoPath;
  final DevicePlatform? _platform;

  DevicePlatform get platform =>
      _platform ??
      (Platform.isAndroid
          ? DevicePlatform.android
          : Platform.isIOS
              ? DevicePlatform.ios
              : DevicePlatform.other);

  @override
  Future<DeviceProfile> current() async {
    final total = await _meminfoTotal() ?? defaultTotalRamBytes;
    int? free;
    try {
      free = await freeStorageBytes?.call();
    } on Object {
      free = null;
    }
    return DeviceProfile(
      platform: platform,
      totalRamBytes: total,
      osVersion: _osVersion(),
      freeStorageBytes: free,
    );
  }

  Future<int?> _meminfoTotal() async {
    try {
      final f = File(meminfoPath);
      if (!f.existsSync()) return null;
      return parseMeminfoTotal(await f.readAsString());
    } on Object {
      return null;
    }
  }

  String? _osVersion() {
    // Android: "Linux 5.10… (Android 15)" is not exposed; the version string
    // is the kernel's, so only iOS gives a usable number here. The Android
    // 17 limiter check then stays off, which the platform plugin fixes.
    if (platform != DevicePlatform.ios) return null;
    final m = RegExp(r'(\d+(?:\.\d+)*)').firstMatch(Platform.operatingSystemVersion);
    return m?.group(1);
  }
}

/// `MemTotal:  3809016 kB` → bytes.
int? parseMeminfoTotal(String meminfo) {
  final m = RegExp(r'^MemTotal:\s+(\d+)\s*kB', multiLine: true).firstMatch(meminfo);
  return m == null ? null : int.parse(m.group(1)!) * 1024;
}

/// A fixed profile: previews, screenshots and tests ("4 GB phone" vs
/// "12 GB phone").
final class FixedDeviceProfileSource implements DeviceProfileSource {
  FixedDeviceProfileSource(this.profile);

  DeviceProfile profile;

  @override
  Future<DeviceProfile> current() async => profile;
}

/// The device facts source. The integrator overrides this with the
/// `sherpa_platform` implementation in `bootstrap()`.
final deviceProfileSourceProvider = Provider<DeviceProfileSource>((ref) => FallbackDeviceProfileSource());

/// The profile right now. Invalidate to re-measure (e.g. after freeing
/// space or closing apps).
final deviceProfileProvider = FutureProvider.autoDispose<DeviceProfile>(
  (ref) => ref.watch(deviceProfileSourceProvider).current(),
);
