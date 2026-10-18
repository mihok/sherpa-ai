@Tags(['golden'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/design/theme.dart';
import 'package:sherpa/design/widgets/privacy_badge.dart';
import 'package:sherpa/design/widgets/section_header.dart';
import 'package:sherpa/design/widgets/state_views.dart';
import 'package:sherpa/features/providers/status_chip.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa/state/ui_preferences.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../support/golden_fonts.dart';
import '../support/harness.dart';

/// Pixel goldens for the shell, light and dark, phone and tablet.
///
/// Rendered by flutter_test's software Skia with Roboto + Material Icons
/// loaded from the pinned SDK (see flutter_test_config.dart), so they are
/// only stable on the pinned Linux CI image. Regenerate there with
/// `flutter test --tags golden --update-goldens`.
void main() {
  final skip = goldenFontsLoaded ? null : 'golden fonts unavailable';

  Future<Harness> seeded(ThemeMode mode) async {
    final h = Harness(
      providers: [openAiConfig(), ollamaConfig()],
      defaultModel: const ModelChoice(providerId: 'openai', modelId: 'gpt-5.2'),
      ui: UiSettings(themeMode: mode),
    );
    await h.addSession('Weekend in Porto', providerId: 'openai', modelId: 'gpt-5.2', age: const Duration(minutes: 4));
    await h.addSession('Refactor the SSE parser', providerId: 'ollama', modelId: 'qwen3-coder:30b',
        age: const Duration(hours: 3));
    await h.addSession('Explain KV cache quantization', providerId: 'ollama', modelId: 'qwen3:8b',
        age: const Duration(days: 1, hours: 2));
    await h.addSession('Draft: landlord email', providerId: 'openai', modelId: 'gpt-5.2-mini',
        age: const Duration(days: 4));
    return h;
  }

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    final name = mode.name;

    testWidgets('home compact $name', (tester) async {
      await pumpApp(tester, await seeded(mode), size: const Size(400, 860));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/home_compact_$name.png'));
    }, skip: skip != null);

    testWidgets('home expanded $name', (tester) async {
      final h = await seeded(mode);
      await pumpApp(tester, h, size: const Size(1200, 800));
      await tapText(tester, 'Weekend in Porto');
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/home_expanded_$name.png'));
    }, skip: skip != null);

    testWidgets('onboarding welcome $name', (tester) async {
      await pumpApp(tester, Harness(onboarded: false, ui: UiSettings(themeMode: mode)), size: const Size(400, 860));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/onboarding_welcome_$name.png'));
    }, skip: skip != null);

    testWidgets('onboarding choose expanded $name', (tester) async {
      await pumpApp(tester, Harness(onboarded: false, ui: UiSettings(themeMode: mode)), size: const Size(1200, 800));
      await tapText(tester, 'Get started');
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/onboarding_choose_expanded_$name.png'));
    }, skip: skip != null);

    testWidgets('privacy compact $name', (tester) async {
      await pumpApp(tester, await seeded(mode), size: const Size(400, 860));
      await goTo(tester, '/settings/privacy');
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/privacy_compact_$name.png'));
    }, skip: skip != null);

    testWidgets('components $name', (tester) async {
      setWindow(tester, const Size(420, 760));
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: mode == ThemeMode.light ? SherpaTheme.light() : SherpaTheme.dark(),
        home: const _ComponentSheet(),
      ));
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/components_$name.png'));
    }, skip: skip != null);
  }
}

class _ComponentSheet extends StatelessWidget {
  const _ComponentSheet();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const SectionHeader('Privacy badges', padding: EdgeInsets.only(bottom: 8)),
              const Wrap(spacing: 8, runSpacing: 8, children: [
                PrivacyBadge(location: ExecutionLocation.onDevice),
                PrivacyBadge(location: ExecutionLocation.localNetwork, host: '192.168.1.20:11434'),
                PrivacyBadge(location: ExecutionLocation.remote, host: 'api.openai.com'),
                PrivacyBadge(location: ExecutionLocation.remote, host: 'api.anthropic.com', size: PrivacyBadgeSize.compact),
              ]),
              const SectionHeader('Status', padding: EdgeInsets.only(top: 24, bottom: 8)),
              const Wrap(spacing: 8, runSpacing: 8, children: [
                EndpointStatusChip(status: EndpointStatus.ok),
                EndpointStatusChip(status: EndpointStatus.unauthorized),
                EndpointStatusChip(status: EndpointStatus.unreachable),
                EndpointStatusChip(status: EndpointStatus.error),
                EndpointStatusChip(status: EndpointStatus.unknown, checking: true),
              ]),
              const SectionHeader('Buttons', padding: EdgeInsets.only(top: 24, bottom: 8)),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton(onPressed: () {}, child: const Text('Connect')),
                OutlinedButton(onPressed: () {}, child: const Text('Test connection')),
                TextButton(onPressed: () {}, child: const Text('Skip')),
              ]),
              const SizedBox(height: 16),
              const TextField(decoration: InputDecoration(labelText: 'Server address', hintText: 'https://')),
              const SizedBox(height: 8),
              const TextField(decoration: InputDecoration(labelText: 'API key', errorText: 'Key not accepted')),
              const SizedBox(height: 300, child: OfflineState()),
            ],
          ),
        ),
      );
}
