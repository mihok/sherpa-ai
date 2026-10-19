import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/chat/links/reply_links.dart';

import 'support/harness.dart';
import 'support/pump.dart';

final class _RecordingLinks implements ChatLinkLauncher {
  final List<(Uri, ReplyLinkKind)> opened = [];
  bool succeed = true;

  @override
  Future<bool> open(Uri uri, ReplyLinkKind kind) async {
    opened.add((uri, kind));
    return succeed;
  }
}

const _reply =
    'See [the docs](https://docs.example.com/guide?a=1) or [the box](http://192.168.1.10/admin), '
    'write to [support](mailto:help@example.com?subject=Hi&body=My%20key), try [this](javascript:alert(1)) '
    'or [that](http:nohost).';

/// The global center of [text] inside the reply (long presses have no
/// `tapOnText` counterpart).
Offset _centerOf(WidgetTester tester, String text) {
  final range = find.textRange.ofSubstring(text).evaluate().single;
  final box = range.renderObject
      .getBoxesForSelection(TextSelection(baseOffset: range.textRange.start, extentOffset: range.textRange.end))
      .first;
  return range.renderObject.localToGlobal(box.toRect().center);
}

void main() {
  group('policy', () {
    test('only http(s) with a host and mailto with an address are opened', () {
      expect(replyLinkKind(Uri.parse('https://example.com/x')), ReplyLinkKind.web);
      expect(replyLinkKind(Uri.parse('HTTP://Example.com')), ReplyLinkKind.web);
      expect(replyLinkKind(Uri.parse('mailto:a@b.co')), ReplyLinkKind.email);
      for (final bad in [
        'javascript:alert(1)',
        'file:///etc/passwd',
        'intent://scan/#Intent;scheme=zxing;end',
        'sherpa://mcp/add?url=https://evil.example',
        'tel:+123',
        'data:text/html,<b>x</b>',
        'http:nohost',
        'mailto:',
        'ftp://example.com/f',
      ]) {
        expect(replyLinkKind(Uri.parse(bad)), isNull, reason: bad);
      }
      expect(replyLinkRefusal(Uri.parse('intent://x')), contains('“intent:” links'));
      expect(replyLinkRefusal(Uri.parse('http:nohost')), contains('incomplete'));
    });

    test('warnings: http, punycode or IDN, user info, bare IPs, prefilled email', () {
      expect(replyLinkWarnings(Uri.parse('https://example.com')), isEmpty);
      expect(replyLinkWarnings(Uri.parse('http://example.com')).single, contains('not encrypted'));
      expect(replyLinkWarnings(Uri.parse('https://xn--pple-43d.com/')).single, contains('international characters'));
      final idn = replyLinkWarnings(Uri.parse('https://exämple.com/'));
      expect(idn.single, contains('exämple.com'), reason: 'shown decoded, as people read it');
      expect(replyLinkWarnings(Uri.parse('https://bank.example@evil.example/')).single, contains('“bank.example@”'));
      for (final ip in ['https://10.0.0.1/', 'https://[::1]/', 'https://2130706433/', 'https://0x7f000001/']) {
        expect(replyLinkWarnings(Uri.parse(ip)), contains(contains('bare IP address')), reason: ip);
      }
      expect(replyLinkWarnings(Uri.parse('https://1e100.net/')), isEmpty);
      expect(replyLinkWarnings(Uri.parse('mailto:a@b.co?body=secret')).single, contains('fills in'));
      expect(replyLinkWarnings(Uri.parse('mailto:a@b.co,c@d.co')).single, contains('more than one'));
    });

    test('the url_launcher opener never uses an in-app WebView', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        (call) async {
          calls.add(call);
          return true;
        },
      );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/url_launcher'),
          null,
        ),
      );
      const links = UrlLauncherChatLinks();
      // This platform has no Custom Tabs / SFSafariViewController: the
      // browser app, not a WebView.
      expect(await links.open(Uri.parse('https://example.com/a'), ReplyLinkKind.web), isTrue);
      expect(await links.open(Uri.parse('mailto:a@b.co'), ReplyLinkKind.email), isTrue);
      expect(await links.open(Uri.parse('javascript:alert(1)'), ReplyLinkKind.web), isFalse);
      final launches = calls.where((c) => c.method == 'launch').toList();
      expect(launches, hasLength(2), reason: 'the refused one never reached the platform');
      for (final c in launches) {
        final args = (c.arguments as Map).cast<String, Object?>();
        expect(args['useWebView'], isFalse);
        expect(args['useSafariVC'], isFalse);
      }
    });
  });

  group('in the chat', () {
    late ChatHarness h;
    late _RecordingLinks links;

    setUp(() {
      links = _RecordingLinks();
      h = ChatHarness(overrides: [chatLinkLauncherProvider.overrideWithValue(links)]);
    });
    tearDown(() => h.dispose());

    Future<void> open(WidgetTester tester) async {
      await h.createSession();
      await h.seedExchange('Any links?', _reply);
      await pumpChatScreen(tester, h);
      await tester.pumpAndSettle();
    }

    testWidgets('tap: a confirm sheet with the site large and the full address; Open opens it', (tester) async {
      await open(tester);
      await tester.tapOnText(find.textRange.ofSubstring('the docs'));
      await tester.pumpAndSettle();
      expect(find.text('Open this link?'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('reply-link-site'))).data, 'docs.example.com');
      final siteStyle = tester.widget<Text>(find.byKey(const ValueKey('reply-link-site'))).style!;
      expect(siteStyle.fontSize, greaterThan(20), reason: 'the site in large type');
      expect(find.text('https://docs.example.com/guide?a=1'), findsOneWidget);
      expect(find.textContaining('not encrypted'), findsNothing);
      expect(links.opened, isEmpty, reason: 'nothing opens (or loads) before the user chooses');

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(links.opened.single, (Uri.parse('https://docs.example.com/guide?a=1'), ReplyLinkKind.web));
      expect(find.text('Open this link?'), findsNothing);
    });

    testWidgets('Cancel opens nothing; risky links carry warnings', (tester) async {
      await open(tester);
      await tester.tapOnText(find.textRange.ofSubstring('the box'));
      await tester.pumpAndSettle();
      expect(find.textContaining('not encrypted (http)'), findsOneWidget);
      expect(find.textContaining('bare IP address'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(links.opened, isEmpty);
    });

    testWidgets('mailto: the address large, a warning about the prefilled text, the mail app', (tester) async {
      await open(tester);
      await tester.tapOnText(find.textRange.ofSubstring('support'));
      await tester.pumpAndSettle();
      expect(find.text('Write an email?'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('reply-link-site'))).data, 'help@example.com');
      expect(find.textContaining('fills in the subject or text'), findsOneWidget);
      await tester.tap(find.text('Write email'));
      await tester.pumpAndSettle();
      expect(links.opened.single.$2, ReplyLinkKind.email);
    });

    testWidgets('long press copies the link and opens nothing; the sheet can copy too', (tester) async {
      await open(tester);
      await tester.longPressAt(_centerOf(tester, 'the docs'));
      await tester.pumpAndSettle();
      expect(h.platform.copied, ['https://docs.example.com/guide?a=1']);
      expect(find.text('Link copied'), findsOneWidget);
      expect(find.text('Open this link?'), findsNothing);
      expect(links.opened, isEmpty);

      await tester.tapOnText(find.textRange.ofSubstring('the box'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy link'));
      await tester.pumpAndSettle();
      expect(h.platform.copied.last, 'http://192.168.1.10/admin');
      expect(links.opened, isEmpty);
    });

    testWidgets('other schemes are not links; an incomplete one is refused with the reason', (tester) async {
      await open(tester);
      await tester.tapOnText(find.textRange.ofSubstring('this'));
      await tester.pumpAndSettle();
      expect(find.text('Open this link?'), findsNothing, reason: 'javascript: renders as plain text');

      await tester.tapOnText(find.textRange.ofSubstring('that'));
      await tester.pumpAndSettle();
      expect(find.text('Open this link?'), findsNothing);
      expect(find.textContaining("This link is incomplete, so it wasn't opened."), findsOneWidget);
      expect(links.opened, isEmpty);
    });

    testWidgets('a failed launch says so', (tester) async {
      links.succeed = false;
      await open(tester);
      await tester.tapOnText(find.textRange.ofSubstring('the docs'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't open a browser for this link."), findsOneWidget);
    });
  });
}
