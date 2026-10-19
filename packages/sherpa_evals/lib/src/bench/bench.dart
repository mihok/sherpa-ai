/// Host benchmarks (R12 §3.8): each scenario runs one warm-up and N
/// samples; a sample returns its metrics, and the result file keeps every
/// run plus the median, which `tools/perf_gate.dart` compares with the
/// committed baseline for the device class.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../stats.dart';

/// Which direction of change is an improvement (mirrors the gate).
enum BenchBetter { lower, higher }

/// One metric of a sample.
final class BenchValue {
  const BenchValue(this.value, {this.unit = '', this.better = BenchBetter.lower});

  final double value;
  final String unit;
  final BenchBetter better;
}

/// A scenario (`bench/baselines/<device-class>/<id>.json`).
abstract class BenchScenario {
  String get id;
  String get description;

  /// Why the scenario cannot run here (missing engine or model), or null.
  String? get skipReason => null;

  Future<void> setUp() async {}

  /// One sample.
  Future<Map<String, BenchValue>> sample();

  Future<void> tearDown() async {}
}

/// The result file of one scenario.
final class BenchResult {
  BenchResult(this.scenario, this.deviceClass, {this.description = '', this.skipped});

  static const String schema = 'sherpa.bench.result/1';

  final String scenario;
  final String deviceClass;
  final String description;
  final String? skipped;
  final Map<String, List<double>> runs = {};
  final Map<String, BenchValue> meta = {};
  int samples = 0;

  Map<String, Object?> toJson() => {
        'schema': schema,
        'scenario': scenario,
        'device_class': deviceClass,
        if (description.isNotEmpty) 'description': description,
        if (skipped != null) 'skipped': skipped,
        'samples': samples,
        'host': {
          'os': Platform.operatingSystem,
          'cpus': Platform.numberOfProcessors,
          'dart': Platform.version.split(' ').first,
        },
        'metrics': {
          for (final e in runs.entries)
            e.key: {
              'median': _round(median(e.value)),
              'unit': meta[e.key]!.unit,
              'better': meta[e.key]!.better.name,
              'runs': [for (final v in e.value) _round(v)],
            },
        },
      };

  File write(String dir) {
    Directory(dir).createSync(recursive: true);
    return File(p.join(dir, '$scenario.json'))..writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(toJson())}\n');
  }
}

num _round(double v) => v.abs() >= 1000 ? double.parse(v.toStringAsFixed(1)) : double.parse(v.toStringAsPrecision(6));

/// Runs [s]: one warm-up sample, then [samples] measured ones.
Future<BenchResult> runScenario(BenchScenario s, {int samples = 5, String deviceClass = 'linux-ci', void Function(String)? log}) async {
  final skip = s.skipReason;
  if (skip != null) return BenchResult(s.id, deviceClass, description: s.description, skipped: skip);
  final r = BenchResult(s.id, deviceClass, description: s.description);
  await s.setUp();
  try {
    await s.sample(); // warm-up (JIT, caches)
    for (var i = 0; i < samples; i++) {
      final m = await s.sample();
      for (final e in m.entries) {
        (r.runs[e.key] ??= []).add(e.value.value);
        r.meta[e.key] = e.value;
      }
      r.samples++;
      log?.call('  ${s.id} #$i: ${[for (final e in m.entries) '${e.key}=${e.value.value.toStringAsFixed(2)}'].join(' ')}');
    }
  } finally {
    await s.tearDown();
  }
  return r;
}

/// Microseconds [body] takes, as the median of [reps] repetitions.
Future<double> timeMedianUs(Future<void> Function() body, {int reps = 5}) async {
  final xs = <double>[];
  for (var i = 0; i < reps; i++) {
    final sw = Stopwatch()..start();
    await body();
    xs.add(sw.elapsedMicroseconds.toDouble());
  }
  return median(xs);
}
