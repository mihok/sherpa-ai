import 'dart:math';

/// Generates identifiers. Injected everywhere so tests are deterministic.
abstract interface class IdGenerator {
  String next([String prefix]);
}

/// Time-ordered, collision-resistant ids (`<prefix>_<millis36><random36>`).
///
/// Ordering by id roughly matches creation order, which keeps SQLite indexes
/// and transcript listings stable without a separate sequence column.
final class RandomIdGenerator implements IdGenerator {
  RandomIdGenerator({Random? random, DateTime Function()? now})
      : _random = random ?? Random.secure(),
        _now = now ?? DateTime.now;

  final Random _random;
  final DateTime Function() _now;

  @override
  String next([String prefix = 'id']) {
    final millis = _now().millisecondsSinceEpoch.toRadixString(36).padLeft(9, '0');
    final buf = StringBuffer('${prefix}_$millis');
    for (var i = 0; i < 10; i++) {
      buf.write(_random.nextInt(36).toRadixString(36));
    }
    return buf.toString();
  }
}

/// Deterministic ids for tests and scripted evals: `<prefix>_1`, `<prefix>_2`…
final class SequentialIdGenerator implements IdGenerator {
  final Map<String, int> _counters = {};

  @override
  String next([String prefix = 'id']) {
    final n = (_counters[prefix] ?? 0) + 1;
    _counters[prefix] = n;
    return '${prefix}_$n';
  }
}
