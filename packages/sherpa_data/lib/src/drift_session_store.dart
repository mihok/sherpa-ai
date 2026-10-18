import 'package:drift/drift.dart';
import 'package:sherpa_core/sherpa_core.dart';

import 'codec.dart';
import 'database/database.dart';

/// [SessionStore] over [SherpaDatabase].
///
/// Every write is a single statement or one transaction, and drift completes
/// the future only after SQLite committed it (WAL, `synchronous = FULL`), so
/// a write is durable when its future completes, as the contract requires.
///
/// Writes upsert (`INSERT … ON CONFLICT DO UPDATE`), never
/// `INSERT OR REPLACE`: REPLACE deletes the old row first, which on
/// `sessions` would cascade-delete the whole transcript.
///
/// Rows for a session (messages, overlays, plan, checkpoint, audit) need
/// the session row to exist first (foreign keys); the agent loop always
/// creates the session before anything else.
///
/// Ties in time-ordered results fall back to insertion order (rowid), which
/// an upsert keeps, so a draft rewritten in place does not move.
final class DriftSessionStore implements SessionStore {
  DriftSessionStore(this._db);

  final SherpaDatabase _db;

  // ---------------------------------------------------------------------------
  // Sessions

  @override
  Future<SessionRecord> putSession(SessionRecord session) async {
    await _db.into(_db.sessions).insertOnConflictUpdate(_sessionRow(session));
    return session;
  }

  @override
  Future<SessionRecord?> getSession(String id) async {
    final row = await (_db.select(_db.sessions)..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _session(row);
  }

  @override
  Future<List<SessionRecord>> listSessions({bool includeArchived = false}) async =>
      [for (final row in await _sessionsQuery(includeArchived).get()) _session(row)];

  /// [listSessions] as a stream that re-emits after every change to the
  /// sessions table, for the session list UI.
  Stream<List<SessionRecord>> watchSessions({bool includeArchived = false}) =>
      _sessionsQuery(includeArchived).watch().map((rows) => [for (final r in rows) _session(r)]);

  SimpleSelectStatement<$SessionsTable, SessionRow> _sessionsQuery(bool includeArchived) {
    final q = _db.select(_db.sessions);
    if (!includeArchived) q.where((t) => t.archived.equals(false));
    return q
      ..orderBy([
        (t) => OrderingTerm.desc(t.updatedAt),
        (t) => OrderingTerm.asc(t.rowId),
      ]);
  }

  /// Deletes the session and everything that belongs to it, atomically.
  ///
  /// The child rows are deleted explicitly even though every child table
  /// also cascades: deleting a chat is a privacy action, so the guarantee
  /// must not hinge on `PRAGMA foreign_keys` being on for this connection.
  @override
  Future<void> deleteSession(String id) => _db.transaction(() async {
        await (_db.delete(_db.messages)..where((t) => t.sessionId.equals(id))).go();
        await (_db.delete(_db.overlays)..where((t) => t.sessionId.equals(id))).go();
        await (_db.delete(_db.plans)..where((t) => t.sessionId.equals(id))).go();
        await (_db.delete(_db.checkpoints)..where((t) => t.sessionId.equals(id))).go();
        await (_db.delete(_db.audit)..where((t) => t.sessionId.equals(id))).go();
        await (_db.delete(_db.sessions)..where((t) => t.id.equals(id))).go();
      });

  // ---------------------------------------------------------------------------
  // Messages

  @override
  Future<void> putMessage(String sessionId, Message message) async {
    await _db.into(_db.messages).insertOnConflictUpdate(_messageRow(sessionId, message));
  }

  /// Upserts many messages in one transaction (imports, handoff bundles):
  /// either all of them are stored or none.
  Future<void> putMessages(String sessionId, Iterable<Message> messages) => _db.batch(
        (b) => b.insertAllOnConflictUpdate(
          _db.messages,
          [for (final m in messages) _messageRow(sessionId, m)],
        ),
      );

  @override
  Future<Message?> getMessage(String sessionId, String messageId) async {
    final row = await (_db.select(_db.messages)
          ..where((t) => t.sessionId.equals(sessionId) & t.id.equals(messageId)))
        .getSingleOrNull();
    return row == null ? null : _message(row.json);
  }

  /// Root → [leafId] in one recursive query (`messagePath` in
  /// queries.drift). The path stops early at a missing ancestor, like the
  /// reference store; a cycle in parent links is a corrupt tree and throws.
  @override
  Future<List<Message>> path(String sessionId, String leafId) async {
    final rows = await _db.messagePath(sessionId, leafId).get();
    final seen = <String>{};
    for (final row in rows) {
      if (!seen.add(row.id)) throw StateError('cycle in message tree at ${row.id}');
    }
    return [for (final row in rows.reversed) _message(row.json)];
  }

  @override
  Future<List<Message>> children(String sessionId, String? parentId) async {
    final q = _db.select(_db.messages)
      ..where((t) =>
          t.sessionId.equals(sessionId) &
          (parentId == null ? t.parentId.isNull() : t.parentId.equals(parentId)))
      ..orderBy([
        (t) => OrderingTerm.asc(t.createdAt),
        (t) => OrderingTerm.asc(t.rowId),
      ]);
    return [for (final row in await q.get()) _message(row.json)];
  }

  /// Every message of the session, all branches, oldest first: the input
  /// for exports and handoff bundles.
  Future<List<Message>> allMessages(String sessionId) async {
    final q = _db.select(_db.messages)
      ..where((t) => t.sessionId.equals(sessionId))
      ..orderBy([
        (t) => OrderingTerm.asc(t.createdAt),
        (t) => OrderingTerm.asc(t.rowId),
      ]);
    return [for (final row in await q.get()) _message(row.json)];
  }

  // ---------------------------------------------------------------------------
  // Overlays, plan, checkpoint

  @override
  Future<void> putOverlay(String sessionId, ContextOverlay overlay) async {
    await _db.into(_db.overlays).insertOnConflictUpdate(OverlaysCompanion(
          sessionId: Value(sessionId),
          id: Value(overlay.id),
          type: Value(overlay.type),
          createdAt: Value(toMicros(overlay.createdAt)),
          json: Value(encodeJson(overlay.toJson())),
        ));
  }

  @override
  Future<void> removeOverlay(String sessionId, String overlayId) async {
    await (_db.delete(_db.overlays)
          ..where((t) => t.sessionId.equals(sessionId) & t.id.equals(overlayId)))
        .go();
  }

  @override
  Future<List<ContextOverlay>> overlays(String sessionId) async {
    final q = _db.select(_db.overlays)
      ..where((t) => t.sessionId.equals(sessionId))
      ..orderBy([
        (t) => OrderingTerm.asc(t.createdAt),
        (t) => OrderingTerm.asc(t.rowId),
      ]);
    return [for (final row in await q.get()) ContextOverlay.fromJson(decodeJsonObject(row.json))];
  }

  @override
  Future<void> putPlan(String sessionId, Plan plan) async {
    await _db.into(_db.plans).insertOnConflictUpdate(PlansCompanion(
          sessionId: Value(sessionId),
          updatedAt: Value(toMicros(plan.updatedAt)),
          json: Value(encodeJson(plan.toJson())),
        ));
  }

  @override
  Future<Plan?> getPlan(String sessionId) async {
    final row = await (_db.select(_db.plans)..where((t) => t.sessionId.equals(sessionId)))
        .getSingleOrNull();
    return row == null ? null : Plan.fromJson(decodeJsonObject(row.json));
  }

  @override
  Future<void> putCheckpoint(RunCheckpoint checkpoint) async {
    await _db.into(_db.checkpoints).insertOnConflictUpdate(CheckpointsCompanion(
          sessionId: Value(checkpoint.sessionId),
          runId: Value(checkpoint.runId),
          phase: Value(checkpoint.phase.name),
          updatedAt: Value(toMicros(checkpoint.updatedAt)),
          json: Value(encodeJson(checkpoint.toJson())),
        ));
  }

  @override
  Future<RunCheckpoint?> getCheckpoint(String sessionId) async {
    final row = await (_db.select(_db.checkpoints)..where((t) => t.sessionId.equals(sessionId)))
        .getSingleOrNull();
    return row == null ? null : RunCheckpoint.fromJson(decodeJsonObject(row.json));
  }

  // ---------------------------------------------------------------------------
  // Audit

  /// Appends [entry]. Re-appending an entry id already present for the
  /// session is a no-op, so a resumed run cannot duplicate audit lines.
  @override
  Future<void> appendAudit(AuditEntry entry) async {
    await _db.into(_db.audit).insert(
          AuditCompanion.insert(
            sessionId: entry.sessionId,
            id: entry.id,
            at: toMicros(entry.at),
            kind: entry.kind.name,
            summary: entry.summary,
            json: encodeJson(entry.toJson()),
          ),
          onConflict: DoNothing(target: [_db.audit.sessionId, _db.audit.id]),
        );
  }

  /// Chronological (by `at`, then append order). With [limit], the newest
  /// [limit] entries, still oldest first.
  @override
  Future<List<AuditEntry>> audit(String sessionId, {int? limit}) async {
    if (limit != null) RangeError.checkNotNegative(limit, 'limit');
    final newestFirst = limit != null;
    final q = _db.select(_db.audit)
      ..where((t) => t.sessionId.equals(sessionId))
      ..orderBy([
        (t) => OrderingTerm(expression: t.at, mode: newestFirst ? OrderingMode.desc : OrderingMode.asc),
        (t) => OrderingTerm(expression: t.seq, mode: newestFirst ? OrderingMode.desc : OrderingMode.asc),
      ]);
    if (limit != null) q.limit(limit);
    final rows = await q.get();
    final entries = [for (final row in rows) AuditEntry.fromJson(decodeJsonObject(row.json))];
    return newestFirst ? entries.reversed.toList() : entries;
  }

  // ---------------------------------------------------------------------------
  // Mapping

  /// Every column is set explicitly (a `Value(null)` included): an absent
  /// value would make the upsert keep the previous one.
  SessionsCompanion _sessionRow(SessionRecord s) => SessionsCompanion(
        id: Value(s.id),
        title: Value(s.title),
        createdAt: Value(toMicros(s.createdAt)),
        updatedAt: Value(toMicros(s.updatedAt)),
        providerId: Value(s.providerId),
        modelId: Value(s.modelId),
        activeLeafId: Value(s.activeLeafId),
        systemPrompt: Value(s.systemPrompt),
        handoffFrom: Value(s.handoffFromSessionId),
        archived: Value(s.archived),
        settingsJson: Value(encodeJson(s.settings)),
      );

  SessionRecord _session(SessionRow r) {
    final settings = decodeJsonObject(r.settingsJson);
    return SessionRecord(
      id: r.id,
      title: r.title,
      createdAt: fromMicros(r.createdAt),
      updatedAt: fromMicros(r.updatedAt),
      providerId: r.providerId,
      modelId: r.modelId,
      activeLeafId: r.activeLeafId,
      systemPrompt: r.systemPrompt,
      handoffFromSessionId: r.handoffFrom,
      archived: r.archived,
      settings: settings.isEmpty ? const {} : settings,
    );
  }

  MessagesCompanion _messageRow(String sessionId, Message m) => MessagesCompanion(
        sessionId: Value(sessionId),
        id: Value(m.id),
        parentId: Value(m.parentId),
        role: Value(m.role.name),
        kind: Value(m.kind.name),
        createdAt: Value(toMicros(m.createdAt)),
        pinned: Value(m.pinned),
        json: Value(encodeJson(m.toJson())),
      );

  Message _message(String json) => Message.fromJson(decodeJsonObject(json));
}
