/// Converts `flutter drive` timeline summaries (one per run) into a bench
/// result that `tools/perf_gate.dart` gates (median of the runs).
///
///     dart bench/app/timeline_to_result.dart --scenario stream_4k_tokens_markdown \
///         --device-class android-mid-adreno650-gles --out build/bench-device run1.json run2.json …
library;

import 'dart:convert';
import 'dart:io';

/// The `TimelineSummary` keys worth gating (R12 §3.7); `frame_count` is
/// kept for the baseline's `min_frames` validity check.
const List<String> keys = [
  'frame_count',
  'average_frame_build_time_millis',
  '90th_percentile_frame_build_time_millis',
  '99th_percentile_frame_build_time_millis',
  'worst_frame_build_time_millis',
  '90th_percentile_frame_rasterizer_time_millis',
  '99th_percentile_frame_rasterizer_time_millis',
  'missed_frame_build_budget_count',
  'missed_frame_rasterizer_budget_count',
  'new_gen_gc_count',
  'old_gen_gc_count',
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
    stderr.writeln('usage: dart bench/app/timeline_to_result.dart --scenario ID --device-class CLASS --out DIR SUMMARY.json…');
    exitCode = 2;
    return;
  }
  final runs = <String, List<num>>{};
  for (final f in files) {
    final j = (jsonDecode(File(f).readAsStringSync()) as Map).cast<String, Object?>();
    for (final k in keys) {
      final v = j[k];
      if (v is num) (runs[k] ??= []).add(v);
    }
  }
  num median(List<num> xs) {
    final s = [...xs]..sort();
    final m = s.length ~/ 2;
    return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
  }

  final result = {
    'schema': 'sherpa.bench.result/1',
    'scenario': scenario,
    'device_class': deviceClass,
    'samples': files.length,
    'metrics': {
      for (final e in runs.entries)
        e.key: {
          'median': median(e.value),
          'unit': e.key.endsWith('_millis') ? 'ms' : 'count',
          'better': e.key == 'frame_count' ? 'higher' : 'lower',
          'runs': e.value,
        },
    },
  };
  Directory(out).createSync(recursive: true);
  File('$out/$scenario.json').writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(result)}\n');
  stdout.writeln('wrote $out/$scenario.json (${files.length} runs)');
}
