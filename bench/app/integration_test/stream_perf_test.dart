// Frame-timing scenario for a device or emulator (docs/research/12 §3.7).
//
// bench/app/run_frame_bench.sh copies this file to
// app/integration_test/_bench_stream_perf_test.dart for the run and deletes
// it afterwards; it is not built in place (bench/analysis_options.yaml).
// The reply streams in ~4-character tokens at 60 Hz into the same
// StreamingMarkdown widget the chat bubble uses, inside traceAction, so the
// driver can summarize build/raster times, missed frames and GCs.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_markdown/sherpa_markdown.dart';

const String reportKey = 'stream_4k_tokens_markdown';

String _reply() {
  final b = StringBuffer();
  for (var i = 0; i < 12; i++) {
    b
      ..writeln('## Section $i')
      ..writeln()
      ..writeln('The **context ladder** prunes stale tool output, then compacts at a legal cut point '
          '(`keepRecentUserTurns = 3`). See [the notes](https://example.org/$i); inline math \$r = n / W\$.')
      ..writeln()
      ..writeln('- elide old results\n- clear large inputs\n  - keep pairing\n1. compact\n2. hand off')
      ..writeln()
      ..writeln('```dart\nfinal prepared = await manager.prepare(request);\nprint(prepared.budget.ratio);\n```')
      ..writeln()
      ..writeln('| stage | trigger |\n|---|---:|\n| prune | 0.60 |\n| compact | 0.80 |')
      ..writeln();
  }
  return b.toString();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(reportKey, (tester) async {
    final text = ValueNotifier<String>('');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ValueListenableBuilder<String>(
            valueListenable: text,
            builder: (context, t, _) => StreamingMarkdown(text: t, streaming: true),
          ),
        ),
      ),
    ));
    final reply = _reply();
    await binding.traceAction(() async {
      for (var i = 0; i < reply.length; i += 4) {
        text.value = reply.substring(0, min(reply.length, i + 4));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
    }, reportKey: reportKey);
  });
}
