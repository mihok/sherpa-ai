// Driver for integration_test/frame_bench_test.dart under `flutter drive`
// (bench/app/run_frame_bench.sh): writes, for every traced action,
// build/<reportKey>.timeline_summary.json (the summary bench/app/timeline_to_result.dart
// reads) and build/<reportKey>.timeline.json (open it in Perfetto/DevTools).
import 'package:flutter_driver/flutter_driver.dart' as driver;
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
      responseDataCallback: (data) async {
        if (data == null) return;
        for (final e in data.entries) {
          final timeline = driver.Timeline.fromJson((e.value as Map).cast<String, dynamic>());
          await driver.TimelineSummary.summarize(timeline).writeTimelineToFile(e.key, pretty: true, includeSummary: true);
        }
      },
    );
