import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../semantic_palette.dart';
import '../tokens.dart';

enum PrivacyBadgeSize {
  /// "Leaves device → api.openai.com". Settings, pickers, headers.
  regular,

  /// "→ api.openai.com" / "On device". Dense rows such as session tiles.
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

  String get _label {
    if (!_leaves) return 'On device';
    final h = host;
    if (size == PrivacyBadgeSize.compact) return h == null ? 'Leaves device' : '→ $h';
    return h == null ? 'Leaves device' : 'Leaves device → $h';
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
    final tokens = SherpaTokens.of(context);
    final color = _leaves ? tokens.semantic.leavesDevice : tokens.semantic.onDevice;
    final text = Theme.of(context).textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600);
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
              borderRadius: BorderRadius.circular(tokens.radius.pill),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: tokens.space.sm, vertical: tokens.space.xxs + 1),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_icon, size: 14, color: color),
                  SizedBox(width: tokens.space.xs),
                  Flexible(child: Text(_label, style: text, maxLines: 1, overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
