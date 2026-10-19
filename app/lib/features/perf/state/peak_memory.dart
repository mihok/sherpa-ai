import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

/// Reads the app's current memory use in bytes, or null when unknown.
typedef MemoryReader = Future<int?> Function();

/// Resident set size of this process from `/proc/self/status` (Linux and
/// Android), else null. With the in-process engine that includes the
/// engine's weights, KV cache and compute buffers.
Future<int?> processResidentBytes() async {
  if (!(Platform.isLinux || Platform.isAndroid)) return null;
  try {
    final status = await File('/proc/self/status').readAsString();
    final m = RegExp(r'^VmRSS:\s+(\d+)\s*kB', multiLine: true).firstMatch(status);
    return m == null ? null : int.parse(m.group(1)!) * 1024;
  } on Object {
    return null;
  }
}

/// Samples [read] every [period] while a measurement runs and keeps the
/// highest value: "peak memory where available".
final class PeakMemorySampler {
  PeakMemorySampler(this.read, {this.period = const Duration(milliseconds: 250)});

  final MemoryReader read;
  final Duration period;

  int? _baseline;
  int? _peak;
  Timer? _timer;
  Future<void>? _inFlight;

  int? get baseline => _baseline;
  int? get peak => _peak;

  Future<void> start() async {
    _baseline = await _safeRead();
    _peak = _baseline;
    _timer = Timer.periodic(period, (_) => _inFlight ??= _sample().whenComplete(() => _inFlight = null));
  }

  Future<void> _sample() async {
    final v = await _safeRead();
    if (v != null) _peak = _peak == null ? v : math.max(_peak!, v);
  }

  Future<int?> _safeRead() async {
    try {
      return await read();
    } on Object {
      return null;
    }
  }

  /// Stops sampling after one last reading.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _inFlight;
    await _sample();
  }
}
