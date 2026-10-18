import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/routing/routes.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../support/harness.dart';

void main() {
  testWidgets('a LAN URL is refused until "my own network" is ticked', (tester) async {
    final h = Harness();
    await pumpApp(tester, h);
    await goTo(tester, Routes.newProviderWithPreset('ollama'));
    expect(find.text('Add Ollama'), findsOneWidget);

    await tester.enterText(fieldLabeled('Server address'), 'http://192.168.1.20:11434/v1');
    await tester.pump();
    expect(find.textContaining('Tick "This is a server on my own network"'), findsOneWidget);
    await tapText(tester, 'Save', index: 1);
    expect(h.registry.configs, isEmpty);

    await tapText(tester, 'This is a server on my own network');
    expect(find.textContaining('Tick "This is a server'), findsNothing);
    expect(findBadge('192.168.1.20:11434', location: ExecutionLocation.localNetwork), findsOneWidget,
        reason: 'live privacy preview');
    await tapText(tester, 'Save', index: 1);

    final saved = h.registry.configs.single;
    expect(saved.allowLocalNetwork, isTrue);
    expect(saved.baseUrl.toString(), 'http://192.168.1.20:11434/v1');
    expect(find.text('Model providers'), findsOneWidget, reason: 'returns to the list');
  });

  testWidgets('credential-looking headers are rejected and point to the key field', (tester) async {
    final h = Harness();
    await pumpApp(tester, h);
    await goTo(tester, Routes.newProviderWithPreset('openai'));
    await tester.enterText(fieldLabeled('API key'), 'sk-real-key-0000');

    await tapText(tester, 'Advanced');
    await tapText(tester, 'Add header');
    await tester.enterText(fieldLabeled('Header name'), 'Authorization');
    await tester.enterText(fieldLabeled('Value'), 'Bearer sk-abc');
    await tester.pump();
    expect(find.textContaining('This looks like a credential. Put it in the api key field'), findsOneWidget);
    expect(find.textContaining('This looks like a key'), findsOneWidget);

    await tapText(tester, 'Save', index: 1);
    expect(h.registry.configs, isEmpty, reason: 'invalid headers block saving');

    await tester.enterText(fieldLabeled('Header name'), 'OpenAI-Organization');
    await tester.enterText(fieldLabeled('Value'), 'org-123');
    await tester.pump();
    await tapText(tester, 'Save', index: 1);
    final saved = h.registry.configs.single;
    expect(saved.headers, {'OpenAI-Organization': 'org-123'});
    expect(await h.secrets.read(saved.secretKey), 'sk-real-key-0000');
  });

  testWidgets('a saved key shows where it is kept, never its value', (tester) async {
    final h = Harness(providers: [openAiConfig()], keys: {'provider/openai/api_key': 'sk-secret-value'});
    await pumpApp(tester, h);
    await goTo(tester, Routes.provider('openai'));
    expect(find.text('Saved in Android Keystore'), findsOneWidget);
    expect(find.textContaining('sk-secret'), findsNothing);
    expect(find.text('Replace'), findsOneWidget);

    await tapText(tester, 'Remove');
    expect(find.textContaining('will be deleted when you save'), findsOneWidget);
    await tapText(tester, 'Save', index: 1);
    // OpenAI requires a key, so removing it without a new one is refused.
    expect(find.text('Paste your api key to continue.'), findsOneWidget);
    expect(await h.secrets.read('provider/openai/api_key'), 'sk-secret-value');
  });

  testWidgets('testing a new provider then discarding it leaves nothing behind', (tester) async {
    final h = Harness(endpoints: {'api.openai.com': const FakeEndpoint(models: ['gpt-a'])});
    await pumpApp(tester, h);
    await goTo(tester, Routes.providers);
    await goTo(tester, Routes.newProviderWithPreset('openai'));
    await tester.enterText(fieldLabeled('API key'), 'sk-test-000000');
    await tapText(tester, 'Test connection');
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('gpt-a'), findsOneWidget, reason: 'model picker appears after a good test');
    expect(h.registry.configs, hasLength(1), reason: 'saved provisionally to probe');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tapText(tester, 'Discard');
    expect(h.registry.configs, isEmpty);
    expect(await h.secrets.keys(prefix: 'provider/'), isEmpty);
  });

  testWidgets('providers list: status, privacy badge, swipe to delete with confirm', (tester) async {
    final h = Harness(
      providers: [openAiConfig(), ollamaConfig()],
      endpoints: {
        'api.openai.com': const FakeEndpoint(models: ['gpt-a']),
        '192.168.1.20': const FakeEndpoint(),
      },
    );
    await pumpApp(tester, h);
    await goTo(tester, Routes.providers);
    expect(findBadge('api.openai.com', location: ExecutionLocation.remote), findsOneWidget);
    expect(findBadge('192.168.1.20:11434', location: ExecutionLocation.localNetwork), findsOneWidget);
    expect(find.text('Connected'), findsNWidgets(2));

    await tester.drag(find.text('OpenAI'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('Remove OpenAI?'), findsOneWidget);
    await tapText(tester, 'Cancel');
    expect(h.registry.configs, hasLength(2));

    await tester.drag(find.text('OpenAI'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    await tapText(tester, 'Remove');
    expect(h.registry.configs.map((c) => c.id), ['ollama']);
    expect(find.text('OpenAI'), findsNothing);
  });
}
