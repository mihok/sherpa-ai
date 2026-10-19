// Pigeon definition for sherpa_platform (platform-channel mode, R09 §4).
//
// Regenerate from packages/sherpa_platform:
//   dart run pigeon --input pigeons/platform_api.dart
//
// Design rules:
// - Native code reports RAW readings (bytes, OS enum values, flags). Every
//   mapping onto MemoryPressure / ThermalLevel is Dart policy
//   (lib/src/memory/pressure_policy.dart), so it is unit-tested on the host
//   and identical on both platforms (PLAN §2: no business logic in
//   Kotlin/Swift). The only native "logic" is parsing OS text formats
//   (/proc, sysfs) and classifying exit reasons, which have JVM tests.
// - Channel mode, not FFI/JNI: Pigeon 29's native-interop mode rejects event
//   channels and @TaskQueue (R09 §4, CHANGELOG 29.0.8).
// - Reads that touch /proc, sysfs, StatFs, binder or the file system run on
//   a background TaskQueue so the platform main thread never blocks.
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/src/messages.pigeon.dart',
  dartPackageName: 'sherpa_platform',
  kotlinOut: 'android/src/main/kotlin/io/github/mihok/sherpa_platform/Messages.g.kt',
  kotlinOptions: KotlinOptions(package: 'io.github.mihok.sherpa_platform', errorClassName: 'SherpaPlatformError'),
  swiftOut: 'ios/sherpa_platform/Sources/sherpa_platform/Messages.g.swift',
  swiftOptions: SwiftOptions(errorClassName: 'SherpaPlatformError'),
))
/// What a [PlatformSignal] reports.
enum SignalKind {
  /// Android `ComponentCallbacks2.onTrimMemory`; `level` is the trim level.
  trimMemory,

  /// iOS `UIApplication.didReceiveMemoryWarningNotification`.
  memoryWarning,

  /// iOS `DispatchSource` memory pressure; `level` 0 normal, 1 warning,
  /// 2 critical.
  memoryPressure,

  /// Thermal status changed; `level` is the raw OS value (Android
  /// `PowerManager.THERMAL_STATUS_*`, iOS `ProcessInfo.ThermalState`).
  thermal,

  /// Android 16+ thermal headroom listener; `value` is the forecast headroom.
  thermalHeadroom,

  /// Power saving changed (Android battery saver, iOS Low Power Mode);
  /// `level` 1 = on.
  powerMode,

  /// The OS ended a background lease before the app did (`leaseId` set,
  /// `detail` says why): Android shortService timeout or service teardown,
  /// iOS background-task expiration or a cancelled continued-processing task.
  leaseExpired,
}

/// One OS event, pushed as it happens (no polling).
class PlatformSignal {
  PlatformSignal({required this.kind, required this.level, required this.timestampMs});

  SignalKind kind;
  int level;
  double? value;
  String? leaseId;
  String? detail;

  /// Wall-clock milliseconds since the epoch, taken natively.
  int timestampMs;
}

/// A raw memory/thermal/power reading. Fields a platform does not have are
/// null.
class MemorySample {
  MemorySample({
    required this.platform,
    required this.timestampMs,
    required this.thermalStatus,
    required this.lowPowerMode,
  });

  /// `android` or `ios`.
  String platform;
  int timestampMs;

  /// Android `Build.VERSION.SDK_INT` (gates the API 37 memory limiter).
  int? apiLevel;

  // Android ActivityManager.MemoryInfo (R07 §2.2).
  int? availMemBytes;
  int? thresholdBytes;
  int? totalMemBytes;

  /// API 34+: retail RAM, may exceed `totalMem` (TEE carve-outs).
  int? advertisedMemBytes;

  /// API 37+: raw free RAM excluding reclaimable memory.
  int? freeMemBytes;
  bool? lowMemory;

  /// `ActivityManager.getMyMemoryState().lastTrimLevel`.
  int? lastTrimLevel;

  /// `/proc/self/status` VmRSS.
  int? rssBytes;

  /// `/proc/self/status` RssAnon + VmSwap: what the Android 17 limiter
  /// counts (R07 §2.3).
  int? anonSwapBytes;

  /// iOS `os_proc_available_memory()`: limit minus footprint (R06 §5).
  int? procAvailableBytes;

  /// iOS `task_vm_info.phys_footprint`.
  int? physFootprintBytes;

  /// iOS `ProcessInfo.physicalMemory`.
  int? physicalMemoryBytes;

  /// Raw OS thermal value (see [SignalKind.thermal]).
  int thermalStatus;

  /// Android `PowerManager.getThermalHeadroom(10)`, polled at most every 2 s;
  /// null when unsupported or NaN.
  double? thermalHeadroom;
  bool lowPowerMode;
}

/// Last process exit, from Android `ApplicationExitInfo` (API 30+).
class ExitRecord {
  ExitRecord({required this.reason, required this.reasonName, required this.classification, required this.timestampMs});

  /// `ApplicationExitInfo.REASON_*`.
  int reason;
  String reasonName;

  /// Native classification (see `ExitClassifier.kt`): memoryLimiter,
  /// lowMemory, likelyLowMemory, crash, nativeCrash, anr, userStopped, ...
  String classification;

  /// `ApplicationExitInfo.getDescription()` (named `details` because Swift
  /// reserves `description`).
  String? details;
  int timestampMs;
  int? status;
  int? importance;
  int? pssBytes;
  int? rssBytes;
  String? processName;

  /// The bytes last passed to `setProcessStateSummary` by that process.
  Uint8List? processStateSummary;
}

/// Static-ish device facts plus one [MemorySample].
class DeviceInfo {
  DeviceInfo({
    required this.platform,
    required this.osVersion,
    required this.memory,
    required this.cpuCores,
    required this.cpuMaxFreqKHz,
    required this.cpuCapacity,
    required this.bigCoreIndices,
    required this.cpuFeatures,
    required this.isLowRamDevice,
  });

  String platform;

  /// Android `Build.VERSION.RELEASE` ("17"), iOS `systemVersion` ("27.0.1").
  String osVersion;
  int? apiLevel;
  String? manufacturer;

  /// Android `Build.MODEL`, iOS `UIDevice.model` ("iPhone").
  String? model;

  /// Android `Build.SOC_MANUFACTURER` / `SOC_MODEL` (API 31+).
  String? socManufacturer;
  String? socModel;

  /// Android `Build.HARDWARE`, iOS `hw.model` (board id).
  String? hardware;

  /// iOS `hw.machine` ("iPhone17,1"), Android `Build.DEVICE`.
  String? machine;
  MemorySample memory;

  /// Android StatFs on `filesDir`, iOS
  /// `volumeAvailableCapacityForImportantUsage`.
  int? freeStorageBytes;
  int? totalStorageBytes;
  int cpuCores;

  /// Per core, kHz; 0 = unknown (Android `cpuinfo_max_freq`).
  List<int> cpuMaxFreqKHz;

  /// Per core scheduler capacity 0..1024; 0 = unknown (Android
  /// `cpu_capacity`).
  List<int> cpuCapacity;

  /// Cores outside the lowest-capacity cluster (Android); empty on iOS.
  List<int> bigCoreIndices;

  /// iOS `hw.perflevel0.physicalcpu`; Android: `bigCoreIndices.length`.
  int? performanceCores;

  /// Normalized ARM features: dotprod, i8mm, sve, sve2, sme, sme2, bf16,
  /// fp16.
  List<String> cpuFeatures;
  bool isLowRamDevice;

  /// 0..1, null when unknown.
  double? batteryLevel;
  bool? charging;
  ExitRecord? lastExit;
}

/// Where a lease runs.
enum LeaseMode {
  /// Nothing was started (see [LeaseResult.error]).
  none,

  /// Android foreground service of type `shortService` (~3 min, R07 §4.1).
  androidShortService,

  /// Android foreground service of type `specialUse` (long agent runs).
  androidSpecialUse,

  /// iOS `UIApplication.beginBackgroundTask` (finishing work, ~30 s).
  iosBackgroundTask,

  /// iOS 26+ `BGContinuedProcessingTask` (system Live Activity, R06 §6.2).
  iosContinuedProcessing,
}

class LeaseRequest {
  LeaseRequest({
    required this.id,
    required this.title,
    required this.reason,
    required this.long,
    required this.iosRequestGpu,
  });

  /// Generated in Dart so [PlatformSignal.leaseId] can be routed even
  /// before `beginLease` returns.
  String id;
  String title;

  /// Shown under the title (notification text / task subtitle).
  String reason;
  bool long;

  /// Android: notification channel name (user-visible, localized by the app).
  String? androidChannelName;

  /// Android: drawable resource name for the status-bar icon; falls back to
  /// the app icon.
  String? androidSmallIcon;

  /// iOS 26+: full continued-processing identifier
  /// (`<bundle>.<context>.<unique>`); null = use beginBackgroundTask only.
  String? iosContinuedTaskIdentifier;

  /// iOS 26+: request `.gpu` when the device supports background GPU.
  bool iosRequestGpu;
}

class LeaseResult {
  LeaseResult({required this.id, required this.mode, required this.granted, required this.notificationsVisible});

  String id;
  LeaseMode mode;
  bool granted;

  /// Why the lease was refused or downgraded.
  String? error;

  /// Android: POST_NOTIFICATIONS granted and notifications enabled; iOS: true.
  bool notificationsVisible;
}

/// A one-off "your reply is ready" notification (Android). Never carries
/// message content: the app passes a chat's title at most.
class FinishedNotice {
  FinishedNotice({required this.tag, required this.title, required this.text});

  /// Replaces an earlier notice with the same tag (one per chat).
  String tag;
  String title;
  String text;

  /// User-visible name of the channel finished-run notices use (localized
  /// by the app); separate from the ongoing-run channel so people can mute
  /// one without the other.
  String? androidChannelName;
}

@HostApi()
abstract class SherpaPlatformHostApi {
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  MemorySample sampleMemory();

  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  DeviceInfo deviceInfo();

  /// Android `ActivityManager.setProcessStateSummary` (≤ 128 bytes, API 30+).
  /// Returns false when unsupported (iOS, API < 30) or rejected.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  bool setProcessStateSummary(Uint8List summary);

  /// iOS: sets `isExcludedFromBackup` on [path] (and its -wal/-shm/-journal
  /// when [includeSqliteSidecars]); returns the paths flagged. Android: no-op,
  /// returns an empty list (the app's backup rules XML excludes them).
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  List<String> excludeFromBackup(String path, bool includeSqliteSidecars);

  bool notificationsPermitted();

  /// Android 13+ (API 33): asks for POST_NOTIFICATIONS with the system
  /// dialog, through the current activity; completes with
  /// [notificationsPermitted] once the user answers. Below 33, when already
  /// granted, or without an activity, completes at once without a dialog.
  /// iOS: true (no notification is involved).
  @asyncCallback
  bool requestNotificationsPermission();

  /// Android: posts [notice] (dismissed on tap, opens the app) when
  /// notifications are permitted; returns whether it was posted. iOS: false
  /// (not supported; the Live Activity shows the end of a continued task).
  bool notifyRunFinished(FinishedNotice notice);

  /// Removes every [notifyRunFinished] notice still showing (the app is on
  /// screen again). iOS: no-op.
  void clearFinishedNotices();

  @asyncCallback
  LeaseResult beginLease(LeaseRequest request);

  void updateLease(String id, double? progress, String? text);

  void endLease(String id);
}

@EventChannelApi()
abstract class SherpaPlatformEventApi {
  PlatformSignal signals();
}
