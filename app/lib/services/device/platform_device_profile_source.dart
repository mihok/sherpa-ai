import 'package:sherpa_hub/sherpa_hub.dart';
import 'package:sherpa_platform/sherpa_platform.dart';

import 'device_profile_source.dart';

/// Device facts measured by the `sherpa_platform` plugin: available memory
/// (`os_proc_available_memory` / `availMem − threshold`), the Android 17
/// limiter, free storage, CPU class and thermal state.
///
/// Falls back to [FallbackDeviceProfileSource] when the plugin cannot
/// answer (tests, desktop, a plugin error), so a fit decision never fails
/// for lack of a measurement; the fallback is the pessimistic one.
final class PlatformDeviceProfileSource implements DeviceProfileSource {
  PlatformDeviceProfileSource({PlatformBackend? backend, DeviceProfileSource? fallback})
      : _backend = backend,
        _fallback = fallback ?? FallbackDeviceProfileSource();

  final PlatformBackend? _backend;
  final DeviceProfileSource _fallback;

  @override
  Future<DeviceProfile> current() async {
    try {
      final snapshot = await DeviceSnapshot.capture(backend: _backend);
      final profile = snapshot.toDeviceProfile();
      // An unreadable total (0) would make every model "Won't fit".
      return profile.totalRamBytes > 0 ? profile : await _fallback.current();
    } on Object {
      return _fallback.current();
    }
  }
}
