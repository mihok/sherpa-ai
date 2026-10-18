import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/routing/routes.dart';
import 'package:sherpa/state/services.dart';

import '../support/harness.dart';

/// Every shell screen at the largest text size we support (2.0) on a small
/// phone, plus Android/iOS tap-target, labelling and text-contrast
/// guidelines. Layout overflow surfaces as a test failure.
void main() {
  const smallPhone = Size(360, 740);

  Future<Harness> seeded() async {
    final h = Harness(
      providers: [openAiConfig(), ollamaConfig()],
      keys: {'provider/openai/api_key': 'sk-x'},
      endpoints: {'api.openai.com': const FakeEndpoint(models: ['gpt-a', 'gpt-b'])},
      defaultModel: const ModelChoice(providerId: 'openai', modelId: 'gpt-a'),
    );
    await h.addSession('A rather long chat title that will need to be truncated', providerId: 'openai', modelId: 'gpt-a');
    await h.addSession('Yesterday', providerId: 'ollama', modelId: 'qwen3:8b', age: const Duration(days: 1));
    return h;
  }

  final routes = [
    Routes.home,
    Routes.settings,
    Routes.providers,
    Routes.newProvider,
    Routes.newProviderWithPreset('openai'),
    Routes.provider('openai'),
    Routes.privacy,
    Routes.about,
  ];

  for (final route in routes) {
    testWidgets('text scale 2.0 without overflow: $route', (tester) async {
      final h = await seeded();
      await pumpApp(tester, h, size: smallPhone, textScale: 2);
      await goTo(tester, route);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('text scale 2.0 without overflow: onboarding steps', (tester) async {
    final h = Harness(onboarded: false, endpoints: {'api.openai.com': const FakeEndpoint(models: ['gpt-a'])});
    await pumpApp(tester, h, size: smallPhone, textScale: 2);
    await tapText(tester, 'Get started');
    await tapText(tester, 'OpenAI');
    await tester.enterText(fieldLabeled('API key'), 'sk-test-000000');
    await tapText(tester, 'Connect');
    expect(find.text('Pick a model'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final route in [
    Routes.home,
    Routes.settings,
    Routes.providers,
    Routes.newProviderWithPreset('ollama'),
    Routes.privacy,
    Routes.about,
  ]) {
    testWidgets('tap targets, labels and contrast: $route', (tester) async {
      final handle = tester.ensureSemantics();
      final h = await seeded();
      await pumpApp(tester, h);
      await goTo(tester, route);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });
  }

  testWidgets('onboarding welcome meets the guidelines', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpApp(tester, Harness(onboarded: false));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    handle.dispose();
  });
}
