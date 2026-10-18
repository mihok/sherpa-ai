import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets/privacy_badge.dart';
import '../state/model_selection.dart';
import 'chat_style.dart';

/// Icon and color of the design system's privacy badge, for places too
/// tight for the full badge (the narrow model chip).
(IconData, Color) privacyGlyph(BuildContext context, PrivacyBadgeData p) {
  final s = SherpaTokens.of(context).semantic;
  return switch (p.location) {
    ExecutionLocation.onDevice => (Icons.smartphone_outlined, s.onDevice),
    ExecutionLocation.localNetwork => (Icons.lan_outlined, s.leavesDevice),
    ExecutionLocation.remote => (Icons.arrow_outward, s.leavesDevice),
  };
}

/// The chat's model with its privacy badge; tap to switch models.
///
/// Compact widths show the badge's icon only (the full sentence is in the
/// semantics label, tooltip and picker); wide layouts add the design
/// system's compact [PrivacyBadge] ("↗ host").
class ModelChip extends StatelessWidget {
  const ModelChip({super.key, required this.selection, required this.onTap, this.maxWidth});

  final ModelSelection? selection;
  final VoidCallback onTap;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final s = selection;
    final wide = MediaQuery.sizeOf(context).width >= 600;
    final name = s?.modelName ?? 'Choose model';
    final semantics = s == null ? 'Choose a model' : 'Model: ${s.modelName}. ${s.privacy.description}';
    return Semantics(
      button: true,
      label: semantics,
      hint: 'Change model',
      excludeSemantics: true,
      child: Tooltip(
        message: s == null ? 'Choose a model' : '${s.providerName} · ${s.privacy.description}',
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: tokens.space.minTouchTarget,
            maxWidth: maxWidth ?? double.infinity,
          ),
          child: MediaQuery.withClampedTextScaling(
            maxScaleFactor: kChromeMaxTextScale,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: onTap,
                customBorder: const StadiumBorder(),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: tokens.space.sm, vertical: tokens.space.sm),
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      shape: StadiumBorder(side: BorderSide(color: theme.colorScheme.outlineVariant)),
                      color: theme.colorScheme.surfaceContainerLow,
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: tokens.space.md, vertical: tokens.space.xs),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (s != null && !wide) ...[
                            Icon(
                              privacyGlyph(context, s.privacy).$1,
                              size: ChatIconSize.small,
                              color: privacyGlyph(context, s.privacy).$2,
                            ),
                            SizedBox(width: tokens.space.xs),
                          ],
                          Flexible(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelLarge,
                            ),
                          ),
                          if (s != null && wide) ...[
                            SizedBox(width: tokens.space.sm),
                            Flexible(
                              child: PrivacyBadge(
                                location: s.location,
                                host: s.host,
                                size: PrivacyBadgeSize.compact,
                              ),
                            ),
                          ],
                          Icon(Icons.expand_more_rounded, size: ChatIconSize.medium, color: theme.colorScheme.onSurfaceVariant),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
