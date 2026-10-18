import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/state/secure_secret_store.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('round-trips, deletes and lists keys by prefix', () async {
    final store = SecureSecretStore();
    await store.write('provider/openai/api_key', 'sk-test');
    await store.write('provider/ollama/api_key', 'x');
    await store.write('db/key', 'k');
    expect(await store.read('provider/openai/api_key'), 'sk-test');
    expect(await store.keys(prefix: 'provider/'), ['provider/ollama/api_key', 'provider/openai/api_key']);
    expect(await store.keys(), hasLength(3));
    await store.delete('provider/openai/api_key');
    expect(await store.read('provider/openai/api_key'), isNull);
  });

  test('keys never sync and stay readable after first unlock', () {
    final ios = SecureSecretStore.defaultStorage.iOptions;
    expect(ios.toMap()['accessibility'], KeychainAccessibility.first_unlock_this_device.name);
    expect(ios.toMap()['synchronizable'], 'false');
    final android = SecureSecretStore.defaultStorage.aOptions.toMap();
    expect(android['resetOnError'], 'false', reason: 'a decrypt error must not wipe the DB key');
  });
}
