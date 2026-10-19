/// `McpUiHostContext` (R03 §6.1, mobile mapping §11.7).
library;

import 'dart:convert';

import 'package:meta/meta.dart';

/// `inline` / `fullscreen` / `pip` (wire names).
enum McpAppDisplayMode {
  inline,
  fullscreen,
  pip;

  static McpAppDisplayMode? tryParse(Object? v) => switch (v) {
        'inline' => inline,
        'fullscreen' => fullscreen,
        'pip' => pip,
        _ => null,
      };
}

/// `light` / `dark`.
enum McpAppTheme { light, dark }

/// `containerDimensions`: a fixed value means the host controls that axis,
/// a `max*` value means the View may size itself up to the cap.
@immutable
final class McpAppContainerDimensions {
  const McpAppContainerDimensions({this.width, this.maxWidth, this.height, this.maxHeight});

  final double? width;
  final double? maxWidth;
  final double? height;
  final double? maxHeight;

  Map<String, Object?> toJson() => {
        if (width != null) 'width': _px(width!) else if (maxWidth != null) 'maxWidth': _px(maxWidth!),
        if (height != null) 'height': _px(height!) else if (maxHeight != null) 'maxHeight': _px(maxHeight!),
      };

  static num _px(double v) => v == v.roundToDouble() ? v.round() : double.parse(v.toStringAsFixed(1));
}

/// Safe-area insets in logical px.
@immutable
final class McpAppInsets {
  const McpAppInsets({this.top = 0, this.right = 0, this.bottom = 0, this.left = 0});

  static const McpAppInsets zero = McpAppInsets();

  final double top;
  final double right;
  final double bottom;
  final double left;

  Map<String, Object?> toJson() => {
        'top': McpAppContainerDimensions._px(top),
        'right': McpAppContainerDimensions._px(right),
        'bottom': McpAppContainerDimensions._px(bottom),
        'left': McpAppContainerDimensions._px(left),
      };
}

/// What the host tells the View about its surroundings. Every field is
/// optional on the wire; [toJson] omits nulls.
@immutable
final class McpAppHostContext {
  const McpAppHostContext({
    this.theme,
    this.styleVariables,
    this.displayMode = McpAppDisplayMode.inline,
    this.availableDisplayModes = const [McpAppDisplayMode.inline, McpAppDisplayMode.fullscreen],
    this.containerDimensions,
    this.locale,
    this.timeZone,
    this.userAgent,
    this.platform = 'mobile',
    this.touch = true,
    this.hover = false,
    this.safeAreaInsets,
    this.toolInfo,
  });

  final McpAppTheme? theme;

  /// `styles.variables`: the standardized `--color-*`, `--font-*`, … keys.
  /// Provide all colour keys or none (R03 §11.7).
  final Map<String, String>? styleVariables;
  final McpAppDisplayMode displayMode;
  final List<McpAppDisplayMode> availableDisplayModes;
  final McpAppContainerDimensions? containerDimensions;

  /// BCP 47, e.g. `en-US`.
  final String? locale;

  /// IANA id (from native; Dart's `timeZoneName` is an abbreviation).
  final String? timeZone;

  /// Host application identifier, e.g. `Sherpa/1.0.0 (Android 16)`.
  final String? userAgent;
  final String platform;
  final bool touch;
  final bool hover;
  final McpAppInsets? safeAreaInsets;

  /// `{id?, tool}`: the host→server `tools/call` id and the full tool.
  final Map<String, Object?>? toolInfo;

  McpAppHostContext copyWith({
    McpAppTheme? theme,
    Map<String, String>? styleVariables,
    McpAppDisplayMode? displayMode,
    List<McpAppDisplayMode>? availableDisplayModes,
    McpAppContainerDimensions? containerDimensions,
    String? locale,
    String? timeZone,
    String? userAgent,
    bool? touch,
    bool? hover,
    McpAppInsets? safeAreaInsets,
    Map<String, Object?>? toolInfo,
  }) =>
      McpAppHostContext(
        theme: theme ?? this.theme,
        styleVariables: styleVariables ?? this.styleVariables,
        displayMode: displayMode ?? this.displayMode,
        availableDisplayModes: availableDisplayModes ?? this.availableDisplayModes,
        containerDimensions: containerDimensions ?? this.containerDimensions,
        locale: locale ?? this.locale,
        timeZone: timeZone ?? this.timeZone,
        userAgent: userAgent ?? this.userAgent,
        platform: platform,
        touch: touch ?? this.touch,
        hover: hover ?? this.hover,
        safeAreaInsets: safeAreaInsets ?? this.safeAreaInsets,
        toolInfo: toolInfo ?? this.toolInfo,
      );

  Map<String, Object?> toJson() => {
        if (toolInfo != null) 'toolInfo': toolInfo,
        if (theme != null) 'theme': theme!.name,
        if (styleVariables != null) 'styles': {'variables': styleVariables},
        'displayMode': displayMode.name,
        'availableDisplayModes': [for (final m in availableDisplayModes) m.name],
        if (containerDimensions != null) 'containerDimensions': containerDimensions!.toJson(),
        if (locale != null) 'locale': locale,
        if (timeZone != null) 'timeZone': timeZone,
        if (userAgent != null) 'userAgent': userAgent,
        'platform': platform,
        'deviceCapabilities': {'touch': touch, 'hover': hover},
        if (safeAreaInsets != null) 'safeAreaInsets': safeAreaInsets!.toJson(),
      };

  /// The keys of [next] that differ from [previous] (JSON equality), for
  /// `ui/notifications/host-context-changed`. Removed keys are not sent.
  static Map<String, Object?> diff(Map<String, Object?> previous, Map<String, Object?> next) => {
        for (final e in next.entries)
          if (jsonEncode(previous[e.key]) != jsonEncode(e.value)) e.key: e.value,
      };
}
