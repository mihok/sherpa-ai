import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../messages.pigeon.dart';

const int _mib = 1024 * 1024;

/// How raw platform readings become [MemoryPressure] and [ThermalLevel].
///
/// Every threshold here is a Sherpa POLICY choice (no OS publishes one) and
/// UNVERIFIED on devices; tune them from kill forensics (`ExitForensics`)
/// and the perf lab. The *inputs* are the ones the research digests say are
/// still live:
///
/// **Android** (R07 §2.1–2.3)
/// - `onTrimMemory`: on API 34+ only `UI_HIDDEN` (20) and `BACKGROUND` (40)
///   arrive. `BACKGROUND` → critical (R07: "release KV cache … when not
///   actively generating"). `UI_HIDDEN` → moderate: the process left the
///   foreground, and the Android 17 limiter's background budget is half the
///   foreground one (2 GB → 1 GB on 4 GB devices), so headroom just shrank.
///   Both describe the hidden state and are cleared when the UI returns.
///   Legacy levels (≤ API 33, minSdk 29): `RUNNING_CRITICAL` (15) → critical,
///   `RUNNING_LOW`/`RUNNING_MODERATE` → moderate, held for a while because
///   no "recovered" event exists.
/// - `MemoryInfo.lowMemory` → critical (the system is killing background
///   services).
/// - Headroom: `availMem − threshold`, capped on API 37+ by an estimated
///   limiter headroom (`limiter − (RssAnon + VmSwap)`), against both an
///   absolute floor and a share of total RAM.
///
/// **iOS** (R06 §5)
/// - `didReceiveMemoryWarning` → critical for [criticalHold], then moderate
///   until [moderateHold] (UIKit sends no all-clear).
/// - `DispatchSource` memory pressure: warning → moderate, critical →
///   critical, normal clears (it is level-triggered).
/// - `os_proc_available_memory()` tiers against an absolute floor and a share
///   of the process limit (`available + phys_footprint`).
///
/// **Thermal**: iOS `ThermalState` maps 1:1. Android status NONE → nominal,
/// LIGHT → fair, MODERATE → serious ("reduce threads, throttle decode"),
/// SEVERE and above → critical ("pause the agent loop"); a 10 s headroom
/// forecast ≥ 0.85 raises to serious and ≥ 1.0 (= SEVERE) to critical
/// (R07 §3.3, R06 §7).
@immutable
final class PressurePolicy {
  const PressurePolicy({
    this.androidCriticalFloorBytes = 256 * _mib,
    this.androidCriticalFraction = 0.04,
    this.androidModerateFloorBytes = 768 * _mib,
    this.androidModerateFraction = 0.10,
    this.limiterSinceApi = 37,
    this.limiterForegroundFraction = 0.5,
    this.limiterBackgroundFraction = 0.25,
    this.iosCriticalFloorBytes = 192 * _mib,
    this.iosCriticalFraction = 0.08,
    this.iosModerateFloorBytes = 512 * _mib,
    this.iosModerateFraction = 0.15,
    this.criticalHold = const Duration(seconds: 10),
    this.moderateHold = const Duration(seconds: 30),
    this.downgradeDelay = const Duration(seconds: 5),
    this.headroomFair = 0.70,
    this.headroomSerious = 0.85,
    this.headroomCritical = 1.0,
  });

  /// Android: critical below `max(floor, fraction × totalMem)` of headroom.
  final int androidCriticalFloorBytes;
  final double androidCriticalFraction;
  final int androidModerateFloorBytes;
  final double androidModerateFraction;

  /// First API level with the per-app memory limiter (Android 17).
  final int limiterSinceApi;

  /// Limiter estimate as a share of RAM: "2 GB in the foreground and 1 GB in
  /// the background on 4 GB devices" (R07 §2.3; other tiers extrapolated,
  /// same as sherpa_hub's `FitConstants.androidLimiterForegroundFraction`).
  final double limiterForegroundFraction;
  final double limiterBackgroundFraction;

  /// iOS: critical below `max(floor, fraction × process limit)` available.
  final int iosCriticalFloorBytes;
  final double iosCriticalFraction;
  final int iosModerateFloorBytes;
  final double iosModerateFraction;

  /// After an edge-triggered warning (iOS memory warning, Android
  /// RUNNING_CRITICAL): critical this long, then moderate until
  /// [moderateHold] after the event.
  final Duration criticalHold;
  final Duration moderateHold;

  /// A lower pressure or thermal level must persist this long before it is
  /// published, so a model reload is not triggered by flapping readings.
  /// Escalations are published at once.
  final Duration downgradeDelay;

  /// Android thermal headroom (10 s forecast) thresholds.
  final double headroomFair;
  final double headroomSerious;
  final double headroomCritical;

  // ---- Android trim levels (ComponentCallbacks2) ---------------------------
  static const int trimRunningModerate = 5;
  static const int trimRunningLow = 10;
  static const int trimRunningCritical = 15;
  static const int trimUiHidden = 20;
  static const int trimBackground = 40;

  /// Pressure implied by a trim level. Levels ≥ [trimUiHidden] describe a
  /// hidden UI; callers drop them when the app is in the foreground.
  MemoryPressure trimPressure(int level) {
    if (level >= trimBackground) return MemoryPressure.critical;
    if (level >= trimUiHidden) return MemoryPressure.moderate;
    if (level >= trimRunningCritical) return MemoryPressure.critical;
    if (level >= trimRunningModerate) return MemoryPressure.moderate;
    return MemoryPressure.normal;
  }

  /// iOS DispatchSource level (0 normal, 1 warning, 2 critical).
  MemoryPressure dispatchPressure(int level) => switch (level) {
        >= 2 => MemoryPressure.critical,
        1 => MemoryPressure.moderate,
        _ => MemoryPressure.normal,
      };

  // ---- derived byte figures ------------------------------------------------

  /// Kernel-visible RAM.
  int? totalBytes(MemorySample s) => s.totalMemBytes ?? s.physicalMemoryBytes;

  /// The app's own footprint: iOS `phys_footprint`; Android anonymous RSS +
  /// swap (the limiter's metric), else VmRSS.
  int? appFootprintBytes(MemorySample s) => s.physFootprintBytes ?? s.anonSwapBytes ?? s.rssBytes;

  /// Android 17+ limiter ceiling estimate for this app, or null when the
  /// limiter does not apply. Uses `advertisedMem` (the retail RAM tier the
  /// limits are quoted against) when available.
  int? limiterEstimateBytes(MemorySample s, {required bool foreground}) {
    if (s.platform != 'android' || (s.apiLevel ?? 0) < limiterSinceApi) return null;
    final ram = s.advertisedMemBytes ?? s.totalMemBytes;
    if (ram == null || ram <= 0) return null;
    return (ram * (foreground ? limiterForegroundFraction : limiterBackgroundFraction)).round();
  }

  /// Physical headroom without the limiter cap: Android `availMem −
  /// threshold`, iOS `os_proc_available_memory()`. This is what
  /// `DeviceProfile.availableRamBytes` expects (device-fit applies the
  /// limiter separately, to anonymous memory only).
  int? physicalAvailableBytes(MemorySample s) {
    if (s.procAvailableBytes != null) return s.procAvailableBytes;
    final avail = s.availMemBytes;
    if (avail == null) return null;
    return math.max(0, avail - (s.thresholdBytes ?? 0));
  }

  /// What the app can still allocate before the OS intervenes
  /// ([MemoryState.availableBytes]): [physicalAvailableBytes], on Android
  /// 17+ also capped by `limiter − (RssAnon + VmSwap)`.
  int? availableBytes(MemorySample s, {required bool foreground}) {
    final physical = physicalAvailableBytes(s);
    final limiter = limiterEstimateBytes(s, foreground: foreground);
    final anon = s.anonSwapBytes;
    if (limiter == null || anon == null) return physical;
    final limiterHeadroom = math.max(0, limiter - anon);
    return physical == null ? limiterHeadroom : math.min(physical, limiterHeadroom);
  }

  /// iOS: the jetsam limit (`available + footprint`, R06 §5); Android 17+:
  /// the limiter estimate.
  int? perProcessLimitBytes(MemorySample s, {required bool foreground}) {
    final avail = s.procAvailableBytes;
    if (avail != null) return avail + (s.physFootprintBytes ?? 0);
    return limiterEstimateBytes(s, foreground: foreground);
  }

  // ---- pressure from a sample ----------------------------------------------

  /// Pressure from one reading alone (no event history).
  MemoryPressure samplePressure(MemorySample s, {required bool foreground}) {
    var p = MemoryPressure.normal;
    if (s.platform == 'android') {
      if (s.lowMemory ?? false) return MemoryPressure.critical;
      final trim = s.lastTrimLevel;
      if (trim != null && (!foreground || trim < trimUiHidden)) p = _max(p, trimPressure(trim));
      final avail = availableBytes(s, foreground: foreground);
      final total = totalBytes(s);
      if (avail != null && total != null && total > 0) {
        p = _max(
          p,
          _tier(
            avail,
            critical: math.max(androidCriticalFloorBytes, (total * androidCriticalFraction).round()),
            moderate: math.max(androidModerateFloorBytes, (total * androidModerateFraction).round()),
          ),
        );
      }
    } else if (s.platform == 'ios') {
      final avail = s.procAvailableBytes;
      if (avail != null) {
        // 0 means "already over the limit" (os_proc_available_memory docs).
        if (avail == 0) return MemoryPressure.critical;
        final limit = avail + (s.physFootprintBytes ?? 0);
        p = _tier(
          avail,
          critical: math.max(iosCriticalFloorBytes, (limit * iosCriticalFraction).round()),
          moderate: math.max(iosModerateFloorBytes, (limit * iosModerateFraction).round()),
        );
      }
    }
    return p;
  }

  // ---- thermal ---------------------------------------------------------------

  /// Maps a raw thermal status (and, on Android, the headroom forecast).
  ThermalLevel thermal({required String platform, required int status, double? headroom}) {
    if (platform == 'ios') {
      return ThermalLevel.values[status.clamp(0, ThermalLevel.values.length - 1)];
    }
    final fromStatus = switch (status) {
      <= 0 => ThermalLevel.nominal,
      1 => ThermalLevel.fair,
      2 => ThermalLevel.serious,
      _ => ThermalLevel.critical,
    };
    final h = headroom;
    if (h == null || h.isNaN) return fromStatus;
    final fromHeadroom = h >= headroomCritical
        ? ThermalLevel.critical
        : h >= headroomSerious
            ? ThermalLevel.serious
            : h >= headroomFair
                ? ThermalLevel.fair
                : ThermalLevel.nominal;
    return fromHeadroom.index > fromStatus.index ? fromHeadroom : fromStatus;
  }

  static MemoryPressure _tier(int available, {required int critical, required int moderate}) {
    if (available < critical) return MemoryPressure.critical;
    if (available < moderate) return MemoryPressure.moderate;
    return MemoryPressure.normal;
  }

  static MemoryPressure _max(MemoryPressure a, MemoryPressure b) => a.index >= b.index ? a : b;
}
