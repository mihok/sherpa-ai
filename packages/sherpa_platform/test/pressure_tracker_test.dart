import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_platform/sherpa_platform.dart';
import 'package:sherpa_platform/testing.dart';

const _mib = 1024 * 1024;

PlatformSignal _signal(SignalKind kind, {int level = 0, double? value, int ts = 0}) =>
    PlatformSignal(kind: kind, level: level, value: value, timestampMs: ts);

void main() {
  final t0 = DateTime.utc(2026, 10, 18, 12);
  DateTime at(int seconds, [int ms = 0]) => t0.add(Duration(seconds: seconds, milliseconds: ms));
  const policy = PressurePolicy();

  test('no input is normal/nominal with unknown bytes', () {
    final t = PressureTracker(policy);
    final s = t.evaluate(t0);
    expect(s.pressure, MemoryPressure.normal);
    expect(s.thermal, ThermalLevel.nominal);
    expect(s.availableBytes, isNull);
    expect(t.nextDeadline(t0), isNull);
  });

  test('a sample fills the byte figures and the source', () {
    final t = PressureTracker(policy)..onSample(FakePlatformBackend.androidSample(availMem: 3072 * _mib));
    final s = t.evaluate(t0);
    expect(s.availableBytes, (3072 - 256) * _mib);
    expect(s.totalBytes, 7680 * _mib);
    expect(s.appFootprintBytes, 400 * _mib);
    expect(s.source, 'android:sample');
  });

  group('Android trims', () {
    test('BACKGROUND is critical until the UI returns', () {
      final t = PressureTracker(policy)
        ..onForeground(false)
        ..onSignal(_signal(SignalKind.trimMemory, level: 40), at(0));
      expect(t.evaluate(at(0)).pressure, MemoryPressure.critical);
      expect(t.evaluate(at(0)).source, 'android:trim:40');
      // Still critical long after: the condition (hidden) persists.
      expect(t.evaluate(at(600)).pressure, MemoryPressure.critical);
      t.onForeground(true);
      // Downgrade waits for the hysteresis delay.
      expect(t.evaluate(at(601)).pressure, MemoryPressure.critical);
      expect(t.evaluate(at(606)).pressure, MemoryPressure.normal);
    });

    test('UI_HIDDEN is recorded even if it beats the lifecycle event', () {
      final t = PressureTracker(policy)..onSignal(_signal(SignalKind.trimMemory, level: 20), at(0));
      expect(t.evaluate(at(0)).pressure, MemoryPressure.moderate);
      t.onForeground(false);
      expect(t.evaluate(at(1)).pressure, MemoryPressure.moderate);
    });

    test('the highest hidden trim wins', () {
      final t = PressureTracker(policy, foreground: false)
        ..onSignal(_signal(SignalKind.trimMemory, level: 40), at(0))
        ..onSignal(_signal(SignalKind.trimMemory, level: 20), at(0));
      expect(t.evaluate(at(0)).pressure, MemoryPressure.critical);
    });

    test('legacy RUNNING_CRITICAL holds critical, then moderate, then clears', () {
      final t = PressureTracker(policy)..onSignal(_signal(SignalKind.trimMemory, level: 15), at(0));
      expect(t.evaluate(at(0)).pressure, MemoryPressure.critical);
      expect(t.nextDeadline(at(0)), at(10));
      expect(t.evaluate(at(9)).pressure, MemoryPressure.critical);
      // Critical hold over at 10 s; the downgrade to moderate matures 5 s later.
      expect(t.evaluate(at(10, 1)).pressure, MemoryPressure.critical);
      expect(t.evaluate(at(15, 2)).pressure, MemoryPressure.moderate);
      // Moderate hold ends at 30 s, then another 5 s of hysteresis.
      expect(t.evaluate(at(30, 1)).pressure, MemoryPressure.moderate);
      expect(t.evaluate(at(35, 2)).pressure, MemoryPressure.normal);
      expect(t.nextDeadline(at(35, 2)), isNull);
    });

    test('RUNNING_LOW is a moderate hold', () {
      final t = PressureTracker(policy)..onSignal(_signal(SignalKind.trimMemory, level: 10), at(0));
      expect(t.evaluate(at(0)).pressure, MemoryPressure.moderate);
    });
  });

  group('iOS', () {
    test('memory warning: critical for 10 s, moderate until 30 s', () {
      final t = PressureTracker(policy)
        ..onSample(FakePlatformBackend.iosSample())
        ..onSignal(_signal(SignalKind.memoryWarning), at(0));
      final s = t.evaluate(at(0));
      expect(s.pressure, MemoryPressure.critical);
      expect(s.source, 'ios:memoryWarning');
      // The monitor re-evaluates at each deadline; hysteresis counts from there.
      expect(t.nextDeadline(at(0)), at(10));
      expect(t.evaluate(at(10, 1)).pressure, MemoryPressure.critical);
      expect(t.evaluate(at(15, 1)).pressure, MemoryPressure.moderate);
      expect(t.evaluate(at(30, 1)).pressure, MemoryPressure.moderate);
      expect(t.evaluate(at(35, 1)).pressure, MemoryPressure.normal);
    });

    test('a second warning extends the hold', () {
      final t = PressureTracker(policy)..onSignal(_signal(SignalKind.memoryWarning), at(0));
      t.evaluate(at(0));
      t.onSignal(_signal(SignalKind.memoryWarning), at(8));
      expect(t.evaluate(at(17)).pressure, MemoryPressure.critical);
    });

    test('dispatch source is level-triggered', () {
      final t = PressureTracker(policy)..onSignal(_signal(SignalKind.memoryPressure, level: 2), at(0));
      expect(t.evaluate(at(0)).pressure, MemoryPressure.critical);
      expect(t.evaluate(at(1000)).pressure, MemoryPressure.critical);
      t.onSignal(_signal(SignalKind.memoryPressure, level: 1), at(1000));
      expect(t.evaluate(at(1000)).pressure, MemoryPressure.critical, reason: 'hysteresis');
      expect(t.evaluate(at(1005)).pressure, MemoryPressure.moderate);
      t.onSignal(_signal(SignalKind.memoryPressure), at(1005));
      expect(t.evaluate(at(1005)).pressure, MemoryPressure.moderate);
      expect(t.evaluate(at(1010)).pressure, MemoryPressure.normal);
    });

    test('a low os_proc_available_memory sample is critical without any event', () {
      final t = PressureTracker(policy)
        ..onSample(FakePlatformBackend.iosSample(procAvailable: 100 * _mib, footprint: 2000 * _mib));
      expect(t.evaluate(t0).pressure, MemoryPressure.critical);
      expect(t.evaluate(t0).source, 'ios:sample');
    });
  });

  group('hysteresis', () {
    test('escalation is immediate, a brief dip does not downgrade', () {
      final t = PressureTracker(policy);
      t.onSample(FakePlatformBackend.androidSample(availMem: 300 * _mib, timestampMs: 1));
      expect(t.evaluate(at(0)).pressure, MemoryPressure.critical);
      t.onSample(FakePlatformBackend.androidSample(availMem: 4000 * _mib, timestampMs: 2));
      expect(t.evaluate(at(2)).pressure, MemoryPressure.critical);
      expect(t.nextDeadline(at(2)), at(7));
      // Back to critical before the delay: the pending downgrade is dropped.
      t.onSample(FakePlatformBackend.androidSample(availMem: 300 * _mib, timestampMs: 3));
      expect(t.evaluate(at(4)).pressure, MemoryPressure.critical);
      t.onSample(FakePlatformBackend.androidSample(availMem: 4000 * _mib, timestampMs: 4));
      expect(t.evaluate(at(5)).pressure, MemoryPressure.critical);
      expect(t.evaluate(at(9)).pressure, MemoryPressure.critical);
      expect(t.evaluate(at(10)).pressure, MemoryPressure.normal);
    });

    test('a zero delay downgrades at once', () {
      final t = PressureTracker(const PressurePolicy(downgradeDelay: Duration.zero))
        ..onSample(FakePlatformBackend.androidSample(availMem: 300 * _mib, timestampMs: 1));
      expect(t.evaluate(at(0)).pressure, MemoryPressure.critical);
      t.onSample(FakePlatformBackend.androidSample(availMem: 4000 * _mib, timestampMs: 2));
      expect(t.evaluate(at(0)).pressure, MemoryPressure.normal);
    });

    test('out-of-order samples are ignored', () {
      final t = PressureTracker(policy)
        ..onSample(FakePlatformBackend.androidSample(availMem: 4000 * _mib, timestampMs: 20))
        ..onSample(FakePlatformBackend.androidSample(availMem: 300 * _mib, timestampMs: 10));
      expect(t.evaluate(t0).pressure, MemoryPressure.normal);
    });
  });

  group('thermal and power', () {
    test('signals and samples, newest wins; downgrade is delayed', () {
      final t = PressureTracker(policy)
        ..onSample(FakePlatformBackend.androidSample(thermalStatus: 0, timestampMs: 100))
        ..onSignal(_signal(SignalKind.thermal, level: 3, ts: 200), at(0));
      expect(t.evaluate(at(0)).thermal, ThermalLevel.critical);
      // An older sample (taken before the signal) does not undo it.
      t.onSample(FakePlatformBackend.androidSample(thermalStatus: 0, timestampMs: 150));
      expect(t.evaluate(at(10)).thermal, ThermalLevel.critical);
      t.onSignal(_signal(SignalKind.thermal, level: 1, ts: 300), at(10));
      expect(t.evaluate(at(10)).thermal, ThermalLevel.critical);
      expect(t.evaluate(at(15)).thermal, ThermalLevel.fair);
    });

    test('headroom pushes raise Android thermal', () {
      final t = PressureTracker(policy)
        ..onSample(FakePlatformBackend.androidSample(timestampMs: 1))
        ..onSignal(_signal(SignalKind.thermalHeadroom, value: 0.9), t0);
      expect(t.evaluate(t0).thermal, ThermalLevel.serious);
    });

    test('power mode follows the newest input', () {
      final t = PressureTracker(policy)..onSignal(_signal(SignalKind.powerMode, level: 1, ts: 10), t0);
      expect(t.evaluate(t0).lowPowerMode, isTrue);
      // A sample taken before the event does not undo it.
      t.onSample(FakePlatformBackend.androidSample(timestampMs: 5));
      expect(t.evaluate(t0).lowPowerMode, isTrue);
      t.onSignal(_signal(SignalKind.powerMode, ts: 20), t0);
      expect(t.evaluate(t0).lowPowerMode, isFalse);
      t.onSample(FakePlatformBackend.androidSample(lowPowerMode: true, timestampMs: 30));
      expect(t.evaluate(t0).lowPowerMode, isTrue);
    });

    test('iOS thermal maps from the sample', () {
      final t = PressureTracker(policy)..onSample(FakePlatformBackend.iosSample(thermalStatus: 2));
      expect(t.evaluate(t0).thermal, ThermalLevel.serious);
    });
  });
}
