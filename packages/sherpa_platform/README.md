# sherpa_platform

Flutter plugin (Android + iOS) for Sherpa's OS signals and background
execution: PLAN §2 layer 4. Native code only reports raw readings and runs
OS lifecycles; every mapping and policy decision is Dart, unit-tested on the
host.

| API | What it does |
|---|---|
| `PlatformMemoryMonitor` | sherpa_core `MemoryMonitor`: pressure, thermal, low-power, `availableBytes`, `totalBytes`, `appFootprintBytes` |
| `DeviceSnapshot` | RAM, storage, CPU cores/frequencies/big cores/features, battery, thermal, Android kill forensics; `toDeviceProfile()` for sherpa_hub device-fit |
| `ProcessStateRecorder` | Android `setProcessStateSummary` (≤ 128 bytes) for kill forensics; no-op on iOS |
| `BackupExclusion` | iOS `isExcludedFromBackup` on a file and its SQLite sidecars; no-op on Android (rules XML) |
| `BackgroundRunGuard` | Android foreground service (`shortService` / `specialUse`), iOS `beginBackgroundTask` / `BGContinuedProcessingTask` |

`package:sherpa_platform/testing.dart` has `FakePlatformBackend` and
`FakeForegroundSource` for tests of code that uses the plugin.

## Wiring (for the app)

```dart
final monitor = PlatformMemoryMonitor();           // sherpa_core MemoryMonitor
final snapshot = await DeviceSnapshot.capture();
final profile = snapshot.toDeviceProfile();        // sherpa_hub assessFit(profile, ...)

// Kill forensics: on launch, act on a new memory kill once.
final exit = snapshot.lastExit;
if (exit != null && exit.wasMemoryKill && exit.timestamp.isAfter(lastSeen)) {
  final s = exit.summary;                          // what the dead process was doing
  // downgrade model / context / backend
}
await ProcessStateRecorder.record(ProcessStateSummary.forModel(
    phase: ProcessPhase.load, modelId: id, backend: 'cpu', contextTokens: 8192));

await BackupExclusion.exclude(dbPath);             // after every database open (iOS)

final guard = BackgroundRunGuard(iosContinuedTaskPrefix: 'io.github.mihok.sherpa.agentrun');
final lease = await guard.begin(title: 'Agent run', reason: 'Step 1 of 4', long: true);
unawaited(lease.expired.then((why) => checkpointAndStop(why)));
await lease.update(progress: 0.25, text: 'Step 2 of 4');
await lease.end();
```

Start leases **while the app is visible** (when the run starts, not on
pause): Android refuses to start a foreground service from the background
(R07 §4.2), and iOS continued-processing tasks must come from a user action.

## Pressure and thermal policy

Implemented in `lib/src/memory/pressure_policy.dart` (thresholds) and
`pressure_tracker.dart` (state machine); every threshold is POLICY /
UNVERIFIED and should be tuned from kill forensics.

- **Android**: `TRIM_MEMORY_BACKGROUND` → critical, `UI_HIDDEN` → moderate
  (the Android 17 limiter's background budget is half the foreground one),
  both cleared when the UI returns; legacy `RUNNING_*` levels (API ≤ 33) are
  held 10 s critical / 30 s moderate. `MemoryInfo.lowMemory` → critical.
  Headroom `availMem − threshold`, capped on API 37+ by
  `limiter − (RssAnon + VmSwap)` with limiter ≈ 50 % (foreground) / 25 %
  (background) of advertised RAM; critical below max(256 MiB, 4 % RAM),
  moderate below max(768 MiB, 10 % RAM).
- **iOS**: memory warning → critical 10 s, then moderate until 30 s;
  DispatchSource warning → moderate, critical → critical (level-triggered);
  `os_proc_available_memory()` critical below max(192 MiB, 8 % of limit),
  moderate below max(512 MiB, 15 %), `0` = over the limit.
- **Thermal**: iOS `ThermalState` 1:1. Android NONE/LIGHT/MODERATE/SEVERE+ →
  nominal/fair/serious/critical, raised by `getThermalHeadroom(10)` ≥ 0.7 /
  0.85 / 1.0. Headroom is polled at most every 2 s natively and not at all
  while the API 36 headroom listener pushes values.
- **Timing**: becoming critical is published at once; other changes in a
  signal burst are coalesced (250 ms) into one update with a fresh sample;
  lower levels must hold 5 s before they are published. Periodic samples
  (2 s) run only while `changes` is listened and the UI is visible.

`MemoryState.availableBytes` is the limiter-capped figure (what the app can
allocate now). `DeviceSnapshot.availableRamBytes` is the *uncapped* physical
headroom and `perProcessLimitHintBytes` the cap, because device-fit applies
the Android limiter to anonymous memory only.

## Android

Merged from the plugin manifest (names checked against the API 37
`android.jar`; there is no `FOREGROUND_SERVICE_SHORT_SERVICE` permission):

- `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE`, `POST_NOTIFICATIONS`
- `<service io.github.mihok.sherpa_platform.RunService
  foregroundServiceType="shortService|specialUse" exported=false>` with
  `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` = "On-device LLM inference for a
  user-started agent task" (reviewed by Play; needs the Play Console FGS
  declaration and a video, R07 §4.1).

The app must request `POST_NOTIFICATIONS` at runtime on API 33+
(`BackgroundRunGuard.notificationsPermitted()` reports it). Without it the
service still runs; the notification only appears in the FGS task manager.
Notifications use `ProgressStyle` on API 36+ and are not promoted to Live
Updates (that needs `POST_PROMOTED_NOTIFICATIONS`, API 36.1, and a product
decision on which runs qualify, R07 §8.1).

Backups: `app/android/app/src/main/res/xml/data_extraction_rules.xml`
(API 31+, cloud + device transfer) and `backup_rules.xml` (≤ 30) exclude
`sherpa.db`, `-wal`, `-shm`, `-journal` in `filesDir`. The database key is
device-only, so a restored copy could never be opened.

## iOS

Swift sources: `ios/sherpa_platform/Sources/sherpa_platform/` (SwiftPM,
`Package.swift`, iOS 17) plus `ios/sherpa_platform.podspec`. The privacy
manifest declares the disk-space API (`E174.1`).

`BGContinuedProcessingTask` (iOS 26+) is used only when
`BackgroundRunGuard(iosContinuedTaskPrefix:)` is set and `begin(long: true)`.
The app must add to `ios/Runner/Info.plist`:

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
  <string>io.github.mihok.sherpa.agentrun.*</string>
</array>
```

Apple requires the wildcard form `<bundle id>.<context>.*`; each lease
submits `<prefix>.<lease id>`. Without the entry (or before iOS 26, or when
the system cannot start the task now) the lease falls back to
`beginBackgroundTask` and `BackgroundLease.error` says why. Background GPU
(`iosRequestGpu: true`) additionally needs the *Background GPU Access*
capability (`com.apple.developer.background-tasks.continued-processing.gpu`)
and a device whose `BGTaskScheduler.supportedResources` contains `.gpu`
(Apple DTS: M3+ iPads, no iPhone). On iPhone, local Metal inference must
pause in the background regardless; the lease keeps the Dart loop, tools and
remote calls running.

Kill forensics have no iOS equivalent here (MetricKit diagnostics are a
separate, later integration).

## Regenerating Pigeon code

```sh
cd packages/sherpa_platform
dart run pigeon --input pigeons/platform_api.dart
```

Generated: `lib/src/messages.pigeon.dart` (excluded from analysis by the
root `*.pigeon.dart` rule), `android/.../Messages.g.kt`,
`ios/.../Messages.g.swift`.

## Tests

```sh
cd packages/sherpa_platform && flutter test --no-pub     # Dart
cd app/android && ./gradlew :sherpa_platform:testDebugUnitTest   # Kotlin JVM
cd app && flutter build apk --debug --target-platform android-arm64
```

The Swift code is written against Apple's documentation. In the Linux dev
container it was parsed and type-checked with a Swift 6.1 toolchain against
hand-written stand-ins for Flutter, UIKit, BackgroundTasks and the Darwin
APIs (mirroring their declarations and `@MainActor` isolation): clean in
Swift 5 mode; `-strict-concurrency=complete` leaves only Swift 6 migration
warnings (`mach_task_self_`, non-Sendable `SignalHub` captured by
NotificationCenter blocks). That does not prove the real SDK shapes or
`#available` gating; CI on macOS is the first real compile.
