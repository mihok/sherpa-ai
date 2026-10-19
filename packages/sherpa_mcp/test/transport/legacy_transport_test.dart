import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:test/test.dart';

import '../support/helpers.dart';

/// Transport-level resumption cases that need a broken socket, which a
/// real shelf server cannot produce on demand.
void main() {
  final url = Uri.parse('http://127.0.0.1:9/mcp');
  const request = JsonRpcRequest(JsonRpcId.int(7), 'tools/call', {'name': 'x'});
  const result = '{"jsonrpc":"2.0","id":7,"result":{"content":[]}}';

  LegacyStreamableHttpTransport transport(MockClientStreamHandler handler) => LegacyStreamableHttpTransport(
        http: McpHttp(
          client: MockClient.streaming(handler),
          serverUrl: url,
          policy: loopbackPolicy,
          timeouts: const McpTimeouts(),
          limits: const McpLimits(maxResumeAttempts: 2),
        ),
      );

  http.StreamedResponse sse(Stream<String> events) => http.StreamedResponse(
        events.map(utf8.encode),
        200,
        headers: {'content-type': 'text/event-stream'},
      );

  Stream<String> primingThenReset() async* {
    yield 'id: s1-0\nretry: 40\ndata:\n\n';
    await Future<void>.delayed(const Duration(milliseconds: 10));
    throw http.ClientException('Connection closed while receiving data');
  }

  test('a stream torn down mid-way resumes from the last event id after `retry`', () async {
    final gets = <(DateTime, String?)>[];
    final t = transport((req, body) async {
      if (req.method == 'POST') return sse(primingThenReset());
      gets.add((DateTime.now(), req.headers['last-event-id']));
      return sse(Stream.value('id: s1-1\ndata: $result\n\n'));
    });
    final sent = DateTime.now();
    final r = await t.request(request);
    expect(r, isA<JsonRpcResult>());
    expect(gets.single.$2, 's1-0');
    expect(gets.single.$1.difference(sent), greaterThanOrEqualTo(const Duration(milliseconds: 40)));
    await t.close();
  });

  test('resumption is bounded; without an event id the request fails as interrupted', () async {
    var getCount = 0;
    final bounded = transport((req, body) async {
      if (req.method == 'POST') return sse(primingThenReset());
      getCount++;
      return sse(primingThenReset());
    });
    await expectLater(
      bounded.request(request),
      throwsA(isA<McpTransportException>().having((e) => e.streamInterrupted, 'interrupted', true)),
    );
    expect(getCount, 2);
    await bounded.close();

    final noId = transport((req, body) async => sse(Stream.value(': only a comment\n\n')));
    await expectLater(
      noId.request(request),
      throwsA(isA<McpTransportException>().having((e) => e.streamInterrupted, 'interrupted', true)),
    );
    await noId.close();
  });

  test('a 405 on the resume GET fails the request', () async {
    final t = transport((req, body) async =>
        req.method == 'POST' ? sse(primingThenReset()) : http.StreamedResponse(const Stream.empty(), 405));
    await expectLater(t.request(request), throwsA(isA<McpTransportException>()));
    await t.close();
  });
}
