/// Host style variables for Views (`hostContext.styles.variables`).
library;

import 'package:material_ui/material_ui.dart';

/// Maps a light and a dark [ColorScheme] onto the standardized MCP Apps
/// style variables, every colour as `light-dark(<light>, <dark>)` so a View
/// that follows `color-scheme` flips with the theme without a new context.
/// All colour keys are provided (partial sets clash with View fallbacks),
/// plus system font stacks (host font URLs would be blocked by `font-src`).
Map<String, String> mcpAppStyleVariables({required ColorScheme light, required ColorScheme dark}) {
  String ld(Color Function(ColorScheme s) pick) => 'light-dark(${_css(pick(light))}, ${_css(pick(dark))})';
  String fixed(int l, int d) => 'light-dark(${_css(Color(l))}, ${_css(Color(d))})';
  Color a(Color c, double alpha) => c.withValues(alpha: alpha);

  const successL = 0xFF1E7B34, successD = 0xFF7DD68F, successBgL = 0xFFE3F4E6, successBgD = 0xFF173B22;
  const warnL = 0xFF8A5300, warnD = 0xFFFFC266, warnBgL = 0xFFFFF1DC, warnBgD = 0xFF3D2A00;

  return {
    '--color-background-primary': ld((s) => s.surface),
    '--color-background-secondary': ld((s) => s.surfaceContainerLow),
    '--color-background-tertiary': ld((s) => s.surfaceContainerHigh),
    '--color-background-inverse': ld((s) => s.inverseSurface),
    '--color-background-ghost': 'transparent',
    '--color-background-info': ld((s) => s.primaryContainer),
    '--color-background-danger': ld((s) => s.errorContainer),
    '--color-background-success': fixed(successBgL, successBgD),
    '--color-background-warning': fixed(warnBgL, warnBgD),
    '--color-background-disabled': ld((s) => a(s.onSurface, 0.12)),
    '--color-text-primary': ld((s) => s.onSurface),
    '--color-text-secondary': ld((s) => s.onSurfaceVariant),
    '--color-text-tertiary': ld((s) => s.outline),
    '--color-text-inverse': ld((s) => s.onInverseSurface),
    '--color-text-ghost': ld((s) => a(s.onSurfaceVariant, 0.7)),
    '--color-text-info': ld((s) => s.primary),
    '--color-text-danger': ld((s) => s.error),
    '--color-text-success': fixed(successL, successD),
    '--color-text-warning': fixed(warnL, warnD),
    '--color-text-disabled': ld((s) => a(s.onSurface, 0.38)),
    '--color-border-primary': ld((s) => s.outlineVariant),
    '--color-border-secondary': ld((s) => s.outline),
    '--color-border-tertiary': ld((s) => a(s.outlineVariant, 0.5)),
    '--color-border-inverse': ld((s) => s.inverseSurface),
    '--color-border-ghost': 'transparent',
    '--color-border-info': ld((s) => s.primary),
    '--color-border-danger': ld((s) => s.error),
    '--color-border-success': fixed(successL, successD),
    '--color-border-warning': fixed(warnL, warnD),
    '--color-border-disabled': ld((s) => a(s.onSurface, 0.12)),
    '--color-ring-primary': ld((s) => s.primary),
    '--color-ring-secondary': ld((s) => s.secondary),
    '--color-ring-inverse': ld((s) => s.inversePrimary),
    '--color-ring-info': ld((s) => s.primary),
    '--color-ring-danger': ld((s) => s.error),
    '--color-ring-success': fixed(successL, successD),
    '--color-ring-warning': fixed(warnL, warnD),
    '--font-sans': 'system-ui, -apple-system, "Roboto", "Segoe UI", sans-serif',
    '--font-mono': 'ui-monospace, "SF Mono", "Roboto Mono", monospace',
    '--font-weight-normal': '400',
    '--font-weight-medium': '500',
    '--font-weight-semibold': '600',
    '--font-weight-bold': '700',
    for (final (k, size, lh) in const [
      ('text-xs', 12, 16),
      ('text-sm', 14, 20),
      ('text-md', 16, 24),
      ('text-lg', 18, 28),
      ('heading-xs', 16, 24),
      ('heading-sm', 18, 26),
      ('heading-md', 20, 28),
      ('heading-lg', 24, 32),
      ('heading-xl', 28, 36),
      ('heading-2xl', 32, 40),
      ('heading-3xl', 36, 44),
    ]) ...{
      '--font-$k-size': '${size}px',
      '--font-$k-line-height': '${lh}px',
    },
    '--border-radius-xs': '2px',
    '--border-radius-sm': '4px',
    '--border-radius-md': '8px',
    '--border-radius-lg': '12px',
    '--border-radius-xl': '16px',
    '--border-radius-full': '9999px',
    '--border-width-regular': '1px',
    '--shadow-hairline': '0 0 0 1px rgba(0, 0, 0, 0.08)',
    '--shadow-sm': '0 1px 2px rgba(0, 0, 0, 0.12)',
    '--shadow-md': '0 2px 6px rgba(0, 0, 0, 0.14)',
    '--shadow-lg': '0 6px 16px rgba(0, 0, 0, 0.18)',
  };
}

String _css(Color c) {
  final v = c.toARGB32();
  final r = (v >> 16) & 0xff, g = (v >> 8) & 0xff, b = v & 0xff, alpha = (v >> 24) & 0xff;
  if (alpha == 0xff) return '#${[r, g, b].map((x) => x.toRadixString(16).padLeft(2, '0')).join()}';
  return 'rgba($r, $g, $b, ${(alpha / 255).toStringAsFixed(2)})';
}
