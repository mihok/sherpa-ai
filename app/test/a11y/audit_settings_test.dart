import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/app.dart';
import 'package:sherpa/bootstrap.dart' show noRetry;
import 'package:sherpa/features/diagnostics/app_error_ring.dart';
import 'package:sherpa/features/diagnostics/diagnostics_providers.dart';
import 'package:sherpa/features/diagnostics/diagnostics_screen.dart';
import 'package:sherpa/features/perf/state/perf_providers.dart';
import 'package:sherpa/routing/routes.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa/state/ui_preferences.dart';

import '../features/diagnostics/diagnostics_screen_test.dart' show FakeDiagnosticsShare;
import '../support/a11y_audit.dart';
import '../support/harness.dart';

// What textContrastGuideline misreads where it is skipped (the exact
// check still runs there; see auditScreen).
const _helperText = '12 px helper text at 1×: the most frequent dark pixel is an anti-aliasing shade';
const _shortWord = 'a short 16 px model name ("gpt-b"): too few solid glyph pixels at 1×';
const _clippedDialog = "a dialog's scrolling text at 2×: its box reaches past the dialog onto the dimmed page";
const _outlinedLabel = "an OutlinedButton's label: the outline's pixels outnumber the glyphs'";

/// M6 audit of Settings and the screens it opens: every one at phone and
/// tablet size, 1× and 2× text, light and dark (see [auditScreen]).
void main() {
  Harness seeded(AuditView view, {bool providers = true}) => Harness(
        providers: providers ? [openAiConfig(), ollamaConfig()] : const [],
        keys: providers ? {'provider/openai/api_key': 'sk-x'} : const {},
        endpoints: {'api.openai.com': const FakeEndpoint(models: ['gpt-a', 'gpt-b'])},
        defaultModel: providers ? const ModelChoice(providerId: 'openai', modelId: 'gpt-a') : null,
        ui: UiSettings(themeMode: view.themeMode),
      );

  AuditOpen route(String location, {bool providers = true}) => (tester, view) async {
        await pumpApp(tester, seeded(view, providers: providers), size: view.size, textScale: view.textScale);
        await goTo(tester, location);
      };

  auditScreen('settings', route(Routes.settings));
  auditScreen('settings, nothing set up', route(Routes.settings, providers: false));
  auditScreen('model providers', route(Routes.providers));
  auditScreen('model providers, empty', route(Routes.providers, providers: false));
  auditScreen('add a provider: presets', route(Routes.newProvider));
  auditScreen('add a provider: OpenAI form', route(Routes.newProviderWithPreset('openai')),
      pixelContrastSkip: {AuditView.tablet1x}, contrastNote: _helperText);
  auditScreen('add a provider: Ollama form', route(Routes.newProviderWithPreset('ollama')));
  auditScreen('add a provider: custom server (advanced open)', route(Routes.newProviderWithPreset('custom')));
  auditScreen('edit a provider with a saved key', route(Routes.provider('openai')),
      pixelContrastSkip: {AuditView.tablet1x}, contrastNote: _shortWord);
  auditScreen('provider not found', route(Routes.provider('gone')));
  auditScreen('privacy & data', route(Routes.privacy),
      pixelContrastSkip: {AuditView.phone1x, AuditView.tablet1x}, contrastNote: _helperText);
  auditScreen('privacy & data, nothing set up', route(Routes.privacy, providers: false),
      pixelContrastSkip: {AuditView.phone1x, AuditView.tablet1x}, contrastNote: _helperText);
  auditScreen('about', route(Routes.about));
  auditScreen('page not found', route('/no/such/page'));

  auditScreen('export my data dialog', (tester, view) async {
    await route(Routes.privacy)(tester, view);
    await tapText(tester, 'Export my data');
  }, pixelContrastSkip: {AuditView.phone2x}, contrastNote: _clippedDialog);
  auditScreen('delete all data dialog', (tester, view) async {
    await route(Routes.privacy)(tester, view);
    await tapText(tester, 'Delete all data');
  }, pixelContrastSkip: {AuditView.phone2x}, contrastNote: _clippedDialog);

  auditScreen('default model sheet', (tester, view) async {
    await route(Routes.settings)(tester, view);
    await tapText(tester, 'Default model');
  }, pixelContrastSkip: {AuditView.tablet1x}, contrastNote: _shortWord);

  auditScreen('remove provider dialog', (tester, view) async {
    await route(Routes.providers)(tester, view);
    await tester.tap(find.byTooltip('More for OpenAI'));
    await tester.pumpAndSettle();
    await tapText(tester, 'Remove');
  });

  auditScreen('diagnostics preview', (tester, view) async {
    final h = seeded(view);
    setAuditWindow(tester, view);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...h.overrides,
        diagnosticsShareProvider.overrideWithValue(FakeDiagnosticsShare()),
        appErrorRingProvider.overrideWithValue(AppErrorRing()..record(StateError('x'), source: 'flutter')),
        perfDeviceReaderProvider.overrideWithValue(() async => null),
        diagnosticsPrivatePathsProvider.overrideWithValue(() async => const []),
      ],
      retry: noRetry,
      child: const SherpaApp(),
    ));
    await tester.pumpAndSettle();
    await goTo(tester, Routes.about);
    await tapText(tester, DiagnosticsScreen.title);
  }, pixelContrastSkip: {AuditView.phone1x}, contrastNote: _outlinedLabel);
}
