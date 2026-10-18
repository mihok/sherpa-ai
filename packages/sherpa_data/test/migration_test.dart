import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_data/sherpa_data.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';
import 'support/harnesses.dart';

// Migration scaffold. Schema v1 is the only version so far; the tests below
// pin down how a v1 file opens, that newer files are refused, and that the
// step machinery behaves (run in order, atomically, versioned) using a
// made-up history. When v2 lands, follow the checklist on SherpaDatabase
// and add a "v1 fixture → v2" test here next to the drift-generated ones.

Future<int> userVersion(SherpaDatabase db) async =>
    (await db.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version');

void main() {
  late Directory dir;
  late String path;
  late String key;

  setUp(() async {
    dir = await tempDir();
    path = p.join(dir.path, 'sherpa.db');
    key = generateDatabaseKey();
  });
  tearDown(() => dir.delete(recursive: true));

  /// Runs [body] on the encrypted file with raw sqlite3, outside drift.
  T raw<T>(T Function(Database db) body) {
    final db = sqlite3.open(path);
    try {
      db.execute("PRAGMA key = 'raw:$key';");
      return body(db);
    } finally {
      db.close();
    }
  }

  Future<void> createV1WithData() async {
    final db = await openSherpaDatabase(path: path, key: key);
    final store = DriftSessionStore(db);
    await store.putSession(session('s1'));
    await store.putMessage('s1', msg('m1'));
    await store.putMessage('s1', msg('m2', parent: 'm1', t: 1));
    await db.close();
  }

  SherpaDatabase withHistory(int version, Map<int, SchemaUpgrade> steps) => SherpaDatabase.withSchemaHistory(
        NativeDatabase(File(path), setup: encryptionSetup(key)),
        schemaVersion: version,
        steps: steps,
      );

  test('a fresh database is created at the current version with the expected schema', () async {
    final db = await openSherpaDatabase(path: path, key: key);
    expect(await userVersion(db), SherpaDatabase.currentSchemaVersion);
    final entities = {
      for (final r in await db
          .customSelect("SELECT type, name FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'")
          .get())
        '${r.read<String>('type')}:${r.read<String>('name')}',
    };
    expect(entities, {
      'table:sessions',
      'table:messages',
      'table:overlays',
      'table:plans',
      'table:checkpoints',
      'table:audit',
      'table:documents',
      'index:sessions_updated_idx',
      'index:messages_parent_idx',
      'index:messages_session_created_idx',
      'index:overlays_session_created_idx',
      'index:audit_session_at_idx',
      'trigger:audit_append_only',
    });
    // Compares the live schema with a freshly created reference, column
    // constraints included.
    await db.validateDatabaseSchema();
    await db.close();
  });

  test('the schema snapshot for the current version is committed', () {
    // `dart run drift_dev make-migrations` writes it; without it no future
    // migration can be tested against this version.
    final snapshot = File('drift_schemas/sherpa/drift_schema_v${SherpaDatabase.currentSchemaVersion}.json');
    expect(snapshot.existsSync(), isTrue, reason: 'run `dart run drift_dev make-migrations`');
  });

  test('an existing v1 file reopens with its data (onCreate is not re-run)', () async {
    await createV1WithData();
    final db = await openSherpaDatabase(path: path, key: key);
    expect(await userVersion(db), 1);
    expect([for (final m in await DriftSessionStore(db).path('s1', 'm2')) m.id], ['m1', 'm2']);
    await db.close();
  });

  for (final background in [true, false]) {
    test('a file from a newer schema is refused and left untouched (background: $background)', () async {
      await createV1WithData();
      raw((db) => db.execute('PRAGMA user_version = 2;'));
      await expectLater(
        openSherpaDatabase(path: path, key: key, background: background),
        throwsA(isA<SchemaDowngradeException>()
            .having((e) => e.fileVersion, 'fileVersion', 2)
            .having((e) => e.appVersion, 'appVersion', 1)),
      );
      expect(raw((db) => db.userVersion), 2);
      expect(raw((db) => db.select('SELECT count(*) AS n FROM messages').single['n']), 2);
    });
  }

  test('pending steps run in order in one go and set the version', () async {
    await createV1WithData();
    final ran = <int>[];
    final db = withHistory(3, {
      1: (m, db) async {
        ran.add(1);
        await db.customStatement('ALTER TABLE sessions ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0');
      },
      2: (m, db) async {
        ran.add(2);
        await m.createIndex(Index('sessions_pinned_idx', 'CREATE INDEX sessions_pinned_idx ON sessions (pinned)'));
      },
    });
    expect(await userVersion(db), 3);
    expect(ran, [1, 2]);
    final info = await db.customSelect('PRAGMA table_info(sessions)').get();
    final columns = [for (final r in info) r.read<String>('name')];
    expect(columns, contains('pinned'));
    expect(
      await db.customSelect("SELECT name FROM sqlite_schema WHERE name = 'sessions_pinned_idx'").get(),
      hasLength(1),
    );
    // Data survived and beforeOpen still ran after the upgrade.
    expect(await DriftSessionStore(db).path('s1', 'm2'), hasLength(2));
    expect((await db.customSelect('PRAGMA foreign_keys').getSingle()).read<int>('foreign_keys'), 1);
    await db.close();
  });

  test('a failing step rolls the whole upgrade back, so the next launch can retry', () async {
    await createV1WithData();
    final db = withHistory(3, {
      1: (m, db) => db.customStatement('ALTER TABLE sessions ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0'),
      2: (m, db) => throw StateError('step 2 failed'),
    });
    await expectLater(db.customSelect('SELECT 1').get(), throwsStateError);
    await db.close();

    expect(raw((db) => db.userVersion), 1);
    final columns = raw((db) => [for (final r in db.select('PRAGMA table_info(sessions)')) r['name']]);
    expect(columns, isNot(contains('pinned')), reason: 'step 1 must have been rolled back');

    // A fixed build then upgrades the untouched v1 file normally.
    final fixed = withHistory(2, {
      1: (m, db) => db.customStatement('ALTER TABLE sessions ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0'),
    });
    expect(await userVersion(fixed), 2);
    await fixed.close();
  });

  test('a gap in the history refuses to open and leaves the file at its version', () async {
    await createV1WithData();
    final db = withHistory(2, const {});
    await expectLater(
      db.customSelect('SELECT 1').get(),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('v1 to v2'))),
    );
    await db.close();
    expect(raw((db) => db.userVersion), 1);
  });

  test('a migration that breaks a foreign key is rolled back', () async {
    await createV1WithData();
    final db = withHistory(2, {
      // Runs with foreign keys off (as real table rebuilds must), so only
      // the post-step foreign_key_check can catch this orphan.
      1: (m, db) => db.customStatement("DELETE FROM sessions WHERE id = 's1'"),
    });
    await expectLater(
      db.customSelect('SELECT 1').get(),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('foreign key'))),
    );
    await db.close();
    expect(raw((db) => db.userVersion), 1);
    expect(raw((db) => db.select('SELECT count(*) AS n FROM sessions').single['n']), 1);
  });
}
