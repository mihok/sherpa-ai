#!/usr/bin/env bash
# Frame-timing benchmark on a device or emulator (docs/research/12 §3.7–3.8).
#
#   bench/app/run_frame_bench.sh -d <flutter device id> -c <device class> [-n runs]
#
#   -d  device id from `flutter devices` (a physical device for real numbers;
#       an emulator only for relative gates, R12 §3.8)
#   -c  device class, e.g. android-mid-adreno650-gles: picks
#       bench/baselines/<class>/ (created on the first run)
#   -n  runs (default 5 on a device; R12 says 3 on an emulator)
#
# What it does:
#   1. copies bench/app/integration_test/stream_perf_test.dart and
#      bench/app/test_driver/perf_driver.dart into app/ under _bench_* names
#      (untracked; removed again on exit, whatever happens), so no tracked
#      app file is edited;
#   2. runs `flutter drive --profile --no-dds` N times and keeps each
#      app/build/stream_4k_tokens_markdown.timeline_summary.json;
#   3. converts the runs into build/bench-device/<scenario>.json (medians);
#   4. gates them with tools/perf_gate.dart against bench/baselines/<class>/,
#      or, when that class has no baselines yet, writes initial ones there
#      for review (commit them with the perf-rebaseline label).
#
# Requirements: Flutter 3.47, a connected device, and the app's dev
# dependencies (integration_test; flutter_driver resolves through it, but
# app/pubspec.yaml should list `flutter_driver: {sdk: flutter}` too).
# UNVERIFIED on hardware: no device was available when this was written.
set -euo pipefail
cd "$(dirname "$0")/../.."

device=""
class=""
runs=5
while getopts "d:c:n:" opt; do
  case $opt in
    d) device=$OPTARG ;;
    c) class=$OPTARG ;;
    n) runs=$OPTARG ;;
    *) sed -n '2,30p' "$0"; exit 2 ;;
  esac
done
if [[ -z $device || -z $class ]]; then
  sed -n '2,30p' "$0"
  exit 2
fi

scenario=stream_4k_tokens_markdown
target=app/integration_test/_bench_stream_perf_test.dart
driver=app/test_driver/_bench_perf_driver.dart
out=build/bench-device
created_driver_dir=0
cleanup() {
  rm -f "$target" "$driver"
  if [[ $created_driver_dir == 1 ]]; then rmdir app/test_driver 2>/dev/null || true; fi
}
trap cleanup EXIT

[[ -d app/test_driver ]] || { mkdir app/test_driver; created_driver_dir=1; }
cp bench/app/integration_test/stream_perf_test.dart "$target"
cp bench/app/test_driver/perf_driver.dart "$driver"
rm -rf "$out/runs"
mkdir -p "$out/runs"

for i in $(seq 1 "$runs"); do
  echo "== run $i/$runs on $device"
  (cd app && flutter drive --profile --no-dds -d "$device" \
    --driver=test_driver/_bench_perf_driver.dart \
    --target=integration_test/_bench_stream_perf_test.dart)
  cp "app/build/$scenario.timeline_summary.json" "$out/runs/run_$i.json"
done

dart bench/app/timeline_to_result.dart --scenario "$scenario" --device-class "$class" --out "$out" "$out"/runs/run_*.json
if [[ -d bench/baselines/$class ]]; then
  dart run tools/perf_gate.dart --results "$out" --baselines "bench/baselines/$class"
else
  echo "== no baselines for $class yet: writing initial ones (review margins, then commit)"
  dart run tools/perf_gate.dart --rebaseline --min-samples "$runs" --results "$out" --baselines "bench/baselines/$class"
fi
