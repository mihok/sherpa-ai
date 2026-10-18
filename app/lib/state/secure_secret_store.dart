import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sherpa_core/sherpa_core.dart';

/// [SecretStore] on the iOS Keychain / Android Keystore.
///
/// Choices, and why:
/// - `first_unlock_this_device`: readable after the first unlock following a
///   reboot, so background work (downloads, resumed runs) can still open the
///   encrypted DB and call providers while the phone is locked; `this_device`
///   keeps keys out of iCloud Keychain sync and device-to-device migration.
/// - `synchronizable: false`: same reason, stated explicitly.
/// - Android `storageNamespace`: isolates Sherpa's entries from anything else
///   a plugin might write to the default shared-preferences file.
/// - Android `resetOnError: false`: the plugin's default silently wipes ALL
///   entries when one fails to decrypt. That would destroy the database key
///   along with API keys; we'd rather surface the error.
///
/// Values are never logged. [keys] has to use `readAll` (the plugin has no
/// key-only listing), so values are briefly in memory and then dropped.
final class SecureSecretStore implements SecretStore {
  SecureSecretStore({FlutterSecureStorage? storage}) : _storage = storage ?? defaultStorage;

  static const FlutterSecureStorage defaultStorage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
    aOptions: AndroidOptions(storageNamespace: 'sherpa_secrets', resetOnError: false),
  );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<List<String>> keys({String prefix = ''}) async {
    final all = await _storage.readAll();
    return all.keys.where((k) => k.startsWith(prefix)).toList()..sort();
  }
}
