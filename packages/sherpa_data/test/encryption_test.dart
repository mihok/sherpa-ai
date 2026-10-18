import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_data/sherpa_data.dart';
import 'package:sherpa_data/src/database/cipher.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';
import 'support/harnesses.dart';

const marker = 'TOP-SECRET-MARKER-7f3a9c41';

/// The 16-byte header of every plaintext SQLite database file.
final List<int> plaintextHeader = ascii.encode('SQLite format 3\u0000');

Matcher encryptionFailure(EncryptionFailure failure) =>
    isA<DatabaseEncryptionException>().having((e) => e.failure, 'failure', failure);

bool containsMarker(File f) => latin1.decode(f.readAsBytesSync()).contains(marker);

Future<void> writeSecret(SherpaDatabase db) async {
  final store = DriftSessionStore(db);
  await store.putSession(session('s1', title: 'title $marker'));
  await store.putMessage('s1', msg('m1', text: 'body $marker'));
  await JsonDocumentStore(db).put(DocumentCollections.preferences, 'app', {'note': marker});
}

Future<void> expectSecretReadable(SherpaDatabase db) async {
  final store = DriftSessionStore(db);
  expect((await store.getSession('s1'))?.title, 'title $marker');
  expect((await store.getMessage('s1', 'm1'))?.text, 'body $marker');
}

void main() {
  late Directory dir;
  late String path;
  late String key;

  setUp(() async {
    dir = await tempDir();
    path = p.join(dir.path, 'nested', 'sherpa.db');
    key = generateDatabaseKey();
  });
  tearDown(() => dir.delete(recursive: true));

  group('at rest', () {
    test('the file has no SQLite header and no plaintext, the WAL neither', () async {
      final db = await openSherpaDatabase(path: path, key: key);
      await writeSecret(db);
      // Before close the rows live in the write-ahead log only.
      final wal = File('$path-wal');
      expect(wal.existsSync(), isTrue);
      expect(wal.lengthSync(), greaterThan(0));
      expect(containsMarker(wal), isFalse);
      await db.close();

      final bytes = File(path).readAsBytesSync();
      expect(bytes.length, greaterThan(plaintextHeader.length));
      expect(bytes.sublist(0, 16), isNot(plaintextHeader));
      expect(containsMarker(File(path)), isFalse);
    });

    test('control: the same scan does see a plaintext SQLite file', () {
      // Guards the test above against passing vacuously.
      final plain = sqlite3.open(path.replaceFirst('nested', ''));
      plain.execute("CREATE TABLE t(x TEXT); INSERT INTO t VALUES ('$marker');");
      plain.close();
      final file = File(path.replaceFirst('nested', ''));
      expect(file.readAsBytesSync().sublist(0, 16), plaintextHeader);
      expect(containsMarker(file), isTrue);
    });
  });

  group('keys', () {
    for (final background in [true, false]) {
      final mode = background ? 'background isolate' : 'same isolate';

      test('the right key reopens with the data intact ($mode)', () async {
        var db = await openSherpaDatabase(path: path, key: key, background: background);
        await writeSecret(db);
        await db.close();
        db = await openSherpaDatabase(path: path, key: key, background: background);
        await expectSecretReadable(db);
        await db.close();
      });

      test('a wrong key fails closed with keyRejected ($mode)', () async {
        final db = await openSherpaDatabase(path: path, key: key, background: background);
        await writeSecret(db);
        await db.close();
        final before = File(path).readAsBytesSync();

        await expectLater(
          openSherpaDatabase(path: path, key: generateDatabaseKey(), background: background),
          throwsA(encryptionFailure(EncryptionFailure.keyRejected)),
        );
        // The failed attempt neither damaged nor rewrote the file.
        expect(File(path).readAsBytesSync(), before);
        final again = await openSherpaDatabase(path: path, key: key, background: background);
        await expectSecretReadable(again);
        await again.close();
      });
    }

    test('an existing plaintext database is refused, never used or rewritten', () async {
      File(path).parent.createSync(recursive: true);
      final plain = sqlite3.open(path);
      plain.execute("CREATE TABLE t(x TEXT); INSERT INTO t VALUES ('$marker');");
      plain.close();
      final before = File(path).readAsBytesSync();

      await expectLater(
        openSherpaDatabase(path: path, key: key),
        throwsA(encryptionFailure(EncryptionFailure.keyRejected)),
      );
      expect(File(path).readAsBytesSync(), before);
    });

    test('a malformed key is refused before the file is touched', () async {
      for (final bad in ['', 'abc', 'g' * 64, '${key}00', key.substring(1), 'x\'$key\'']) {
        await expectLater(
          openSherpaDatabase(path: path, key: bad),
          throwsA(encryptionFailure(EncryptionFailure.invalidKey)),
        );
      }
      expect(File(path).existsSync(), isFalse);
    });

    test('errors never echo the key', () async {
      final db = await openSherpaDatabase(path: path, key: key);
      await db.close();
      final wrong = generateDatabaseKey();
      try {
        await openSherpaDatabase(path: path, key: wrong);
        fail('opened with a wrong key');
      } on DatabaseEncryptionException catch (e) {
        expect(e.toString(), isNot(contains(wrong)));
        expect(e.toString(), isNot(contains(key)));
      }
    });

    test("the key is raw key material: x'…' equals raw:…, and differs from a passphrase", () async {
      final db = await openSherpaDatabase(path: path, key: key);
      await writeSecret(db);
      await db.close();

      String? titleWith(String keyPragma) {
        final raw = sqlite3.open(path);
        try {
          raw.execute(keyPragma);
          return raw.select("SELECT title FROM sessions WHERE id = 's1'").single['title'] as String;
        } on SqliteException {
          return null;
        } finally {
          raw.close();
        }
      }

      expect(titleWith("PRAGMA key = 'raw:$key';"), 'title $marker');
      expect(titleWith('PRAGMA key = "x\'$key\'";'), 'title $marker');
      // The same hex digits as a passphrase go through the KDF and yield a
      // different key: proof that the x'…' form really bypassed it.
      expect(titleWith("PRAGMA key = '$key';"), isNull);
      expect(titleWith('SELECT 1;'), isNull);
    });

    test('generateDatabaseKey yields 32 random bytes as 64 hex digits', () {
      final keys = {for (var i = 0; i < 64; i++) generateDatabaseKey()};
      expect(keys, hasLength(64));
      for (final k in keys) {
        expect(k, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(isValidDatabaseKey(k), isTrue);
      }
      expect(isValidDatabaseKey(key.toUpperCase()), isTrue);
      expect(isValidDatabaseKey('${key}0'), isFalse);
    });
  });

  group('cipher', () {
    test('PRAGMA cipher reports sqlite3mc (ChaCha20-Poly1305 by default)', () async {
      final db = await openSherpaDatabase(path: path, key: key);
      expect(await db.cipherName(), 'chacha20');
      final raw = sqlite3.openInMemory();
      expect(raw.select('PRAGMA cipher').single.values.single, 'chacha20');
      raw.close();
      await db.close();
    });

    test('an empty PRAGMA cipher answer (plain SQLite build) means no cipher', () {
      // This is the decision behind EncryptionFailure.cipherUnavailable. The
      // bundled library cannot be swapped in-process (sqlite3 binds through
      // @Native assets), so the plain-SQLite case is pinned down here.
      expect(cipherFromRows(const []), isNull);
      expect(cipherFromRows(const [{}]), isNull);
      expect(cipherFromRows(const [
        {'cipher': ''},
      ]), isNull);
      expect(cipherFromRows(const [
        {'cipher': null},
      ]), isNull);
      expect(cipherFromRows(const [
        {'chacha20': 'chacha20'},
      ]), 'chacha20');
      expect(cipherFromRows(const [
        {'cipher': ' sqlcipher '},
      ]), 'sqlcipher');
    });
  });

  group('loadOrCreateDatabaseKey', () {
    test('creates, stores and then keeps returning one key', () async {
      final secrets = InMemorySecretStore();
      final first = await loadOrCreateDatabaseKey(secrets, databasePath: path);
      expect(isValidDatabaseKey(first), isTrue);
      expect(await secrets.read(databaseKeySecretName), first);

      final db = await openSherpaDatabase(path: path, key: first);
      await db.close();
      expect(await loadOrCreateDatabaseKey(secrets, databasePath: path), first);
    });

    test('never mints a new key over an existing database file', () async {
      final db = await openSherpaDatabase(path: path, key: key);
      await db.close();
      final secrets = InMemorySecretStore();
      await expectLater(
        loadOrCreateDatabaseKey(secrets, databasePath: path),
        throwsA(encryptionFailure(EncryptionFailure.keyMissing)),
      );
      expect(await secrets.read(databaseKeySecretName), isNull);
    });

    test('rejects a malformed stored key', () async {
      final secrets = InMemorySecretStore();
      await secrets.write(databaseKeySecretName, 'not-a-key');
      await expectLater(
        loadOrCreateDatabaseKey(secrets, databasePath: path),
        throwsA(encryptionFailure(EncryptionFailure.invalidKey)),
      );
    });

    test('detects a secure store that silently drops writes', () async {
      await expectLater(
        loadOrCreateDatabaseKey(_ForgetfulSecretStore(), databasePath: path),
        throwsA(encryptionFailure(EncryptionFailure.keyNotPersisted)),
      );
    });

    test('honours a custom secret name', () async {
      final secrets = InMemorySecretStore();
      final k = await loadOrCreateDatabaseKey(secrets, databasePath: path, secretName: 'custom');
      expect(await secrets.read('custom'), k);
      expect(await secrets.read(databaseKeySecretName), isNull);
    });
  });
}

final class _ForgetfulSecretStore implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}

  @override
  Future<List<String>> keys({String prefix = ''}) async => const [];
}
