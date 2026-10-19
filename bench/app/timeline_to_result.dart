/// Converts `flutter drive` timeline summaries (one per run) into a bench
/// result that `tools/perf_gate.dart` gates (median of the runs).
///
///     dart bench/app/timeline_to_result.dart --scenario chat_stream_long_reply \
///         --device-class android-mid-adreno650-gles [--device "Pixel 6a"] --out build/bench-device run1.json run2.json …
///
/// Gated `metrics` are the frame build and raster times (R12 §3.7), the
/// missed-frame-budget and GC counts, plus `frame_count` for the baseline's
/// `min_frames` validity check. Counts carry a `min_abs_tolerance`
/// suggestion ([countTolerance]): perf_gate's relative bound alone is zero
/// for a zero baseline, so a scenario that once measured "0 missed frames"
/// would fail on the first one; the floor lets a few through, and
/// `--rebaseline` copies it into new baselines. The worst frames and the
/// missed vsyncs stay in `info` (single outliers; reported, not gated).
library;

import 'dart:convert';
import 'dart:io';

/// Gated, lower is better (except `frame_count`, which only validates).
const List<String> gatedKeys = [
  'frame_count',
  'average_frame_build_time_millis',
  '90th_percentile_frame_build_time_millis',
  '99th_percentile_frame_build_time_millis',
  '90th_percentile_frame_rasterizer_time_millis',
  '99th_percentile_frame_rasterizer_time_millis',
  'missed_frame_build_budget_count',
  'missed_frame_rasterizer_budget_count',
  'new_gen_gc_count',
  'old_gen_gc_count',
];

/// Gated counts and the absolute change each may make before it fails,
/// whatever its baseline (perf_gate `min_abs_tolerance`): a few missed
/// 16.7 ms budgets per scenario run are noise on a phone (a GC pause, the
/// first frame of a route), and new-generation GCs scale with allocation.
const Map<String, num> countTolerance = {
  'missed_frame_build_budget_count': 3,
  'missed_frame_rasterizer_budget_count': 3,
  'new_gen_gc_count': 5,
  'old_gen_gc_count': 2,
};

/// Reported only (medians of the runs).
const List<String> infoKeys = [
  'worst_frame_build_time_millis',
  'worst_frame_rasterizer_time_millis',
  '90th_percentile_vsync_transitions_missed',
  '99th_percentile_vsync_transitions_missed',
];

void main(List<String> args) {
  String? opt(String name) {
    final i = args.indexOf('--$name');
    return i < 0 || i + 1 >= args.length ? null : args[i + 1];
  }

  final scenario = opt('scenario');
  final deviceClass = opt('device-class');
  final out = opt('out');
  final files = [
    for (var i = 0; i < args.length; i++)
      if (!args[i].startsWith('--') && (i == 0 || !args[i - 1].startsWith('--'))) args[i],
  ];
  if (scenario == null || deviceClass == null || out == null || files.isEmpty) {
    stderr.writeln('usage: dart bench/app/timeline_to_result.dart --scenario ID --device-class CLASS '
        '[--device NAME] --out DIR SUMMARY.json…');
    exitCode = 2;
    return;
  }
  final runs = <String, List<num>>{};
  for (final f in files) {
    final j = (jsonDecode(File(f).readAsStringSync()) as Map).cast<String, Object?>();
    for (final k in [...gatedKeys, ...infoKeys]) {
      final v = j[k];
      if (v is num) (runs[k] ??= []).add(v);
    }
  }
  num median(List<num> xs) {
    final s = [...xs]..sort();
    final m = s.length ~/ 2;
    return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
  }

  Map<String, Object?> metric(String k, List<num> v) => {
        'median': median(v),
        'unit': k.endsWith('_millis') ? 'ms' : 'count',
        'better': k == 'frame_count' ? 'higher' : 'lower',
        'min_abs_tolerance': ?countTolerance[k],
        'runs': v,
      };

  final device = opt('device');
  final result = {
    'schema': 'sherpa.bench.result/1',
    'scenario': scenario,
    'device_class': deviceClass,
    'samples': files.length,
    'host': {'device_class': deviceClass, 'device': ?device},
    'metrics': {
      for (final k in gatedKeys)
        if (runs[k] != null) k: metric(k, runs[k]!),
    },
    'info': {
      for (final k in infoKeys)
        if (runs[k] != null) k: metric(k, runs[k]!),
    },
  };
  Directory(out).createSync(recursive: true);
  File('$out/$scenario.json').writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(result)}\n');
  stdout.writeln('wrote $out/$scenario.json (${files.length} runs)');
}
