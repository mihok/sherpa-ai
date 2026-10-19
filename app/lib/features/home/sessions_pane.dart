import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../design/motion.dart';
import '../../design/tokens.dart';
import '../../design/widgets/a11y.dart';
import '../../routing/routes.dart';
import '../../shell/shell_layout.dart';
import '../../state/sessions.dart';
import 'home_actions.dart';
import 'session_search_field.dart';
import 'sessions_list.dart';

/// Phone layout: the sessions list as a full screen with an app bar and a
/// "New chat" button.
class SessionsScreen extends ConsumerWidget {
  const SessionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rail = ShellLayout.maybeOf(context)?.rail ?? false;
    final archived = ref.watch(showArchivedProvider);
    return Scaffold(
      appBar: AppBar(
        title: Heading(level: 1, child: Text(archived ? 'Archived chats' : 'Chats')),
        actions: [
          const _ArchivedToggle(),
          // With a rail, Settings is a rail destination instead.
          if (!rail)
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => context.go(Routes.settings),
            ),
          const _HomeOverflow(),
        ],
      ),
      body: const SessionsList(header: SliverToBoxAdapter(child: SessionSearchField())),
      floatingActionButton: rail
          ? null
          : FloatingActionButton.extended(
              onPressed: () => unawaited(startNewChat(context, ref)),
              icon: const Icon(Icons.edit_square),
              label: const Text('New chat'),
              tooltip: 'Start a new chat',
            ),
    );
  }
}

/// Tablet layout: the sessions list as the left pane next to the open chat.
class SessionsPane extends ConsumerWidget {
  const SessionsPane({super.key, this.selectedId});

  final String? selectedId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final archived = ref.watch(showArchivedProvider);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        bottom: false,
        right: false,
        left: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsetsDirectional.fromSTEB(t.space.lg, t.space.sm, t.space.xs, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Heading(
                      level: 1,
                      child: Text(archived ? 'Archived chats' : 'Chats', style: theme.textTheme.titleLarge),
                    ),
                  ),
                  const _ArchivedToggle(),
                  const _HomeOverflow(),
                ],
              ),
            ),
            const SessionSearchField(),
            Expanded(child: SessionsList(selectedId: selectedId)),
          ],
        ),
      ),
    );
  }
}

class _ArchivedToggle extends ConsumerWidget {
  const _ArchivedToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final archived = ref.watch(showArchivedProvider);
    return IconButton(
      tooltip: archived ? 'Show active chats' : 'Show archived chats',
      isSelected: archived,
      icon: const Icon(Icons.archive_outlined),
      selectedIcon: const Icon(Icons.archive),
      onPressed: () => ref.read(showArchivedProvider.notifier).toggle(),
    );
  }
}

/// Less frequent list actions. "Import handoff…" continues a task that was
/// handed off on another device (or saved earlier) as a new chat.
class _HomeOverflow extends StatelessWidget {
  const _HomeOverflow();

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        tooltip: 'More',
        popUpAnimationStyle: motionStyleOf(context),
        icon: const Icon(Icons.more_vert_rounded),
        onSelected: (route) => unawaited(context.push<void>(route)),
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: Routes.handoffImport,
            child: ListTile(leading: Icon(Icons.move_down_rounded), title: Text('Import handoff…')),
          ),
        ],
      );
}
