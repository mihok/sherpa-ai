import 'package:material_ui/material_ui.dart';

/// Overrides on top of the Material 3 (2021) type scale.
///
/// Sherpa keeps the platform's own font (Roboto / SF): it is what users read
/// all day, it has the best hinting and Dynamic Type support, and it avoids
/// shipping font files. Only weights and line heights are tuned:
/// - titles a step firmer so dense lists scan quickly;
/// - body line height 1.5 for long model answers.
TextTheme sherpaTextOverrides() => const TextTheme(
      titleLarge: TextStyle(fontWeight: FontWeight.w500),
      titleMedium: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.1),
      bodyLarge: TextStyle(height: 1.5),
      bodyMedium: TextStyle(height: 1.45),
    );

/// Text styles for numbers that change in place (token counts, timings,
/// relative times). Tabular figures stop digits from jittering as they
/// update and keep columns aligned.
extension SherpaTextStyles on TextTheme {
  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  TextStyle get metricSmall => (labelSmall ?? const TextStyle()).copyWith(fontFeatures: _tabular);
  TextStyle get metric => (labelMedium ?? const TextStyle()).copyWith(fontFeatures: _tabular);
  TextStyle get metricLarge => (titleMedium ?? const TextStyle()).copyWith(fontFeatures: _tabular);
}

/// The user's text scale is past 1.3: rows that sit side by side at 1×
/// should stack, and one-line names may take a few.
bool isLargeText(BuildContext context) => MediaQuery.textScalerOf(context).scale(10) > 13;

/// [normal] lines at ordinary text sizes, [large] once [isLargeText]: names
/// and titles that fit on one line at 1× would otherwise be cut to a few
/// letters at 2× on a phone.
int scaledMaxLines(BuildContext context, {int normal = 1, int large = 3}) => isLargeText(context) ? large : normal;
