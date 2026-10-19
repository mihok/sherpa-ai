import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_webview/sherpa_webview.dart';
import 'package:sherpa_webview/src/protocol/jsonrpc.dart';

void main() {
  group('LinkPolicy', () {
    const p = LinkPolicy();

    test('https only by default', () {
      expect(p.check('https://example.com/a?b=1#c').uri.toString(), 'https://example.com/a?b=1#c');
      for (final bad in [
        'http://example.com',
        'javascript:alert(1)',
        'JavaScript:alert(1)',
        'data:text/html,hi',
        'file:///etc/passwd',
        'content://media/1',
        'intent://x#Intent;end',
        'sherpa://settings',
        'mailto:a@example.com',
        'tel:+123',
        'about:blank',
        'blob:https://x/1',
      ]) {
        expect(p.check(bad).isAllowed, isFalse, reason: bad);
        expect(p.check(bad).refusal, LinkRefusal.scheme, reason: bad);
      }
    });

    test('refuses malformed, hidden-character, credential and oversized links', () {
      expect(p.check(null).refusal, LinkRefusal.malformed);
      expect(p.check(42).refusal, LinkRefusal.malformed);
      expect(p.check('').refusal, LinkRefusal.malformed);
      expect(p.check(' https://example.com').refusal, LinkRefusal.malformed);
      expect(p.check('https://exa\nmple.com').refusal, LinkRefusal.malformed);
      expect(p.check('https://example.com/\u202Egnp.exe').refusal, LinkRefusal.malformed);
      expect(p.check('https://example.com/\u200Bx').refusal, LinkRefusal.malformed);
      expect(p.check('https://user:pw@example.com').refusal, LinkRefusal.credentials);
      expect(p.check('https:///nohost').refusal, LinkRefusal.host);
      expect(p.check('https://example.com/${'a' * 3000}').refusal, LinkRefusal.tooLong);
    });

    test('mailto / tel are opt-in', () {
      const q = LinkPolicy(allowMailto: true, allowTel: true);
      expect(q.check('mailto:a@example.com').isAllowed, isTrue);
      expect(q.check('tel:+15551234').isAllowed, isTrue);
    });
  });

  group('TokenBucket', () {
    test('bursts, then refills at the rate', () {
      final clock = FakeClock();
      final b = TokenBucket(capacity: 3, perSecond: 2, clock: clock);
      expect([for (var i = 0; i < 5; i++) b.take()], [true, true, true, false, false]);
      clock.advance(const Duration(milliseconds: 500));
      expect(b.take(), isTrue);
      expect(b.take(), isFalse);
      clock.advance(const Duration(seconds: 10));
      expect([for (var i = 0; i < 4; i++) b.take()], [true, true, true, false]);
    });
  });

  group('McpAppResource', () {
    const html = '<!DOCTYPE html><html><body>héllo ☀</body></html>';

    test('text resource with content-level _meta.ui', () {
      final r = McpAppResource.fromContents(
        uri: 'ui://weather/view',
        mimeType: 'text/html;profile=mcp-app',
        text: html,
        contentMeta: {
          'ui': {
            'csp': {
              'connectDomains': ['https://api.example.com'],
            },
            'permissions': {'camera': <String, Object?>{}},
            'prefersBorder': false,
            'domain': 'x.example.com',
          },
        },
        listingMeta: {
          'ui': {
            'csp': {
              'connectDomains': ['https://listing.example.com'],
            },
          },
        },
      );
      expect(r.html, html);
      expect([for (final o in r.declared.connect) o.source], ['https://api.example.com'], reason: 'content item wins');
      expect(r.permissions.camera, isTrue);
      expect(r.permissions.any, isTrue);
      expect(r.prefersBorder, isFalse);
      expect(r.domain, 'x.example.com');
      expect(r.sha256, McpAppResource.sha256Of(utf8.encode(html)));
    });

    test('falls back to listing _meta.ui; base64 blob decoded as UTF-8', () {
      final r = McpAppResource.fromContents(
        uri: 'ui://weather/view',
        mimeType: 'TEXT/HTML; profile=mcp-app',
        blob: base64.encode(utf8.encode(html)),
        listingMeta: {
          'ui': {
            'csp': {
              'resourceDomains': ['https://cdn.example.com'],
            },
          },
        },
      );
      expect(r.html, html, reason: 'not Latin-1');
      expect([for (final o in r.declared.resource) o.source], ['https://cdn.example.com']);
    });

    test('rejects what the spec forbids', () {
      void bad(String reason,
              {String uri = 'ui://a/b', String? mime = 'text/html;profile=mcp-app', String? text, String? blob}) =>
          expect(
            () => McpAppResource.fromContents(
                uri: uri, mimeType: mime, text: text, blob: blob, limits: const McpAppLimits(maxHtmlBytes: 64)),
            throwsA(isA<McpAppResourceException>()),
            reason: reason,
          );
      bad('scheme', uri: 'https://a/b', text: '<p>');
      bad('mime', mime: 'text/html', text: '<p>');
      bad('mime null', mime: null, text: '<p>');
      bad('skybridge', mime: 'text/html+skybridge', text: '<p>');
      bad('no body');
      bad('empty', text: '  ');
      bad('too large', text: 'x' * 65);
      bad('bad base64', blob: '!!!');
      bad('not utf-8', blob: base64.encode([0xff, 0xfe, 0xfd]));
    });
  });

  group('ViewMessage.parse', () {
    test('requests, notifications, responses', () {
      expect(ViewMessage.parse({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}), isA<ViewRequest>());
      expect(ViewMessage.parse({'jsonrpc': '2.0', 'id': 'a', 'method': 'x', 'params': <String, Object?>{}}),
          isA<ViewRequest>());
      expect(ViewMessage.parse({'jsonrpc': '2.0', 'method': 'n'}), isA<ViewNotification>());
      expect(ViewMessage.parse({'jsonrpc': '2.0', 'id': 'h1', 'result': <String, Object?>{}}), isA<ViewResponse>());
      expect(
          ViewMessage.parse({
            'jsonrpc': '2.0',
            'id': 'h1',
            'error': {'code': 1, 'message': 'x'},
          }),
          isA<ViewResponse>());
    });

    test('drops malformed messages', () {
      for (final m in <Object?>[
        null,
        'string',
        [1],
        <String, Object?>{},
        {'jsonrpc': '1.0', 'id': 1, 'method': 'x'},
        {'id': 1, 'method': 'x'},
        {'jsonrpc': '2.0', 'id': null, 'method': 'x'},
        {'jsonrpc': '2.0', 'id': 1.5, 'method': 'x'},
        {'jsonrpc': '2.0', 'id': true, 'method': 'x'},
        {'jsonrpc': '2.0', 'id': '', 'method': 'x'},
        {'jsonrpc': '2.0', 'id': 'x' * 200, 'method': 'x'},
        {'jsonrpc': '2.0', 'id': 1, 'method': 7},
        {'jsonrpc': '2.0', 'id': 1, 'method': ''},
        {'jsonrpc': '2.0', 'id': 1, 'method': 'm' * 129},
        {'jsonrpc': '2.0', 'id': 1, 'method': 'x', 'params': <Object?>[]},
        {'jsonrpc': '2.0', 'id': 1},
        {'jsonrpc': '2.0', 'result': <String, Object?>{}},
      ]) {
        expect(ViewMessage.parse(m), isNull, reason: '$m');
      }
    });
  });

  group('McpAppHostContext', () {
    test('serializes the mobile mapping and diffs by key', () {
      const a = McpAppHostContext(
        theme: McpAppTheme.dark,
        locale: 'pt-PT',
        timeZone: 'Europe/Lisbon',
        userAgent: 'Sherpa/0.1.0 (Android 16)',
        containerDimensions: McpAppContainerDimensions(width: 360, maxHeight: 560.5),
        safeAreaInsets: McpAppInsets.zero,
      );
      final j = a.toJson();
      expect(j['theme'], 'dark');
      expect(j['platform'], 'mobile');
      expect(j['displayMode'], 'inline');
      expect(j['availableDisplayModes'], ['inline', 'fullscreen']);
      expect(j['containerDimensions'], {'width': 360, 'maxHeight': 560.5});
      expect(j['deviceCapabilities'], {'touch': true, 'hover': false});
      final b = a.copyWith(theme: McpAppTheme.light).toJson();
      expect(McpAppHostContext.diff(j, b), {'theme': 'light'});
      expect(McpAppHostContext.diff(j, j), isEmpty);
    });
  });

  group('callToolResultJson', () {
    test('maps core parts to MCP blocks and strips Sherpa meta', () {
      final j = callToolResultJson(ToolResult(
        content: [
          const TextPart('hi'),
          ImagePart(mimeType: 'image/png', data: utf8.encode('png')),
          ImagePart(mimeType: 'image/png', uri: Uri.parse('file:///data/user/0/secret.png')),
          const ResourceLinkPart(uri: 'https://example.com/r'),
          const EmbeddedResourcePart(uri: 'mem://x', text: 't'),
          const ReasoningPart(text: 'thinking'),
        ],
        structured: const {'a': 1},
        isError: true,
        meta: const {'ai.sherpa/serverId': 's', 'viewUUID': 'v'},
      ));
      expect(j['content'], [
        {'type': 'text', 'text': 'hi'},
        {'type': 'image', 'data': base64Encode(utf8.encode('png')), 'mimeType': 'image/png'},
        {'type': 'resource_link', 'uri': 'https://example.com/r', 'name': 'https://example.com/r'},
        {
          'type': 'resource',
          'resource': {'uri': 'mem://x', 'text': 't'},
        },
      ]);
      expect(j['structuredContent'], {'a': 1});
      expect(j['isError'], isTrue);
      expect(j['_meta'], {'viewUUID': 'v'});
    });
  });
}
