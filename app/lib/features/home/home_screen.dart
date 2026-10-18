import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../design/widgets/sherpa_mark.dart';
import '../../design/widgets/state_views.dart';
import '../../shell/shell_layout.dart';
import '../../shell/shortcuts.dart';
import 'home_actions.dart';
import 'sessions_pane.dart';

/// The `/` route.
///
/// On phones it *is* the sessions list. When the shell already shows the
/// list in its own pane, this page sits in the detail pane instead, so it
/// becomes a calm "pick a chat" placeholder.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      (ShellLayout.maybeOf(context)?.twoPane ?? false) ? const ChatPlaceholder() : const SessionsScreen();
}

class ChatPlaceholder extends ConsumerWidget {
  const ChatPlaceholder({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        body: StateView(
          illustration: const SherpaMark(size: 56),
          title: 'Pick a chat, or start a new one',
          message: 'Tip: ${shortcutLabel('N')} starts a new chat, ${shortcutLabel(',')} opens settings.',
          primaryAction: FilledButton.tonalIcon(
            onPressed: () => unawaited(startNewChat(context, ref)),
            icon: const Icon(Icons.edit_square),
            label: const Text('New chat'),
          ),
        ),
      );
}
