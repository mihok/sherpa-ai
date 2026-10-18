import 'package:drift/drift.dart';

// Schema v1 of the Sherpa database.
//
// Conventions (they apply to every table below):
//
// * Every table is STRICT, so SQLite rejects a value of the wrong storage
//   class instead of silently coercing it. Booleans are INTEGER with a
//   CHECK (x IN (0, 1)) that drift generates.
// * Timestamps are INTEGER microseconds since the Unix epoch (UTC). Drift's
//   DateTime mapping keeps whole seconds only, and the ISO-8601 strings that
//   `DateTime.toIso8601String` produces do not sort lexically (the
//   microsecond digits are omitted when they are zero), so neither can back
//   an ORDER BY.
// * Domain objects are stored losslessly as their hand-written `toJson()`
//   in a `json` TEXT column; the few other columns are denormalized copies
//   that exist only to filter, order and index. A field added to a core
//   model therefore round-trips without a schema migration.
// * Child tables reference `sessions(id)` with ON DELETE CASCADE, and each
//   one's primary key or an index leads with `session_id`, so the cascade
//   never scans a whole table.

/// One chat session. Mapped column by column (rather than as JSON) because
/// the session list filters and orders on these fields.
@DataClassName('SessionRow')
@TableIndex(name: 'sessions_updated_idx', columns: {#updatedAt})
class Sessions extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  TextColumn get providerId => text().nullable()();
  TextColumn get modelId => text().nullable()();
  TextColumn get activeLeafId => text().nullable()();
  TextColumn get systemPrompt => text().nullable()();
  TextColumn get handoffFrom => text().nullable()();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  TextColumn get settingsJson => text().withDefault(const Constant('{}'))();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  bool get isStrict => true;
}

/// Nodes of a session's conversation tree.
///
/// `messages_parent_idx` serves `children()` completely (filter on session
/// and parent, ordered by time); `messages_session_created_idx` serves
/// chronological scans of a whole session (export, handoff bundles). The
/// primary key serves `getMessage()` and each step of the recursive
/// `path()` query.
@DataClassName('MessageRow')
@TableIndex(name: 'messages_parent_idx', columns: {#sessionId, #parentId, #createdAt})
@TableIndex(name: 'messages_session_created_idx', columns: {#sessionId, #createdAt})
class Messages extends Table {
  TextColumn get sessionId =>
      text().references(Sessions, #id, onDelete: KeyAction.cascade)();
  TextColumn get id => text()();
  TextColumn get parentId => text().nullable()();
  TextColumn get role => text()();
  TextColumn get kind => text()();
  IntColumn get createdAt => integer()();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();

  /// `Message.toJson()`: the source of truth for the message.
  TextColumn get json => text()();

  @override
  Set<Column<Object>> get primaryKey => {sessionId, id};

  @override
  bool get isStrict => true;
}

/// Context overlays (elisions, truncations, compactions) per session.
@DataClassName('OverlayRow')
@TableIndex(name: 'overlays_session_created_idx', columns: {#sessionId, #createdAt})
class Overlays extends Table {
  TextColumn get sessionId =>
      text().references(Sessions, #id, onDelete: KeyAction.cascade)();
  TextColumn get id => text()();
  TextColumn get type => text()();
  IntColumn get createdAt => integer()();
  TextColumn get json => text()();

  @override
  Set<Column<Object>> get primaryKey => {sessionId, id};

  @override
  bool get isStrict => true;
}

/// The current plan of each session (at most one row per session).
@DataClassName('PlanRow')
class Plans extends Table {
  TextColumn get sessionId =>
      text().references(Sessions, #id, onDelete: KeyAction.cascade)();
  IntColumn get updatedAt => integer()();
  TextColumn get json => text()();

  @override
  Set<Column<Object>> get primaryKey => {sessionId};

  @override
  bool get isStrict => true;
}

/// The latest run checkpoint of each session (at most one row per session:
/// a new checkpoint replaces the previous one).
@DataClassName('CheckpointRow')
class Checkpoints extends Table {
  TextColumn get sessionId =>
      text().references(Sessions, #id, onDelete: KeyAction.cascade)();
  TextColumn get runId => text()();
  TextColumn get phase => text()();
  IntColumn get updatedAt => integer()();
  TextColumn get json => text()();

  @override
  Set<Column<Object>> get primaryKey => {sessionId};

  @override
  bool get isStrict => true;
}

/// Append-only audit trail. `seq` (an AUTOINCREMENT rowid, never reused)
/// records append order and breaks ties between entries with the same
/// timestamp; the `audit_append_only` trigger (queries.drift) rejects
/// UPDATEs, so rows only ever disappear together with their session.
@DataClassName('AuditRow')
@TableIndex(name: 'audit_session_at_idx', columns: {#sessionId, #at})
class Audit extends Table {
  IntColumn get seq => integer().autoIncrement()();
  TextColumn get sessionId =>
      text().references(Sessions, #id, onDelete: KeyAction.cascade)();
  TextColumn get id => text()();
  IntColumn get at => integer()();
  TextColumn get kind => text()();
  TextColumn get summary => text()();
  TextColumn get json => text()();

  /// Entry ids are unique per session, which makes re-appending the same
  /// entry (e.g. a run resumed after a crash) a no-op instead of a duplicate.
  @override
  List<Set<Column<Object>>> get uniqueKeys => [
        {sessionId, id},
      ];

  @override
  bool get isStrict => true;
}

/// Generic JSON documents for app-level records that are read whole and
/// rarely queried: provider configs, preferences, the model library, MCP
/// servers, download records. See `JsonDocumentStore`.
@DataClassName('DocumentRow')
class Documents extends Table {
  TextColumn get collection => text()();
  TextColumn get id => text()();
  TextColumn get json => text()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {collection, id};

  @override
  bool get isStrict => true;
}
