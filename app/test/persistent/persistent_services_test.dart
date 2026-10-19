import 'dart:convert';
import 'dart:io' show InternetAddress;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sherpa/state/persistent/preferences_store.dart';
import 'package:sherpa/state/persistent/provider_registry.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_data/sherpa_data.dart';
import 'package:sherpa_net/sherpa_net.dart' show UrlPolicyViolation;
import 'package:sherpa_providers/sherpa_providers.dart';

void main() {
  late SherpaDatabase db;
  late JsonDocumentStore docs;
  late InMemorySecretStore secrets;

  setUp(() {
    db = SherpaDatabase.inMemory();
    docs = JsonDocumentStore(db);
    secrets = InMemorySecretStore();
  });
  tearDown(() => db.close());

  final anthropic = ProviderConfig(
    id: 'a1',
    flavor: ApiFlavor.anthropic,
    displayName: 'Anthropic',
    baseUrl: Uri.parse('https://api.anthropic.com'),
  );

  http.Client modelsClient({int status = 200}) => MockClient((req) async {
        if (status != 200) return http.Response('{"error":{"type":"authentication_error","message":"bad"}}', status);
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'claude-sonnet-5-5', 'display_name': 'Claude Sonnet 5.5', 'max_input_tokens': 200000, 'max_tokens': 64000},
            ],
            'has_more': false,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

  test('configs persist without secrets; keys go to the secret store', () async {
    final reg = DocumentProviderRegistry(documents: docs, secrets: secrets, client: modelsClient());
    await reg.add(anthropic, apiKey: ' sk-ant-secret ');
    expect(await reg.hasApiKey('a1'), isTrue);
    expect(await secrets.read(anthropic.secretKey), 'sk-ant-secret');
    final stored = await docs.get(DocumentCollections.providerConfigs, 'a1');
    expect(jsonEncode(stored), isNot(contains('sk-ant')));

    final reloaded = DocumentProviderRegistry(documents: docs, secrets: secrets, client: modelsClient());
    await reloaded.load();
    expect(reloaded.configs.single.displayName, 'Anthropic');
  });

  test('probe maps outcomes and remove deletes the key', () async {
    final ok = DocumentProviderRegistry(documents: docs, secrets: secrets, client: modelsClient());
    await ok.add(anthropic, apiKey: 'k');
    expect(await ok.probe('a1'), EndpointStatus.ok);
    expect((await ok.models('a1')).map((m) => m.id), contains('claude-sonnet-5-5'));

    final denied = DocumentProviderRegistry(documents: docs, secrets: secrets, client: modelsClient(status: 401));
    await denied.load();
    expect(await denied.probe('a1'), EndpointStatus.unauthorized);

    await ok.remove('a1');
    expect(await secrets.read(anthropic.secretKey), isNull);
    expect(await docs.get(DocumentCollections.providerConfigs, 'a1'), isNull);
  });

  test('update can clear the key and emits changes', () async {
    final reg = DocumentProviderRegistry(documents: docs, secrets: secrets, client: modelsClient());
    final emitted = <int>[];
    reg.changes.listen((c) => emitted.add(c.length));
    await reg.add(anthropic, apiKey: 'k');
    await reg.update(anthropic.copyWith(displayName: 'Work'), clearApiKey: true);
    await Future<void>.delayed(Duration.zero);
    expect(await reg.hasApiKey('a1'), isFalse);
    expect(reg.configs.single.displayName, 'Work');
    expect(emitted, [1, 1]);
  });

  test('saving refuses plain http to a host that resolves to a public address (finding 23)', () async {
    Future<List<InternetAddress>> dns(String host) async =>
        host == 'studio.local' ? [InternetAddress('192.168.1.30')] : [InternetAddress('104.18.32.47')];
    final reg = DocumentProviderRegistry(documents: docs, secrets: secrets, client: modelsClient(), resolver: dns);
    final groq = ProviderConfig(
      id: 'g',
      flavor: ApiFlavor.openAiChat,
      displayName: 'Groq',
      baseUrl: Uri.parse('http://api.groq.com/openai/v1'),
      allowLocalNetwork: true,
    );
    await expectLater(reg.add(groq, apiKey: 'gsk_secret'), throwsA(isA<UrlPolicyViolation>()));
    expect(reg.configs, isEmpty);
    expect(await docs.get(DocumentCollections.providerConfigs, 'g'), isNull);
    expect(await secrets.read(groq.secretKey), isNull, reason: 'the key is not stored either');

    final lan = ProviderConfig(
      id: 'l',
      flavor: ApiFlavor.openAiChat,
      displayName: 'LM Studio',
      baseUrl: Uri.parse('http://studio.local:1234/v1'),
      allowLocalNetwork: true,
    );
    await reg.add(lan);
    expect(reg.configs.single.id, 'l');
    // Editing a saved LAN provider to point at a public host is refused too.
    await expectLater(
      reg.update(lan.copyWith(baseUrl: Uri.parse('http://api.groq.com/v1'))),
      throwsA(isA<UrlPolicyViolation>()),
    );
    expect(reg.configs.single.baseUrl.host, 'studio.local');
  });

  test('preferences round-trip through the database', () async {
    final prefs = DocumentPreferencesStore(docs);
    await prefs.load();
    expect(prefs.onboardingComplete, isFalse);
    await prefs.setDefaultModel(const ModelChoice(providerId: 'a1', modelId: 'm'));
    await prefs.setOnboardingComplete(true);
    final again = DocumentPreferencesStore(docs);
    await again.load();
    expect(again.defaultModel, const ModelChoice(providerId: 'a1', modelId: 'm'));
    expect(again.onboardingComplete, isTrue);
    await again.setDefaultModel(null);
    expect(again.defaultModel, isNull);
  });
}
