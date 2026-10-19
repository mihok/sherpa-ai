import 'package:sherpa_core/sherpa_core.dart';

import '../messages.pigeon.dart';
import 'pressure_policy.dart';

/// Pure state machine behind [PlatformMemoryMonitor]: folds samples, OS
/// signals and foreground changes into one [MemoryState], with time passed
/// in explicitly so every rule is unit-testable without timers.
///
/// Inputs combine as `max(sample, hidden-trim, transient holds, dispatch)`.
/// Escalations take effect immediately; a lower level must hold for
/// [PressurePolicy.downgradeDelay] first (hysteresis), separately for
/// pressure and thermal.
final class PressureTracker {
  PressureTracker(this.policy, {bool foreground = true}) : _foreground = foreground;

  final PressurePolicy policy;

  bool _foreground;
  MemorySample? _sample;
  int _sampleAtMs = -1;

  /// Android UI_HIDDEN / BACKGROUND trims; cleared when the UI returns.
  int? _hiddenTrim;

  /// Edge-triggered warnings with no all-clear, as (level, until) holds.
  final List<({MemoryPressure level, DateTime until, String source})> _holds = [];

  /// iOS DispatchSource level (level-triggered).
  MemoryPressure _dispatch = MemoryPressure.normal;

  int? _thermalStatus;
  int _thermalAtMs = -1;
  double? _headroom;
  bool? _lowPower;
  int _lowPowerAtMs = -1;
  String _platform = 'unknown';

  MemoryPressure _pressure = MemoryPressure.normal;
  DateTime? _pressureLowerSince;
  ThermalLevel _thermal = ThermalLevel.nominal;
  DateTime? _thermalLowerSince;
  String _source = 'unknown';

  bool get foreground => _foreground;
  MemorySample? get lastSample => _sample;

  void onForeground(bool foreground) {
    _foreground = foreground;
    // Hidden-state trims describe a UI that is visible again.
    if (foreground) _hiddenTrim = null;
  }

  /// Applies [s] unless a newer reading was already applied (samples are
  /// async and can return out of order).
  void onSample(MemorySample s) {
    if (s.timestampMs < _sampleAtMs) return;
    _sample = s;
    _sampleAtMs = s.timestampMs;
    _platform = s.platform;
    if (s.timestampMs >= _thermalAtMs) {
      _thermalStatus = s.thermalStatus;
      _thermalAtMs = s.timestampMs;
      if (s.thermalHeadroom != null) _headroom = s.thermalHeadroom;
    }
    if (s.timestampMs >= _lowPowerAtMs) {
      _lowPower = s.lowPowerMode;
      _lowPowerAtMs = s.timestampMs;
    }
  }

  void onSignal(PlatformSignal s, DateTime now) {
    switch (s.kind) {
      case SignalKind.trimMemory:
        _platform = 'android';
        final level = s.level;
        if (level >= PressurePolicy.trimUiHidden) {
          // Only ever sent to a hidden UI, and it may arrive before Flutter's
          // own lifecycle event, so it is recorded regardless of
          // [_foreground] and cleared by the next onForeground(true).
          _hiddenTrim = (_hiddenTrim ?? 0) > level ? _hiddenTrim : level;
        } else if (level >= PressurePolicy.trimRunningCritical) {
          _warn(now, critical: true, source: 'trim:$level');
        } else if (level >= PressurePolicy.trimRunningModerate) {
          _warn(now, critical: false, source: 'trim:$level');
        }
      case SignalKind.memoryWarning:
        _platform = 'ios';
        _warn(now, critical: true, source: 'memoryWarning');
      case SignalKind.memoryPressure:
        _platform = 'ios';
        _dispatch = policy.dispatchPressure(s.level);
      case SignalKind.thermal:
        if (s.timestampMs >= _thermalAtMs) {
          _thermalStatus = s.level;
          _thermalAtMs = s.timestampMs;
        }
      case SignalKind.thermalHeadroom:
        _headroom = s.value;
      case SignalKind.powerMode:
        if (s.timestampMs >= _lowPowerAtMs) {
          _lowPower = s.level != 0;
          _lowPowerAtMs = s.timestampMs;
        }
      case SignalKind.leaseExpired:
        break;
    }
  }

  void _warn(DateTime now, {required bool critical, required String source}) {
    if (critical) _holds.add((level: MemoryPressure.critical, until: now.add(policy.criticalHold), source: source));
    _holds.add((level: MemoryPressure.moderate, until: now.add(policy.moderateHold), source: source));
  }

  /// The state at [now], applying hysteresis.
  MemoryState evaluate(DateTime now) {
    _holds.removeWhere((h) => !h.until.isAfter(now));

    var target = MemoryPressure.normal;
    var source = 'sample';
    void consider(MemoryPressure p, String from) {
      if (p.index > target.index) {
        target = p;
        source = from;
      }
    }

    final s = _sample;
    if (s != null) consider(policy.samplePressure(s, foreground: _foreground), 'sample');
    final trim = _hiddenTrim;
    if (trim != null) consider(policy.trimPressure(trim), 'trim:$trim');
    for (final h in _holds) {
      consider(h.level, h.source);
    }
    consider(_dispatch, 'dispatch:${_dispatch.name}');

    final (pressure, pressureLowerSince) = _hysteresis(_pressure, target, _pressureLowerSince, now);
    _pressure = pressure;
    _pressureLowerSince = pressureLowerSince;
    if (pressure == target) _source = source;

    final thermalTarget = _thermalStatus == null
        ? ThermalLevel.nominal
        : policy.thermal(platform: _platform, status: _thermalStatus!, headroom: _headroom);
    final (thermal, thermalLowerSince) = _hysteresis(_thermal, thermalTarget, _thermalLowerSince, now);
    _thermal = thermal;
    _thermalLowerSince = thermalLowerSince;

    return MemoryState(
      pressure: _pressure,
      availableBytes: s == null ? null : policy.availableBytes(s, foreground: _foreground),
      totalBytes: s == null ? null : policy.totalBytes(s),
      appFootprintBytes: s == null ? null : policy.appFootprintBytes(s),
      thermal: _thermal,
      lowPowerMode: _lowPower ?? false,
      source: '$_platform:$_source',
    );
  }

  /// When [evaluate] may change with no new input (a hold expiring or a
  /// pending downgrade maturing), or null.
  DateTime? nextDeadline(DateTime now) {
    DateTime? next;
    void take(DateTime t) {
      if (t.isAfter(now) && (next == null || t.isBefore(next!))) next = t;
    }

    for (final h in _holds) {
      take(h.until);
    }
    if (_pressureLowerSince != null) take(_pressureLowerSince!.add(policy.downgradeDelay));
    if (_thermalLowerSince != null) take(_thermalLowerSince!.add(policy.downgradeDelay));
    return next;
  }

  (T, DateTime?) _hysteresis<T extends Enum>(T current, T target, DateTime? lowerSince, DateTime now) {
    if (target.index >= current.index) return (target, null);
    final since = lowerSince ?? now;
    if (now.difference(since) >= policy.downgradeDelay) return (target, null);
    return (current, since);
  }
}
