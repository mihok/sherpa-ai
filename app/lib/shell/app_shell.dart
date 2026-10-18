import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../design/adaptive.dart';
import '../design/tokens.dart';
import '../features/home/home_actions.dart';
import '../features/home/sessions_pane.dart';
import '../routing/routes.dart';
import 'shell_layout.dart';
import 'shortcuts.dart';

/// Adaptive frame around every route except onboarding.
///
/// - compact (< 600dp): just the page; navigation is push/pop.
/// - medium: NavigationRail + one pane.
/// - expanded (≥ 840dp) or a vertical hinge: rail + sessions pane + detail,
///   split exactly on the hinge when there is one.
///
/// [child] is go_router's nested Navigator (it carries a GlobalKey), so it
/// keeps its stack and page state when a fold/unfold or rotation moves it
/// between these layouts.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.location, required this.child});

  /// Current path, e.g. `/chat/abc`.
  final String location;
  final Widget child;

  static const double railWidth = 80;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  /// Where "Chats" in the rail returns to (the last open chat).
  late String _lastChatsLocation = Routes.isSettings(widget.location) ? Routes.home : widget.location;

  @override
  void didUpdateWidget(AppShell old) {
    super.didUpdateWidget(old);
    if (!Routes.isSettings(widget.location)) _lastChatsLocation = widget.location;
  }

  void _newChat() => unawaited(startNewChat(context, ref));

  void _settings() => context.go(Routes.settings);

  @override
  Widget build(BuildContext context) {
    final layout = AdaptiveLayout.of(context);
    final inSettings = Routes.isSettings(widget.location);
    final showList = layout.twoPane && !inSettings;

    final Widget body;
    if (!layout.showRail) {
      body = widget.child;
    } else {
      final tokens = SherpaTokens.of(context);
      final paneWidth = layout.listPaneWidth(
        leadingWidth: AppShell.railWidth + 1,
        min: tokens.layout.paneMinWidth,
        max: tokens.layout.paneMaxWidth,
      );
      body = Scaffold(
        // Nested page Scaffolds become non-root, so snackbars show once,
        // full width, instead of once per pane.
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MediaQuery.removePadding(
              context: context,
              removeRight: true,
              child: _Rail(
                selectedIndex: inSettings ? 1 : 0,
                onNewChat: _newChat,
                onChats: () => context.go(_lastChatsLocation),
                onSettings: _settings,
              ),
            ),
            const VerticalDivider(width: 1),
            if (showList) ...[
              SizedBox(
                width: paneWidth,
                child: MediaQuery.removePadding(
                  context: context,
                  removeLeft: true,
                  removeRight: true,
                  child: SessionsPane(selectedId: Routes.chatIdOf(widget.location)),
                ),
              ),
              // A hinge is its own divider; a plain split gets a hairline.
              if (layout.separator == null)
                const VerticalDivider(width: 1)
              else
                SizedBox(width: layout.separator!.width),
            ],
            Expanded(
              child: MediaQuery.removePadding(context: context, removeLeft: true, child: widget.child),
            ),
          ],
        ),
      );
    }

    return ShellLayout(
      rail: layout.showRail,
      twoPane: showList,
      child: AppShortcuts(onNewChat: _newChat, onSettings: _settings, child: body),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({
    required this.selectedIndex,
    required this.onNewChat,
    required this.onChats,
    required this.onSettings,
  });

  final int selectedIndex;
  final VoidCallback onNewChat;
  final VoidCallback onChats;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    return SafeArea(
      right: false,
      child: SizedBox(
        width: AppShell.railWidth,
        child: NavigationRail(
          minWidth: AppShell.railWidth,
          selectedIndex: selectedIndex,
          onDestinationSelected: (i) => i == 0 ? onChats() : onSettings(),
          leading: Padding(
            padding: EdgeInsets.only(top: t.space.sm, bottom: t.space.lg),
            child: FloatingActionButton(
              heroTag: null,
              elevation: 0,
              tooltip: 'New chat (${shortcutLabel('N')})',
              onPressed: onNewChat,
              child: const Icon(Icons.edit_square),
            ),
          ),
          destinations: const [
            NavigationRailDestination(
              icon: Icon(Icons.chat_bubble_outline_rounded),
              selectedIcon: Icon(Icons.chat_bubble_rounded),
              label: Text('Chats'),
            ),
            NavigationRailDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: Text('Settings'),
            ),
          ],
        ),
      ),
    );
  }
}
