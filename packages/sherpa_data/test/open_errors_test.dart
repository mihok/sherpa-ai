import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sherpa_data/sherpa_data.dart';
import 'package:sherpa_data/src/database/open.dart' show classifyOpenError;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/harnesses.dart' show tempDir;

/// Finding 24: only the cipher's wrong-key signature may count as
/// [EncryptionFailure.keyRejected], because the app quarantines (and
/// replaces) a database whose key was rejected.
void main() {
  Matcher openFailure(int code) => isA<DatabaseOpenException>().having((e) => e.resultCode, 'resultCode', code);

  group('classifyOpenError', () {
    SqliteException err(int extended, String message) =>
        SqliteException(extendedResultCode: extended, message: message);

    test('SQLITE_NOTADB is the wrong-key signature', () {
      expect(
        classifyOpenError(err(SqlError.SQLITE_NOTADB, 'file is not a database')),
        isA<DatabaseEncryptionException>().having((e) => e.failure, 'failure', EncryptionFailure.keyRejected),
      );
    });

    test('disk full, I/O, busy, locked, out of memory and corruption are not', () {
      const shmSize = SqlError.SQLITE_IOERR | (19 << 8); // SQLITE_IOERR_SHMSIZE
      final cases = {
        SqlError.SQLITE_FULL: 'database or disk is full',
        shmSize: 'disk I/O error',
        SqlError.SQLITE_BUSY: 'database is locked',
        SqlError.SQLITE_LOCKED: 'database table is locked',
        SqlError.SQLITE_NOMEM: 'out of memory',
        SqlError.SQLITE_CORRUPT: 'database disk image is malformed',
        SqlError.SQLITE_CANTOPEN: 'unable to open database file',
      };
      for (final c in cases.entries) {
        final e = classifyOpenError(err(c.key, c.value));
        expect(e, isA<DatabaseOpenException>(), reason: c.value);
        e as DatabaseOpenException;
        expect(e.extendedResultCode, c.key);
        expect(e.message, contains(c.value));
      }
      expect((classifyOpenError(err(shmSize, 'disk I/O error')) as DatabaseOpenException).resultCode,
          SqlError.SQLITE_IOERR);
      expect((classifyOpenError(err(SqlError.SQLITE_FULL, 'full')) as DatabaseOpenException).isTransient, isTrue);
      expect((classifyOpenError(err(SqlError.SQLITE_CORRUPT, 'bad')) as DatabaseOpenException).isTransient, isFalse);
    });
  });

  group('openSherpaDatabase', () {
    late Directory dir;
    late String path;
    late String key;

    setUp(() async {
      dir = await tempDir();
      path = p.join(dir.path, 'sherpa.db');
      key = generateDatabaseKey();
      final db = await openSherpaDatabase(path: path, key: key);
      await db.close();
    });
    tearDown(() => dir.delete(recursive: true));

    for (final background in [true, false]) {
      final mode = background ? 'background isolate' : 'same isolate';
      test('the right key on a locked file is a DatabaseOpenException, not keyRejected ($mode)', () async {
        // Another connection holds an exclusive lock with the right key.
        final other = sqlite3.open(path)
          ..execute('PRAGMA key = "x\'$key\'";')
          ..execute('PRAGMA locking_mode = EXCLUSIVE;')
          ..execute('BEGIN EXCLUSIVE;');
        try {
          await expectLater(
            openSherpaDatabase(path: path, key: key, background: background),
            throwsA(openFailure(SqlError.SQLITE_BUSY)),
          );
        } finally {
          other
            ..execute('COMMIT;')
            ..close();
        }
        // Nothing was lost: the same key opens the file once the lock is gone.
        final db = await openSherpaDatabase(path: path, key: key, background: background);
        await db.close();
      });
    }

    test('a wrong key is still keyRejected', () async {
      await expectLater(
        openSherpaDatabase(path: path, key: generateDatabaseKey()),
        throwsA(isA<DatabaseEncryptionException>().having((e) => e.failure, 'failure', EncryptionFailure.keyRejected)),
      );
    });

    test('the error never echoes the key', () async {
      final other = sqlite3.open(path)
        ..execute('PRAGMA key = "x\'$key\'";')
        ..execute('PRAGMA locking_mode = EXCLUSIVE;')
        ..execute('BEGIN EXCLUSIVE;');
      try {
        await openSherpaDatabase(path: path, key: key);
        fail('opened a locked database');
      } on DatabaseOpenException catch (e) {
        expect(e.toString(), isNot(contains(key)));
      } finally {
        other
          ..execute('COMMIT;')
          ..close();
      }
    });
  });
}
