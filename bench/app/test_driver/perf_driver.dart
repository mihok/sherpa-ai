// Driver for bench/app/integration_test/stream_perf_test.dart (copied to
// app/test_driver/_bench_perf_driver.dart by run_frame_bench.sh): writes
// build/<reportKey>.timeline_summary.json for each traced action.
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
