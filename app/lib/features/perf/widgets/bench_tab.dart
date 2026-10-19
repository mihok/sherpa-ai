import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets/a11y.dart';
import '../../../design/widgets/section_header.dart';
import '../../models/widgets/format.dart';
import '../state/perf_models.dart';
import '../state/perf_providers.dart';
import 'bench_history.dart';
import 'perf_common.dart';
import 'perf_format.dart';

/// Benchmark the model with its current settings; the latest result and
/// the last 10 runs.
class BenchTab extends ConsumerWidget {
  const BenchTab({super.key, required this.overview});

  final PerfOverview overview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final id = overview.modelId;
    final s = ref.watch(perfLabControllerProvider(id));
    final c = ref.read(perfLabControllerProvider(id).notifier);
    final spec = s.benchSpec;
    final latest = s.lastRun ?? (s.history.isEmpty ? null : s.history.last);
    final config = overview.current.config;
    return ListView(
      padding: EdgeInsets.only(bottom: 32 + MediaQuery.paddingOf(context).bottom),
      children: [
        SizedBox(height: t.space.sm),
        PerfCard(
          child: HeadingGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Heading(
                  level: 2,
                  child: Text('Benchmark the current settings', style: Theme.of(context).textTheme.titleSmall),
                ),
                SizedBox(height: t.space.xxs),
                LabNote(config.summary),
                SizedBox(height: t.space.md),
                FieldGrid(children: [
                  (w) => LabDropdown<int>(
                        width: w,
                        label: 'Prompt tokens',
                        value: spec.promptTokens,
                        options: [for (final v in BenchSpec.promptChoices) (v, '$v')],
                        onChanged: s.busy ? null : (v) => c.setBenchSpec(spec.copyWith(promptTokens: v)),
                      ),
                  (w) => LabDropdown<int>(
                        width: w,
                        label: 'Generated tokens',
                        value: spec.genTokens,
                        options: [for (final v in BenchSpec.genChoices) (v, '$v')],
                        onChanged: s.busy ? null : (v) => c.setBenchSpec(spec.copyWith(genTokens: v)),
                      ),
                  (w) => LabDropdown<int>(
                        width: w,
                        label: 'Runs',
                        value: spec.reps,
                        options: [for (final v in BenchSpec.repChoices) (v, '$v')],
                        onChanged: s.busy ? null : (v) => c.setBenchSpec(spec.copyWith(reps: v)),
                      ),
                ]),
                SizedBox(height: t.space.md),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilledButton.icon(
                    onPressed: s.busy ? null : () => unawaited(c.runBench()),
                    icon: const Icon(Icons.speed_rounded),
                    label: const Text('Run benchmark'),
                  ),
                ),
                SizedBox(height: t.space.xs),
                LabNote(config.needsGeneration
                    ? 'Speculative decoding is on, so this runs real generations (copying a list), one warm-up '
                        'excluded. It runs in the background and pauses for chat replies.'
                    : 'One warm-up run, then the measured runs, averaged. It runs in the background and pauses for '
                        'chat replies.'),
              ],
            ),
          ),
        ),
        JobBanner(modelId: id, kinds: const {LabJobKind.bench}),
        LabMessageCard(modelId: id, kind: LabJobKind.bench),
        if (latest != null) ...[
          const SectionHeader('Latest result'),
          BenchResultCard(run: latest),
        ],
        SectionHeader(
          'History',
          trailing: s.history.isEmpty
              ? null
              : TextButton(onPressed: s.busy ? null : () => unawaited(c.clearHistory()), child: const Text('Clear')),
        ),
        BenchHistoryView(runs: s.history),
      ],
    );
  }
}

/// One run's numbers.
class BenchResultCard extends StatelessWidget {
  const BenchResultCard({super.key, required this.run});

  final BenchRun run;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final s = run.sample;
    final peak = s.peakMemoryBytes;
    final base = s.baselineMemoryBytes;
    return PerfCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LabNote('${formatDateTime(run.at)} · ${run.spec.promptTokens} prompt / ${run.spec.genTokens} generated tokens'
              ' · ${run.spec.reps} run${run.spec.reps == 1 ? '' : 's'}'
              '${run.method == BenchMethod.generation ? ' · real generation' : ''}'),
          SizedBox(height: t.space.sm),
          Wrap(
            spacing: t.space.lg,
            runSpacing: t.space.xs,
            children: [
              MetricTile(label: 'Prefill', value: formatTps(s.prefillTps), spoken: spokenTps(s.prefillTps)),
              MetricTile(label: 'Decode', value: formatTps(s.decodeTps), spoken: spokenTps(s.decodeTps)),
              MetricTile(
                label: 'First token',
                value: formatMs(s.ttftMs),
                detail: run.method == BenchMethod.bench ? 'prompt + one step' : null,
              ),
              MetricTile(
                label: 'Peak memory',
                value: peak == null ? '—' : formatBytes(peak),
                detail: peak == null
                    ? 'not visible for this engine'
                    : base != null && peak > base
                        ? '+${formatBytes(peak - base)} during the run'
                        : null,
              ),
              if (s.draftAcceptRate != null) MetricTile(label: 'Draft accepted', value: formatPercent(s.draftAcceptRate!)),
            ],
          ),
          SizedBox(height: t.space.sm),
          Wrap(
            spacing: t.space.xs,
            runSpacing: t.space.xs,
            children: [
              if (s.thermalAfter == s.thermalBefore)
                ThermalPill(s.thermalBefore, prefix: 'Thermal before and after', visiblePrefix: 'Before and after: ')
              else ...[
                ThermalPill(s.thermalBefore, prefix: 'Thermal before', visiblePrefix: 'Before: '),
                ThermalPill(s.thermalAfter, prefix: 'Thermal after', visiblePrefix: 'After: '),
              ],
            ],
          ),
          SizedBox(height: t.space.xs),
          LabNote(run.config.summary),
        ],
      ),
    );
  }
}
