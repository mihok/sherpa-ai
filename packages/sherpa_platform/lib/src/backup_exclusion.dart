import 'backend.dart';

/// Keeps files out of device backups.
///
/// The encrypted database's key is device-only (`first_unlock_this_device`),
/// so a backed-up copy is undecryptable elsewhere: backing it up only leaks
/// ciphertext and wastes the quota.
///
/// - **iOS**: sets `URLResourceValues.isExcludedFromBackup` on [exclude]'s
///   path and, by default, its SQLite sidecars (`-wal`, `-shm`, `-journal`)
///   that exist. The flag lives on the file, and Apple notes some operations
///   reset it, so call this after every database open (it is idempotent and
///   cheap). Excluding the containing directory instead covers sidecars
///   created later.
/// - **Android**: a no-op that returns `[]`. The app's
///   `res/xml/data_extraction_rules.xml` (API 31+, cloud backup and
///   device-to-device transfer) and `res/xml/backup_rules.xml` (API ≤ 30)
///   exclude `sherpa.db*` in `filesDir`; rules XML is the only mechanism that
///   also covers device-to-device transfer.
abstract final class BackupExclusion {
  /// Returns the paths that were flagged (empty on Android and for missing
  /// files).
  static Future<List<String>> exclude(String path, {bool includeSqliteSidecars = true, PlatformBackend? backend}) =>
      (backend ?? SherpaPlatform.backend).excludeFromBackup(path, includeSqliteSidecars: includeSqliteSidecars);
}
