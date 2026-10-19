# Frame-timing benchmark (app)

Frame build and raster times of the real app, measured on a phone or an
emulator and gated with `tools/perf_gate.dart` against
`bench/baselines/<device-class>/` (docs/research/12-mobile-ux-ci.md §3.7–3.8).
The host benchmarks of the packages (`dart run sherpa_evals:bench`,
`bench/baselines/linux-ci/`) are separate; see `packages/sherpa_evals/README.md`.

| Scenario | What is traced |
|---|---|
| `stream_4k_tokens_markdown` | `StreamingMarkdown` alone (no chat chrome): a ~1.5K-token reply with headings, lists, code and tables revealed 4 characters per 16 ms frame |
| `chat_stream_long_reply` | The chat screen streaming a long reply (8 sections with fenced code and tables) from the scripted model, one 4-character delta every 8 ms, until the run ends |
| `chat_scroll_long_transcript` | Six flings up through a 60-exchange transcript (markdown replies, tool cards), six back down |
| `model_picker_open` | Opening the model picker (4 providers × 12 models plus the on-device section), flinging it, closing it; four times, after a warm-up open |
| `context_inspector` | Opening "What the model sees" for the 60-exchange chat, flinging it, going back; three times |

The app comes from `bootstrap(inMemory: true)`, with the model providers
replaced by a scripted "remote" model (`ScriptedProvider`), chats seeded
straight into the session store, onboarding done, and the on-device engine
wired but not started on its own (the picker's warm-up open starts it, outside
the trace). Nothing touches the network.

Files:

* `app/integration_test/frame_bench_test.dart`: the scenarios, each inside
  `traceAction` under the report key `<scenario>.r<k>` (repetition `k`);
* `app/integration_test/support/bench_app.dart`: the bench app, seeding and
  real-time waits;
* `app/test_driver/perf_driver.dart`: writes
  `app/build/<key>.timeline_summary.json` and `<key>.timeline.json`;
* `bench/app/timeline_to_result.dart`: summaries of the runs → one result per
  scenario (medians) in the format perf_gate reads;
* `bench/app/run_frame_bench.sh`: all of the above, then the gate.

## Run it on an Android phone

1. Enable USB debugging, connect the phone and find its id with
   `flutter devices`.
2. Get the phone into a steady state: unplugged from power or at least
   charged above 80%, battery saver off, "Remove animations" off
   (Settings › Accessibility; with it on, Flutter runs every animation at 5%
   of its duration), the screen on, and a couple of minutes idle so the SoC
   is cool. Close other apps.
3. From the repository root:

   ```bash
   bench/app/run_frame_bench.sh -d <device id> -c android-mid-adreno650-gles
   ```

   The script launches the app five times (`-n 5`) with
   `flutter drive --profile --no-dds --endless-trace-buffer` (profile mode:
   AOT code, real frame timings; the endless buffer keeps the whole trace),
   collects the summaries in `build/bench-device/runs/<scenario>/`, writes
   `build/bench-device/<scenario>.json` and gates them. The scenarios take
   about a minute and a half per launch, plus the build (incremental after
   the first launch).
4. The first run on a device class finds placeholders
   (`"placeholder": true`) instead of baselines, so it reports against them
   for information and then writes the measured medians over them, keeping
   the margins, `min_samples`, `optional` and the note; `min_frames` becomes
   90% of the measured frame count. Review the diff, then commit it in a PR
   labelled `perf-rebaseline`. From then on the script gates: exit 1 on a
   regression or an invalid run (too few samples or frames).

A phone that is not in an existing class gets a new one: pick a name like
`<platform>-<tier>-<gpu>-<renderer>` (`android-high-adreno750-vulkan`) and
pass it with `-c`; the script creates `bench/baselines/<class>/` with
measured baselines on the first run (default margins: +150% and a 10× cap;
tighten them to R12's +10–15% with absolute caps by hand, as the placeholders
do). `-b <dir>` writes new baselines elsewhere instead (CI uses it).

Options: `-n` launches, `-r` repetitions of each scenario inside one launch
(each is a sample too; `-n 1 -r 3` is the cheap emulator setting), `-s` a
comma-separated subset of scenarios, `-o` the output directory.

## Run it on an emulator

Emulator numbers come from CPU rendering (SwiftShader) unless the emulator
uses the host GPU, so they are only good for relative, catastrophic-regression
gates, never for budgets (R12 §3.4, §3.8). The
`android-emulator-api36-swiftshader` class matches the CI emulator:

```bash
sdkmanager "system-images;android-36;google_apis;x86_64"
avdmanager create avd -n bench36 -k "system-images;android-36;google_apis;x86_64" -d pixel_6
emulator -avd bench36 -gpu swiftshader_indirect -no-snapshot -noaudio -no-boot-anim &
adb wait-for-device
bench/app/run_frame_bench.sh -d emulator-5554 -c android-emulator-api36-swiftshader -n 1 -r 3
```

Leave animations on (`adb shell settings get global transition_animation_scale`
must not print 0). An emulator with `-gpu host` measures your workstation's GPU:
give it its own class.

## iOS

Profile mode needs a physical iPhone (simulators only run debug builds).
`bench/app/run_frame_bench.sh -d <udid> -c ios-a15-metal` works the same way
once the device is set up for development in Xcode; there are no iOS
placeholders yet, so the first run creates the class.

## On the host (no device)

The same file runs on the Flutter test device as a smoke test of the five
flows (debug mode, so the timings mean nothing):

```bash
cd app && flutter test -d flutter-tester integration_test/frame_bench_test.dart
```

It takes about three minutes. With
`--dart-define=SHERPA_BENCH_SUMMARY_DIR=/abs/path` it also writes the
timeline summaries there (the host has a VM service but no driver), which is
enough to try `timeline_to_result.dart` and perf_gate end to end.

## In CI

The `frame-bench` job in `.github/workflows/ci.yml` runs on pull requests
labelled `frame-bench` (re-run the job after adding the label): an API 36
x86_64 emulator from `reactivecircus/android-emulator-runner@v2` with
animations on, `-n 1 -r 3` against the emulator class. It is
`continue-on-error` and never blocks a merge. While the class holds
placeholders it uploads measured baselines (`frame-bench` artifact,
`new-baselines/`) for review instead of gating.

## What is gated

Per scenario, the medians of `average_frame_build_time_millis`, the 90th and
99th percentile frame build times and the 90th and 99th percentile raster
times; `frame_count` validates the run (`min_frames`). The worst frames,
missed-budget counts, GC counts and missed vsyncs are in each result's `info`
block, reported but not gated: perf_gate's relative bound is zero for a zero
baseline, so "0 missed frames" would become a zero-tolerance gate.

Traces record only the `Dart`, `Embedder` and `GC` timeline streams, which is
everything `TimelineSummary` reads; with all streams the VM's ring buffer
overflows within a couple of seconds and only the last frames survive.

Not run on hardware yet: the device and emulator baselines are placeholders.
