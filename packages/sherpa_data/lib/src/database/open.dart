import 'dart:io';
import 'dart:math';

import 'package:drift/isolate.dart' show DriftRemoteException;
import 'package:drift/native.dart';
import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart' show SecretStore;
import 'package:sqlite3/common.dart';

import 'cipher.dart';
import 'database.dart';

/// Why the encrypted database was not opened.
enum EncryptionFailure {
  /// SQLite was built without SQLite3MultipleCiphers (`PRAGMA cipher` is
  /// empty). Almost always the `hooks.user_defines.sqlite3.source: sqlite3mc`
  /// block went missing from the workspace *root* pubspec (a member pubspec
  /// is silently ignored). Opening would write plaintext, so it is refused.
  cipherUnavailable,

  /// The key is not 64 hex characters (32 bytes).
  invalidKey,

  /// The key does not decrypt the file: a wrong key, a plaintext file, or a
  /// corrupt one. SQLite cannot tell these apart.
  ///
  /// Only the cipher's wrong-key signature counts: `SQLITE_NOTADB` ("file is
  /// not a database") on the first page read after `PRAGMA key`. Any other
  /// SQLite failure while opening (disk full, I/O error, busy or locked,
  /// out of memory, corruption detected after a successful decrypt) is a
  /// [DatabaseOpenException] instead, because the key and the file may be
  /// fine and resetting the database would discard the user's data.
  keyRejected,

  /// The database file exists but its key is gone from secure storage (for
  /// example a device-to-device backup restored the file but not the
  /// this-device-only key). The data is unrecoverable; the app has to offer
  /// a reset.
  keyMissing,

  /// Secure storage did not keep a newly generated key.
  keyNotPersisted,
}

/// Thrown instead of ever opening the database without encryption.
final class DatabaseEncryptionException implements Exception {
  const DatabaseEncryptionException(this.failure, this.message);

  final EncryptionFailure failure;

  /// Diagnostic detail. Never contains key material.
  final String message;

  @override
  String toString() => 'DatabaseEncryptionException(${failure.name}): $message';
}

/// SQLite failed to open the database for a reason other than the key: the
/// disk is full, an I/O error, another connection holds a lock, memory ran
/// out, the file is corrupt even though it decrypted, or it cannot be
/// opened at all (permissions, a missing directory).
///
/// Unlike [EncryptionFailure.keyRejected], nothing says the key or the data
/// are lost, so callers must not quarantine or reset the database: report
/// the failure and let the user retry (most causes clear up on their own,
/// see [isTransient]).
final class DatabaseOpenException implements Exception {
  const DatabaseOpenException({
    required this.resultCode,
    required this.extendedResultCode,
    required this.message,
  });

  /// From a [SqliteException]; [what] names the step that failed. Only the
  /// SQLite message is kept: the causing statement can be the key pragma.
  factory DatabaseOpenException.from(SqliteException e, String what) => DatabaseOpenException(
        resultCode: e.resultCode,
        extendedResultCode: e.extendedResultCode,
        message: '$what failed: ${e.message}${e.explanation == null ? '' : ' (${e.explanation})'}',
      );

  /// SQLite primary result code (`SQLITE_FULL`, `SQLITE_IOERR`, ...).
  final int resultCode;

  /// SQLite extended result code (e.g. `SQLITE_IOERR_SHMSIZE`).
  final int extendedResultCode;

  /// Diagnostic detail. Never contains key material.
  final String message;

  /// Whether the same open can succeed later without anyone touching the
  /// file: busy/locked, out of memory, disk full, I/O errors.
  bool get isTransient => const {
        SqlError.SQLITE_BUSY,
        SqlError.SQLITE_LOCKED,
        SqlError.SQLITE_NOMEM,
        SqlError.SQLITE_IOERR,
        SqlError.SQLITE_FULL,
        SqlError.SQLITE_CANTOPEN,
        SqlError.SQLITE_PROTOCOL,
        SqlError.SQLITE_INTERRUPT,
      }.contains(resultCode);

  @override
  String toString() => 'DatabaseOpenException(code $extendedResultCode): $message';
}

/// Name of the database key in the app's [SecretStore].
const String databaseKeySecretName = 'sherpa.database.key';

final RegExp _keyPattern = RegExp(r'^[0-9a-fA-F]{64}$');

/// Whether [key] has the shape [generateDatabaseKey] produces.
bool isValidDatabaseKey(String key) => _keyPattern.hasMatch(key);

/// A fresh database key: 32 bytes from [Random.secure], as 64 hex digits.
///
/// The key is random rather than derived from a user passphrase, so it is
/// used as raw key material and skips the cipher's KDF (see
/// [openSherpaDatabase]).
String generateDatabaseKey() {
  final random = Random.secure();
  final out = StringBuffer();
  for (var i = 0; i < 32; i++) {
    out.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

/// Reads the database key from [secrets], generating and storing one the
/// first time.
///
/// It never mints a new key while a database file exists at [databasePath]:
/// that file was encrypted with the lost key, so a new key could not open it
/// either, and the caller needs to know the data is gone
/// ([EncryptionFailure.keyMissing]) rather than see a misleading
/// [EncryptionFailure.keyRejected].
///
/// The app passes its Keychain/Keystore-backed [SecretStore]. Store the key
/// with `KeychainAccessibility.first_unlock_this_device` on iOS so
/// background work can open the database while the phone is locked and the
/// key never syncs to iCloud.
Future<String> loadOrCreateDatabaseKey(
  SecretStore secrets, {
  required String databasePath,
  String secretName = databaseKeySecretName,
}) async {
  final stored = await secrets.read(secretName);
  if (stored != null) {
    if (!isValidDatabaseKey(stored)) {
      throw const DatabaseEncryptionException(
        EncryptionFailure.invalidKey,
        'the stored database key is malformed',
      );
    }
    return stored;
  }
  if (File(databasePath).existsSync()) {
    throw const DatabaseEncryptionException(
      EncryptionFailure.keyMissing,
      'a database file exists but its key is not in secure storage',
    );
  }
  final key = generateDatabaseKey();
  await secrets.write(secretName, key);
  // A keystore that drops writes would otherwise strand the database we are
  // about to create: the next launch would find a file and no key.
  if (await secrets.read(secretName) != key) {
    throw const DatabaseEncryptionException(
      EncryptionFailure.keyNotPersisted,
      'secure storage did not keep the new database key',
    );
  }
  return key;
}

/// Opens (creating if needed) the encrypted Sherpa database at [path].
///
/// Encryption is SQLite3MultipleCiphers (default cipher ChaCha20-Poly1305),
/// selected at build time by the root pubspec's `hooks.user_defines`. The
/// call fails closed: if the cipher is unavailable, the [key] is malformed
/// or does not decrypt the file, it throws [DatabaseEncryptionException] and
/// never falls back to plaintext. Any other SQLite failure while opening
/// (disk full, I/O, locks, corruption) throws [DatabaseOpenException]. A
/// file written by a newer schema throws [SchemaDowngradeException].
///
/// With [background] (the default) SQLite runs on a drift background
/// isolate so queries never block the UI isolate.
///
/// Typical app wiring (the key lives in the Keychain/Keystore, the file in
/// the app-support directory):
///
/// ```dart
/// final path = p.join((await getApplicationSupportDirectory()).path, 'sherpa.db');
/// final key = await loadOrCreateDatabaseKey(secretStore, databasePath: path);
/// final db = await openSherpaDatabase(path: path, key: key);
/// final sessions = DriftSessionStore(db);
/// final documents = JsonDocumentStore(db);
/// ```
Future<SherpaDatabase> openSherpaDatabase({
  required String path,
  required String key,
  bool background = true,
}) async {
  final setup = encryptionSetup(key);
  final file = File(path);
  await file.parent.create(recursive: true);
  final db = SherpaDatabase(
    background
        ? NativeDatabase.createInBackground(file, setup: setup)
        : NativeDatabase(file, setup: setup),
  );
  try {
    // Drift opens lazily. Forcing the open here (setup, migrations,
    // beforeOpen) makes a bad key or a plaintext build fail at startup
    // rather than at some later write, and re-checks the cipher from this
    // side of the isolate boundary.
    if (await db.cipherName() == null) {
      throw const DatabaseEncryptionException(
        EncryptionFailure.cipherUnavailable,
        'SQLite reports no cipher after opening',
      );
    }
    return db;
  } catch (e, st) {
    try {
      await db.close();
    } catch (_) {
      // The open already failed; that error is the one worth reporting.
    }
    final typed = _typedOpenError(e);
    if (typed != null) Error.throwWithStackTrace(typed, st);
    rethrow;
  }
}

/// The drift `setup` callback that unlocks a database with [hexKey].
///
/// It runs in the database isolate before drift touches the file, and it
/// is self-contained (it captures only the key string) so drift can send it
/// to that isolate. Exposed for apps that build their own executor; such an
/// executor stays fail-closed because the callback itself throws.
void Function(CommonDatabase) encryptionSetup(String hexKey) {
  if (!isValidDatabaseKey(hexKey)) {
    throw const DatabaseEncryptionException(
      EncryptionFailure.invalidKey,
      'the database key must be 64 hex characters (32 bytes); see generateDatabaseKey()',
    );
  }
  return (CommonDatabase raw) {
    final String? cipher;
    try {
      // The x'…' form is raw key material: sqlite3mc uses the 32 bytes as the
      // cipher key directly instead of running them through PBKDF2 (64k
      // iterations by default for chacha20). A random key gains nothing from
      // stretching, every open gets cheaper, and there is no ambiguity about
      // how a passphrase string would be encoded. The pattern check above
      // guarantees the statement contains nothing but hex digits.
      raw.execute('PRAGMA key = "x\'$hexKey\'";');
      cipher = cipherFromRows(raw.select('PRAGMA cipher;'));
    } on SqliteException catch (e) {
      throw DatabaseOpenException.from(e, 'setting the database key');
    }
    if (cipher == null) {
      throw const DatabaseEncryptionException(
        EncryptionFailure.cipherUnavailable,
        'SQLite was built without SQLite3MultipleCiphers; put '
        '"hooks: user_defines: sqlite3: source: sqlite3mc" in the workspace root pubspec',
      );
    }
    try {
      // The key pragma itself always succeeds; the first page read is what
      // fails ("file is not a database") when the key is wrong.
      raw.select('SELECT count(*) FROM sqlite_schema;');
    } on SqliteException catch (e) {
      throw classifyOpenError(e, step: 'reading the first database page');
    }
  };
}

/// What a SQLite failure while opening the database means. Only
/// `SQLITE_NOTADB` is the cipher's wrong-key signature (sqlite3mc reports a
/// page that does not decrypt, or fails its MAC, as "file is not a
/// database"); everything else is about the file system, locks, memory or
/// a file that decrypted but is damaged, and must not be mistaken for a
/// lost key. [step] names what was being done, for the message.
@visibleForTesting
Exception classifyOpenError(SqliteException e, {String step = 'opening the database'}) {
  if (e.resultCode == SqlError.SQLITE_NOTADB) {
    return DatabaseEncryptionException(
      EncryptionFailure.keyRejected,
      'the key does not decrypt this database (${e.message})',
    );
  }
  return DatabaseOpenException.from(e, step);
}

/// Errors from the background isolate arrive wrapped in a
/// [DriftRemoteException], twice for migration errors (the migration
/// callbacks run back on this isolate at the server's request); callers
/// should see the typed cause.
Exception? _typedOpenError(Object error) {
  var cause = error;
  while (cause is DriftRemoteException) {
    cause = cause.remoteCause;
  }
  return switch (cause) {
    DatabaseEncryptionException() || DatabaseOpenException() || SchemaDowngradeException() => cause as Exception,
    SqliteException() => classifyOpenError(cause),
    _ => null,
  };
}
