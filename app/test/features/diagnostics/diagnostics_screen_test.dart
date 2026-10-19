import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/app.dart';
import 'package:sherpa/bootstrap.dart' show noRetry;
import 'package:sherpa/features/diagnostics/app_error_ring.dart';
import 'package:sherpa/features/diagnostics/diagnostics_providers.dart';
import 'package:sherpa/features/diagnostics/diagnostics_screen.dart';
import 'package:sherpa/features/perf/state/perf_providers.dart';
import 'package:sherpa/routing/routes.dart';
import 'package:sherpa/state/services.dart';

import '../../support/harness.dart';

/// Records what would have gone to the share sheet and the clipboard.
final class FakeDiagnosticsShare implements DiagnosticsShare {
  final List<({String name, Uint8List bytes, String subject})> shared = [];
  final List<String> copied = [];
  bool failShare = false;

  @override
  Future<void> shareFile({required String name, required Uint8List bytes, required String subject}) async {
    if (failShare) throw StateError('no share sheet');
    shared.add((name: name, bytes: bytes, subject: subject));
  }

  @override
  Future<void> copyText(String text) async => copied.add(text);
}

void main() {
  const apiKey = 'sk-proj-WIDGETSEEDkey0123456789';
  const chat = 'WIDGETCHATSEED what I told the model';

  late FakeDiagnosticsShare share;
  late AppErrorRing ring;

  Future<Harness> pumpAbout(WidgetTester tester, {Size size = phone, double textScale = 1}) async {
    share = FakeDiagnosticsShare();
    ring = AppErrorRing()..record(StateError('x'), source: 'flutter');
    final h = Harness(
      providers: [openAiConfig()],
      keys: {'provider/openai/api_key': apiKey},
      endpoints: {'api.openai.com': const FakeEndpoint(models: ['gpt-a'])},
      defaultModel: const ModelChoice(providerId: 'openai', modelId: 'gpt-a'),
    );
    await h.addSession(chat, providerId: 'openai', modelId: 'gpt-a');
    setWindow(tester, size, textScale: textScale);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...h.overrides,
        diagnosticsShareProvider.overrideWithValue(share),
        appErrorRingProvider.overrideWithValue(ring),
        perfDeviceReaderProvider.overrideWithValue(() async => null),
        diagnosticsPrivatePathsProvider.overrideWithValue(() async => const []),
      ],
      retry: noRetry,
      child: const SherpaApp(),
    ));
    await tester.pumpAndSettle();
    await goTo(tester, Routes.about);
    return h;
  }

  Future<void> openPreview(WidgetTester tester) async {
    await tapText(tester, DiagnosticsScreen.title);
    expect(find.byType(DiagnosticsScreen), findsOneWidget);
  }

  testWidgets('About › Export diagnostics previews everything before sharing', (tester) async {
    await pumpAbout(tester);
    await openPreview(tester);

    expect(find.text('This is everything that will be shared'), findsOneWidget);
    expect(find.text('Summary'), findsOneWidget);
    expect(find.textContaining('Model providers (1)'), findsOneWidget, reason: 'the summary is shown');
    expect(find.textContaining('api.openai.com'), findsWidgets);
    for (final label in [
      'Everything in the file',
      'App',
      'Device',
      'Model providers',
      'Tool servers',
      'Recent errors (types and codes only)',
    ]) {
      await tester.scrollUntilVisible(find.text(label), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text(label), findsOneWidget);
    }
    // Nothing went anywhere yet.
    expect(share.shared, isEmpty);
    expect(share.copied, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Share hands the redacted JSON file to the share sheet', (tester) async {
    await pumpAbout(tester);
    await openPreview(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Share'));
    await tester.pumpAndSettle();

    final sent = share.shared.single;
    expect(sent.name, matches(RegExp(r'^sherpa-diagnostics-\d{4}-\d{2}-\d{2}-\d{4}\.json$')));
    expect(sent.subject, 'Sherpa diagnostics');
    final text = utf8.decode(sent.bytes);
    final json = jsonDecode(text) as Map<String, Object?>;
    expect(json['format'], 'sherpa.diagnostics');
    expect((json['data']! as Map)['chats'], 1);
    expect(((json['errors']! as Map)['recent']! as List).single, containsPair('type', 'StateError'));
    expect(((json['providers']! as List).single as Map)['apiKeySet'], isTrue);
    expect(text, isNot(contains(apiKey)));
    expect(text, isNot(contains('WIDGETSEED')));
    expect(text, isNot(contains(chat)));
    expect(text, isNot(contains('WIDGETCHATSEED')));
  });

  testWidgets('Copy summary copies the readable text and says so', (tester) async {
    await pumpAbout(tester);
    await openPreview(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Copy summary'));
    await tester.pump();
    expect(find.text('Summary copied.'), findsOneWidget);
    final copied = share.copied.single;
    expect(copied, startsWith('Sherpa diagnostics'));
    expect(copied, contains('1 chat (0 archived)'));
    expect(copied, isNot(contains(apiKey)));
    expect(copied, isNot(contains('WIDGETCHATSEED')));
    expect(share.shared, isEmpty, reason: 'copying shares nothing');
  });

  testWidgets('a share sheet that fails says nothing was shared', (tester) async {
    await pumpAbout(tester);
    share.failShare = true;
    await openPreview(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Share'));
    await tester.pump();
    expect(find.text("Couldn't open the share sheet. Nothing was shared."), findsOneWidget);
  });

  testWidgets('the preview meets the tap-target, label and contrast guidelines', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpAbout(tester);
    await openPreview(tester);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    handle.dispose();
  });

  testWidgets('the preview lays out at text scale 2.0 on a small phone', (tester) async {
    await pumpAbout(tester, size: const Size(360, 740), textScale: 2);
    await openPreview(tester);
    await tester.scrollUntilVisible(find.text('File name'), 300, scrollable: find.byType(Scrollable).first);
    expect(tester.takeException(), isNull);
  });
}
