import 'package:material_ui/material_ui.dart';
import 'package:sherpa_hub/sherpa_hub.dart';

import '../../../design/tokens.dart';
import '../state/model_fit.dart';
import 'format.dart';

/// "Weights 4.6 GB + KV cache 288 MB (4K context, q8_0) + buffers 60 MB +
/// runtime 64 MB ≈ 5.0 GB of ~6.1 GB available (estimated from total RAM)."
///
/// Every component the fit engine adds up, so a verdict is never a bare
/// "Won't fit" (R12 §2: show why, never fail silently).
///
/// [runtime] names what differs for MLX (8-bit KV, no separate buffers) and
/// LiteRT-LM (the CPU weight cache; KV not known before the engine reads
/// the file).
String fitBreakdown(FitResult f, {FitOptions options = const FitOptions(), SherpaRuntime runtime = SherpaRuntime.llamaCpp}) {
  final b = f.breakdown;
  final llama = runtime == SherpaRuntime.llamaCpp;
  final kvKnown = b.kvBytes > 0 || f.kv.bytesPerFullCell > 0 || llama;
  final kvType = runtime == SherpaRuntime.mlx ? '8-bit' : options.typeK.name;
  final parts = <String>[
    'Weights ${formatBytes(b.weightsBytes)}',
    if (b.mmprojBytes > 0) 'vision projector ${formatBytes(b.mmprojBytes)}',
    if (b.draftBytes > 0) 'draft ${formatBytes(b.draftBytes)}',
    if (kvKnown)
      'KV cache ${formatBytes(b.kvBytes)} (${formatContext(f.contextLength)} context, $kvType)'
    else
      'KV cache (not known yet)',
    if (llama || b.computeBytes > 0) 'buffers ${formatBytes(b.computeBytes)}',
    'runtime ${formatBytes(b.runtimeOverheadBytes)}',
    if (b.repackBytes > 0) '${runtime == SherpaRuntime.litert ? 'CPU weight cache' : 'repacking'} ${formatBytes(b.repackBytes)}',
    if (b.appOverheadBytes > 0) 'app ${formatBytes(b.appOverheadBytes)}',
  ];
  final avail = '~${formatBytes(f.budgetBytes)} available${f.budgetEstimated ? ' (estimated from total RAM)' : ''}';
  return '${parts.join(' + ')} ≈ ${formatBytes(f.demandBytes)} of $avail.';
}

/// Tooltip for the recommended-context figure.
String contextExplanation(FitResult f, {int? trained}) {
  final max = f.recommendedMaxContext;
  if (max == null) return 'Not even a short conversation fits in memory on this device.';
  final t = trained == null ? '' : ' The model was trained for ${formatContext(trained)} tokens.';
  return 'The longest conversation (prompt + reply, in tokens) that still fits with headroom on this device; '
      'longer chats get summarized.$t';
}

/// Asks before a Tight or unchecked download. Returns true to go ahead.
Future<bool> confirmRiskyDownload(BuildContext context, VariantRow row) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _RiskSheet(row: row),
  );
  return ok ?? false;
}

class _RiskSheet extends StatelessWidget {
  const _RiskSheet({required this.row});

  final VariantRow row;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final fit = row.fit;
    final unknown = row.kind == FitBadgeKind.unknown;
    final title = unknown ? "Fit couldn't be checked" : 'Memory will be tight';
    final body = unknown
        ? "Sherpa couldn't read this model's header, so it doesn't know how much memory ${row.label} needs. "
            'The download is ${formatBytes(row.downloadBytes)}.'
        : '${row.reason} The model may be stopped if the phone runs low, and other apps may be closed while it runs.';
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(t.space.xl, 0, t.space.xl, t.space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(unknown ? Icons.help_outline_rounded : Icons.error_outline_rounded, color: t.semantic.warning, size: 32),
            SizedBox(height: t.space.md),
            Semantics(headingLevel: 2, child: Text(title, style: theme.textTheme.titleLarge)),
            SizedBox(height: t.space.sm),
            Text(body, style: theme.textTheme.bodyMedium),
            if (fit != null) ...[
              SizedBox(height: t.space.md),
              Text(
                fitBreakdown(fit, runtime: row.variant.runtime),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            SizedBox(height: t.space.xl),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
                SizedBox(width: t.space.sm),
                FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Download anyway')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
