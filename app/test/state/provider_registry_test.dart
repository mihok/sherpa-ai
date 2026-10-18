import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/state/in_memory/in_memory_provider_registry.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../support/harness.dart';

void main() {
  InMemoryProviderRegistry registry(InMemorySecretStore secrets, Map<String, FakeEndpoint> endpoints) =>
      InMemoryProviderRegistry(
        secrets: secrets,
        factory: (c, key) => FakeModelProvider(c, endpoints[c.baseUrl.host] ?? const FakeEndpoint(), key),
      );

  test('keys go to the secret store, never into the config', () async {
    final secrets = InMemorySecretStore();
    final r = registry(secrets, {});
    final c = await r.add(openAiConfig(), apiKey: '  sk-abc  ');
    expect(await secrets.read(c.secretKey), 'sk-abc');
    expect(c.toJson().toString(), isNot(contains('sk-abc')));
    expect(await r.hasApiKey(c.id), isTrue);
    await r.update(c, clearApiKey: true);
    expect(await r.hasApiKey(c.id), isFalse);
  });

  test('remove deletes every secret under the provider prefix', () async {
    final secrets = InMemorySecretStore();
    final r = registry(secrets, {});
    await r.add(openAiConfig(), apiKey: 'sk');
    await secrets.write('provider/openai/oauth_refresh', 'r');
    await secrets.write('provider/other/api_key', 'keep');
    await r.remove('openai');
    expect(r.configs, isEmpty);
    expect(await secrets.keys(prefix: 'provider/openai/'), isEmpty);
    expect(await secrets.read('provider/other/api_key'), 'keep');
  });

  test('probe maps failures to statuses the UI can explain', () async {
    final r = registry(InMemorySecretStore(), {
      'ok.example.com': const FakeEndpoint(models: ['m1']),
      'auth.example.com': const FakeEndpoint(error: ProviderException(ProviderErrorKind.auth, '401')),
      'down.example.com': const FakeEndpoint(error: ProviderException(ProviderErrorKind.network, 'refused')),
      'odd.example.com': const FakeEndpoint(error: ProviderException(ProviderErrorKind.invalidRequest, '404')),
    });
    Future<EndpointStatus> probe(String host) async {
      final c = openAiConfig(id: host).copyWith(baseUrl: Uri.parse('https://$host/v1'));
      await r.add(c);
      return r.probe(c.id);
    }

    expect(await probe('ok.example.com'), EndpointStatus.ok);
    expect(await probe('auth.example.com'), EndpointStatus.unauthorized);
    expect(await probe('down.example.com'), EndpointStatus.unreachable);
    expect(await probe('odd.example.com'), EndpointStatus.error);
    expect(await r.probe('missing'), EndpointStatus.unknown);
    expect((await r.models('ok.example.com')).single.id, 'm1');
  });

  test('changes emit after every mutation', () async {
    final r = registry(InMemorySecretStore(), {});
    final emitted = <int>[];
    final sub = r.changes.listen((l) => emitted.add(l.length));
    await r.add(openAiConfig());
    await r.add(ollamaConfig());
    await r.remove('openai');
    await Future<void>.delayed(Duration.zero);
    expect(emitted, [1, 2, 1]);
    await sub.cancel();
  });
}
