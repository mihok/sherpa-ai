import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_inference/sherpa_inference.dart';

import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets/a11y.dart';
import '../../../design/widgets/section_header.dart';
import '../../models/widgets/format.dart';
import '../../models/widgets/pills.dart';
import '../state/perf_lab.dart' show PerfLabException;
import '../state/perf_models.dart';
import '../state/perf_providers.dart';
import '../state/perf_stats.dart';
import 'perf_common.dart';
import 'perf_format.dart';

/// The A/B tester: two configs, measured in turns, compared on medians and
/// spread, with "Apply" for a clear winner.
class CompareTab extends ConsumerWidget {
  const CompareTab({super.key, required this.overview});

  final PerfOverview overview;

  /// A's starting point: the model's current settings.
  static LabConfig defaultA(PerfOverview o) => o.current.config;

  /// B's starting point: A with the other common KV cache type.
  static LabConfig defaultB(PerfOverview o) {
    final a = defaultA(o);
    final kv = a.kv == KvType.f16 ? KvType.q8_0 : KvType.f16;
    final fa = kv.isQuantized && a.flashAttention == FlashAttention.off ? FlashAttention.auto : a.flashAttention;
    return a.copyWith(kv: kv, flashAttention: fa);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final id = overview.modelId;
    final s = ref.watch(perfLabControllerProvider(id));
    final c = ref.read(perfLabControllerProvider(id).notifier);
    final a = s.a ?? defaultA(overview);
    final b = s.b ?? defaultB(overview);
    final fitA = ref.watch(perfFitProvider((id, a)));
    final fitB = ref.watch(perfFitProvider((id, b)));
    final ready = (fitA.value?.fits ?? false) && (fitB.value?.fits ?? false);
    final spec = s.abSpec;
    return ListView(
      padding: EdgeInsets.only(bottom: 32 + MediaQuery.paddingOf(context).bottom),
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(t.space.lg, t.space.md, t.space.lg, t.space.xs),
          child: const LabNote(
            'Measure two settings in turns and keep the faster one. Sherpa names a winner only when the middle half '
            'of its runs beats the middle half of the other’s; otherwise the difference is noise.',
          ),
        ),
        ConfigEditor(
          side: 'A',
          config: a,
          overview: overview,
          fit: fitA,
          onChanged: s.busy ? null : c.setA,
        ),
        ConfigEditor(
          side: 'B',
          config: b,
          overview: overview,
          fit: fitB,
          onChanged: s.busy ? null : c.setB,
        ),
        PerfCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FieldGrid(children: [
                (w) => LabDropdown<int>(
                      width: w,
                      label: 'Runs of each',
                      value: spec.reps,
                      options: const [(3, '3'), (5, '5'), (8, '8'), (10, '10')],
                      onChanged: s.busy ? null : (v) => c.setAbSpec(spec.copyWith(reps: v)),
                    ),
                (w) => LabDropdown<int>(
                      width: w,
                      label: 'Prompt tokens',
                      value: spec.promptTokens,
                      options: [for (final v in BenchSpec.promptChoices) (v, '$v')],
                      onChanged: s.busy ? null : (v) => c.setAbSpec(spec.copyWith(promptTokens: v)),
                    ),
                (w) => LabDropdown<int>(
                      width: w,
                      label: 'Generated tokens',
                      value: spec.genTokens,
                      options: [for (final v in BenchSpec.genChoices) (v, '$v')],
                      onChanged: s.busy ? null : (v) => c.setAbSpec(spec.copyWith(genTokens: v)),
                    ),
              ]),
              SizedBox(height: t.space.md),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton.icon(
                  onPressed: s.busy || !ready ? null : () => unawaited(c.runCompare(a, b)),
                  icon: const Icon(Icons.compare_arrows_rounded),
                  label: const Text('Run comparison'),
                ),
              ),
              SizedBox(height: t.space.xs),
              LabNote(a.needsGeneration || b.needsGeneration
                  ? 'Speculative decoding needs real generations, so both settings are measured by copying a list '
                      '(greedy). It runs in the background and pauses for chat replies.'
                  : 'A, B, A, B…: each run is one engine benchmark after a warm-up. It runs in the background and '
                      'pauses for chat replies.'),
            ],
          ),
        ),
        JobBanner(modelId: id, kinds: const {LabJobKind.compare}),
        LabMessageCard(modelId: id, kind: LabJobKind.compare),
        if (s.ab != null) ...[
          const SectionHeader('Result'),
          AbResultView(result: s.ab!, overview: overview),
        ],
      ],
    );
  }
}

/// One side's settings.
class ConfigEditor extends StatelessWidget {
  const ConfigEditor({
    super.key,
    required this.side,
    required this.config,
    required this.overview,
    required this.fit,
    required this.onChanged,
  });

  final String side;
  final LabConfig config;
  final PerfOverview overview;
  final AsyncValue<FitCheck> fit;
  final ValueChanged<LabConfig>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final c = config;
    final o = overview;
    final maxThreads = math.min(16, [
      o.engine.system?.logicalCores ?? 0,
      o.device?.cpu.cores ?? 0,
      c.nThreads,
      4,
    ].reduce(math.max));
    final drafts = o.drafts;
    void set(LabConfig n) => onChanged?.call(n);
    final enabled = onChanged != null;
    return PerfCard(
      child: HeadingGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Heading(level: 2, child: Text('Setting $side', style: theme.textTheme.titleSmall)),
            SizedBox(height: t.space.md),
            FieldGrid(children: [
              (w) => LabDropdown<int>(
                    width: w,
                    label: 'Threads',
                    value: c.nThreads,
                    options: [(0, 'Auto'), for (var i = 1; i <= maxThreads; i++) (i, '$i')],
                    onChanged: enabled ? (v) => set(c.copyWith(nThreads: v)) : null,
                  ),
              (w) => LabDropdown<KvType>(
                    width: w,
                    label: 'KV cache',
                    value: c.kv,
                    options: [for (final k in const [KvType.f16, KvType.q8_0, KvType.q4_0]) (k, k.label)],
                    onChanged: enabled ? (v) => set(c.copyWith(kv: v)) : null,
                  ),
              (w) => LabDropdown<int>(
                    width: w,
                    label: 'Batch',
                    value: c.nBatch,
                    options: const [(0, 'Auto'), (64, '64'), (128, '128'), (256, '256'), (512, '512'), (1024, '1024'), (2048, '2048')],
                    onChanged: enabled ? (v) => set(c.copyWith(nBatch: v)) : null,
                  ),
              (w) => LabDropdown<int>(
                    width: w,
                    label: 'Micro-batch',
                    value: c.nUbatch,
                    options: const [(0, 'Auto'), (32, '32'), (64, '64'), (128, '128'), (256, '256'), (512, '512')],
                    onChanged: enabled ? (v) => set(c.copyWith(nUbatch: v)) : null,
                  ),
              (w) => LabDropdown<FlashAttention>(
                    width: w,
                    label: 'Flash attention',
                    value: c.flashAttention,
                    options: const [(FlashAttention.auto, 'Auto'), (FlashAttention.on, 'On'), (FlashAttention.off, 'Off')],
                    onChanged: enabled ? (v) => set(c.copyWith(flashAttention: v)) : null,
                  ),
              (w) => LabDropdown<SpeculativeChoice>(
                    width: w,
                    label: 'Speculative decoding',
                    value: c.speculative,
                    options: [
                      for (final s in SpeculativeChoice.values)
                        if (s != SpeculativeChoice.draft || drafts.isNotEmpty || c.speculative == s) (s, s.label),
                    ],
                    onChanged: enabled
                        ? (v) => set(v == SpeculativeChoice.draft
                            ? c.copyWith(speculative: v, draftModelId: c.draftModelId ?? drafts.firstOrNull?.modelId)
                            : c.copyWith(speculative: v, clearDraft: true))
                        : null,
                  ),
              if (c.speculative == SpeculativeChoice.draft && drafts.isNotEmpty)
                (w) => LabDropdown<String>(
                      width: w,
                      label: 'Draft model',
                      value: c.draftModelId ?? drafts.first.modelId,
                      options: [for (final d in drafts) (d.modelId, d.label)],
                      onChanged: enabled ? (v) => set(c.copyWith(draftModelId: v)) : null,
                    ),
            ]),
            SizedBox(height: t.space.sm),
            FitLine(fit: fit),
            if (c.kv == KvType.q4_0 && o.toolCalling) ...[
              SizedBox(height: t.space.xs),
              LabNote(
                'A q4_0 KV cache can make tool calls less reliable on small models.',
                icon: Icons.warning_amber_rounded,
                color: t.semantic.warning,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// "Fits: 906 MB of 1072 MB" or why it won't fit.
class FitLine extends StatelessWidget {
  const FitLine({super.key, required this.fit});

  final AsyncValue<FitCheck> fit;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final f = fit.value;
    if (f == null) {
      final e = fit.error;
      return LabNote(e == null ? 'Checking memory…' : 'Couldn’t check memory: ${e is PerfLabException ? e.message : e}');
    }
    final problem = f.problem;
    if (problem != null) {
      return Semantics(
        liveRegion: true,
        child: LabNote(problem, icon: Icons.error_outline_rounded, color: t.semantic.danger),
      );
    }
    final e = f.estimate;
    final b = f.budget;
    return LabNote(
      e == null
          ? 'Memory not checked.'
          : 'Fits: about ${formatBytes(e.totalBytes)} at a ${f.contextTokens}-token context'
              '${b?.totalBytes == null ? '' : ', of ${formatBytes(b!.totalBytes!)} available'}.',
      icon: Icons.check_circle_outline_rounded,
      color: t.semantic.success,
    );
  }
}

/// The comparison's verdict, per-metric medians and spread, and Apply.
class AbResultView extends ConsumerWidget {
  const AbResultView({super.key, required this.result, required this.overview});

  final AbResult result;
  final PerfOverview overview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final r = result;
    final id = overview.modelId;
    final busy = ref.watch(perfLabControllerProvider(id).select((s) => s.busy));
    final c = ref.read(perfLabControllerProvider(id).notifier);
    final h = r.headline;
    final w = r.winningConfig;
    final name = r.winner == Winner.a ? 'A' : 'B';
    final colors = (theme.colorScheme.primary, theme.colorScheme.tertiary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PerfCard(
          child: Semantics(
            liveRegion: true,
            container: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      w == null ? Icons.balance_rounded : Icons.emoji_events_outlined,
                      color: w == null ? theme.colorScheme.onSurfaceVariant : t.semantic.success,
                    ),
                    SizedBox(width: t.space.md),
                    Expanded(
                      child: Text(
                        w == null ? 'No clear winner' : '$name is faster',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: t.space.xs),
                Text(
                  w != null
                      ? '${formatPercent(h.advantage)} less time per agent turn (${kLabWorkload.promptTokens} prompt + '
                          '${kLabWorkload.genTokens} generated tokens), and the middle halves of the runs don’t overlap.'
                      : h.enoughReps
                          ? 'The runs overlap: the difference is within run-to-run noise. Keep the current settings, '
                              'or run more times.'
                          : 'Run each setting at least $kMinRepsForVerdict times to call a winner.',
                  style: theme.textTheme.bodyMedium,
                ),
                SizedBox(height: t.space.xs),
                LabNote(r.method == BenchMethod.generation
                    ? 'Measured with real generations (speculative decoding needs sampling), ${r.aSamples.length} '
                        'runs each.'
                    : 'Measured with the engine benchmark (synthetic tokens from an empty cache), ${r.aSamples.length} '
                        'runs each.'),
                SizedBox(height: t.space.sm),
                _sideLine(context, 'A', r.a, colors.$1),
                _sideLine(context, 'B', r.b, colors.$2),
                SizedBox(height: t.space.md),
                Wrap(
                  spacing: t.space.sm,
                  runSpacing: t.space.sm,
                  children: [
                    FilledButton.icon(
                      onPressed: w == null || busy ? null : () => unawaited(_apply(context, ref, w)),
                      icon: const Icon(Icons.check_rounded),
                      label: Text(w == null ? 'Apply winner' : 'Apply $name'),
                    ),
                    if (overview.hasOverrides)
                      TextButton(onPressed: busy ? null : () => unawaited(c.resetToAuto()), child: const Text('Reset to auto')),
                  ],
                ),
                if (w?.speculative == SpeculativeChoice.draft) ...[
                  SizedBox(height: t.space.xs),
                  const LabNote('Applying it loads the draft model next to this one for every chat.'),
                ],
              ],
            ),
          ),
        ),
        for (final m in AbMetric.values) _MetricBlock(metric: m, comparison: r.metrics[m]!, colors: colors),
      ],
    );
  }

  Widget _sideLine(BuildContext context, String side, LabConfig c, Color color) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: t.space.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Padding(
              padding: EdgeInsets.only(top: t.space.xs),
              child: SizedBox.square(
                dimension: t.space.md,
                child: DecoratedBox(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(t.space.xxs))),
              ),
            ),
          ),
          SizedBox(width: t.space.sm),
          Expanded(child: Text('$side: ${c.summary}', style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }

  Future<void> _apply(BuildContext context, WidgetRef ref, LabConfig w) async {
    final c = ref.read(perfLabControllerProvider(overview.modelId).notifier);
    if (w.kv == KvType.q4_0 && overview.toolCalling) {
      final ok = await showDialog<bool>(
        context: context,
        animationStyle: motionStyleOf(context),
        builder: (context) => AlertDialog(
          title: const Heading(child: Text('Use a q4_0 KV cache?')),
          content: const Text('It is faster and smaller, but small models make more mistakes in tool calls with it.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Apply anyway')),
          ],
        ),
      );
      if (!(ok ?? false)) return;
    }
    await c.apply(w);
  }
}

class _MetricBlock extends StatelessWidget {
  const _MetricBlock({required this.metric, required this.comparison, required this.colors});

  final AbMetric metric;
  final MetricComparison comparison;
  final (Color, Color) colors;

  String _value(double v) => switch (metric) {
        AbMetric.turn => formatSeconds(v),
        AbMetric.decode || AbMetric.prefill => formatTps(v),
        AbMetric.ttft => formatMs(v),
      };

  String _range(Summary s) => '${_value(s.q1)}–${_value(s.q3)}';

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final cmp = comparison;
    final w = cmp.winner;
    final verdict = switch (w) {
      Winner.a => 'A better by ${formatPercent(cmp.advantage)}',
      Winner.b => 'B better by ${formatPercent(cmp.advantage)}',
      Winner.none => 'Within noise',
    };
    final lo = math.min(cmp.a.min, cmp.b.min);
    final hi = math.max(cmp.a.max, cmp.b.max);
    return PerfCard(
      child: Semantics(
        container: true,
        label: '${metric.label}: A median ${_value(cmp.a.median)}, middle half ${_range(cmp.a)}; '
            'B median ${_value(cmp.b.median)}, middle half ${_range(cmp.b)}. $verdict.',
        excludeSemantics: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: t.space.sm,
              runSpacing: t.space.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('${metric.label} (${metric.higherIsBetter ? 'higher' : 'lower'} is better)',
                    style: theme.textTheme.titleSmall),
                InfoPill(
                  label: verdict,
                  tone: w == Winner.none ? PillTone.neutral : PillTone.success,
                  icon: w == Winner.none ? Icons.drag_handle_rounded : Icons.check_rounded,
                ),
              ],
            ),
            SizedBox(height: t.space.sm),
            for (final (side, s, color) in [('A', cmp.a, colors.$1), ('B', cmp.b, colors.$2)]) ...[
              Text.rich(
                TextSpan(children: [
                  TextSpan(text: '$side  ', style: const TextStyle(fontWeight: FontWeight.w600)),
                  TextSpan(text: _value(s.median), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
                  TextSpan(
                    text: '  middle half ${_range(s)}',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ]),
                style: theme.textTheme.bodyMedium,
              ),
              SizedBox(height: t.space.xxs),
              SizedBox(
                height: 14,
                child: CustomPaint(
                  painter: _RangePainter(summary: s, lo: lo, hi: hi, color: color, track: theme.colorScheme.outlineVariant),
                ),
              ),
              SizedBox(height: t.space.sm),
            ],
          ],
        ),
      ),
    );
  }
}

/// Min–max whisker, IQR box and median tick on a scale shared by A and B.
final class _RangePainter extends CustomPainter {
  _RangePainter({required this.summary, required this.lo, required this.hi, required this.color, required this.track});

  final Summary summary;
  final double lo;
  final double hi;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final span = hi - lo;
    final pad = span == 0 ? 1.0 : span * 0.1;
    final from = lo - pad;
    final to = hi + pad;
    double x(double v) => (v - from) / (to - from) * size.width;
    final mid = size.height / 2;
    canvas.drawLine(Offset(0, mid), Offset(size.width, mid), Paint()
      ..color = track
      ..strokeWidth = 1);
    final s = summary;
    canvas.drawLine(Offset(x(s.min), mid), Offset(x(s.max), mid), Paint()
      ..color = color
      ..strokeWidth = 2);
    final box = Rect.fromLTRB(x(s.q1), 2, math.max(x(s.q3), x(s.q1) + 2), size.height - 2);
    canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(3)), Paint()..color = color.withValues(alpha: 0.35));
    canvas.drawLine(Offset(x(s.median), 0), Offset(x(s.median), size.height), Paint()
      ..color = color
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_RangePainter old) =>
      old.summary != summary || old.lo != lo || old.hi != hi || old.color != color;
}
