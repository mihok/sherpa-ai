import '../context/overlay.dart';
import '../model/message.dart';
import 'checkpoint.dart';
import 'plan.dart';
import 'session_store.dart';

/// Reference [SessionStore] for tests, evals and the scripted fake provider.
/// Round-trips everything through JSON so it catches serialization bugs the
/// real store would hit.
final class InMemorySessionStore implements SessionStore {
  final Map<String, SessionRecord> _sessions = {};
  final Map<String, Map<String, Map<String, Object?>>> _messages = {};
  final Map<String, Map<String, Map<String, Object?>>> _overlays = {};
  final Map<String, Map<String, Object?>> _plans = {};
  final Map<String, Map<String, Object?>> _checkpoints = {};
  final Map<String, List<Map<String, Object?>>> _audit = {};

  @override
  Future<SessionRecord> putSession(SessionRecord session) async {
    _sessions[session.id] = SessionRecord.fromJson(session.toJson());
    return session;
  }

  @override
  Future<SessionRecord?> getSession(String id) async => _sessions[id];

  @override
  Future<List<SessionRecord>> listSessions({bool includeArchived = false}) async {
    final list = _sessions.values.where((s) => includeArchived || !s.archived).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  @override
  Future<void> deleteSession(String id) async {
    _sessions.remove(id);
    _messages.remove(id);
    _overlays.remove(id);
    _plans.remove(id);
    _checkpoints.remove(id);
    _audit.remove(id);
  }

  /// Mirrors the SQL store's foreign keys: rows need an existing session.
  void _requireSession(String sessionId) {
    if (!_sessions.containsKey(sessionId)) throw StateError('unknown session $sessionId');
  }

  @override
  Future<void> putMessage(String sessionId, Message message) async {
    _requireSession(sessionId);
    (_messages[sessionId] ??= {})[message.id] = message.toJson();
  }

  @override
  Future<Message?> getMessage(String sessionId, String messageId) async {
    final j = _messages[sessionId]?[messageId];
    return j == null ? null : Message.fromJson(j);
  }

  @override
  Future<List<Message>> path(String sessionId, String leafId) async {
    final out = <Message>[];
    final seen = <String>{};
    String? cur = leafId;
    while (cur != null) {
      if (!seen.add(cur)) throw StateError('cycle in message tree at $cur');
      final m = await getMessage(sessionId, cur);
      if (m == null) break;
      out.add(m);
      cur = m.parentId;
    }
    return out.reversed.toList();
  }

  @override
  Future<List<Message>> children(String sessionId, String? parentId) async {
    final all = (_messages[sessionId] ?? const {}).values.map(Message.fromJson);
    return all.where((m) => m.parentId == parentId).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  @override
  Future<void> putOverlay(String sessionId, ContextOverlay overlay) async {
    _requireSession(sessionId);
    (_overlays[sessionId] ??= {})[overlay.id] = overlay.toJson();
  }

  @override
  Future<void> removeOverlay(String sessionId, String overlayId) async {
    _overlays[sessionId]?.remove(overlayId);
  }

  @override
  Future<List<ContextOverlay>> overlays(String sessionId) async =>
      (_overlays[sessionId] ?? const {}).values.map(ContextOverlay.fromJson).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  @override
  Future<void> putPlan(String sessionId, Plan plan) async {
    _requireSession(sessionId);
    _plans[sessionId] = plan.toJson();
  }

  @override
  Future<Plan?> getPlan(String sessionId) async {
    final j = _plans[sessionId];
    return j == null ? null : Plan.fromJson(j);
  }

  @override
  Future<void> putCheckpoint(RunCheckpoint checkpoint) async {
    _requireSession(checkpoint.sessionId);
    _checkpoints[checkpoint.sessionId] = checkpoint.toJson();
  }

  @override
  Future<RunCheckpoint?> getCheckpoint(String sessionId) async {
    final j = _checkpoints[sessionId];
    return j == null ? null : RunCheckpoint.fromJson(j);
  }

  @override
  Future<void> appendAudit(AuditEntry entry) async {
    _requireSession(entry.sessionId);
    final list = _audit[entry.sessionId] ??= [];
    // Idempotent per id so a resumed run cannot duplicate audit lines.
    if (list.any((e) => e['id'] == entry.id)) return;
    list.add(entry.toJson());
  }

  @override
  Future<List<AuditEntry>> audit(String sessionId, {int? limit}) async {
    // Chronological by time, ties in append order. List.sort is not
    // stable, so the append index is the explicit tiebreak.
    final indexed = [for (final (i, j) in (_audit[sessionId] ?? const []).indexed) (i, AuditEntry.fromJson(j))]
      ..sort((x, y) {
        final c = x.$2.at.compareTo(y.$2.at);
        return c != 0 ? c : x.$1.compareTo(y.$1);
      });
    final all = [for (final (_, e) in indexed) e];
    if (limit == null || all.length <= limit) return all;
    return all.sublist(all.length - limit);
  }
}
