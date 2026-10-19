import 'package:material_ui/material_ui.dart';

import 'semantic_palette.dart';

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
    this.layout = const LayoutTokens(),
  });

  /// Complete token set for [scheme]: semantic colors are derived from it and
  /// contrast-checked (see `semanticColorsFor`), so this works for the brand
  /// scheme and for any dynamic (wallpaper) scheme alike.
  factory SherpaTokens.fromScheme(ColorScheme scheme, {bool reducedMotion = false}) => SherpaTokens(
        space: const SpaceScale(),
        radius: const RadiusScale(),
        motion: MotionTokens(reduced: reducedMotion),
        semantic: semanticColorsFor(scheme),
      );

  final SpaceScale space;
  final RadiusScale radius;
  final MotionTokens motion;
  final SemanticColors semantic;
  final LayoutTokens layout;

  static SherpaTokens of(BuildContext context) =>
      Theme.of(context).extension<SherpaTokens>() ??
      (throw StateError('SherpaTokens missing from ThemeData.extensions'));

  static SherpaTokens? maybeOf(BuildContext context) => Theme.of(context).extension<SherpaTokens>();

  @override
  SherpaTokens copyWith({
    SpaceScale? space,
    RadiusScale? radius,
    MotionTokens? motion,
    SemanticColors? semantic,
    LayoutTokens? layout,
  }) =>
      SherpaTokens(
        space: space ?? this.space,
        radius: radius ?? this.radius,
        motion: motion ?? this.motion,
        semantic: semantic ?? this.semantic,
        layout: layout ?? this.layout,
      );

  @override
  SherpaTokens lerp(SherpaTokens? other, double t) => other == null
      ? this
      : copyWith(
          semantic: semantic.lerp(other.semantic, t),
          // Non-color tokens can't be interpolated meaningfully; switch halfway.
          motion: t < 0.5 ? motion : other.motion,
        );

  // Value equality keeps AnimatedTheme from re-animating on every rebuild
  // (ThemeData compares extensions with ==).
  @override
  bool operator ==(Object other) =>
      other is SherpaTokens &&
      other.space == space &&
      other.radius == radius &&
      other.motion == motion &&
      other.semantic == semantic &&
      other.layout == layout;

  @override
  int get hashCode => Object.hash(space, radius, motion, semantic, layout);
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

  @override
  bool operator ==(Object other) => other is SpaceScale;

  @override
  int get hashCode => (SpaceScale).hashCode;
}

@immutable
class RadiusScale {
  const RadiusScale();
  double get sm => 8;
  double get md => 12;
  double get lg => 16;
  double get xl => 24;
  double get pill => 999;

  @override
  bool operator ==(Object other) => other is RadiusScale;

  @override
  int get hashCode => (RadiusScale).hashCode;
}

/// Durations and curves. Feature code must route animations through these
/// so reduced-motion settings can zero them in one place.
///
/// `reduced` is resolved by `MotionScope` from BOTH Android "Remove
/// animations" (`MediaQuery.disableAnimations`) and iOS "Reduce Motion"
/// (`AccessibilityFeatures.reduceMotion`, which never reaches MediaQuery).
@immutable
class MotionTokens {
  const MotionTokens({this.reduced = false});
  final bool reduced;

  /// Micro feedback: ripples, toggles, chip selection.
  Duration get extraFast => reduced ? Duration.zero : const Duration(milliseconds: 80);
  Duration get fast => reduced ? Duration.zero : const Duration(milliseconds: 120);
  Duration get medium => reduced ? Duration.zero : const Duration(milliseconds: 220);
  Duration get slow => reduced ? Duration.zero : const Duration(milliseconds: 360);

  /// Ambient loops (skeleton shimmer). Zero means "render a static frame".
  Duration get ambient => reduced ? Duration.zero : const Duration(milliseconds: 1400);

  Curve get standard => Curves.easeOutCubic;
  Curve get emphasized => Curves.easeInOutCubicEmphasized;

  /// Elements entering the screen.
  Curve get decelerate => Curves.easeOutCubic;

  /// Elements leaving the screen.
  Curve get accelerate => Curves.easeInCubic;

  /// Scales an arbitrary duration (e.g. a third-party widget parameter).
  Duration scale(Duration d) => reduced ? Duration.zero : d;

  /// For framework widgets that animate on their own and take an
  /// [AnimationStyle] (`showModalBottomSheet`'s `sheetAnimationStyle`,
  /// `showDialog`'s `animationStyle`, `ExpansionTile`'s
  /// `expansionAnimationStyle`): no animation under reduced motion, the
  /// widget's own default otherwise. None of them read
  /// `MediaQuery.disableAnimations` themselves.
  AnimationStyle? get style => reduced ? AnimationStyle.noAnimation : null;

  /// For `TabController.animationDuration` (tab taps slide the view).
  Duration get tabs => scale(const Duration(milliseconds: 300));

  @override
  bool operator ==(Object other) => other is MotionTokens && other.reduced == reduced;

  @override
  int get hashCode => reduced.hashCode;
}

/// Layout constants that keep long lines readable on big screens.
@immutable
class LayoutTokens {
  const LayoutTokens();

  /// Readable column for settings, onboarding and forms.
  double get maxContentWidth => 640;

  /// Narrow column for single-purpose forms.
  double get maxFormWidth => 560;

  /// Sessions list pane width bounds in the two-pane layout.
  double get paneMinWidth => 300;
  double get paneMaxWidth => 400;

  @override
  bool operator ==(Object other) => other is LayoutTokens;

  @override
  int get hashCode => (LayoutTokens).hashCode;
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

  @override
  bool operator ==(Object other) =>
      other is SemanticColors &&
      other.onDevice == onDevice &&
      other.leavesDevice == leavesDevice &&
      other.success == success &&
      other.warning == warning &&
      other.danger == danger &&
      other.reasoning == reasoning &&
      other.toolSurface == toolSurface &&
      other.codeSurface == codeSurface;

  @override
  int get hashCode =>
      Object.hash(onDevice, leavesDevice, success, warning, danger, reasoning, toolSurface, codeSurface);
}
