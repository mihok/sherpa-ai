import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_webview/sherpa_webview.dart';

void main() {
  group('CspOrigin', () {
    test('accepts plain https / wss origins, normalized', () {
      expect(CspOrigin.tryParse('https://api.example.com')!.source, 'https://api.example.com');
      expect(CspOrigin.tryParse(' HTTPS://API.Example.COM/ ')!.source, 'https://api.example.com');
      expect(CspOrigin.tryParse('https://api.example.com:8443')!.source, 'https://api.example.com:8443');
      expect(CspOrigin.tryParse('wss://stream.example.com')!.source, 'wss://stream.example.com');
      final w = CspOrigin.tryParse('https://*.cdn.example.com')!;
      expect(w.wildcard, isTrue);
      expect(w.source, 'https://*.cdn.example.com');
      expect(CspOrigin.tryParse('https://xn--bcher-kva.example')!.host, 'xn--bcher-kva.example');
    });

    test('rejects anything that is not a public origin', () {
      for (final bad in [
        '',
        '*',
        'https://*',
        'https:',
        'data:',
        'blob:',
        "'self'",
        "'unsafe-eval'",
        'http://api.example.com',
        'ws://api.example.com',
        'ftp://example.com',
        'https://example.com/path',
        'https://example.com?q=1',
        'https://example.com#x',
        'https://user@example.com',
        'https://example.com; script-src *',
        'https://exa mple.com',
        'https://example.com\nscript-src *',
        'https://127.0.0.1',
        'https://10.0.0.1:8080',
        'https://[::1]',
        'https://localhost',
        'https://printer.local',
        'https://router.lan',
        'https://box.home',
        'https://svc.internal',
        'https://mcp-view.sherpa.invalid',
        'https://intranet',
        'https://*.com',
        'https://-bad.example.com',
        'https://bad-.example.com',
        'https://a..example.com',
        'https://example.com.',
        'https://bücher.example',
        'https://example.com:0',
        'https://example.com:70000',
        'https://${'a' * 64}.example.com',
      ]) {
        expect(CspOrigin.tryParse(bad), isNull, reason: bad);
      }
    });

    test('scheme restriction (resource domains are https only)', () {
      expect(CspOrigin.tryParse('wss://x.example.com', schemes: const {'https'}), isNull);
    });
  });

  group('DeclaredDomains', () {
    test('parses, validates, de-duplicates and records rejects', () {
      final d = DeclaredDomains.fromCsp({
        'connectDomains': ['https://api.example.com', 'https://API.example.com/', 'http://x.example.com', 7],
        'resourceDomains': ['https://cdn.example.com', 'wss://cdn.example.com'],
        'frameDomains': ['https://youtube.com'],
        'baseUriDomains': ['https://base.example.com'],
      });
      expect([for (final o in d.connect) o.source], ['https://api.example.com']);
      expect([for (final o in d.resource) o.source], ['https://cdn.example.com']);
      expect(d.rejected, ['http://x.example.com', 'wss://cdn.example.com']);
      expect(d.ignoredFrameDomains, ['https://youtube.com']);
      expect(d.ignoredBaseUriDomains, ['https://base.example.com']);
      expect(d.isEmpty, isFalse);
    });

    test('grant keeps only declared AND granted origins', () {
      final d = DeclaredDomains.fromCsp({
        'connectDomains': ['https://a.example.com', 'https://b.example.com'],
      });
      final g = d.grant({'https://b.example.com', 'https://undeclared.example.com'});
      expect([for (final o in g.connect) o.source], ['https://b.example.com']);
      expect(g.toSandboxCsp(), {
        'connectDomains': ['https://b.example.com'],
        'resourceDomains': <String>[],
      });
    });

    test('caps the number of entries read', () {
      final d = DeclaredDomains.fromCsp({
        'connectDomains': [for (var i = 0; i < 200; i++) 'https://h$i.example.com'],
      });
      expect(d.connect, hasLength(64));
    });
  });

  group('McpAppCsp', () {
    test('no grant: no network at all', () {
      final p = McpAppCsp.build().policy;
      expect(p, startsWith("default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:;"));
      for (final d in [
        "connect-src 'none'",
        "font-src 'none'",
        "media-src 'none'",
        "frame-src 'none'",
        "child-src 'none'",
        "worker-src 'none'",
        "object-src 'none'",
        "base-uri 'none'",
        "form-action 'none'",
      ]) {
        expect(p, contains(d));
      }
      expect(p, isNot(contains("'self'")));
      expect(p, isNot(contains('unsafe-eval')));
      expect(McpAppCsp.build().allowsNetwork, isFalse);
    });

    test('policies only ever use the characters native code accepts', () {
      final d = DeclaredDomains.fromCsp({
        'connectDomains': ['https://api.example.com:8443', 'wss://ws.example.com'],
        'resourceDomains': ['https://*.cdn.example.com'],
      });
      final csp = McpAppCsp.build(d);
      expect(McpAppCsp.allowedChars.hasMatch(csp.policy), isTrue, reason: csp.policy);
      expect(csp.allowedOrigins, ['https://api.example.com:8443', 'wss://ws.example.com', 'https://*.cdn.example.com']);
    });

    test('golden fixture shared with the Chromium suite matches the builder', () {
      final doc = jsonDecode(File('test/web/fixtures/policies.json').readAsStringSync()) as Map<String, Object?>;
      for (final c in (doc['cases']! as List).cast<Map<String, Object?>>()) {
        final declared = DeclaredDomains.fromCsp((c['csp']! as Map).cast<String, Object?>());
        final csp = McpAppCsp.build(declared.grant({...(c['granted']! as List).cast<String>()}));
        expect(csp.policy, c['policy'], reason: '${c['name']}: run `dart run tool/csp_fixture.dart` and review');
        expect(csp.allowedOrigins, c['allowedOrigins'], reason: '${c['name']}');
        expect(declared.rejected, c['rejected'], reason: '${c['name']}');
      }
    });
  });
}
