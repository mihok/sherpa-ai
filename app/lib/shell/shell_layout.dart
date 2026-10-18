import 'package:material_ui/material_ui.dart';

/// What the adaptive shell is currently showing, for pages inside it.
///
/// Pages use it to adapt without measuring the window again: the home page
/// shows the sessions list on phones but a "pick a chat" placeholder when the
/// list already sits in its own pane; pane-root pages drop their back button.
class ShellLayout extends InheritedWidget {
  const ShellLayout({super.key, required this.rail, required this.twoPane, required super.child});

  /// A NavigationRail is visible (medium and up).
  final bool rail;

  /// The sessions list is visible next to the detail pane.
  final bool twoPane;

  static ShellLayout? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ShellLayout>();

  /// Like [maybeOf] without registering a dependency (for route getters that
  /// run outside build).
  static ShellLayout? peek(BuildContext context) => context.getInheritedWidgetOfExactType<ShellLayout>();

  @override
  bool updateShouldNotify(ShellLayout old) => old.rail != rail || old.twoPane != twoPane;
}
