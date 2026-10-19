/// OS signals and background execution for Sherpa (PLAN §2, layer 4).
///
/// - [PlatformMemoryMonitor]: sherpa_core's `MemoryMonitor` over Android
///   trim/MemoryInfo/limiter/thermal and iOS memory warnings, dispatch
///   pressure, `os_proc_available_memory` and thermal state.
/// - [DeviceSnapshot]: RAM, storage, CPU topology and features, battery,
///   thermal and kill forensics; [DeviceSnapshot.toDeviceProfile] feeds
///   sherpa_hub's device-fit.
/// - [ProcessStateRecorder]: what the process was doing when it died
///   (Android `setProcessStateSummary`).
/// - [BackupExclusion]: keep the encrypted database out of iOS backups.
/// - [BackgroundRunGuard]: finish a reply or a run after the user leaves
///   (Android foreground service, iOS background tasks).
library;

export 'src/backend.dart' show PigeonPlatformBackend, PlatformBackend, SherpaPlatform, UnsupportedPlatformBackend;
export 'src/background/background_run_guard.dart';
export 'src/backup_exclusion.dart';
export 'src/device/device_snapshot.dart';
export 'src/memory/foreground.dart';
export 'src/memory/platform_memory_monitor.dart';
export 'src/memory/pressure_policy.dart';
export 'src/memory/pressure_tracker.dart';
// Wire types: needed to implement PlatformBackend and to read lease modes.
export 'src/messages.pigeon.dart'
    show
        DeviceInfo,
        ExitRecord,
        LeaseMode,
        LeaseRequest,
        LeaseResult,
        MemorySample,
        PlatformSignal,
        SignalKind;
export 'src/process_state.dart';
