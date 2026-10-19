import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_platform/sherpa_platform.dart';
import 'package:sherpa_platform/testing.dart';

const _mib = 1024 * 1024;

final class _FakeAsyncClock implements Clock {
  _FakeAsyncClock(this.fa);

  final FakeAsync fa;
  final DateTime start = DateTime.utc(2026, 10, 18);

  @override
  DateTime now() => start.add(fa.elapsed);
}

void main() {
  late FakePlatformBackend backend;
  late FakeForegroundSource fg;

  PlatformMemoryMonitor monitor(FakeAsync fa, {PressurePolicy policy = const PressurePolicy()}) =>
      PlatformMemoryMonitor(backend: backend, foreground: fg, clock: _FakeAsyncClock(fa), policy: policy);

  setUp(() {
    backend = FakePlatformBackend();
    fg = FakeForegroundSource();
  });

  test('sample() works without listeners and updates current', () async {
    final m = PlatformMemoryMonitor(backend: backend, foreground: fg);
    expect(m.current.pressure, MemoryPressure.normal);
    expect(m.current.availableBytes, isNull);
    final s = await m.sample();
    expect(s.availableBytes, (3072 - 256) * _mib);
    expect(m.current, same(s));
    expect(backend.signalsListened, isFalse, reason: 'no native registration without listeners');
    await m.dispose();
  });

  test('a platform error keeps the last state and is recorded', () async {
    final m = PlatformMemoryMonitor(backend: backend, foreground: fg);
    await m.sample();
    backend.sampleError = StateError('channel-error');
    final s = await m.sample();
    expect(s.availableBytes, (3072 - 256) * _mib);
    expect(m.lastError, isA<StateError>());
    await m.dispose();
  });

  test('periodic sampling runs only while listened and in the foreground', () {
    fakeAsync((fa) {
      final m = monitor(fa);
      fa.elapse(const Duration(seconds: 10));
      expect(backend.sampleCalls, 0, reason: 'nothing runs without listeners');

      final sub = m.changes.listen((_) {});
      fa.flushMicrotasks();
      expect(backend.signalsListened, isTrue);
      expect(backend.sampleCalls, 1, reason: 'initial sample on listen');
      fa.elapse(const Duration(seconds: 6));
      expect(backend.sampleCalls, 4, reason: 'every 2 s');

      fg.foreground = false;
      fa.flushMicrotasks();
      final afterHide = backend.sampleCalls;
      expect(afterHide, 5, reason: 'one sample on the transition');
      fa.elapse(const Duration(minutes: 1));
      expect(backend.sampleCalls, afterHide, reason: 'no polling in the background');

      fg.foreground = true;
      fa.flushMicrotasks();
      fa.elapse(const Duration(seconds: 2));
      expect(backend.sampleCalls, afterHide + 2);

      unawaited(sub.cancel());
      fa.flushMicrotasks();
      expect(backend.signalsListened, isFalse);
      final stopped = backend.sampleCalls;
      fa.elapse(const Duration(seconds: 10));
      expect(backend.sampleCalls, stopped);
      unawaited(m.dispose());
      fa.flushMicrotasks();
    });
  });

  test('a burst of signals yields one urgent emission and one trailing sample', () {
    fakeAsync((fa) {
      fg.foreground = false;
      final m = monitor(fa);
      final states = <MemoryState>[];
      final sub = m.changes.listen(states.add);
      fa.flushMicrotasks();
      final base = backend.sampleCalls;
      states.clear();

      // Android leaving the foreground: UI_HIDDEN then BACKGROUND within 1 ms.
      backend.emit(SignalKind.trimMemory, level: 20);
      backend.emit(SignalKind.trimMemory, level: 40);
      fa.flushMicrotasks();
      expect(states.map((s) => s.pressure), [MemoryPressure.critical],
          reason: 'critical is published at once; the moderate step is coalesced away');
      expect(backend.sampleCalls, base, reason: 'sampling waits for the burst to settle');

      fa.elapse(const Duration(milliseconds: 300));
      expect(backend.sampleCalls, base + 1);
      expect(states.length, 1, reason: 'the trailing sample changed nothing');
      unawaited(sub.cancel());
      unawaited(m.dispose());
      fa.flushMicrotasks();
    });
  });

  test('non-urgent changes are coalesced into the trailing update', () {
    fakeAsync((fa) {
      final m = monitor(fa);
      final states = <MemoryState>[];
      final sub = m.changes.listen(states.add);
      fa.flushMicrotasks();
      states.clear();

      // Newer than the fake's (static) sample, as a real event would be.
      final later = backend.memory.timestampMs + 1000;
      backend.emit(SignalKind.powerMode, level: 1, timestampMs: later);
      backend.emit(SignalKind.thermal, level: 1, timestampMs: later);
      fa.flushMicrotasks();
      expect(states, isEmpty);
      fa.elapse(const Duration(milliseconds: 260));
      expect(states, hasLength(1));
      expect(states.single.lowPowerMode, isTrue);
      expect(states.single.thermal, ThermalLevel.fair);
      unawaited(sub.cancel());
      unawaited(m.dispose());
      fa.flushMicrotasks();
    });
  });

  test('an iOS memory warning decays on its own via scheduled deadlines', () {
    fakeAsync((fa) {
      backend.memory = FakePlatformBackend.iosSample();
      final m = monitor(fa);
      final states = <MemoryPressure>[];
      final sub = m.changes.listen((s) => states.add(s.pressure));
      fa.flushMicrotasks();
      states.clear();

      backend.emit(SignalKind.memoryWarning);
      fa.flushMicrotasks();
      expect(m.current.pressure, MemoryPressure.critical);
      // 10 s critical hold + 5 s hysteresis → moderate; 30 s hold + 5 s → normal.
      fa.elapse(const Duration(seconds: 14));
      expect(m.current.pressure, MemoryPressure.critical);
      fa.elapse(const Duration(seconds: 2));
      expect(m.current.pressure, MemoryPressure.moderate);
      fa.elapse(const Duration(seconds: 20));
      expect(m.current.pressure, MemoryPressure.normal);
      expect(states, [MemoryPressure.critical, MemoryPressure.moderate, MemoryPressure.normal]);
      unawaited(sub.cancel());
      unawaited(m.dispose());
      fa.flushMicrotasks();
    });
  });

  test('periodic samples are emitted only when something changed', () {
    fakeAsync((fa) {
      final m = monitor(fa);
      final states = <MemoryState>[];
      final sub = m.changes.listen(states.add);
      fa.flushMicrotasks();
      expect(states, hasLength(1));
      fa.elapse(const Duration(seconds: 4));
      expect(states, hasLength(1), reason: 'identical samples are not re-emitted');
      backend.memory = FakePlatformBackend.androidSample(availMem: 2048 * _mib);
      fa.elapse(const Duration(seconds: 2));
      expect(states, hasLength(2));
      expect(states.last.availableBytes, (2048 - 256) * _mib);
      unawaited(sub.cancel());
      unawaited(m.dispose());
      fa.flushMicrotasks();
    });
  });

  test('returning to the foreground clears hidden-state trims (after hysteresis)', () {
    fakeAsync((fa) {
      fg.foreground = false;
      final m = monitor(fa);
      final sub = m.changes.listen((_) {});
      fa.flushMicrotasks();
      backend.emit(SignalKind.trimMemory, level: 40);
      fa.flushMicrotasks();
      expect(m.current.pressure, MemoryPressure.critical);
      fg.foreground = true;
      fa.flushMicrotasks();
      expect(m.current.pressure, MemoryPressure.critical);
      fa.elapse(const Duration(seconds: 6));
      expect(m.current.pressure, MemoryPressure.normal);
      unawaited(sub.cancel());
      unawaited(m.dispose());
      fa.flushMicrotasks();
    });
  });

  test('lease signals are ignored by the monitor', () {
    fakeAsync((fa) {
      final m = monitor(fa);
      final states = <MemoryState>[];
      final sub = m.changes.listen(states.add);
      fa.flushMicrotasks();
      states.clear();
      backend.emit(SignalKind.leaseExpired, leaseId: 'x');
      fa.elapse(const Duration(seconds: 1));
      expect(states, isEmpty);
      unawaited(sub.cancel());
      unawaited(m.dispose());
      fa.flushMicrotasks();
    });
  });

  test('implements the sherpa_core contract', () {
    final MemoryMonitor m = PlatformMemoryMonitor(backend: backend, foreground: fg);
    expect(m.current, MemoryState.unknown);
  });
}
