import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

bool get _apple => defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS;

/// "⌘N" on Apple platforms, "Ctrl+N" elsewhere, for tooltips and hints.
String shortcutLabel(String key) => _apple ? '⌘$key' : 'Ctrl+$key';

/// App-wide hardware-keyboard shortcuts (tablets, foldables with keyboard
/// covers, ChromeOS):
/// - Ctrl/⌘+N: new chat
/// - Ctrl/⌘+,: settings
///
/// Both modifiers are bound on every platform: iPad keyboards send ⌘, but
/// so may an external Mac keyboard on Android.
class AppShortcuts extends StatelessWidget {
  const AppShortcuts({super.key, required this.onNewChat, required this.onSettings, required this.child});

  final VoidCallback onNewChat;
  final VoidCallback onSettings;
  final Widget child;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyN, control: true): onNewChat,
          const SingleActivator(LogicalKeyboardKey.keyN, meta: true): onNewChat,
          const SingleActivator(LogicalKeyboardKey.comma, control: true): onSettings,
          const SingleActivator(LogicalKeyboardKey.comma, meta: true): onSettings,
        },
        // Shortcuts only see keys that reach a focused descendant; this node
        // catches them when nothing more specific has focus.
        child: Focus(autofocus: true, skipTraversal: true, child: child),
      );
}
