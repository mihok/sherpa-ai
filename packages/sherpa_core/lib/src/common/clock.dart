/// Injectable time source so timeouts, expiries and checkpoints are testable.
abstract interface class Clock {
  DateTime now();
}

final class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now().toUtc();
}

/// Manually advanced clock for tests.
final class FakeClock implements Clock {
  FakeClock([DateTime? start]) : _now = start ?? DateTime.utc(2026, 1, 1);

  DateTime _now;

  @override
  DateTime now() => _now;

  void advance(Duration d) => _now = _now.add(d);

  set current(DateTime value) => _now = value;
}
