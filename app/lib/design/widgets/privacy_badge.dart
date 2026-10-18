import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../semantic_palette.dart';
import '../tokens.dart';

enum PrivacyBadgeSize {
  /// "Leaves device → api.openai.com". Settings, pickers, headers.
  regular,

  /// "↗ api.openai.com" / "On device". Dense rows such as session tiles.
  compact,
}

/// Where a model runs, at a glance: "On device" or "Leaves device → host".
///
/// This is Sherpa's core trust signal, so it is always text + icon + color
/// (never color alone), always carries a full spoken label, and its colors
/// are contrast-checked against every surface (see `semanticColorsFor`).
class PrivacyBadge extends StatelessWidget {
  const PrivacyBadge({
    super.key,
    required this.location,
    this.host,
    this.size = PrivacyBadgeSize.regular,
  });

  final ExecutionLocation location;

  /// Destination host for data that leaves the device.
  final String? host;
  final PrivacyBadgeSize size;

  bool get _leaves => location != ExecutionLocation.onDevice;

  /// Text before the arrow; null in the compact variant when the host alone
  /// (after the outward icon) says it.
  String? get _lead {
    if (!_leaves) return 'On device';
    if (size == PrivacyBadgeSize.compact && host != null) return null;
    return 'Leaves device';
  }

  /// Full sentence for screen readers, independent of the visual size.
  String get semanticLabel => switch (location) {
        ExecutionLocation.onDevice => 'Runs on this device. Nothing leaves your phone.',
        ExecutionLocation.localNetwork =>
          'Leaves this device. Sent to ${host ?? 'a server'} on your local network.',
        ExecutionLocation.remote => 'Leaves this device. Sent to ${host ?? 'a remote server'}.',
      };

  IconData get _icon => switch (location) {
        ExecutionLocation.onDevice => Icons.smartphone_outlined,
        ExecutionLocation.localNetwork => Icons.lan_outlined,
        ExecutionLocation.remote => Icons.arrow_outward,
      };

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final color = _leaves ? t.semantic.leavesDevice : t.semantic.onDevice;
    final text = Theme.of(context).textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600);
    final lead = _lead;
    final h = _leaves ? host : null;
    Widget label(String s) => Flexible(child: Text(s, style: text, maxLines: 1, overflow: TextOverflow.ellipsis));
    // Dense chrome may scale, but not without bound (research/12 §1.7).
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.5,
      child: Semantics(
        label: semanticLabel,
        excludeSemantics: true,
        child: Tooltip(
          message: semanticLabel,
          excludeFromSemantics: true,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color.withValues(alpha: kSemanticTintAlpha),
              borderRadius: BorderRadius.circular(t.radius.pill),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: t.space.sm, vertical: t.space.xxs + 1),
              // The arrow is an icon, not "→": the badge must not depend on
              // the font having that glyph (the SDK's Roboto subset doesn't).
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_icon, size: 14, color: color),
                  SizedBox(width: t.space.xs),
                  if (lead != null) label(lead),
                  if (lead != null && h != null)
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: t.space.xxs),
                      child: Icon(Icons.arrow_forward, size: 12, color: color),
                    ),
                  if (h != null) label(h),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
