import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sherpa_net/sherpa_net.dart';
import 'package:test/test.dart';

Future<List<SseEvent>> parse(List<String> chunks) =>
    Stream.fromIterable(chunks).transform(const SseTextDecoder()).toList();

void main() {
  group('SSE decoder', () {
    test('basic events, comments and default type', () async {
      final ev = await parse([': keep-alive\n', 'data: hello\n\n', 'event: done\ndata: {"a":1}\n\n']);
      expect(ev.map((e) => e.event), ['message', 'done']);
      expect(ev.map((e) => e.data), ['hello', '{"a":1}']);
    });

    test('CRLF split across chunks, CR-only and LF endings', () async {
      final ev = await parse(['data: a\r', '\ndata: b\r\n\r', '\n', 'data: c\r\rdata: d\n\n']);
      expect(ev.map((e) => e.data), ['a\nb', 'c', 'd']);
    });

    test('multi-line data, optional space, field without colon', () async {
      final ev = await parse(['data:one\ndata:  two\ndata\n\n']);
      expect(ev.single.data, 'one\n two\n');
    });

    test('ids persist, NUL ids are ignored, retry parsed', () async {
      final ev = await parse(['id: 7\nretry: 1500\ndata: x\n\n', 'id: bad\u0000\ndata: y\n\n', 'retry: abc\ndata: z\n\n']);
      expect(ev.map((e) => e.id), ['7', '7', '7']);
      expect(ev.first.retry, const Duration(milliseconds: 1500));
      expect(ev.last.retry, isNull);
    });

    test('BOM is stripped and an unterminated event is discarded', () async {
      final ev = await parse(['﻿data: first\n\n', 'data: partial']);
      expect(ev.single.data, 'first');
    });

    test('byte decoder handles UTF-8 split mid-codepoint', () async {
      final bytes = utf8.encode('data: héllo 日本\n\n');
      final chunks = [bytes.sublist(0, 8), bytes.sublist(8, 15), bytes.sublist(15)];
      final ev = await Stream<List<int>>.fromIterable(chunks).transform(const SseDecoder()).toList();
      expect(ev.single.data, 'héllo 日本');
    });

    test('encodeSse round-trips', () async {
      const e = SseEvent(data: 'a\nb', event: 'update', id: '3');
      final back = await parse([encodeSse(e)]);
      expect(back.single.data, 'a\nb');
      expect(back.single.event, 'update');
      expect(back.single.id, '3');
    });
  });

  group('UrlPolicy', () {
    Future<List<InternetAddress>> fakeDns(String host) async => switch (host) {
          'evil.example' => [InternetAddress('10.0.0.5')],
          'meta.example' => [InternetAddress('169.254.169.254')],
          'good.example' => [InternetAddress('93.184.216.34')],
          'mapped.example' => [InternetAddress('::ffff:192.168.1.1')],
          _ => throw const SocketException('nxdomain'),
        };

    test('public https passes; http, creds and odd schemes fail', () async {
      final p = UrlPolicy(resolver: fakeDns);
      expect((await p.check('https://good.example/mcp')).host, 'good.example');
      for (final bad in ['http://good.example', 'ftp://good.example', 'https://u:p@good.example', 'not a url', 'file:///etc/passwd']) {
        expect(() => p.checkSyntax(bad), throwsA(isA<UrlPolicyViolation>()), reason: bad);
      }
    });

    test('names resolving to private, link-local or mapped addresses are blocked', () async {
      final p = UrlPolicy(resolver: fakeDns);
      for (final h in ['evil.example', 'meta.example', 'mapped.example']) {
        await expectLater(p.check('https://$h/'), throwsA(isA<UrlPolicyViolation>()), reason: h);
      }
      await expectLater(p.check('https://nx.example/'), throwsA(isA<UrlPolicyViolation>()));
    });

    test('literal addresses classified', () {
      final pub = const UrlPolicy();
      for (final h in ['https://127.0.0.1', 'https://[::1]', 'https://192.168.0.2', 'https://169.254.169.254', 'https://0.0.0.0', 'https://[fe80::1]', 'https://[fd00::1]', 'https://localhost', 'https://printer.local']) {
        expect(() => pub.checkSyntax(h), throwsA(isA<UrlPolicyViolation>()), reason: h);
      }
      const lan = UrlPolicy(scope: NetworkScope.localNetwork, allowHttp: true);
      expect(lan.checkSyntax('http://192.168.0.2:8080/v1').port, 8080);
      expect(() => lan.checkSyntax('http://127.0.0.1:8080'), throwsA(isA<UrlPolicyViolation>()));
      expect(() => lan.checkSyntax('https://169.254.169.254'), throwsA(isA<UrlPolicyViolation>()));
      const loop = UrlPolicy(scope: NetworkScope.loopback, allowHttp: true);
      expect(loop.checkSyntax('http://127.0.0.1:8080').host, '127.0.0.1');
    });
  });

  group('httpRequiresLocalAddress (finding 23)', () {
    Future<List<InternetAddress>> dns(String host) async => switch (host) {
          'api.groq.com' => [InternetAddress('104.18.32.47')],
          'nas.local' => [InternetAddress('192.168.1.20')],
          'corp.example.com' => [InternetAddress('10.1.2.3'), InternetAddress('fd00::7')],
          'mixed.example.com' => [InternetAddress('10.1.2.3'), InternetAddress('104.18.32.47')],
          _ => throw const SocketException('no such host'),
        };
    final strict = UrlPolicy(scope: NetworkScope.loopback, allowHttp: true, httpRequiresLocalAddress: true, resolver: dns);

    test('plain http to a public host by name or literal is refused', () async {
      await expectLater(strict.check('http://api.groq.com/openai/v1'), throwsA(isA<UrlPolicyViolation>()));
      await expectLater(strict.check('http://mixed.example.com/v1'), throwsA(isA<UrlPolicyViolation>()));
      expect(() => strict.checkSyntax('http://8.8.8.8/v1'), throwsA(isA<UrlPolicyViolation>()));
      // Names are settled by DNS, not by the syntax check.
      expect(strict.checkSyntax('http://api.groq.com/v1').host, 'api.groq.com');
    });

    test('mDNS names, private names and literal private / loopback addresses keep working', () async {
      expect((await strict.check('http://nas.local:11434/v1')).host, 'nas.local');
      expect((await strict.check('http://corp.example.com/v1')).host, 'corp.example.com');
      expect((await strict.check('http://192.168.1.20:1234/v1')).port, 1234);
      expect((await strict.check('http://[fd00::1]:8080/v1')).port, 8080);
      expect((await strict.check('http://127.0.0.1:8080/v1')).port, 8080);
      expect((await strict.check('http://100.101.102.103/v1')).host, '100.101.102.103'); // CGNAT / Tailscale
    });

    test('https is unaffected, and the default stays as before', () async {
      expect((await strict.check('https://api.groq.com/openai/v1')).scheme, 'https');
      final legacy = UrlPolicy(scope: NetworkScope.loopback, allowHttp: true, resolver: dns);
      expect((await legacy.check('http://api.groq.com/openai/v1')).host, 'api.groq.com');
    });
  });

  group('Retry-After', () {
    test('seconds, ms, HTTP-date and vendor reset formats', () {
      final now = DateTime.utc(2026, 10, 18, 12);
      expect(parseRetryAfter({'retry-after': '3'}), const Duration(seconds: 3));
      expect(parseRetryAfter({'retry-after-ms': '250'}), const Duration(milliseconds: 250));
      expect(parseRetryAfter({'retry-after': 'Sun, 18 Oct 2026 12:00:10 GMT'}, now: now), const Duration(seconds: 10));
      expect(parseRetryAfter({'x-ratelimit-reset-requests': '1m2.5s'}), const Duration(milliseconds: 62500));
      expect(parseRetryAfter({'x-ratelimit-reset-requests': '20ms'}), const Duration(milliseconds: 20));
      expect(parseRetryAfter({}), isNull);
    });

    test('backoff stays within the exponential cap', () {
      final b = Backoff(base: const Duration(milliseconds: 100), max: const Duration(seconds: 1));
      for (var i = 0; i < 10; i++) {
        expect(b.delay(i).inMilliseconds, lessThanOrEqualTo(1000));
      }
      expect(b.delay(0).inMilliseconds, lessThanOrEqualTo(100));
    });
  });

  group('Redactor', () {
    test('headers, query params and token-shaped text', () {
      expect(Redactor.headers({'Authorization': 'Bearer abc', 'X-Api-Key': 'k', 'Accept': 'json'}),
          {'Authorization': Redactor.mask, 'X-Api-Key': Redactor.mask, 'Accept': 'json'});
      final u = Redactor.uri(Uri.parse('https://x.dev/cb?code=123&state=s&access_token=t'));
      expect(u.queryParameters, {'code': Redactor.mask, 'state': 's', 'access_token': Redactor.mask});
      final t = Redactor.text('auth Bearer eyJhbGciOi.eyJzdWIiOiIx.sigsigsig and sk-ant-abcdefghijklmnop and hf_abcdefghijklmnopqrstuv');
      expect(t, isNot(contains('sk-ant')));
      expect(t, isNot(contains('hf_abc')));
      expect(t, contains('Bearer ${Redactor.mask}'));
    });
  });
}
