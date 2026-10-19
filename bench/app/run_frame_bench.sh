#!/usr/bin/env bash
# Frame-timing benchmark on a device or emulator (docs/research/12 §3.7–3.8).
#
#   bench/app/run_frame_bench.sh -d <device id> -c <device class> [-n runs] [-r repeats]
#                                [-s scenario,…] [-o out dir] [-b new-baselines dir]
#
#   -d  device id from `flutter devices` (a physical device for real numbers;
#       an emulator only for relative, catastrophic-regression gates, R12 §3.8)
#   -c  device class, e.g. android-mid-adreno650-gles: picks
#       bench/baselines/<class>/
#   -n  app launches (default 5; R12 asks for 3 on an emulator)
#   -r  repetitions of each scenario inside one launch (default 1)
#   -s  only these scenarios (default: all five)
#   -o  output directory (default build/bench-device)
#   -b  where to write new baselines when the class has none yet or only
#       placeholders (default: bench/baselines/<class>/ itself)
#
# What it does:
#   1. runs app/integration_test/frame_bench_test.dart N times with
#      `flutter drive --profile --no-dds --endless-trace-buffer`; the driver
#      (app/test_driver/perf_driver.dart) writes
#      app/build/<scenario>.r<k>.timeline_summary.json per scenario;
#   2. converts each scenario's runs × repetitions into
#      <out>/<scenario>.json (medians) with bench/app/timeline_to_result.dart;
#   3. gates them with tools/perf_gate.dart against bench/baselines/<class>/,
#      or, when that class has no baselines yet or only placeholders
#      ("placeholder": true), writes measured ones (margins kept) to -b for
#      review; commit them with the perf-rebaseline label.
#
# Exit code: perf_gate's (0 pass, 1 regression or invalid run, 2 usage).
# The scenarios also run on the host as a smoke test (no gating):
#   cd app && flutter test -d flutter-tester integration_test/frame_bench_test.dart
set -euo pipefail
cd "$(dirname "$0")/../.."

usage() { sed -n '2,33p' "$0"; exit 2; }

device=""
class=""
runs=5
repeats=1
only=""
out=build/bench-device
new_baselines=""
while getopts "d:c:n:r:s:o:b:" opt; do
  case $opt in
    d) device=$OPTARG ;;
    c) class=$OPTARG ;;
    n) runs=$OPTARG ;;
    r) repeats=$OPTARG ;;
    s) only=$OPTARG ;;
    o) out=$OPTARG ;;
    b) new_baselines=$OPTARG ;;
    *) usage ;;
  esac
done
[[ -n $device && -n $class ]] || usage

scenarios=(stream_4k_tokens_markdown chat_stream_long_reply chat_scroll_long_transcript model_picker_open context_inspector)
if [[ -n $only ]]; then IFS=, read -r -a scenarios <<< "$only"; fi
baselines=bench/baselines/$class

rm -rf "$out"
mkdir -p "$out/runs" "$out/timelines"
defines=(--dart-define=SHERPA_BENCH_REPEAT="$repeats")
[[ -n $only ]] && defines+=(--dart-define=SHERPA_BENCH_ONLY="$only")

for i in $(seq 1 "$runs"); do
  echo "== launch $i/$runs on $device ($repeats repetition(s) per scenario)"
  rm -f app/build/*.timeline_summary.json app/build/*.timeline.json
  (cd app && flutter drive --profile --no-dds --endless-trace-buffer -d "$device" "${defines[@]}" \
    --driver=test_driver/perf_driver.dart --target=integration_test/frame_bench_test.dart)
  for s in "${scenarios[@]}"; do
    mkdir -p "$out/runs/$s"
    found=0
    for f in app/build/"$s".r*.timeline_summary.json; do
      [[ -e $f ]] || continue
      rep=$(basename "$f" .timeline_summary.json); rep=${rep##*.}
      cp "$f" "$out/runs/$s/launch$i.$rep.json"
      found=1
    done
    [[ $found == 1 ]] || { echo "!! no timeline summary for $s in launch $i"; exit 1; }
  done
  # Keep the last launch's full timelines for Perfetto / DevTools.
  mv app/build/*.timeline.json "$out/timelines/" 2>/dev/null || true
done

for s in "${scenarios[@]}"; do
  dart bench/app/timeline_to_result.dart --scenario "$s" --device-class "$class" --out "$out" "$out/runs/$s"/*.json
done

if [[ -d $baselines ]] && ! grep -lq '"placeholder": true' "$baselines"/*.json 2>/dev/null; then
  dart run tools/perf_gate.dart --results "$out" --baselines "$baselines" --json "$out/perf-gate.json" \
    ${GITHUB_STEP_SUMMARY:+--summary "$GITHUB_STEP_SUMMARY"}
else
  target=${new_baselines:-$baselines}
  echo "== $class has no measured baselines yet: writing them to $target (review the margins, then commit)"
  # Report against the placeholders first (informational), then rebaseline.
  dart run tools/perf_gate.dart --results "$out" --baselines "$baselines" \
    ${GITHUB_STEP_SUMMARY:+--summary "$GITHUB_STEP_SUMMARY"} || true
  # The placeholder flag and its note drop out; margins, min_samples,
  # optional and the class note are kept.
  dart run tools/perf_gate.dart --rebaseline --min-samples "$((runs * repeats))" --results "$out" \
    --baselines "$baselines" --out "$target"
fi
