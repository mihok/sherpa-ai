import 'package:material_ui/material_ui.dart';

/// Sherpa design tokens beyond what [ColorScheme] / [TextTheme] carry.
///
/// Widgets read them with `SherpaTokens.of(context)`; never hard-code
/// spacing, radii, durations or semantic colors in feature code.
@immutable
class SherpaTokens extends ThemeExtension<SherpaTokens> {
  const SherpaTokens({
    required this.space,
    required this.radius,
    required this.motion,
    required this.semantic,
  });

  final SpaceScale space;
  final RadiusScale radius;
  final MotionTokens motion;
  final SemanticColors semantic;

  static SherpaTokens of(BuildContext context) =>
      Theme.of(context).extension<SherpaTokens>() ??
      (throw StateError('SherpaTokens missing from ThemeData.extensions'));

  @override
  SherpaTokens copyWith({
    SpaceScale? space,
    RadiusScale? radius,
    MotionTokens? motion,
    SemanticColors? semantic,
  }) =>
      SherpaTokens(
        space: space ?? this.space,
        radius: radius ?? this.radius,
        motion: motion ?? this.motion,
        semantic: semantic ?? this.semantic,
      );

  @override
  SherpaTokens lerp(SherpaTokens? other, double t) =>
      other == null ? this : copyWith(semantic: semantic.lerp(other.semantic, t));
}

/// 4-pt spacing scale.
@immutable
class SpaceScale {
  const SpaceScale();
  double get xxs => 2;
  double get xs => 4;
  double get sm => 8;
  double get md => 12;
  double get lg => 16;
  double get xl => 24;
  double get xxl => 32;
  double get xxxl => 48;

  /// Minimum interactive target (WCAG / platform guidance).
  double get minTouchTarget => 48;
}

@immutable
class RadiusScale {
  const RadiusScale();
  double get sm => 8;
  double get md => 12;
  double get lg => 16;
  double get xl => 24;
  double get pill => 999;
}

/// Durations and curves. Feature code must route animations through these
/// so reduced-motion settings can zero them in one place.
@immutable
class MotionTokens {
  const MotionTokens({this.reduced = false});
  final bool reduced;

  Duration get fast => reduced ? Duration.zero : const Duration(milliseconds: 120);
  Duration get medium => reduced ? Duration.zero : const Duration(milliseconds: 220);
  Duration get slow => reduced ? Duration.zero : const Duration(milliseconds: 360);
  Curve get standard => Curves.easeOutCubic;
  Curve get emphasized => Curves.easeInOutCubicEmphasized;
}

/// Colors with meaning that Material's scheme does not name.
@immutable
class SemanticColors {
  const SemanticColors({
    required this.onDevice,
    required this.leavesDevice,
    required this.success,
    required this.warning,
    required this.danger,
    required this.reasoning,
    required this.toolSurface,
    required this.codeSurface,
  });

  /// "Runs on this device" indicator.
  final Color onDevice;

  /// "Data leaves this device" indicator.
  final Color leavesDevice;
  final Color success;
  final Color warning;
  final Color danger;

  /// Dimmed text for streamed reasoning.
  final Color reasoning;
  final Color toolSurface;
  final Color codeSurface;

  SemanticColors lerp(SemanticColors o, double t) => SemanticColors(
        onDevice: Color.lerp(onDevice, o.onDevice, t)!,
        leavesDevice: Color.lerp(leavesDevice, o.leavesDevice, t)!,
        success: Color.lerp(success, o.success, t)!,
        warning: Color.lerp(warning, o.warning, t)!,
        danger: Color.lerp(danger, o.danger, t)!,
        reasoning: Color.lerp(reasoning, o.reasoning, t)!,
        toolSurface: Color.lerp(toolSurface, o.toolSurface, t)!,
        codeSurface: Color.lerp(codeSurface, o.codeSurface, t)!,
      );
}
