import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart' show ThermalLevel;

import '../../../design/tokens.dart';
import '../../../design/typography.dart';
import '../../models/widgets/pills.dart';
import '../state/perf_models.dart';
import '../state/perf_providers.dart';
import 'perf_format.dart';

/// A rounded surface grouping one part of the lab.
class PerfCard extends StatelessWidget {
  const PerfCard({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: t.space.lg, vertical: t.space.xs),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(t.radius.lg),
        ),
        child: Padding(padding: padding ?? EdgeInsets.all(t.space.lg), child: child),
      ),
    );
  }
}

/// "Label ............ value", read as one phrase by screen readers. Both
/// sides wrap, so it never overflows at large text sizes.
class FactRow extends StatelessWidget {
  const FactRow(this.label, this.value, {super.key, this.explanation, this.valueColor});

  final String label;
  final String value;

  /// Tooltip (long-press) and spoken after the value.
  final String? explanation;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    Widget row = Padding(
      padding: EdgeInsets.symmetric(vertical: t.space.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          SizedBox(width: t.space.sm),
          Expanded(
            flex: 3,
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                color: valueColor,
              ),
            ),
          ),
        ],
      ),
    );
    if (explanation != null) {
      row = Tooltip(message: explanation, excludeFromSemantics: true, triggerMode: TooltipTriggerMode.longPress, child: row);
    }
    return Semantics(
      container: true,
      label: [label, value, ?explanation].join(': '),
      excludeSemantics: true,
      child: row,
    );
  }
}

/// A headline number: label above, value below (a stat tile).
class MetricTile extends StatelessWidget {
  const MetricTile({super.key, required this.label, required this.value, this.spoken, this.detail});

  final String label;
  final String value;

  /// The value in words for screen readers ("21.4 tokens per second").
  final String? spoken;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: '$label: ${spoken ?? value}${detail == null ? '' : ', $detail'}',
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 128),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: t.space.xs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              Text(value, style: theme.textTheme.metricLarge),
              if (detail != null)
                Text(detail!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Thermal state as icon + words + color, never color alone.
class ThermalPill extends StatelessWidget {
  const ThermalPill(this.level, {super.key, this.prefix = 'Thermal', this.visiblePrefix});

  final ThermalLevel? level;

  /// Spoken before the level.
  final String prefix;

  /// Shown before the level ("Before: ").
  final String? visiblePrefix;

  @override
  Widget build(BuildContext context) => InfoPill(
        label: '${visiblePrefix ?? ''}${thermalLabel(level)}',
        icon: Icons.thermostat_rounded,
        semanticPrefix: prefix,
        tone: switch (level) {
          null => PillTone.neutral,
          ThermalLevel.nominal => PillTone.success,
          ThermalLevel.fair => PillTone.neutral,
          ThermalLevel.serious => PillTone.warning,
          ThermalLevel.critical => PillTone.danger,
        },
        explanation: switch (level) {
          null => 'This platform does not report thermal state.',
          ThermalLevel.nominal => 'The phone is cool: measurements show its full speed.',
          ThermalLevel.fair => 'Slightly warm. Speeds may start to drop on long runs.',
          ThermalLevel.serious => 'Hot: the system is slowing the CPU, so measurements show the throttle.',
          ThermalLevel.critical => 'Very hot: the system is throttling hard. Let the phone cool down first.',
        },
      );
}

/// A labelled dropdown that fills its width and follows [value].
class LabDropdown<T> extends StatelessWidget {
  const LabDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.width,
  });

  final String label;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T>? onChanged;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final items = [
      for (final (v, l) in options) DropdownMenuItem<T>(value: v, child: Text(l, overflow: TextOverflow.ellipsis)),
      if (!options.any((o) => o.$1 == value)) DropdownMenuItem<T>(value: value, child: Text('$value')),
    ];
    final field = DropdownButtonFormField<T>(
      key: ValueKey('$label:$value'),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: items,
      onChanged: onChanged == null
          ? null
          : (v) {
              if (v != null) onChanged!(v);
            },
    );
    return width == null ? field : SizedBox(width: width, child: field);
  }
}

/// Lays out fields two per row when there is room, one per row otherwise
/// (narrow screens, large text).
class FieldGrid extends StatelessWidget {
  const FieldGrid({super.key, required this.children});

  final List<Widget Function(double width)> children;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return LayoutBuilder(builder: (context, c) {
      final two = c.maxWidth >= 320 * scale.clamp(1.0, 3.0);
      final w = two ? (c.maxWidth - t.space.md) / 2 : c.maxWidth;
      return Wrap(
        spacing: t.space.md,
        runSpacing: t.space.md,
        children: [for (final f in children) f(w)],
      );
    });
  }
}

/// The running job of [modelId] (when its kind is in [kinds]): where it is
/// in the queue, its progress, and Cancel.
class JobBanner extends ConsumerWidget {
  const JobBanner({super.key, required this.modelId, required this.kinds});

  final String modelId;
  final Set<LabJobKind> kinds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final job = ref.watch(perfLabControllerProvider(modelId).select((s) => s.job));
    if (job == null || !kinds.contains(job.kind)) return const SizedBox.shrink();
    final what = switch (job.kind) {
      LabJobKind.bench => 'Benchmark',
      LabJobKind.compare => 'Comparison',
      LabJobKind.autotune => 'Autotune',
    };
    final status = job.cancelling
        ? 'Cancelling…'
        : switch (job.phase) {
            LabJobPhase.waiting => 'Waiting for the engine. It starts when no chat is using it.',
            LabJobPhase.running => job.detail ?? 'Running…',
            LabJobPhase.paused => 'Paused: a chat reply needed the engine. It continues once the reply is done.',
          };
    return PerfCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            liveRegion: true,
            container: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$what in progress', style: theme.textTheme.titleSmall),
                SizedBox(height: t.space.xxs),
                Text(status, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          SizedBox(height: t.space.sm),
          LinearProgressIndicator(
            value: job.phase == LabJobPhase.running ? job.progress : (job.progress ?? 0),
            semanticsLabel: '$what progress',
            semanticsValue: job.progress == null ? null : formatPercent(job.progress!),
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(
              onPressed: job.cancelling ? null : ref.read(perfLabControllerProvider(modelId).notifier).cancel,
              child: Text(job.cancelling ? 'Cancelling…' : 'Cancel'),
            ),
          ),
        ],
      ),
    );
  }
}

/// The outcome of the last action of [kind], dismissible.
class LabMessageCard extends ConsumerWidget {
  const LabMessageCard({super.key, required this.modelId, required this.kind});

  final String modelId;
  final LabJobKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final s = ref.watch(perfLabControllerProvider(modelId));
    final m = s.message;
    if (m == null || s.messageFor != kind) return const SizedBox.shrink();
    final (icon, color) = switch (m.tone) {
      LabMessageTone.info => (Icons.info_outline_rounded, theme.colorScheme.onSurfaceVariant),
      LabMessageTone.success => (Icons.check_circle_outline_rounded, t.semantic.success),
      LabMessageTone.error => (Icons.error_outline_rounded, t.semantic.danger),
    };
    return PerfCard(
      padding: EdgeInsetsDirectional.fromSTEB(t.space.lg, t.space.md, t.space.xs, t.space.md),
      child: Semantics(
        liveRegion: true,
        container: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: EdgeInsets.only(top: t.space.xxs), child: Icon(icon, color: color, size: 20)),
            SizedBox(width: t.space.md),
            Expanded(child: Text(m.text, style: theme.textTheme.bodyMedium)),
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close_rounded),
              onPressed: ref.read(perfLabControllerProvider(modelId).notifier).dismissMessage,
            ),
          ],
        ),
      ),
    );
  }
}

/// A short paragraph in secondary ink.
class LabNote extends StatelessWidget {
  const LabNote(this.text, {super.key, this.color, this.icon});

  final String text;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.onSurfaceVariant;
    final text = Text(this.text, style: theme.textTheme.bodySmall?.copyWith(color: c));
    if (icon == null) return Semantics(container: true, child: text);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: EdgeInsets.only(top: t.space.xxs), child: Icon(icon, size: 16, color: c)),
        SizedBox(width: t.space.sm),
        Expanded(child: text),
      ],
    );
  }
}
