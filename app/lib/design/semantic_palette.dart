import 'package:material_ui/material_ui.dart';

import 'brand.dart';
import 'contrast.dart';
import 'tokens.dart';

/// Opacity of a semantic color when used as a pill/container tint behind
/// the same color as text (privacy badge, status chips).
const double kSemanticTintAlpha = 0.12;

/// Minimum contrast every semantic foreground must reach (WCAG AA body text).
const double kMinTextContrast = 4.5;

/// Derives [SemanticColors] for [scheme].
///
/// Each semantic hue is turned into a tone that matches the scheme's
/// brightness (via `ColorScheme.fromSeed`, the same tonal math as the rest of
/// the theme), then nudged until it passes [kMinTextContrast] against every
/// surface role *and* against its own tinted pill on each surface. That
/// guarantee is what lets feature code put an "On device" / "Leaves device"
/// label anywhere without re-checking legibility.
SemanticColors semanticColorsFor(ColorScheme scheme) {
  Color tone(Color seed) =>
      ColorScheme.fromSeed(seedColor: seed, brightness: scheme.brightness).primary;

  final surfaces = surfaceRoles(scheme);
  List<Color> withTints(Color fg) => [
        ...surfaces,
        for (final s in surfaces) Color.alphaBlend(fg.withValues(alpha: kSemanticTintAlpha), s),
      ];
  Color legible(Color c) => ensureContrast(c, withTints, minRatio: kMinTextContrast);

  return SemanticColors(
    onDevice: legible(tone(SherpaBrand.onDeviceSeed)),
    leavesDevice: legible(tone(SherpaBrand.leavesDeviceSeed)),
    success: legible(tone(SherpaBrand.successSeed)),
    warning: legible(tone(SherpaBrand.warningSeed)),
    danger: legible(scheme.error),
    reasoning: ensureContrast(scheme.onSurfaceVariant, (_) => surfaces, minRatio: kMinTextContrast),
    toolSurface: scheme.surfaceContainerHigh,
    codeSurface: scheme.surfaceContainerHighest,
  );
}
