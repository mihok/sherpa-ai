import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/chat/attachments/attachment_policy.dart';
import 'package:sherpa/features/chat/attachments/attachment_store.dart';
import 'package:sherpa/features/chat/attachments/composer_attachments.dart';
import 'package:sherpa/features/chat/attachments/image_prep.dart';
import 'package:sherpa/features/chat/attachments/inlining_provider.dart';
import 'package:sherpa/features/chat/state/chat_controller.dart';
import 'package:sherpa/features/chat/state/transcript_model.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';

import 'support/harness.dart';
import 'support/pump.dart';

/// 400×300 stored pixels with EXIF orientation 6 (shown as 300×400), a
/// red block in the stored top-left corner, and EXIF GPS (Lisbon), camera
/// make/model and a timestamp. Made with Pillow.
Uint8List _fixture() => File('test/features/chat/fixtures/gps_rotated.jpg').readAsBytesSync();

bool _contains(Uint8List hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

bool _reddish(img.Pixel p) => p.r > 180 && p.g < 110 && p.b < 110;

final Uint8List _pdf = Uint8List.fromList(utf8.encode('%PDF-1.4\n1 0 obj << >> endobj\ntrailer << >>\n%%EOF\n'));

const _vision = ModelCapabilities(contextLength: 32768, vision: true);

/// A model that also reads PDFs (Claude, GPT-5, ...).
const _visionPdf = ModelCapabilities(contextLength: 32768, vision: true, pdfInput: true);

const ProviderInfo _anthropic = ProviderInfo(
  id: kProviderId,
  kind: ProviderKind.anthropic,
  displayName: 'Anthropic',
  location: ExecutionLocation.remote,
);

const ProviderInfo _openAi = ProviderInfo(
  id: kProviderId,
  kind: ProviderKind.openAiCompatible,
  displayName: 'OpenAI',
  location: ExecutionLocation.remote,
);

Future<PreparedImage> _syncPrepare(Uint8List input, {required int maxLongEdge}) async =>
    prepareImage(input, maxLongEdge: maxLongEdge);

final class _FakePicker implements ChatAttachmentPicker {
  PickedAttachment? photo;
  PickedAttachment? file;
  int cameraCalls = 0;

  @override
  Future<PickedAttachment?> pickPhoto() async => photo;

  @override
  Future<PickedAttachment?> takePhoto() async {
    cameraCalls++;
    return photo;
  }

  @override
  Future<PickedAttachment?> pickFile({required int maxBytes}) async => file;
}

PickedAttachment _picked(String name, Uint8List bytes) =>
    PickedAttachment(name: name, size: bytes.length, bytes: bytes);

void main() {
  group('image preparation', () {
    test('downscales to the long edge, applies the EXIF orientation and drops all metadata', () {
      final input = _fixture();
      expect(_contains(input, ascii.encode('Exif')), isTrue, reason: 'the fixture carries EXIF');
      expect(_contains(input, ascii.encode('SherpaCam')), isTrue);

      final out = prepareImage(input, maxLongEdge: 200);
      expect((out.width, out.height), (150, 200), reason: 'portrait after orientation 6, long edge 200');
      expect((out.originalWidth, out.originalHeight), (300, 400));
      expect(out.resized, isTrue);
      expect(out.removedMetadata, isTrue);
      expect(out.mimeType, 'image/jpeg');
      expect(out.sizeNote, startsWith('150×200 · '));
      expect(out.sizeNote, endsWith('(from 300×400)'));

      expect(_contains(out.bytes, ascii.encode('Exif')), isFalse, reason: 'no EXIF block at all');
      expect(_contains(out.bytes, ascii.encode('SherpaCam')), isFalse);
      final decoded = img.decodeJpg(out.bytes)!;
      expect(decoded.exif.isEmpty, isTrue);
      expect(decoded.exif.gpsIfd.isEmpty, isTrue);
      expect((decoded.width, decoded.height), (150, 200));
      // Stored top-left rotates 90° clockwise to the top-right corner.
      expect(_reddish(decoded.getPixel(140, 20)), isTrue, reason: 'pixels were rotated, not just relabelled');
      expect(_reddish(decoded.getPixel(10, 20)), isFalse);
    });

    test('a small image keeps its size (still re-encoded without metadata)', () {
      final out = prepareImage(_fixture(), maxLongEdge: AttachmentPolicy.anthropicImageEdge);
      expect((out.width, out.height), (300, 400));
      expect(out.resized, isFalse);
      expect(out.sizeNote, isNot(contains('from')));
      expect(_contains(out.bytes, ascii.encode('Exif')), isFalse);
    });

    test('transparency is flattened onto white', () {
      final png = img.encodePng(img.Image(width: 20, height: 10, numChannels: 4)..clear(img.ColorRgba8(0, 0, 0, 0)));
      final out = prepareImage(png, maxLongEdge: 100);
      final p = img.decodeJpg(out.bytes)!.getPixel(5, 5);
      expect(p.r, greaterThan(240));
      expect(p.g, greaterThan(240));
      expect(out.removedMetadata, isFalse);
    });

    test('refuses what it cannot read, and images too large to decode on a phone', () {
      expect(
        () => prepareImage(Uint8List.fromList(utf8.encode('not an image')), maxLongEdge: 100),
        throwsA(isA<ImagePrepException>().having((e) => e.message, 'message', contains('JPEG, PNG'))),
      );
      // The same JPEG claiming 9000×9000 in its frame header.
      final big = Uint8List.fromList(_fixture());
      final sof = [
        for (var i = 0; i + 1 < big.length; i++)
          if (big[i] == 0xFF && big[i + 1] == 0xC0) i,
      ].first;
      big
        ..[sof + 5] = 0x23
        ..[sof + 6] = 0x28
        ..[sof + 7] = 0x23
        ..[sof + 8] = 0x28;
      expect(
        () => prepareImage(big, maxLongEdge: 100),
        throwsA(isA<ImagePrepException>().having((e) => e.message, 'message', contains('81 MP'))),
      );
    });
  });

  group('policy', () {
    test('per provider: image edge; capabilities decide images and PDFs', () {
      final a = AttachmentPolicy.forModel(modelName: 'Claude', provider: _anthropic, capabilities: _visionPdf);
      expect((a.imagesAllowed, a.maxImageEdge, a.pdfAllowed), (true, 1568, true));
      final o = AttachmentPolicy.forModel(modelName: 'GPT', provider: _openAi, capabilities: _vision);
      expect((o.maxImageEdge, o.pdfAllowed), (2048, false));
      expect(o.pdfRefusal, "GPT can't read PDFs. Switch to a model that reads documents, or attach the text as a .txt or .md file instead.");
      // The capability, not the provider kind: an OpenAI model that reads
      // PDFs takes them, an Anthropic model whose capabilities say no does not.
      final gpt5 = AttachmentPolicy.forModel(modelName: 'GPT-5', provider: _openAi, capabilities: _visionPdf);
      expect((gpt5.pdfAllowed, gpt5.pdfRefusal), (true, null));
      expect(gpt5.summary, contains('PDFs up to 10 MB'));
      final oldClaude = AttachmentPolicy.forModel(modelName: 'Claude 3 Haiku', provider: _anthropic, capabilities: _vision);
      expect(oldClaude.pdfAllowed, isFalse);
      const lan = ProviderInfo(
        id: 'l',
        kind: ProviderKind.openAiCompatible,
        displayName: 'llama.cpp',
        location: ExecutionLocation.localNetwork,
      );
      expect(AttachmentPolicy.forModel(modelName: 'q', provider: lan, capabilities: _vision).maxImageEdge, 1024);
      const local = ProviderInfo(
        id: 'local',
        kind: ProviderKind.localLlamaCpp,
        displayName: 'On this device',
        location: ExecutionLocation.onDevice,
      );
      final blind = AttachmentPolicy.forModel(
        modelName: 'Qwen3 4B',
        provider: local,
        capabilities: const ModelCapabilities(contextLength: 8192),
      );
      expect(blind.imagesAllowed, isFalse);
      expect(blind.imageRefusal, "Qwen3 4B can't see images. Switch to a model with vision to attach photos.");
      expect(a.summary, contains('1568 px'));
      expect(a.summary, contains('location data is removed'));
    });
  });

  group('composer attachments', () {
    final claude = AttachmentPolicy.forModel(modelName: 'Claude', provider: _anthropic, capabilities: _visionPdf);
    final gpt = AttachmentPolicy.forModel(modelName: 'GPT', provider: _openAi, capabilities: _vision);
    final blind = AttachmentPolicy.forModel(
      modelName: 'Tiny',
      provider: _openAi,
      capabilities: const ModelCapabilities(contextLength: 4096),
    );

    test('text, code and data files are read as UTF-8 with their name', () async {
      final c = ComposerAttachments(prepare: _syncPrepare);
      expect(await c.add(_picked('notes.md', Uint8List.fromList(utf8.encode('﻿# Plan\n- one'))), gpt), isNull);
      expect(await c.add(_picked('data.csv', Uint8List.fromList(utf8.encode('a,b\n1,2'))), gpt), isNull);
      expect(await c.add(_picked('main.dart', Uint8List.fromList(utf8.encode('void main() {}'))), gpt), isNull);
      expect(c.items.map((a) => (a.kind, a.mimeType)), [
        (AttachmentKind.text, 'text/markdown'),
        (AttachmentKind.text, 'text/csv'),
        (AttachmentKind.text, 'text/plain'),
      ]);
      expect(c.items.first.text, '# Plan\n- one', reason: 'BOM dropped');
    });

    test('refusals say why: kind, size, encoding, model', () async {
      final c = ComposerAttachments(prepare: _syncPrepare);
      expect(await c.add(_picked('app.exe', Uint8List(4)), gpt), contains("can't send “app.exe”"));
      expect(await c.add(_picked('blob.txt', Uint8List.fromList([0x41, 0, 0x42])), gpt), contains('not plain text'));
      final big = PickedAttachment(name: 'huge.log', size: 300 * 1024);
      expect(await c.add(big, gpt), allOf(contains('300 KB'), contains('256 KB')));
      expect(await c.add(_picked('report.pdf', _pdf), gpt), gpt.pdfRefusal);
      expect(
        await c.add(_picked('fake.pdf', Uint8List.fromList(utf8.encode('hello'))), claude),
        contains('not a valid PDF'),
      );
      expect(await c.add(PickedAttachment(name: 'scan.pdf', size: 11 * 1024 * 1024), claude), contains('10 MB'));
      expect(
        await c.add(_picked('photo.jpg', _fixture()), blind),
        "Tiny can't see images. Switch to a model with vision to attach photos.",
      );
      expect(c.isEmpty, isTrue, reason: 'nothing refused is attached');
    });

    test('photos are prepared for the model, PDFs kept as they are; at most six per message', () async {
      final c = ComposerAttachments(prepare: _syncPrepare);
      expect(await c.add(_picked('IMG_1.HEIC.jpeg', _fixture()), claude), isNull);
      expect(await c.add(_picked('report.pdf', _pdf), claude), isNull);
      final photo = c.items.first;
      expect((photo.kind, photo.name, photo.mimeType), (AttachmentKind.image, 'IMG_1.HEIC.jpg', 'image/jpeg'));
      expect(photo.image!.removedMetadata, isTrue);
      expect(photo.semanticLabel, contains('location and camera data removed'));
      expect(c.items.last.size, _pdf.length);
      for (var i = 0; i < 4; i++) {
        expect(await c.add(_picked('n$i.txt', Uint8List.fromList([0x61])), claude), isNull);
      }
      expect(await c.add(_picked('n7.txt', Uint8List.fromList([0x61])), claude), contains('up to 6'));
    });

    test('a model switch after attaching blocks the send with the reason', () async {
      final c = ComposerAttachments(prepare: _syncPrepare);
      await c.add(_picked('report.pdf', _pdf), claude);
      expect(c.blockedReason(claude), isNull);
      expect(c.blockedReason(gpt), gpt.pdfRefusal);
      c.clear();
      await c.add(_picked('p.jpg', _fixture()), claude);
      expect(c.blockedReason(blind), blind.imageRefusal);
    });

    test('busy while a photo is prepared; removing it while preparing drops it', () async {
      final gate = Completer<void>();
      final c = ComposerAttachments(
        prepare: (input, {required maxLongEdge}) async {
          await gate.future;
          return prepareImage(input, maxLongEdge: maxLongEdge);
        },
      );
      final adding = c.add(_picked('p.jpg', _fixture()), claude);
      await Future<void>.delayed(Duration.zero);
      expect(c.busy, isTrue);
      expect(c.items.single.note, 'Preparing…');
      c.remove(c.items.single.id);
      gate.complete();
      expect(await adding, isNull);
      expect(c.isEmpty, isTrue);
    });
  });

  group('sending', () {
    late Directory dir;
    late ChatAttachmentStore store;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('sherpa_attachments_');
      store = ChatAttachmentStore(root: () async => dir);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('parts and metadata; files are inlined into each request, the transcript keeps the reference', () async {
      final provider = ScriptedProvider(
        [ScriptedTurn.text('Nice photo.')],
        info: _anthropic,
        capabilitiesValue: _visionPdf,
      );
      final h = ChatHarness(provider: provider, overrides: [chatAttachmentStoreProvider.overrideWithValue(store)]);
      addTearDown(h.dispose);
      await h.createSession();
      final c = await h.open();
      final claude = h.state.attachmentPolicy;
      expect(claude.pdfAllowed, isTrue);
      final draft = ComposerAttachments(prepare: _syncPrepare);
      await draft.add(_picked('beach.jpg', _fixture()), claude);
      await draft.add(_picked('notes.md', Uint8List.fromList(utf8.encode('# Trip'))), claude);
      await draft.add(_picked('report.pdf', _pdf), claude);
      await c.send('What do you see?', attachments: draft.take());
      await h.settle();

      final user = (await h.activePath()).firstWhere((m) => m.role == Role.user);
      final image = user.content.whereType<ImagePart>().single;
      expect(image.data, isNull, reason: 'stored as a file, not in the database');
      expect(image.uri!.scheme, 'file');
      expect(p(image.uri!).startsWith(dir.path), isTrue);
      expect(File.fromUri(image.uri!).readAsBytesSync(), isNot(_fixture()), reason: 'the prepared copy');
      final resources = user.content.whereType<EmbeddedResourcePart>().toList();
      expect(resources.map((r) => r.mimeType), ['text/markdown', 'application/pdf']);
      expect(resources.first.text, '# Trip');
      expect(resources.last.blob, isNull);
      expect(resources.last.size, _pdf.length, reason: 'recorded for the token estimate');
      expect(resources.last.pages, isNull, reason: 'this tiny PDF declares no pages');
      expect(HeuristicTokenCounter().countMessage(user), greaterThan(pdfTokensPerPage),
          reason: 'the stored PDF is not free in the context ring');
      expect(user.text, 'What do you see?');
      expect(user.content.first, isA<ImagePart>(), reason: 'attachments before the question');
      final listed = user.metadata[kMessageAttachmentsKey]! as List;
      expect([for (final e in listed) (e as Map)['name']], ['beach.jpg', 'notes.md', 'report.pdf']);

      // What the provider was sent: bytes, not paths.
      final sent = provider.requests.single.messages.firstWhere((m) => m.role == Role.user);
      final sentImage = sent.content.whereType<ImagePart>().single;
      expect(sentImage.data, File.fromUri(image.uri!).readAsBytesSync());
      expect(sent.content.whereType<EmbeddedResourcePart>().last.blob, _pdf);

      final item = h.state.items.whereType<UserItem>().single;
      expect(item.attachments.map((a) => (a.kind, a.name)), [
        ('image', 'beach.jpg'),
        ('text', 'notes.md'),
        ('pdf', 'report.pdf'),
      ]);
      expect(item.attachments.first.note, '300×400 · ${formatBytes(File.fromUri(image.uri!).lengthSync())}');
      expect(item.resources, isEmpty, reason: 'attachments are not shown as resources');
    });

    test('the store: a moved app container still resolves; chat delete and erase-all hooks', () async {
      final uri = await store.save(sessionId: 's1', id: 'a1', fileName: 'p.jpg', bytes: Uint8List.fromList([1]));
      final keep = await store.save(sessionId: 's2', id: 'a2', fileName: 'q.pdf', bytes: Uint8List.fromList([2]));
      // iOS moves the container on update: same chat folder and name, new root.
      final moved = Uri.file('/var/mobile/Containers/Data/Application/OLD/Library/attachments/s1/${uri.pathSegments.last}');
      expect(await store.read(moved), [1]);
      expect(await store.read(Uri.parse('https://example.com/p.jpg')), isNull);

      final c = ProviderContainer(overrides: [chatAttachmentStoreProvider.overrideWithValue(store)]);
      addTearDown(c.dispose);
      for (final hook in c.read(chatSessionDeletedHooksProvider)) {
        await hook('s1');
      }
      expect(await store.read(uri), isNull, reason: "a deleted chat's attachments go with it");
      expect(await store.read(keep), [2]);
      await chatAttachmentsEraseHook(c.read(_refProbe))();
      expect(await store.read(keep), isNull);
      expect(dir.existsSync(), isFalse);
      dir.createSync(); // for tearDown
    });

    test('a deleted file becomes a note for the model; nothing outside the folder is read', () async {
      final inner = ScriptedProvider([ScriptedTurn.text('ok')]);
      final provider = AttachmentInliningProvider(inner, store);
      final outside = File('${Directory.systemTemp.path}/outside_${DateTime.now().microsecondsSinceEpoch}.jpg')
        ..writeAsBytesSync([1, 2, 3]);
      addTearDown(outside.deleteSync);
      final kept = await store.save(sessionId: 's', id: 'a', fileName: 'x.jpg', bytes: Uint8List.fromList([9]));
      final messages = [
        Message(
          id: 'm',
          role: Role.user,
          createdAt: DateTime.utc(2026),
          content: [
            ImagePart(mimeType: 'image/jpeg', uri: kept),
            ImagePart(mimeType: 'image/jpeg', uri: dir.uri.resolve('s/gone.jpg')),
            ImagePart(mimeType: 'image/jpeg', uri: outside.uri),
            const TextPart('hi'),
          ],
        ),
      ];
      final out = await provider.resolve(messages);
      final parts = out.single.content;
      expect((parts[0] as ImagePart).data, [9]);
      expect((parts[1] as TextPart).text, contains('no longer on this device'));
      expect(parts[2], isA<TextPart>(), reason: 'a file outside the attachments folder is never read');
      final plain = [
        Message(id: 'n', role: Role.user, createdAt: DateTime.utc(2026), content: const [TextPart('x')]),
      ];
      expect(identical(await provider.resolve(plain), plain), isTrue);
    });
  });

  group('in the chat', () {
    late Directory dir;
    late _FakePicker picker;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('sherpa_attachments_ui_');
      picker = _FakePicker();
    });
    tearDown(() => dir.deleteSync(recursive: true));

    ChatHarness harness({ProviderInfo? info, ModelCapabilities caps = _vision}) => ChatHarness(
      provider: ScriptedProvider([ScriptedTurn.text('Got it.')], info: info ?? kCloudInfo, capabilitiesValue: caps),
      overrides: [
        chatAttachmentStoreProvider.overrideWithValue(ChatAttachmentStore(root: () async => dir)),
        chatAttachmentPickerProvider.overrideWithValue(picker),
        chatImagePreparerProvider.overrideWithValue(_syncPrepare),
      ],
    );

    /// Real time for file IO, fake time for the UI; at least [rounds]
    /// rounds and then until no run is active (a busy CPU makes IO slow).
    Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
      final c = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
      for (var i = 0; i < 400; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump(const Duration(milliseconds: 16));
        if (i >= rounds && !c.read(chatControllerProvider(kSession)).isRunActive) break;
      }
      await tester.pumpAndSettle();
    }

    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('composer-attach')));
      await tester.pumpAndSettle();
    }

    testWidgets('vision gating: photos are off with the reason for a model without vision', (tester) async {
      final h = harness(caps: const ModelCapabilities(contextLength: 32768));
      addTearDown(h.dispose);
      await h.createSession();
      await pumpChatScreen(tester, h);
      await settle(tester);
      await openSheet(tester);
      expect(find.text('Attach'), findsOneWidget);
      final photos = tester.widget<ListTile>(find.byKey(const ValueKey('attach-photos')));
      final camera = tester.widget<ListTile>(find.byKey(const ValueKey('attach-camera')));
      expect(photos.enabled, isFalse);
      expect(camera.enabled, isFalse);
      expect(
        find.text("Scripted model can't see images. Switch to a model with vision to attach photos."),
        findsNWidgets(2),
      );
      expect(tester.widget<ListTile>(find.byKey(const ValueKey('attach-files'))).enabled, isTrue);
      expect(find.textContaining('Attachments are sent to Test Cloud with your message.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('attach-camera')));
      await tester.pumpAndSettle();
      expect(picker.cameraCalls, 0);
    });

    testWidgets('a photo: chip with the size note and remove, then a thumbnail; the model gets the bytes', (
      tester,
    ) async {
      final h = harness();
      addTearDown(h.dispose);
      await h.createSession();
      picker.photo = _picked('beach.jpg', _fixture());
      await pumpChatScreen(tester, h);
      await settle(tester);
      await openSheet(tester);
      expect(find.text('Resized to 1568 px on the long edge; location and camera data removed.'), findsNWidgets(2));
      await tester.tap(find.byKey(const ValueKey('attach-photos')));
      await settle(tester);

      expect(find.text('beach.jpg'), findsOneWidget);
      expect(find.textContaining('300×400 · '), findsOneWidget);
      expect(find.byTooltip('Remove beach.jpg'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove beach.jpg'));
      await tester.pump();
      expect(find.text('beach.jpg'), findsNothing, reason: 'removed before sending');

      await openSheet(tester);
      await tester.tap(find.byKey(const ValueKey('attach-photos')));
      await settle(tester);
      expect(
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded)).onPressed,
        isNotNull,
        reason: 'a photo alone can be sent',
      );
      await tester.tap(find.byTooltip('Send'));
      await settle(tester, rounds: 20);

      final semantics = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel('Photo beach.jpg, 300 by 400 pixels'),
        findsOneWidget,
        reason: 'a thumbnail in the transcript',
      );
      semantics.dispose();
      expect(find.text('Got it.'), findsOneWidget);
      final sent = h.scripted.requests.single.messages.firstWhere((m) => m.role == Role.user);
      expect(sent.content.whereType<ImagePart>().single.data, isNotNull);
      expect(find.text('beach.jpg'), findsNothing, reason: 'the composer is empty again');
    });

    testWidgets('text and PDF files: a PDF is refused with the reason unless the model reads documents', (
      tester,
    ) async {
      final h = harness();
      addTearDown(h.dispose);
      await h.createSession();
      await pumpChatScreen(tester, h);
      await settle(tester);

      picker.file = _picked('report.pdf', _pdf);
      await openSheet(tester);
      expect(find.textContaining("can't read PDFs"), findsOneWidget, reason: 'said up front');
      await tester.tap(find.byKey(const ValueKey('attach-files')));
      await settle(tester);
      expect(find.textContaining("Scripted model can't read PDFs"), findsOneWidget);
      expect(find.text('report.pdf'), findsNothing);
      await tester.pump(const Duration(seconds: 5)); // the snackbar goes away
      await tester.pumpAndSettle();

      picker.file = _picked('notes.md', Uint8List.fromList(utf8.encode('# Plan')));
      await openSheet(tester);
      await tester.tap(find.byKey(const ValueKey('attach-files')));
      await settle(tester);
      expect(find.text('notes.md'), findsOneWidget);
      expect(find.text('6 B'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Summarize');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await settle(tester, rounds: 20);
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Text file notes.md, 6 B'), findsOneWidget, reason: 'a file chip in the transcript');
      semantics.dispose();
      final sent = h.scripted.requests.single.messages.firstWhere((m) => m.role == Role.user);
      expect(sent.content.whereType<EmbeddedResourcePart>().single.text, '# Plan');
    });

    testWidgets('a PDF goes to a model that reads documents, with its size and pages for the estimate', (tester) async {
      final h = harness(info: _anthropic, caps: _visionPdf);
      addTearDown(h.dispose);
      await h.createSession();
      await pumpChatScreen(tester, h);
      await settle(tester);
      picker.file = _picked('report.pdf', _pdf);
      await openSheet(tester);
      expect(find.textContaining('PDFs up to 10 MB'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('attach-files')));
      await settle(tester);
      expect(find.text('report.pdf'), findsOneWidget);
      await tester.tap(find.byTooltip('Send'));
      await settle(tester, rounds: 20);
      final sent = h.scripted.requests.single.messages.firstWhere((m) => m.role == Role.user);
      final doc = sent.content.whereType<EmbeddedResourcePart>().single;
      expect(doc.mimeType, 'application/pdf');
      expect(doc.blob, _pdf);
      expect(doc.size, _pdf.length);
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel(RegExp(r'^PDF report\.pdf')), findsOneWidget);
      semantics.dispose();
    });
  });
}

String p(Uri u) => u.toFilePath();

/// A provider that hands out its [Ref] (for hooks that take one).
final _refProbe = Provider<Ref>((ref) => ref);
