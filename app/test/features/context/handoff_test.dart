import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sherpa/features/context/handoff/handoff_codec.dart';
import 'package:sherpa/features/context/handoff/handoff_service.dart';
import 'package:sherpa_core/sherpa_core.dart';

import 'support/context_harness.dart';

const String kApiKey = 'sk-ant-api03-Zx9Qw8Er7Ty6Ui5Op4As3Df2';

/// Text gzip can't shrink much (a QR code must hold it compressed).
String noise(int chars, {int seed = 1}) {
  final r = Random(seed);
  const abc = 'abcdefghijklmnopqrstuvwxyz';
  final b = StringBuffer();
  while (b.length < chars) {
    final n = 3 + r.nextInt(7);
    for (var i = 0; i < n; i++) {
      b.write(abc[r.nextInt(abc.length)]);
    }
    b.write(' ');
  }
  return b.toString();
}

void main() {
  late ContextHarness h;
  tearDown(() => h.dispose());

  ListTile tile(WidgetTester tester, String title) =>
      tester.widget<ListTile>(find.ancestor(of: find.text(title), matching: find.byType(ListTile)));

  group('Hand off…', () {
    testWidgets('build → review → start a new chat here seeds it with the handoff', (tester) async {
      h = ContextHarness();
      await h.seedConversation(turns: 3, resultLines: 10);
      await h.open();
      await pumpContext(tester, h, location: '/chat/$kSession/handoff');

      expect(find.text('What will be sent'), findsOneWidget);
      expect(find.text('Size'), findsOneWidget);
      expect(find.text('Compressed'), findsOneWidget);
      expect(find.textContaining('API keys and tokens are removed automatically'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('What it contains'), 300, scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('Handoff: Step 1'), findsOneWidget, reason: 'the toMarkdown review');

      await tester.scrollUntilVisible(find.text('Start a new chat here'), -300, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Start a new chat here'));
      await settle(tester);

      final created = (await h.store.listSessions()).firstWhere((s) => s.id != kSession);
      expect(created.handoffFromSessionId, kSession);
      expect(created.providerId, kProviderId);
      expect(created.modelId, kModelId);
      final path = await h.store.path(created.id, created.activeLeafId!);
      expect(path.first.kind, MessageKind.handoff);
      expect(path.first.pinned, isTrue);
      expect(path.first.text, contains('Task: Step 1: read the next log'));
      expect(path.first.text, contains('Never email customers.'));
      expect(path.last.role, Role.assistant);
      expect(find.text('chat:${created.id}'), findsOneWidget, reason: 'opened the new chat');
    });

    testWidgets('Share writes a .sherpa-handoff.json that parses and holds no secrets', (tester) async {
      h = ContextHarness();
      await h.createSession();
      await h.addTurn(1, userText: 'Deploy with key $kApiKey and password=hunter2hunter2, then report.');
      await h.open();
      await pumpContext(tester, h, location: '/chat/$kSession/handoff');
      await tester.ensureVisible(find.text('Share'));
      await tester.pump();
      await tester.tap(find.text('Share'));
      await settle(tester);

      final file = h.platform.shared.single;
      expect(file.name, endsWith(HandoffCodec.fileSuffix));
      expect(file.mimeType, 'application/json');
      final text = utf8.decode(file.bytes);
      expect(text, isNot(contains(kApiKey)));
      expect(text, isNot(contains('hunter2hunter2')));
      expect(text, contains('«redacted»'));
      final bundle = HandoffBundle.parse(text);
      expect(bundle.task, contains('Deploy with key'));

      await tester.ensureVisible(find.text('Save to Files'));
      await tester.pump();
      await tester.tap(find.text('Save to Files'));
      await settle(tester);
      expect(h.platform.saved.single, file.name);
    });

    testWidgets('a note for the next chat travels with the bundle, scrubbed and importable', (tester) async {
      h = ContextHarness();
      await h.seedConversation(turns: 2, resultLines: 10);
      await h.open();
      await pumpContext(tester, h, location: '/chat/$kSession/handoff');
      await tester.scrollUntilVisible(find.byType(TextField), 300, scrollable: find.byType(Scrollable).first);
      // A bidi control in the note must not make the file unimportable.
      await tester.enterText(find.byType(TextField), 'Use the staging token $kApiKey from now on.\u202E');
      await settle(tester);
      await tester.scrollUntilVisible(find.text('Share'), -300, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Share'));
      await settle(tester);
      final bundle = HandoffBundle.parse(utf8.decode(h.platform.shared.single.bytes));
      expect(bundle.notes, 'Use the staging token «redacted» from now on.');
    });
  });

  group('QR codes', () {
    testWidgets('a small handoff can be shown as a QR code', (tester) async {
      h = ContextHarness();
      await h.createSession();
      await h.addTurn(1, resultLines: 3);
      await h.open();
      await pumpContext(tester, h, location: '/chat/$kSession/handoff');
      expect(tile(tester, 'Show QR code').enabled, isTrue);
      expect(find.textContaining('For a phone nearby'), findsOneWidget);
      await tester.ensureVisible(find.text('Show QR code'));
      await tester.pump();
      await tester.tap(find.text('Show QR code'));
      await settle(tester);
      expect(find.text('Scan to continue'), findsOneWidget);
      final qr = tester.widget<QrImageView>(find.byType(QrImageView));
      expect(qr.errorCorrectionLevel, QrErrorCorrectLevel.L);
      expect(qr.semanticsLabel, startsWith('QR code with the handoff'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a large handoff explains why there is no QR code', (tester) async {
      h = ContextHarness();
      await h.createSession();
      for (var n = 1; n <= 3; n++) {
        await h.addTurn(n, userText: 'Notes $n: ${noise(1800, seed: n)}');
      }
      await h.open();
      await pumpContext(tester, h, location: '/chat/$kSession/handoff');
      expect(tile(tester, 'Show QR code').enabled, isFalse);
      expect(find.textContaining('Too large for a QR code'), findsOneWidget);
      expect(find.textContaining('Share the file instead'), findsOneWidget);
    });

    test('the payload round-trips and the capacity is the real QR limit', () async {
      h = ContextHarness();
      await h.seedConversation(turns: 2, resultLines: 10);
      final bundle = await HandoffService(store: h.store, registry: h.registry, clock: h.clock, ids: h.ids)
          .build(sessionId: kSession);
      final payload = HandoffCodec.qrPayload(bundle);
      expect(payload, startsWith(HandoffCodec.qrPrefix));
      expect(RegExp(r'^[A-Za-z0-9_:\-]+$').hasMatch(payload), isTrue, reason: 'QR byte mode, nothing to escape');
      expect(HandoffCodec.parseText(payload).encode(), bundle.encode());
      expect(HandoffCodec.fitsQr(payload), isTrue);

      // 2,953 bytes is what a version-40, level-L code holds in byte mode.
      expect(
        () => QrImage(QrCode.fromData(data: 'x' * HandoffCodec.qrCapacityBytes, errorCorrectLevel: QrErrorCorrectLevel.L)),
        returnsNormally,
      );
      expect(
        () => QrImage(
          QrCode.fromData(data: 'x' * (HandoffCodec.qrCapacityBytes + 1), errorCorrectLevel: QrErrorCorrectLevel.L),
        ),
        throwsA(isA<InputTooLongException>()),
      );
      expect(HandoffCodec.fitsQr('${HandoffCodec.qrPrefix}${'a' * HandoffCodec.qrCapacityBytes}'), isFalse);
    });
  });

  testWidgets('handoff review and import are usable at 2x text', (tester) async {
    h = ContextHarness();
    await h.seedConversation(turns: 2, resultLines: 10);
    await h.open();
    final semantics = tester.ensureSemantics();
    await pumpContext(tester, h, location: '/chat/$kSession/handoff', textScale: 2.0);
    expect(tester.takeException(), isNull);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await pumpContext(tester, h, location: '/handoff/import', textScale: 2.0);
    expect(tester.takeException(), isNull);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    semantics.dispose();
  });
}
