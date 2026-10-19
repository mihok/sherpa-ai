import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/design/haptics.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';

import '../../support/harness.dart';
import '../../support/url_policy_registry.dart';

Finder field(String label) => fieldLabeled(label);

void main() {
  testWidgets('happy path: welcome → OpenAI → key → model → first chat', (tester) async {
    final h = Harness(
      onboarded: false,
      endpoints: {'api.openai.com': const FakeEndpoint(models: ['gpt-a', 'gpt-b'])},
    );
    await pumpApp(tester, h);

    expect(find.text('Meet Sherpa'), findsOneWidget);
    await tapText(tester, 'Get started');

    expect(find.text('Where should your models run?'), findsOneWidget);
    expect(find.text('Local models (download)'), findsOneWidget);
    await tapText(tester, 'OpenAI');

    expect(find.text('Connect OpenAI'), findsOneWidget);
    expect(find.textContaining('platform.openai.com'), findsOneWidget, reason: 'where to get a key, as text');
    final keyField = tester.widget<TextField>(field('API key'));
    expect(keyField.obscureText, isTrue);
    expect(keyField.autocorrect, isFalse);
    expect(keyField.enableSuggestions, isFalse);

    await tester.enterText(field('API key'), 'sk-test-123456789');
    await tapText(tester, 'Connect');

    expect(find.text('Pick a model'), findsOneWidget);
    expect(h.haptics.calls, contains(HapticKind.success));
    await tapText(tester, 'gpt-b');
    await tapText(tester, 'Start chatting');

    // Landed in the chat, with everything persisted.
    final session = (await h.store.listSessions()).single;
    expect(find.text('chat:${session.id}'), findsOneWidget);
    expect(session.title, defaultSessionTitle);
    expect(session.modelId, 'gpt-b');
    expect(h.prefs.onboardingComplete, isTrue);
    expect(h.prefs.defaultModel, const ModelChoice(providerId: 'openai', modelId: 'gpt-b'));
    expect(h.registry.configs.single.defaultModelId, 'gpt-b');
    expect(await h.secrets.read('provider/openai/api_key'), 'sk-test-123456789');
    expect(h.apiKeysSeen['openai'], 'sk-test-123456789');
  });

  testWidgets('a rejected key explains itself and the retry updates the same provider', (tester) async {
    final endpoints = {
      'api.anthropic.com': const FakeEndpoint(error: ProviderException(ProviderErrorKind.auth, '401 invalid x-api-key')),
    };
    final h = Harness(onboarded: false, endpoints: endpoints);
    await pumpApp(tester, h);
    await tapText(tester, 'Get started');
    await tapText(tester, 'Anthropic');

    await tapText(tester, 'Connect');
    expect(find.text('Paste your api key to continue.'), findsOneWidget, reason: 'key is required');
    expect(h.registry.configs, isEmpty);

    await tester.enterText(field('API key'), 'sk-ant-wrong');
    await tapText(tester, 'Connect');
    expect(find.text('Key not accepted'), findsOneWidget);
    expect(h.haptics.calls, contains(HapticKind.error));
    expect(h.registry.configs, hasLength(1));

    endpoints['api.anthropic.com'] = const FakeEndpoint(models: ['claude-x']);
    await tester.enterText(field('API key (optional)'), 'sk-ant-right');
    await tapText(tester, 'Connect');
    expect(find.text('Pick a model'), findsOneWidget);
    expect(h.registry.configs, hasLength(1), reason: 'retry must not duplicate the provider');
    expect(await h.secrets.read('provider/anthropic/api_key'), 'sk-ant-right');
  });

  testWidgets('a LAN server needs the explicit "my own network" opt-in', (tester) async {
    final h = Harness(
      onboarded: false,
      endpoints: {'192.168.1.20': const FakeEndpoint(models: ['qwen3:8b'])},
    );
    await pumpApp(tester, h);
    await tapText(tester, 'Get started');
    await tapText(tester, 'Ollama');

    await tester.enterText(field('Server address'), 'http://192.168.1.20:11434/v1');
    await tapText(tester, 'Connect');
    expect(find.textContaining('Tick "This is a server on my own network"'), findsOneWidget);
    expect(h.registry.configs, isEmpty);

    await tapText(tester, 'This is a server on my own network');
    await tapText(tester, 'Connect');
    expect(find.text('Pick a model'), findsOneWidget);
    // A single model is preselected; one tap to start.
    await tapText(tester, 'Start chatting');
    expect(h.registry.configs.single.allowLocalNetwork, isTrue);
    expect(h.prefs.defaultModel?.modelId, 'qwen3:8b');
  });

  testWidgets('a plain-http name that resolves publicly is refused before the key is stored', (tester) async {
    final h = Harness(onboarded: false); // fake DNS: unknown names are public
    await pumpApp(tester, h);
    await tapText(tester, 'Get started');
    await tapText(tester, 'Ollama');
    await tester.enterText(fieldLabeled('Server address'), 'http://ollama.myvps.example.com:11434/v1');
    await tapText(tester, 'This is a server on my own network');
    await tapText(tester, 'Connect');
    expect(find.text('This is a public internet address. Use https:// so your messages are encrypted on the way.'),
        findsOneWidget);
    expect(find.text('Pick a model'), findsNothing);
    expect(h.registry.configs, isEmpty);
    expect(h.haptics.calls, contains(HapticKind.error));
  });

  testWidgets("the registry's own URL refusal is shown under the address", (tester) async {
    final h = Harness(
      onboarded: false,
      wrapRegistry: (inner) => RefusingRegistry(
        inner,
        const UrlPolicyViolation('http://192.168.1.20:11434/v1', 'linkLocal address 169.254.1.1 is not allowed'),
      ),
    );
    await pumpApp(tester, h);
    await tapText(tester, 'Get started');
    await tapText(tester, 'Ollama');
    await tester.enterText(fieldLabeled('Server address'), 'http://192.168.1.20:11434/v1');
    await tapText(tester, 'This is a server on my own network');
    await tapText(tester, 'Connect');
    expect(find.text("Sherpa won't connect to link-local or reserved addresses."), findsOneWidget);
    expect(find.text('Pick a model'), findsNothing);
  });

  testWidgets('back steps through the flow instead of leaving it', (tester) async {
    final h = Harness(onboarded: false);
    await pumpApp(tester, h);
    await tapText(tester, 'Get started');
    await tapText(tester, 'OpenAI');
    expect(find.text('Connect OpenAI'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Where should your models run?'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Meet Sherpa'), findsOneWidget);
  });

  testWidgets('"Skip for now" never dead-ends', (tester) async {
    final h = Harness(onboarded: false);
    await pumpApp(tester, h);
    await tapText(tester, 'Skip for now');
    expect(h.prefs.onboardingComplete, isTrue);
    expect(find.text('Connect a model to start'), findsOneWidget);
  });

  testWidgets('the local-models card explains and offers a working alternative', (tester) async {
    final h = Harness(onboarded: false);
    await pumpApp(tester, h);
    await tapText(tester, 'Get started');
    await tapText(tester, 'Local models (download)');
    expect(find.text('On-device models are next'), findsOneWidget);
    await tapText(tester, 'Use a server on my network');
    expect(find.text('Connect Ollama'), findsOneWidget);
  });

  testWidgets('"Run setup again" from settings returns to settings on back', (tester) async {
    final h = Harness();
    await pumpApp(tester, h);
    await goTo(tester, '/settings');
    await tapText(tester, 'Run setup again');
    expect(find.text('Meet Sherpa'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    // Back on the settings page (still scrolled to where the row was).
    expect(find.text('Meet Sherpa'), findsNothing);
    expect(find.text('Run setup again'), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
  });
}
