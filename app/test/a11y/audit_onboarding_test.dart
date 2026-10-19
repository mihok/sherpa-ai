import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/state/ui_preferences.dart';
import 'package:sherpa_core/sherpa_core.dart' show ProviderErrorKind, ProviderException;
import 'package:sherpa_hub/sherpa_hub.dart' show CatalogModelDetails;

import '../features/models/support/models_rig.dart';
import '../features/onboarding/onboarding_on_device_test.dart' show settleUntil;
import '../support/a11y_audit.dart';
import '../support/harness.dart';

// textContrastGuideline at 1× on the connect step: "Connects to" sits next
// to the privacy badge's tinted pill, and the 12 px "Saved in …" note next
// to a green lock icon; their pixels outnumber the glyphs' in the sampled
// box. The exact check still runs there (see auditScreen).
const _connectNote = 'small text beside a tinted badge or an icon: their pixels win the sample at 1×';
const _oneX = {AuditView.phone1x, AuditView.tablet1x};

/// M6 audit of the first-run flow, every step (see [auditScreen]).
void main() {
  Harness fresh(AuditView view, {Map<String, FakeEndpoint> endpoints = const {}}) =>
      Harness(onboarded: false, endpoints: endpoints, ui: UiSettings(themeMode: view.themeMode));

  Future<Harness> start(WidgetTester tester, AuditView view, {Map<String, FakeEndpoint> endpoints = const {}}) async {
    final h = fresh(view, endpoints: endpoints);
    await pumpApp(tester, h, size: view.size, textScale: view.textScale);
    return h;
  }

  auditScreen('welcome', (tester, view) async => start(tester, view));

  auditScreen('where should your models run', (tester, view) async {
    await start(tester, view);
    await tapText(tester, 'Get started');
  });

  auditScreen('on-device teaser sheet', (tester, view) async {
    await start(tester, view);
    await tapText(tester, 'Get started');
    await tapText(tester, 'Local models (download)');
  });

  auditScreen('connect OpenAI', (tester, view) async {
    await start(tester, view);
    await tapText(tester, 'Get started');
    await tapText(tester, 'OpenAI');
  }, pixelContrastSkip: _oneX, contrastNote: _connectNote);

  auditScreen('connect Ollama (own network)', (tester, view) async {
    await start(tester, view);
    await tapText(tester, 'Get started');
    await tapText(tester, 'Ollama');
  }, pixelContrastSkip: _oneX, contrastNote: _connectNote);

  auditScreen('connect: key rejected', (tester, view) async {
    await start(tester, view, endpoints: {
      'api.anthropic.com': const FakeEndpoint(error: ProviderException(ProviderErrorKind.auth, '401 invalid x-api-key')),
    });
    await tapText(tester, 'Get started');
    await tapText(tester, 'Anthropic');
    await tester.enterText(fieldLabeled('API key'), 'sk-ant-wrong');
    await tapText(tester, 'Connect');
  }, pixelContrastSkip: _oneX, contrastNote: _connectNote);

  auditScreen('pick a model', (tester, view) async {
    await start(tester, view, endpoints: {'api.openai.com': const FakeEndpoint(models: ['gpt-a', 'gpt-b'])});
    await tapText(tester, 'Get started');
    await tapText(tester, 'OpenAI');
    await tester.enterText(fieldLabeled('API key'), 'sk-test-000000');
    await tapText(tester, 'Connect');
  });

  auditScreen('pick a model: none listed', (tester, view) async {
    await start(tester, view, endpoints: {'192.168.1.20': const FakeEndpoint()});
    await tapText(tester, 'Get started');
    await tapText(tester, 'Ollama');
    await tester.enterText(fieldLabeled('Server address'), 'http://192.168.1.20:11434/v1');
    await tapText(tester, 'This is a server on my own network');
    await tapText(tester, 'Connect');
  });

  Future<ModelsRig> onDevice(WidgetTester tester, AuditView view) async {
    final rig = await ModelsRig.create(tester, onboarded: false, mode: view.themeMode, details: <String, CatalogModelDetails>{});
    rig.catalog.detailsById[llama1b] = fixtureDetails(llama1b, [for (final f in rig.hub.files.values) f.listing]);
    await rig.pump(tester, size: view.size, textScale: view.textScale);
    await tapText(tester, 'Get started');
    return rig;
  }

  auditScreen('where should your models run (on-device wired)', (tester, view) async => onDevice(tester, view));

  auditScreen('run a model on this phone', (tester, view) async {
    await onDevice(tester, view);
    await tapText(tester, 'Run a model on this phone');
    await settleUntil(tester, () => find.text('Finding a model that fits this phone…').evaluate().isEmpty, what: 'the pick');
  });
}
