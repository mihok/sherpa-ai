import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// WCAG 2.x contrast ratio between two opaque colors (1.0 – 21.0).
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// Smallest contrast of [fg] against every color in [backgrounds].
double minContrast(Color fg, Iterable<Color> backgrounds) =>
    backgrounds.map((b) => contrastRatio(fg, b)).reduce(math.min);

/// Returns [fg], darkened or lightened (keeping hue and saturation) until it
/// reaches [minRatio] against every background [backgroundsFor] produces.
///
/// Why a function of the candidate: tinted pills composite the foreground
/// over the surface, so the background moves with the foreground we try.
/// Why adjust at runtime at all: with dynamic color the surfaces come from
/// the user's wallpaper, so a fixed semantic color can't be proven legible
/// ahead of time.
Color ensureContrast(
  Color fg,
  List<Color> Function(Color candidate) backgroundsFor, {
  double minRatio = 4.5,
}) {
  if (minContrast(fg, backgroundsFor(fg)) >= minRatio) return fg;
  final bgs = backgroundsFor(fg);
  final avgLuminance = bgs.map((c) => c.computeLuminance()).reduce((a, b) => a + b) / bgs.length;
  // Light surfaces need a darker foreground and vice versa.
  final darken = avgLuminance > 0.18;
  final hsl = HSLColor.fromColor(fg);
  var best = fg;
  var bestRatio = 0.0;
  for (var step = 1; step <= 100; step++) {
    final l = (hsl.lightness + (darken ? -step : step) / 100).clamp(0.0, 1.0);
    final candidate = hsl.withLightness(l).toColor().withValues(alpha: fg.a);
    final ratio = minContrast(candidate, backgroundsFor(candidate));
    if (ratio > bestRatio) {
      best = candidate;
      bestRatio = ratio;
    }
    if (ratio >= minRatio) return candidate;
    if (l == 0.0 || l == 1.0) break;
  }
  return best;
}

/// Every surface role a semantic foreground may sit on directly.
List<Color> surfaceRoles(ColorScheme s) => [
      s.surface,
      s.surfaceDim,
      s.surfaceBright,
      s.surfaceContainerLowest,
      s.surfaceContainerLow,
      s.surfaceContainer,
      s.surfaceContainerHigh,
      s.surfaceContainerHighest,
    ];
