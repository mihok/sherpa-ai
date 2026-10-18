import 'package:material_ui/material_ui.dart';

/// The only literal colors in the app. Everything else is derived from a
/// [ColorScheme] (brand or the user's wallpaper) so dynamic color, dark mode
/// and contrast fixes apply everywhere at once.
abstract final class SherpaBrand {
  /// Glacier teal: calm, outdoorsy, and far enough from the usual AI-app
  /// purple/blue that Sherpa reads as its own thing.
  static const Color seed = Color(0xFF2B6F77);

  /// Hue for "runs on this device". Green = contained, nothing leaves.
  static const Color onDeviceSeed = Color(0xFF2E7D4F);

  /// Hue for "data leaves this device". Amber, not red: sending a prompt to
  /// a provider you chose is not an error, but it should never be invisible.
  static const Color leavesDeviceSeed = Color(0xFFB4690E);

  static const Color successSeed = Color(0xFF2E7D32);
  static const Color warningSeed = Color(0xFFB26A00);
}
