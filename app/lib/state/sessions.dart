import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import 'app_providers.dart';
import 'observable_session_store.dart';
import 'providers.dart';
import 'services.dart';

/// Whether the sessions list includes archived chats.
final showArchivedProvider = NotifierProvider<ShowArchived, bool>(ShowArchived.new);

class ShowArchived extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
}

/// Free-text filter for the sessions list.
final sessionQueryProvider = NotifierProvider<SessionQuery, String>(SessionQuery.new);

class SessionQuery extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;
}

/// Ids hidden from the list while a write is in flight or an undo window is
/// open. Kept outside [sessionListProvider] because Riverpod 3 recreates a
/// notifier (and its fields) on every rebuild.
final hiddenSessionIdsProvider = NotifierProvider<HiddenSessionIds, Set<String>>(HiddenSessionIds.new);

class HiddenSessionIds extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void hide(String id) => state = {...state, id};

  void unhide(String id) => state = {...state}..remove(id);
}

/// Sessions straight from the store, newest first.
///
/// Live when the store is an [ObservableSessionStore] (bootstrap wires one):
/// any `putSession`/`deleteSession` anywhere in the app refreshes it.
final sessionListProvider =
    AsyncNotifierProvider<SessionListController, List<SessionRecord>>(SessionListController.new);

class SessionListController extends AsyncNotifier<List<SessionRecord>> {
  @override
  Future<List<SessionRecord>> build() async {
    final store = ref.watch(sessionStoreProvider);
    final includeArchived = ref.watch(showArchivedProvider);
    if (store is ObservableSessionStore) {
      final sub = store.changes.listen((_) => unawaited(refresh()));
      ref.onDispose(sub.cancel);
    }
    return store.listSessions(includeArchived: includeArchived);
  }

  /// Re-reads the store, keeping the current list on screen meanwhile.
  Future<void> refresh() async {
    if (!ref.mounted) return;
    final store = ref.read(sessionStoreProvider);
    final includeArchived = ref.read(showArchivedProvider);
    final next = await AsyncValue.guard(() => store.listSessions(includeArchived: includeArchived));
    if (ref.mounted) state = next;
  }
}

/// What the list renders: store contents minus hidden ids, filtered by the
/// search query (title, model id, provider name; case-insensitive).
final visibleSessionsProvider = Provider<AsyncValue<List<SessionRecord>>>((ref) {
  final sessions = ref.watch(sessionListProvider);
  final hidden = ref.watch(hiddenSessionIdsProvider);
  final query = ref.watch(sessionQueryProvider).trim().toLowerCase();
  final configs = query.isEmpty
      ? const <ProviderConfig>[]
      : (ref.watch(providerConfigsProvider).value ?? ref.read(providerRegistryProvider).configs);
  final names = {for (final c in configs) c.id: c.displayName.toLowerCase()};
  bool matches(SessionRecord s) =>
      query.isEmpty ||
      s.title.toLowerCase().contains(query) ||
      (s.modelId?.toLowerCase().contains(query) ?? false) ||
      (names[s.providerId]?.contains(query) ?? false);
  return sessions.whenData((list) => [
        for (final s in list)
          if (!hidden.contains(s.id) && matches(s)) s,
      ]);
});

/// Session mutations the shell performs. Lives as long as the app, so the
/// callbacks it hands out (undo handles) never hold a disposed widget ref.
final sessionActionsProvider = Provider<SessionActions>(SessionActions.new);

final class SessionActions {
  SessionActions(this._ref);

  final Ref _ref;

  SessionStore get _store => _ref.read(sessionStoreProvider);

  Future<void> _refresh() => _ref.read(sessionListProvider.notifier).refresh();

  /// Creates a "New chat" session on [model] (default: the user's default
  /// model, which may be null; the chat screen then asks for one).
  Future<SessionRecord> create({ModelChoice? model}) async {
    final now = _ref.read(clockProvider).now();
    final choice = model ?? _ref.read(preferencesProvider).defaultModel;
    final record = SessionRecord(
      id: _ref.read(idGeneratorProvider).next('chat'),
      title: defaultSessionTitle,
      createdAt: now,
      updatedAt: now,
      providerId: choice?.providerId,
      modelId: choice?.modelId,
    );
    await _store.putSession(record);
    await _refresh();
    return record;
  }

  /// Hides [id] at once (synchronously, as `Dismissible` requires) and
  /// returns a handle that either deletes for real or brings it back.
  ///
  /// The delete happens only after the undo window, so a crash during it
  /// errs on the side of keeping the chat.
  PendingDelete deleteWithUndo(String id) {
    final hidden = _ref.read(hiddenSessionIdsProvider.notifier)..hide(id);
    return PendingDelete._(
      commit: () async {
        try {
          await _store.deleteSession(id);
          await _refresh();
        } finally {
          hidden.unhide(id);
        }
      },
      undo: () async => hidden.unhide(id),
    );
  }

  /// Archives or restores a chat. With [archived] and archived chats hidden,
  /// the row disappears synchronously.
  Future<void> setArchived(String id, {required bool archived}) async {
    final hidden = _ref.read(hiddenSessionIdsProvider.notifier);
    final hide = archived && !_ref.read(showArchivedProvider);
    if (hide) hidden.hide(id);
    try {
      final record = await _store.getSession(id);
      if (record != null) await _store.putSession(record.copyWith(archived: archived));
      await _refresh();
    } finally {
      if (hide) hidden.unhide(id);
    }
  }
}

/// Second phase of a delete with undo. The first call to either method wins.
final class PendingDelete {
  PendingDelete._({required Future<void> Function() commit, required Future<void> Function() undo})
      : _commit = commit,
        _undo = undo;

  final Future<void> Function() _commit;
  final Future<void> Function() _undo;
  bool _done = false;

  Future<void> commit() async {
    if (_done) return;
    _done = true;
    await _commit();
  }

  Future<void> undo() async {
    if (_done) return;
    _done = true;
    await _undo();
  }
}
