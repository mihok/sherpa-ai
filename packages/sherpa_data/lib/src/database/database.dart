import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:meta/meta.dart';

import 'cipher.dart';
import 'tables.dart';

part 'database.g.dart';

/// Thrown when the file was written by a newer schema than this build knows.
///
/// Opening it anyway could corrupt data the newer version relies on, so the
/// database refuses; the user has to update the app (or restore a backup).
final class SchemaDowngradeException implements Exception {
  const SchemaDowngradeException({required this.fileVersion, required this.appVersion});

  final int fileVersion;
  final int appVersion;

  @override
  String toString() => 'SchemaDowngradeException: the database has schema v$fileVersion '
      'but this build only knows up to v$appVersion';
}

/// One step of the schema history: upgrades a database from version `v` to
/// `v + 1` (the map key is `v`).
typedef SchemaUpgrade = Future<void> Function(Migrator m, SherpaDatabase db);

/// The Sherpa database: sessions and their message trees, context overlays,
/// plans, checkpoints, the audit trail, and generic JSON documents.
///
/// Use `openSherpaDatabase` for the encrypted on-disk database and
/// [SherpaDatabase.inMemory] in tests. Application code talks to it through
/// `DriftSessionStore` and `JsonDocumentStore`, not through these tables.
///
/// ## Adding schema v2
///
/// 1. Change `tables.dart` / `queries.drift`.
/// 2. Bump [currentSchemaVersion] to 2 and add the v1→v2 step to
///    [upgradeSteps] under key `1`, e.g.
///    `1: (m, db) => m.addColumn(db.sessions, db.sessions.pinned)`.
///    All pending steps run in one transaction with foreign keys off
///    (SQLite cannot toggle them inside a transaction, and table rebuilds
///    need them off), followed by a `PRAGMA foreign_key_check`.
/// 3. Run `dart run drift_dev make-migrations` to snapshot v2 next to v1 in
///    `drift_schemas/` and generate step-by-step migration tests in
///    `test/drift/`, then `dart run build_runner build`.
/// 4. Add a v1-fixture → v2 case to `test/migration_test.dart`.
@DriftDatabase(
  tables: [Sessions, Messages, Overlays, Plans, Checkpoints, Audit, Documents],
  include: {'queries.drift'},
)
final class SherpaDatabase extends _$SherpaDatabase {
  /// Wraps any drift executor. The executor decides where the data lives
  /// and how it is encrypted; this class only owns the schema.
  SherpaDatabase(super.executor);

  /// A private, unencrypted, in-memory database for tests.
  factory SherpaDatabase.inMemory() => SherpaDatabase(NativeDatabase.memory());

  /// Exercises the migration machinery with a made-up schema history, so it
  /// is tested before the first real upgrade exists.
  @visibleForTesting
  factory SherpaDatabase.withSchemaHistory(
    QueryExecutor executor, {
    required int schemaVersion,
    required Map<int, SchemaUpgrade> steps,
  }) = _SchemaHistoryDatabase;

  static const int currentSchemaVersion = 1;

  /// Upgrade steps keyed by the version they upgrade *from*.
  static final Map<int, SchemaUpgrade> upgradeSteps = Map.unmodifiable(<int, SchemaUpgrade>{});

  /// Must stay a constant reference: `drift_dev make-migrations` reads it
  /// from the source.
  @override
  int get schemaVersion => currentSchemaVersion;

  Map<int, SchemaUpgrade> get _steps => upgradeSteps;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        // Drift writes user_version only after beforeOpen returns, and the
        // index/trigger statements have no IF NOT EXISTS. One transaction
        // that also writes the version makes a first launch that dies
        // half-way leave an empty file (created again next time) instead of
        // a half-built schema that still claims to be version 0.
        onCreate: (m) => transaction(() async {
          await m.createAll();
          await customStatement('PRAGMA user_version = $schemaVersion');
        }),
        onUpgrade: _upgrade,
        beforeOpen: (details) async {
          // Connection-scoped settings: SQLite forgets them on close.
          await customStatement('PRAGMA foreign_keys = ON');
          // Persisted in the file; re-issuing it is a no-op. In-memory
          // databases answer "memory" and stay in that mode.
          await customStatement('PRAGMA journal_mode = WAL');
          // FULL fsyncs the WAL on every commit. SessionStore promises that
          // a write is durable when its future completes, and NORMAL would
          // keep that promise only for app crashes, not for power loss.
          await customStatement('PRAGMA synchronous = FULL');
        },
      );

  /// Runs every pending step and writes the new version in ONE
  /// transaction. Drift would otherwise write user_version only after all
  /// steps, so a failure in step 2 would leave step 1 applied under the old
  /// version number and the next launch would re-run (and trip over) step 1.
  /// All-or-nothing leaves the file exactly at its old version instead, and
  /// the next launch simply retries.
  Future<void> _upgrade(Migrator m, int from, int to) async {
    if (from > to) throw SchemaDowngradeException(fileVersion: from, appVersion: to);
    await transaction(() async {
      for (var v = from; v < to; v++) {
        final step = _steps[v];
        if (step == null) throw StateError('no schema migration from v$v to v${v + 1}');
        await step(m, this);
      }
      final violations = await customSelect('PRAGMA foreign_key_check').get();
      if (violations.isNotEmpty) {
        throw StateError('schema migration $from→$to left ${violations.length} '
            'foreign key violation(s), first: ${violations.first.data}');
      }
      await customStatement('PRAGMA user_version = $to');
    });
  }

  /// The cipher SQLite3MultipleCiphers reports (e.g. `chacha20`), or null
  /// when SQLite was built without encryption support.
  ///
  /// This describes the library, not the file: an in-memory database
  /// reports a cipher too. `openSherpaDatabase` uses it to fail closed.
  Future<String?> cipherName() async {
    final rows = await customSelect('PRAGMA cipher').get();
    return cipherFromRows(rows.map((r) => r.data));
  }
}

final class _SchemaHistoryDatabase extends SherpaDatabase {
  _SchemaHistoryDatabase(
    super.executor, {
    required int schemaVersion,
    required Map<int, SchemaUpgrade> steps,
  })  : _version = schemaVersion,
        _history = steps;

  final int _version;
  final Map<int, SchemaUpgrade> _history;

  @override
  int get schemaVersion => _version;

  @override
  Map<int, SchemaUpgrade> get _steps => _history;
}
