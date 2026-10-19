import 'dart:math' as math;

import 'package:flutter/semantics.dart' show SemanticsProperties;
import 'package:material_ui/material_ui.dart';

import '../../../design/tokens.dart';
import '../../../design/typography.dart';
import '../../models/widgets/format.dart';
import '../state/perf_models.dart';
import 'perf_common.dart';
import 'perf_format.dart';

/// What the history chart plots. One measure per chart: prefill runs ~10×
/// faster than decode, so the two never share an axis.
enum HistoryMetric {
  decode('Decode', 'tok/s'),
  prefill('Prefill', 'tok/s'),
  ttft('First token', 'ms'),
  memory('Peak memory', 'MB');

  const HistoryMetric(this.label, this.unit);

  final String label;
  final String unit;

  double? of(BenchRun r) => switch (this) {
        decode => r.sample.decodeTps > 0 ? r.sample.decodeTps : null,
        prefill => r.sample.prefillTps > 0 ? r.sample.prefillTps : null,
        ttft => r.sample.ttftMs > 0 ? r.sample.ttftMs : null,
        memory => r.sample.peakMemoryBytes == null ? null : r.sample.peakMemoryBytes! / (1024 * 1024),
      };

  String format(double? v) => switch (this) {
        decode || prefill => formatTps(v),
        ttft => formatMs(v),
        memory => v == null ? '—' : formatBytes((v * 1024 * 1024).round()),
      };

  String spoken(double? v) => switch (this) {
        decode || prefill => spokenTps(v),
        ttft => v == null ? 'not measured' : '${v.round()} milliseconds',
        memory => v == null ? 'not measured' : '${v.round()} megabytes',
      };
}

/// The last runs as a bar chart (one metric at a time) or as a table.
///
/// The chart is a single series, so its title names it and there is no
/// legend; bars are thin, rounded at the data end and anchored to the
/// baseline; the grid is one recessive line at the axis maximum. Each bar
/// is its own semantics node ("Run 3 of 7, Oct 19, 09:12: 21.4 tokens per
/// second") and can be tapped to show its run. At large text sizes the
/// table is the default view.
class BenchHistoryView extends StatefulWidget {
  const BenchHistoryView({super.key, required this.runs});

  /// Oldest first.
  final List<BenchRun> runs;

  @override
  State<BenchHistoryView> createState() => _BenchHistoryViewState();
}

class _BenchHistoryViewState extends State<BenchHistoryView> {
  HistoryMetric _metric = HistoryMetric.decode;
  bool? _table;
  int? _selected;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final runs = widget.runs;
    if (runs.isEmpty) {
      return const PerfCard(child: LabNote('No runs yet. Run a benchmark and its numbers show here, up to the last 10.'));
    }
    final table = _table ?? MediaQuery.textScalerOf(context).scale(1) > 1.5;
    final available = [for (final m in HistoryMetric.values) if (runs.any((r) => m.of(r) != null)) m];
    final metric = available.contains(_metric) ? _metric : available.first;
    final selected = (_selected ?? runs.length - 1).clamp(0, runs.length - 1);
    return PerfCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: t.space.sm,
            runSpacing: t.space.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (!table)
                for (final m in available)
                  ChoiceChip(
                    label: Text(m.label),
                    selected: m == metric,
                    onSelected: (_) => setState(() => _metric = m),
                  ),
              TextButton.icon(
                onPressed: () => setState(() => _table = !table),
                icon: Icon(table ? Icons.bar_chart_rounded : Icons.table_rows_outlined),
                label: Text(table ? 'Show chart' : 'Show table'),
              ),
            ],
          ),
          SizedBox(height: t.space.sm),
          if (table)
            HistoryTable(runs: runs)
          else
            HistoryChart(
              runs: runs,
              metric: metric,
              selected: selected,
              onSelect: (i) => setState(() => _selected = i),
            ),
        ],
      ),
    );
  }
}

class HistoryChart extends StatelessWidget {
  const HistoryChart({super.key, required this.runs, required this.metric, required this.selected, required this.onSelect});

  final List<BenchRun> runs;
  final HistoryMetric metric;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final values = [for (final r in runs) metric.of(r)];
    final known = values.whereType<double>().toList();
    final top = _niceCeil(known.isEmpty ? 1 : known.reduce(math.max));
    final latest = known.isEmpty ? null : values.lastWhere((v) => v != null);
    final low = known.isEmpty ? null : known.reduce(math.min);
    final high = known.isEmpty ? null : known.reduce(math.max);
    final r = runs[selected];
    final axis = theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    String barLabel(int i) =>
        'Run ${i + 1} of ${runs.length}, ${formatDateTime(runs[i].at)}: ${metric.spoken(values[i])}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          container: true,
          label: '${metric.label} over the last ${runs.length} runs, oldest first: lowest ${metric.spoken(low)}, '
              'highest ${metric.spoken(high)}, latest ${metric.spoken(latest)}.',
          child: Text('${metric.label} (${metric.unit}), oldest to newest', style: theme.textTheme.labelLarge),
        ),
        SizedBox(height: t.space.sm),
        SizedBox(
          height: 140,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [Text(_axisLabel(top), style: axis), Text('0', style: axis)],
                ),
              ),
              SizedBox(width: t.space.sm),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, c) => GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (d) => onSelect((d.localPosition.dx / c.maxWidth * runs.length).floor().clamp(0, runs.length - 1)),
                    child: CustomPaint(
                      size: Size(c.maxWidth, c.maxHeight),
                      painter: _BarsPainter(
                        values: values,
                        top: top,
                        selected: selected,
                        bar: scheme.primary,
                        muted: scheme.primary.withValues(alpha: 0.45),
                        grid: scheme.outlineVariant,
                        labels: [for (var i = 0; i < runs.length; i++) barLabel(i)],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: t.space.sm),
        Semantics(
          liveRegion: true,
          child: Text(
            'Run ${selected + 1}: ${formatDateTime(r.at)} · ${metric.format(values[selected])} · ${r.config.summary}',
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  String _axisLabel(double v) => switch (metric) {
        HistoryMetric.memory => formatBytes((v * 1024 * 1024).round()),
        _ => v >= 100 ? '${v.round()}' : v.toStringAsFixed(v >= 10 ? 0 : 1),
      };

  /// 1, 2, 2.5, 5 × 10^n at or above [v].
  static double _niceCeil(double v) {
    if (v <= 0) return 1;
    final p = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
    for (final m in const [1.0, 2.0, 2.5, 5.0, 10.0]) {
      if (v <= m * p) return m * p;
    }
    return 10 * p;
  }
}

final class _BarsPainter extends CustomPainter {
  _BarsPainter({
    required this.values,
    required this.top,
    required this.selected,
    required this.bar,
    required this.muted,
    required this.grid,
    required this.labels,
  });

  final List<double?> values;
  final double top;
  final int selected;
  final Color bar;
  final Color muted;
  final Color grid;
  final List<String> labels;

  Rect _slot(Size size, int i) {
    final w = size.width / values.length;
    return Rect.fromLTWH(i * w, 0, w, size.height);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = grid
      ..strokeWidth = 1;
    canvas
      ..drawLine(Offset(0, 0.5), Offset(size.width, 0.5), line)
      ..drawLine(Offset(0, size.height - 0.5), Offset(size.width, size.height - 0.5), line);
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v == null) continue;
      final slot = _slot(size, i);
      // Thin bars with at least a 2 px gap between neighbours.
      final w = math.min(28.0, math.max(2.0, slot.width - 2 - slot.width * 0.35));
      final h = (v / top).clamp(0.0, 1.0) * (size.height - 1);
      final rect = Rect.fromLTWH(slot.center.dx - w / 2, size.height - 1 - h, w, h);
      final r = Radius.circular(math.min(4, w / 2));
      canvas.drawRRect(
        RRect.fromRectAndCorners(rect, topLeft: r, topRight: r),
        Paint()..color = i == selected ? bar : muted,
      );
    }
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder => (size) => [
        for (var i = 0; i < values.length; i++)
          CustomPainterSemantics(
            key: ValueKey('bar$i'),
            rect: _slot(size, i),
            // Read-only: bars are narrower than a touch target; the whole
            // chart takes taps, and the table view lists every run.
            properties: SemanticsProperties(
              label: labels[i],
              selected: i == selected,
              textDirection: TextDirection.ltr,
            ),
          ),
      ];

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.values != values || old.selected != selected || old.top != top || old.bar != bar;

  @override
  bool shouldRebuildSemantics(_BarsPainter old) => old.labels.join() != labels.join() || old.selected != selected;
}

/// The history as rows (newest first), each read as one sentence: the
/// chart's accessible equivalent, and the default at large text sizes.
class HistoryTable extends StatelessWidget {
  const HistoryTable({super.key, required this.runs});

  final List<BenchRun> runs;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final rows = runs.reversed.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, r) in rows.indexed) ...[
          if (i > 0) const Divider(height: 1),
          Semantics(
            container: true,
            label: 'Run on ${formatDateTime(r.at)}, ${r.config.summary}. Prefill ${spokenTps(r.sample.prefillTps)}, '
                'decode ${spokenTps(r.sample.decodeTps)}, first token ${formatMs(r.sample.ttftMs)}, '
                'peak memory ${HistoryMetric.memory.format(HistoryMetric.memory.of(r))}, '
                'thermal ${spokenThermalChange(r.sample.thermalBefore, r.sample.thermalAfter)}.',
            excludeSemantics: true,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: t.space.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(formatDateTime(r.at), style: theme.textTheme.labelLarge),
                  Text(r.config.summary,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  SizedBox(height: t.space.xxs),
                  Wrap(
                    spacing: t.space.md,
                    runSpacing: t.space.xxs,
                    children: [
                      _cell(context, 'Prefill', formatTps(r.sample.prefillTps)),
                      _cell(context, 'Decode', formatTps(r.sample.decodeTps)),
                      _cell(context, 'First token', formatMs(r.sample.ttftMs)),
                      _cell(context, 'Peak', HistoryMetric.memory.format(HistoryMetric.memory.of(r))),
                      _cell(context, 'Thermal', thermalChange(r.sample.thermalBefore, r.sample.thermalAfter)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _cell(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: '$label ', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
        TextSpan(text: value, style: theme.textTheme.metric),
      ]),
      style: theme.textTheme.bodySmall,
    );
  }
}
