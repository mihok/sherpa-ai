import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/harness.dart';

/// Records platform-channel calls (clipboard, haptics).
List<MethodCall> mockPlatform(WidgetTester tester) {
  final calls = <MethodCall>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      calls.add(call);
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return calls;
}

void main() {
  group('copy button', () {
    testWidgets('copies, buzzes, reports, then resets its icon', (
      tester,
    ) async {
      final calls = mockPlatform(tester);
      final copied = <String>[];
      await pumpMarkdown(tester, '```sh\necho hi\n```', onCopyCode: copied.add);
      await tester.tap(find.byIcon(Icons.content_copy_rounded));
      await tester.pump();

      final setData = calls.singleWhere((c) => c.method == 'Clipboard.setData');
      expect((setData.arguments as Map)['text'], 'echo hi');
      expect(
        calls
            .where((c) => c.method == 'HapticFeedback.vibrate')
            .map((c) => c.arguments),
        ['HapticFeedbackType.lightImpact'],
      );
      expect(copied, ['echo hi']);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      expect(find.byIcon(Icons.content_copy_rounded), findsOneWidget);
    });

    testWidgets('has an accessible label and a tooltip', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpMarkdown(tester, '```\nx\n```');
      expect(find.bySemanticsLabel('Copy code'), findsOneWidget);
      expect(find.byType(Tooltip), findsOneWidget);
      semantics.dispose();
    });
  });

  group('links', () {
    testWidgets('tap calls onLinkTap with the parsed Uri', (tester) async {
      final taps = <Uri>[];
      await pumpMarkdown(
        tester,
        'Read [the docs](https://example.com/docs?a=1) now',
        onLinkTap: taps.add,
      );
      await tester.tapOnText(find.textRange.ofSubstring('the docs'));
      expect(taps, [Uri.parse('https://example.com/docs?a=1')]);
    });

    testWidgets('autolinks are tappable', (tester) async {
      final taps = <Uri>[];
      await pumpMarkdown(
        tester,
        'see https://sherpa.example.org/x ok',
        onLinkTap: taps.add,
      );
      await tester.tapOnText(find.textRange.ofSubstring('sherpa.example'));
      expect(taps.single.host, 'sherpa.example.org');
    });

    testWidgets('a link still streaming in is not tappable', (tester) async {
      final taps = <Uri>[];
      await pumpMarkdown(
        tester,
        'Read [the docs](https://exam',
        streaming: true,
        onLinkTap: taps.add,
      );
      await tester.tapOnText(find.textRange.ofSubstring('the docs'));
      expect(taps, isEmpty);
    });

    testWidgets('disallowed schemes render as plain text', (tester) async {
      final taps = <Uri>[];
      await pumpMarkdown(
        tester,
        '[click](javascript:alert(1)) and [file](file:///etc/passwd)',
        onLinkTap: taps.add,
      );
      await tester.tapOnText(find.textRange.ofSubstring('click'));
      await tester.tapOnText(find.textRange.ofSubstring('file'));
      expect(taps, isEmpty);
    });

    testWidgets('the newest callback is used even for frozen blocks', (
      tester,
    ) async {
      final first = <Uri>[];
      final second = <Uri>[];
      await pumpMarkdown(
        tester,
        '[a](https://a.io)\n\nmore',
        onLinkTap: first.add,
      );
      await pumpMarkdown(
        tester,
        '[a](https://a.io)\n\nmore',
        onLinkTap: second.add,
      );
      await tester.tapOnText(find.textRange.ofSubstring('a'));
      expect(first, isEmpty);
      expect(second, hasLength(1));
    });
  });

  group('images', () {
    const doc = '![diagram](https://images.example.net/d.png)';

    testWidgets('network images are placeholders until tapped', (tester) async {
      final semantics = tester.ensureSemantics();
      final client = _RecordingHttpClient();
      debugNetworkImageHttpClientProvider = () => client;
      try {
        await pumpMarkdown(tester, doc);
        expect(find.text('Image from images.example.net'), findsOneWidget);
        expect(find.byType(Image), findsNothing);
        expect(
          tester.getSemantics(find.text('Image from images.example.net')),
          isSemantics(isButton: true, hint: 'Tap to load'),
        );

        // Nothing is requested on rebuilds or as the message grows.
        await pumpMarkdown(tester, '$doc\n\nmore text');
        await tester.pump();
        expect(client.requested, isEmpty);

        await tester.tap(find.text('Image from images.example.net'));
        await tester.pump();
        await tester.pump();
        final image = tester.widget<Image>(find.byType(Image));
        expect(
          (image.image as NetworkImage).url,
          'https://images.example.net/d.png',
        );
        expect(client.requested, [
          Uri.parse('https://images.example.net/d.png'),
        ]);
        // The failed fetch shows a retry chip, not a broken layout.
        await tester.pump();
        expect(find.textContaining("Couldn't load image"), findsOneWidget);
      } finally {
        debugNetworkImageHttpClientProvider = null;
        semantics.dispose();
      }
    });

    testWidgets('inline images in text are placeholders too', (tester) async {
      await pumpMarkdown(
        tester,
        'Look: ![x](http://cdn.example.com/x.gif) here',
      );
      expect(find.text('Image from cdn.example.com'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('data: URIs render directly; oversized and SVG ones do not', (
      tester,
    ) async {
      // 1×1 transparent PNG.
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
      await pumpMarkdown(tester, '![dot](data:image/png;base64,$png)');
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<ResizeImage>());

      final svg = base64.encode(
        utf8.encode('<svg xmlns="http://www.w3.org/2000/svg"/>'),
      );
      await pumpMarkdown(tester, '![v](data:image/svg+xml;base64,$svg)');
      expect(find.byType(Image), findsNothing);
      expect(find.text('Unsupported image'), findsOneWidget);

      final huge = 'A' * (3 * 1024 * 1024);
      await pumpMarkdown(tester, '![big](data:image/png;base64,$huge)');
      expect(find.byType(Image), findsNothing);
      expect(find.text('Image too large'), findsOneWidget);
    });

    testWidgets('relative and file: sources are never loaded', (tester) async {
      await pumpMarkdown(
        tester,
        '![a](img/a.png)\n\n![b](file:///sdcard/b.png)',
      );
      expect(find.byType(Image), findsNothing);
      expect(find.text('Image not loaded'), findsNWidgets(2));
    });

    testWidgets('a streaming image (no URL yet) is a disabled placeholder', (
      tester,
    ) async {
      await pumpMarkdown(tester, '![chart](https://img', streaming: true);
      expect(find.text('Image'), findsOneWidget);
      await tester.tap(find.text('Image'));
      await tester.pump();
      expect(find.byType(Image), findsNothing);
    });
  });
}

/// Records image fetches and fails them (no network in tests).
class _RecordingHttpClient implements HttpClient {
  final requested = <Uri>[];

  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    requested.add(url);
    return Future.error(const SocketException('offline (test)'));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
