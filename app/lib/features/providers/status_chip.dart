import 'package:material_ui/material_ui.dart';

import '../../design/semantic_palette.dart';
import '../../design/tokens.dart';
import '../../state/services.dart';

/// Health of a provider from its last probe, as a small labelled chip.
class EndpointStatusChip extends StatelessWidget {
  const EndpointStatusChip({super.key, required this.status, this.checking = false});

  final EndpointStatus status;
  final bool checking;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (label, icon, color) = checking
        ? ('Checking…', Icons.sync, scheme.onSurfaceVariant)
        : switch (status) {
            EndpointStatus.ok => ('Connected', Icons.check_circle_rounded, t.semantic.success),
            EndpointStatus.unauthorized => ('Key rejected', Icons.vpn_key_off_outlined, t.semantic.danger),
            EndpointStatus.unreachable => ('Unreachable', Icons.cloud_off_outlined, t.semantic.warning),
            EndpointStatus.error => ('Error', Icons.error_outline_rounded, t.semantic.danger),
            EndpointStatus.unknown => ('Not checked', Icons.help_outline, scheme.onSurfaceVariant),
          };
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.5,
      child: Semantics(
        label: 'Status: $label',
        excludeSemantics: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color.withValues(alpha: kSemanticTintAlpha),
            borderRadius: BorderRadius.circular(t.radius.pill),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: t.space.sm, vertical: t.space.xxs + 1),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: color),
                SizedBox(width: t.space.xs),
                Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
