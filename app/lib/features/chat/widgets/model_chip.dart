import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../../design/tokens.dart';
import '../state/model_selection.dart';
import 'chat_style.dart';

/// "On device" / "→ api.anthropic.com" with the matching icon and color.
/// Used by the model chip and every row of the model picker, so the user
/// learns one visual for "this leaves my phone".
class PrivacyBadge extends StatelessWidget {
  const PrivacyBadge({super.key, required this.privacy, this.showLabel = true});

  final PrivacyBadgeData privacy;
  final bool showLabel;

  static IconData iconFor(ExecutionLocation location) => switch (location) {
        ExecutionLocation.onDevice => Icons.smartphone_rounded,
        ExecutionLocation.localNetwork => Icons.router_outlined,
        ExecutionLocation.remote => Icons.cloud_upload_outlined,
      };

  static Color colorFor(BuildContext context, PrivacyBadgeData p) {
    final s = SherpaTokens.of(context).semantic;
    return p.leavesDevice ? s.leavesDevice : s.onDevice;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final color = colorFor(context, privacy);
    final icon = Icon(iconFor(privacy.location), size: ChatIconSize.small, color: color);
    return Semantics(
      label: privacy.description,
      excludeSemantics: true,
      child: !showLabel
          ? icon
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                icon,
                SizedBox(width: tokens.space.xs),
                Flexible(
                  child: Text(
                    privacy.shortLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// The chat's model with its privacy badge; tap to switch models.
///
/// Compact widths show the badge icon only (the full sentence is in the
/// semantics label, tooltip and picker); wide layouts add the host.
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
                          if (s != null) ...[
                            PrivacyBadge(privacy: s.privacy, showLabel: false),
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
                          if (wide && s != null && s.leavesDevice && s.host != null) ...[
                            SizedBox(width: tokens.space.sm),
                            Flexible(child: PrivacyBadge(privacy: s.privacy)),
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
