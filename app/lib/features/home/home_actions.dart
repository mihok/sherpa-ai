import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../routing/routes.dart';
import '../../state/providers.dart';
import '../../state/sessions.dart';
import '../../state/ui_preferences.dart';

/// "Now", refreshed every minute so relative times in lists stay true
/// without each tile running its own timer.
final minuteClockProvider = StreamProvider<DateTime>((ref) async* {
  final clock = ref.watch(clockProvider);
  yield clock.now();
  yield* Stream<DateTime>.periodic(const Duration(minutes: 1), (_) => clock.now());
});

/// Creates a chat on the default model and opens it.
///
/// Works with no model configured too: the chat screen owns that empty
/// state ("connect a model"), so the button never dead-ends.
Future<void> startNewChat(BuildContext context, WidgetRef ref) async {
  final SessionRecord session;
  try {
    session = await ref.read(sessionActionsProvider).create();
  } on Object {
    if (context.mounted) showErrorSnackBar(context, "Couldn't create a chat. Try again.");
    return;
  }
  ref.read(hapticsProvider).light();
  if (context.mounted) context.go(Routes.chat(session.id));
}

/// Deletes with a 6 s undo window. Navigates away first if the chat is open.
void deleteSessionWithUndo(BuildContext context, WidgetRef ref, SessionRecord session, {String? openSessionId}) {
  final pending = ref.read(sessionActionsProvider).deleteWithUndo(session.id);
  ref.read(hapticsProvider).warning();
  if (openSessionId == session.id) context.go(Routes.home);
  _undoSnackBar(
    context,
    message: 'Chat deleted',
    onUndo: pending.undo,
    onTimeout: pending.commit,
  );
}

/// Archives (or restores) with undo.
void archiveSessionWithUndo(BuildContext context, WidgetRef ref, SessionRecord session, {String? openSessionId}) {
  final actions = ref.read(sessionActionsProvider);
  final archiving = !session.archived;
  unawaited(actions.setArchived(session.id, archived: archiving));
  ref.read(hapticsProvider).selection();
  if (archiving && openSessionId == session.id) context.go(Routes.home);
  _undoSnackBar(
    context,
    message: archiving ? 'Chat archived' : 'Chat restored',
    onUndo: () => actions.setArchived(session.id, archived: !archiving),
  );
}

void _undoSnackBar(
  BuildContext context, {
  required String message,
  required Future<void> Function() onUndo,
  Future<void> Function()? onTimeout,
}) {
  final messenger = ScaffoldMessenger.of(context)
    // Closing the previous one commits its pending action (reason: hide).
    ..hideCurrentSnackBar();
  final controller = messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      // An undo window must close by itself, or deletes never commit.
      persist: false,
      duration: const Duration(seconds: 6),
      action: SnackBarAction(label: 'Undo', onPressed: () => unawaited(onUndo())),
    ),
  );
  if (onTimeout != null) {
    unawaited(controller.closed.then((reason) {
      if (reason != SnackBarClosedReason.action) return onTimeout();
    }));
  }
}

/// One-line error toast, consistent everywhere.
void showErrorSnackBar(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
