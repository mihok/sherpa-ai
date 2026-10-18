import 'package:material_ui/material_ui.dart';

import 'brand.dart';
import 'component_themes.dart';
import 'tokens.dart';
import 'typography.dart';

/// Builds Sherpa's [ThemeData] for a light or dark [ColorScheme].
abstract final class SherpaTheme {
  /// Brand scheme, used everywhere dynamic color is unavailable (iOS,
  /// Android < 12) or turned off by the user.
  static ColorScheme brandScheme(Brightness brightness) =>
      ColorScheme.fromSeed(seedColor: SherpaBrand.seed, brightness: brightness);

  /// Normalizes a wallpaper scheme from `dynamic_color`.
  ///
  /// The plugin mixes legacy `Scheme` tones with seeded surface containers,
  /// so surfaces and containers come from two different tone tables.
  /// Re-seeding from the wallpaper primary keeps the user's hue while giving
  /// one consistent M3 tone set, which is what our contrast guarantees and
  /// tonal-elevation layout are built on.
  static ColorScheme fromDynamic(ColorScheme dynamicScheme) =>
      ColorScheme.fromSeed(seedColor: dynamicScheme.primary, brightness: dynamicScheme.brightness);

  static ThemeData light({ColorScheme? dynamicScheme}) =>
      build(dynamicScheme == null ? brandScheme(Brightness.light) : fromDynamic(dynamicScheme));

  static ThemeData dark({ColorScheme? dynamicScheme}) =>
      build(dynamicScheme == null ? brandScheme(Brightness.dark) : fromDynamic(dynamicScheme));

  static ThemeData build(ColorScheme scheme, {bool reducedMotion = false}) {
    final tokens = SherpaTokens.fromScheme(scheme, reducedMotion: reducedMotion);
    final c = SherpaComponentThemes(scheme, tokens);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: sherpaTextOverrides(),
      visualDensity: VisualDensity.standard,
      // Material's default is 48dp minimum targets; keep it explicit because
      // desktop/tablet defaults would otherwise shrink them.
      materialTapTargetSize: MaterialTapTargetSize.padded,
      extensions: [tokens],
      appBarTheme: c.appBar,
      cardTheme: c.card,
      chipTheme: c.chip,
      inputDecorationTheme: c.input,
      bottomSheetTheme: c.bottomSheet,
      dialogTheme: c.dialog,
      navigationBarTheme: c.navigationBar,
      navigationRailTheme: c.navigationRail,
      snackBarTheme: c.snackBar,
      listTileTheme: c.listTile,
      filledButtonTheme: c.filledButton,
      outlinedButtonTheme: c.outlinedButton,
      textButtonTheme: c.textButton,
      dividerTheme: c.divider,
      tooltipTheme: c.tooltip,
      floatingActionButtonTheme: c.fab,
    );
  }
}
