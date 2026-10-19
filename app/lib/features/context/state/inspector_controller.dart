import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../chat/state/chat_controller.dart';
import '../../chat/state/chat_view_state.dart';
import 'context_actions.dart';

/// The context inspector's data for one chat: a [ContextSnapshot], or null
/// while the chat has no usable model.
///
/// It re-inspects whenever a run ends (new messages, new overlays) or the
/// chat's model changes, so the screen never shows a stale view next to a
/// fresh context ring. Listening to the chat controller also keeps it alive
/// while the inspector is open, even if the chat page below is disposed.
final contextInspectorProvider =
    AsyncNotifierProvider.autoDispose.family<ContextInspectorController, ContextSnapshot?, String>(
  ContextInspectorController.new,
  name: 'contextInspectorProvider',
);

class ContextInspectorController extends AsyncNotifier<ContextSnapshot?> {
  ContextInspectorController(this.sessionId);

  final String sessionId;

  ChatController get _chat => ref.read(chatControllerProvider(sessionId).notifier);

  @override
  Future<ContextSnapshot?> build() async {
    final chat = chatControllerProvider(sessionId);
    ref.listen(
      chat.select((s) => (s.isRunActive, s.model?.choice, s.availability)),
      (prev, next) {
        if (prev == null) return;
        final runEnded = prev.$1 && !next.$1;
        if (runEnded || prev.$2 != next.$2 || prev.$3 != next.$3) ref.invalidateSelf();
      },
    );
    return _chat.inspectContext();
  }

  /// Re-reads without dropping the current view (pull to refresh).
  Future<void> refresh() async {
    final next = await AsyncValue.guard(_chat.inspectContext);
    if (ref.mounted) state = next;
  }

  /// "Compact now" through the chat controller (persisted, audited, and
  /// refused while a run is active). Null when it was refused.
  Future<CompactionOutcome?> compactNow() async {
    final outcome = await _chat.compactNow();
    if (outcome?.compacted ?? false) await refresh();
    return outcome;
  }

  /// Undoes [overlayId] and its dependents; returns the ids removed.
  Future<List<String>?> undo(String overlayId) async {
    final removed = await _chat.undoContextChange(overlayId);
    if (removed != null) await refresh();
    return removed;
  }
}

/// Whether context changes are possible right now, and if not, why.
final contextActionGateProvider = Provider.autoDispose.family<String?, String>((ref, sessionId) {
  final (running, availability) = ref.watch(
    chatControllerProvider(sessionId).select((s) => (s.isRunActive, s.availability)),
  );
  if (running) return 'Wait for the current reply to finish.';
  if (availability != ProviderAvailability.ready) return 'Choose a model for this chat first.';
  return null;
});
