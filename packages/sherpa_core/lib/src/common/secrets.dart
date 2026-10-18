/// Where API keys and OAuth tokens live. The app implements it with the
/// Keychain / Android Keystore (flutter_secure_storage); nothing else in
/// Sherpa may persist a secret.
abstract interface class SecretStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);

  /// Keys under [prefix], for cleanup when a provider or server is removed.
  Future<List<String>> keys({String prefix = ''});
}

/// Volatile [SecretStore] for tests and evals.
final class InMemorySecretStore implements SecretStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<List<String>> keys({String prefix = ''}) async =>
      _values.keys.where((k) => k.startsWith(prefix)).toList()..sort();
}
