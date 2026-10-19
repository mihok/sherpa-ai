import 'package:material_ui/material_ui.dart';
import 'package:sherpa_hub/sherpa_hub.dart';

import '../../../design/semantic_palette.dart';
import '../../../design/tokens.dart';
import '../../../design/typography.dart';
import '../state/model_fit.dart';

enum PillTone { neutral, accent, success, warning, danger }

/// A small labelled pill whose meaning is always one long-press away.
///
/// Every decoded name token, badge and status in the model screens is one
/// of these, so every number and abbreviation on screen carries its
/// explanation (tooltip on long-press / hover, and in the spoken label).
/// Text + icon + color, never color alone; text scaling is clamped like
/// the other chips (research/12 §1.7).
class InfoPill extends StatelessWidget {
  const InfoPill({
    super.key,
    required this.label,
    this.explanation,
    this.icon,
    this.tone = PillTone.neutral,
    this.semanticPrefix,
    this.dense = false,
  });

  final String label;

  /// Tooltip and spoken explanation.
  final String? explanation;
  final IconData? icon;
  final PillTone tone;

  /// Spoken before the label ("Quantization: Q4_K_M").
  final String? semanticPrefix;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (Color fg, Color? bg, Color? border) = switch (tone) {
      PillTone.neutral => (scheme.onSurfaceVariant, null, scheme.outlineVariant),
      PillTone.accent => (scheme.onSecondaryContainer, scheme.secondaryContainer, null),
      PillTone.success => (t.semantic.success, t.semantic.success.withValues(alpha: kSemanticTintAlpha), null),
      PillTone.warning => (t.semantic.warning, t.semantic.warning.withValues(alpha: kSemanticTintAlpha), null),
      PillTone.danger => (t.semantic.danger, t.semantic.danger.withValues(alpha: kSemanticTintAlpha), null),
    };
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: fg,
          fontWeight: tone == PillTone.neutral ? FontWeight.w500 : FontWeight.w600,
        );
    final spoken = [
      if (semanticPrefix != null) '$semanticPrefix: $label' else label,
      ?explanation,
    ].join('. ');
    Widget pill = DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        border: border == null ? null : Border.all(color: border),
        borderRadius: BorderRadius.circular(t.radius.pill),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: dense ? t.space.xs + 2 : t.space.sm, vertical: t.space.xxs + 1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[Icon(icon, size: 14, color: fg), SizedBox(width: t.space.xs)],
            Flexible(child: Text(label, style: style, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
    );
    if (explanation != null) {
      pill = Tooltip(
        message: explanation,
        excludeFromSemantics: true,
        triggerMode: TooltipTriggerMode.longPress,
        child: pill,
      );
    }
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.5,
      child: Semantics(label: spoken, excludeSemantics: true, child: pill),
    );
  }
}

/// The decoded name, token by token: family + version, size (and active
/// parameters for MoE), variants, quant, format. Every chip explains
/// itself with the parser's own tooltip text ([Decoded.explanation]).
class ModelNameChips extends StatelessWidget {
  const ModelNameChips({super.key, required this.name, this.showFormat = true, this.showQuant = true, this.max});

  final ParsedModelName name;
  final bool showFormat;
  final bool showQuant;

  /// Cap for dense cards; the rest is summarized as "+N".
  final int? max;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final chips = modelNameChipData(name, showFormat: showFormat, showQuant: showQuant);
    final shown = max == null || chips.length <= max! ? chips : chips.take(max!).toList();
    return Wrap(
      spacing: t.space.xs,
      runSpacing: t.space.xs,
      children: [
        for (final c in shown)
          InfoPill(label: c.label, explanation: c.explanation, semanticPrefix: c.kind, tone: c.tone, icon: c.icon),
        if (shown.length < chips.length)
          InfoPill(
            label: '+${chips.length - shown.length}',
            explanation: chips.skip(shown.length).map((c) => '${c.kind}: ${c.label}').join('\n'),
            semanticPrefix: 'More',
          ),
      ],
    );
  }
}

typedef NameChip = ({String kind, String label, String explanation, PillTone tone, IconData? icon});

/// Chip data for a parsed name (exposed for tests and for the card's
/// spoken summary).
List<NameChip> modelNameChipData(ParsedModelName n, {bool showFormat = true, bool showQuant = true}) {
  final out = <NameChip>[];
  final family = n.family;
  if (family != null) {
    final v = n.version;
    out.add((
      kind: 'Family',
      label: v == null ? family.value : '${family.value} ${v.value}',
      explanation: [family.explanation, ?v?.explanation].join(' '),
      tone: PillTone.accent,
      icon: null,
    ));
  }
  final size = n.size;
  if (size != null) {
    final a = n.activeParams;
    out.add((
      kind: a == null ? 'Size' : 'Size and active parameters',
      label: a == null ? size.value.label : '${size.value.label} · ${a.value.label} active',
      explanation: [size.explanation, ?a?.explanation].join(' '),
      tone: PillTone.neutral,
      icon: null,
    ));
  } else if (n.tier != null) {
    out.add((kind: 'Size tier', label: n.tier!.value, explanation: n.tier!.explanation, tone: PillTone.neutral, icon: null));
  }
  for (final v in n.variants) {
    out.add((
      kind: 'Variant',
      label: v.raw,
      explanation: v.explanation,
      tone: v.value.isUncensored ? PillTone.warning : PillTone.neutral,
      icon: null,
    ));
  }
  final q = n.quant;
  if (showQuant && q != null) {
    out.add((kind: 'Quantization', label: q.value.label, explanation: q.explanation, tone: PillTone.neutral, icon: null));
  }
  final ctx = n.contextHint;
  if (ctx != null) {
    out.add((kind: 'Context', label: ctx.raw, explanation: ctx.explanation, tone: PillTone.neutral, icon: null));
  }
  if (showFormat && n.format != ModelFormat.other) {
    out.add((
      kind: 'Format',
      label: _formatLabel(n.format),
      explanation: n.format.explanation,
      tone: PillTone.neutral,
      icon: null,
    ));
  }
  return out;
}

String _formatLabel(ModelFormat f) => switch (f) {
      ModelFormat.gguf || ModelFormat.ggufPart => 'GGUF',
      ModelFormat.mlx || ModelFormat.mlxNpz => 'MLX',
      ModelFormat.litert => 'LiteRT',
      ModelFormat.safetensors => 'safetensors',
      ModelFormat.gptq => 'GPTQ',
      ModelFormat.awq => 'AWQ',
      ModelFormat.exl2 => 'EXL2',
      ModelFormat.exl3 => 'EXL3',
      ModelFormat.onnx || ModelFormat.onnxData => 'ONNX',
      ModelFormat.ggml => 'GGML',
      ModelFormat.pickle => 'pickle',
      ModelFormat.other => 'other',
    };

/// Fits / Tight / Won't fit / unknown / blocked.
class FitBadge extends StatelessWidget {
  const FitBadge({super.key, required this.kind, this.explanation, this.estimated = false});

  final FitBadgeKind kind;
  final String? explanation;

  /// Card estimates say so ("Likely fits").
  final bool estimated;

  @override
  Widget build(BuildContext context) {
    final (label, icon, tone) = switch (kind) {
      FitBadgeKind.fits => (estimated ? 'Likely fits' : 'Fits', Icons.check_circle_rounded, PillTone.success),
      FitBadgeKind.tight => (estimated ? 'Might be tight' : 'Tight', Icons.error_outline_rounded, PillTone.warning),
      FitBadgeKind.wontFit => (estimated ? 'Likely too big' : "Won't fit", Icons.block_rounded, PillTone.danger),
      FitBadgeKind.unknown => ('Fit unknown', Icons.help_outline_rounded, PillTone.neutral),
      FitBadgeKind.blocked => ('Unavailable', Icons.gpp_bad_outlined, PillTone.danger),
    };
    return InfoPill(label: label, icon: icon, tone: tone, explanation: explanation, semanticPrefix: 'Device fit');
  }
}

/// A labelled number with its meaning on long-press ("↓ 1.2M").
class Metric extends StatelessWidget {
  const Metric({super.key, required this.icon, required this.value, required this.explanation, this.spoken});

  final IconData icon;
  final String value;
  final String explanation;

  /// Spoken form when it differs from the visual ("1.2 million downloads").
  final String? spoken;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Semantics(
      label: spoken ?? '$value. $explanation',
      excludeSemantics: true,
      child: Tooltip(
        message: explanation,
        excludeFromSemantics: true,
        triggerMode: TooltipTriggerMode.longPress,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            SizedBox(width: t.space.xxs + 1),
            Text(value, style: theme.textTheme.metricSmall.copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}
