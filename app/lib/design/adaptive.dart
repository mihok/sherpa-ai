import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:material_ui/material_ui.dart';

/// Material window size classes by width (developer.android.com
/// "use window size classes"). Flutter ships none, so we define them from
/// `MediaQuery.sizeOf`, never from device type or orientation.
enum WindowClass {
  /// < 600dp: phones in portrait. Single pane, no rail.
  compact,

  /// 600–839dp: small tablets, foldables unfolded in portrait. Rail + one pane.
  medium,

  /// ≥ 840dp: tablets, landscape foldables. Rail + list + detail.
  expanded;

  static const double mediumMin = 600;
  static const double expandedMin = 840;

  static WindowClass fromWidth(double width) => width < mediumMin
      ? WindowClass.compact
      : width < expandedMin
          ? WindowClass.medium
          : WindowClass.expanded;

  static WindowClass of(BuildContext context) => fromWidth(MediaQuery.sizeOf(context).width);

  bool get isCompact => this == WindowClass.compact;
  bool operator >=(WindowClass other) => index >= other.index;
}

/// A display feature that physically or visually splits the window into a
/// left and a right half (a hinge, or a fold in book posture).
///
/// `displayFeatures` is only populated on Android. A flat fold doesn't
/// obstruct anything, so we only split on it when the device is half open.
DisplayFeature? verticalSeparatorOf(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  for (final f in MediaQuery.maybeDisplayFeaturesOf(context) ?? const <DisplayFeature>[]) {
    final b = f.bounds;
    final isVertical = b.height >= size.height - 1 && b.width < size.width / 2;
    if (!isVertical) continue;
    if (f.type == DisplayFeatureType.hinge) return f;
    if (f.type == DisplayFeatureType.fold && f.state == DisplayFeatureState.postureHalfOpened) return f;
  }
  return null;
}

/// How the shell should arrange itself for the current window.
@immutable
final class AdaptiveLayout {
  const AdaptiveLayout({required this.windowClass, required this.size, this.separator});

  factory AdaptiveLayout.of(BuildContext context) => AdaptiveLayout(
        windowClass: WindowClass.of(context),
        size: MediaQuery.sizeOf(context),
        separator: verticalSeparatorOf(context)?.bounds,
      );

  final WindowClass windowClass;
  final Size size;

  /// Bounds of a vertical hinge or half-open fold, in window coordinates.
  final Rect? separator;

  /// A NavigationRail replaces in-app-bar navigation from 600dp up.
  bool get showRail => windowClass >= WindowClass.medium || separator != null;

  /// List + detail side by side: at ≥ 840dp, or whenever hardware splits the
  /// window (a pane must never straddle a hinge).
  bool get twoPane => windowClass == WindowClass.expanded || separator != null;

  /// Horizontal page gutter: 16dp on phones, 24dp from medium up.
  double get gutter => windowClass.isCompact ? 16 : 24;

  /// Width of the list pane (sessions) in the two-pane layout, measured from
  /// the window's start edge after [leadingWidth] (the rail).
  double listPaneWidth({required double leadingWidth, double min = 300, double max = 400}) {
    final hinge = separator;
    if (hinge != null) return (hinge.left - leadingWidth).clamp(min, hinge.left);
    return (size.width * 0.34).clamp(min, max);
  }

  @override
  bool operator ==(Object other) =>
      other is AdaptiveLayout && other.windowClass == windowClass && other.size == size && other.separator == separator;

  @override
  int get hashCode => Object.hash(windowClass, size, separator);
}
