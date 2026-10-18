import 'dart:async';

import 'package:sherpa_core/sherpa_core.dart';

/// Decorates a [SessionStore] so the UI learns about session-level writes
/// made anywhere in the app (the agent loop renaming a chat, the chat screen
/// switching models), without polling and without adding a stream to the
/// core contract.
///
/// Only [putSession] and [deleteSession] notify: message writes happen per
/// streamed delta and the sessions list doesn't care about them.
///
/// Wire it once in bootstrap around the real store; every consumer of
/// `sessionStoreProvider` then writes through it.
final class ObservableSessionStore implements SessionStore {
  ObservableSessionStore(this._inner);

  final SessionStore _inner;
  final StreamController<String> _changes = StreamController<String>.broadcast();

  /// Emits the id of every session that was written or deleted.
  Stream<String> get changes => _changes.stream;

  /// The wrapped store (for the integrator's migrations and diagnostics).
  SessionStore get inner => _inner;

  Future<void> close() => _changes.close();

  @override
  Future<SessionRecord> putSession(SessionRecord session) async {
    final saved = await _inner.putSession(session);
    _changes.add(session.id);
    return saved;
  }

  @override
  Future<void> deleteSession(String id) async {
    await _inner.deleteSession(id);
    _changes.add(id);
  }

  @override
  Future<SessionRecord?> getSession(String id) => _inner.getSession(id);

  @override
  Future<List<SessionRecord>> listSessions({bool includeArchived = false}) =>
      _inner.listSessions(includeArchived: includeArchived);

  @override
  Future<void> putMessage(String sessionId, Message message) => _inner.putMessage(sessionId, message);

  @override
  Future<Message?> getMessage(String sessionId, String messageId) => _inner.getMessage(sessionId, messageId);

  @override
  Future<List<Message>> path(String sessionId, String leafId) => _inner.path(sessionId, leafId);

  @override
  Future<List<Message>> children(String sessionId, String? parentId) => _inner.children(sessionId, parentId);

  @override
  Future<void> putOverlay(String sessionId, ContextOverlay overlay) => _inner.putOverlay(sessionId, overlay);

  @override
  Future<void> removeOverlay(String sessionId, String overlayId) => _inner.removeOverlay(sessionId, overlayId);

  @override
  Future<List<ContextOverlay>> overlays(String sessionId) => _inner.overlays(sessionId);

  @override
  Future<void> putPlan(String sessionId, Plan plan) => _inner.putPlan(sessionId, plan);

  @override
  Future<Plan?> getPlan(String sessionId) => _inner.getPlan(sessionId);

  @override
  Future<void> putCheckpoint(RunCheckpoint checkpoint) => _inner.putCheckpoint(checkpoint);

  @override
  Future<RunCheckpoint?> getCheckpoint(String sessionId) => _inner.getCheckpoint(sessionId);

  @override
  Future<void> appendAudit(AuditEntry entry) => _inner.appendAudit(entry);

  @override
  Future<List<AuditEntry>> audit(String sessionId, {int? limit}) => _inner.audit(sessionId, limit: limit);
}
