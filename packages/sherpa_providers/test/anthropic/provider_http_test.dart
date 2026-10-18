import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/src/anthropic/anthropic.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const apiKey = 'sk-ant-api03-TESTKEY0123456789abcdef';

final class Recorded {
  Recorded(this.method, this.path, this.query, this.headers, this.body);
  final String method;
  final String path;
  final Map<String, String> query;
  final Map<String, String> headers;
  final String body;
  JsonMap get json => (jsonDecode(body) as Map).cast<String, Object?>();
}

/// A local stand-in for api.anthropic.com.
final class FakeAnthropic {
  late HttpServer _server;
  final List<Recorded> requests = [];
  FutureOr<Response> Function(Recorded r) handler = (_) => Response.notFound('no handler');

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> start() async {
    _server = await shelf_io.serve((Request r) async {
      final rec = Recorded(r.method, r.url.path, r.url.queryParameters, r.headers, await r.readAsString());
      requests.add(rec);
      return handler(rec);
    }, '127.0.0.1', 0);
  }

  Future<void> close() => _server.close(force: true);
}

Response sse(String text, {Map<String, String> headers = const {}}) =>
    Response.ok(text, headers: {'content-type': 'text/event-stream', ...headers});

Response streamed(Stream<List<int>> body) => Response.ok(
      body,
      headers: {'content-type': 'text/event-stream'},
      context: {'shelf.io.buffer_output': false},
    );

Response jsonResponse(int status, Object body, {Map<String, String> headers = const {}}) =>
    Response(status, body: jsonEncode(body), headers: {'content-type': 'application/json', ...headers});

JsonMap errorBody(String type, String message) => {
      'type': 'error',
      'error': {'type': type, 'message': message},
      'request_id': 'req_011TEST',
    };

ModelRequest simpleRequest({String model = 'claude-opus-5-5', String? session}) => ModelRequest(
      modelId: model,
      systemPrompt: 'You are Sherpa.',
      messages: [user('u1', 'hello')],
      cache: CacheHints(sessionId: session),
    );

/// Splits a fixture into its SSE events (blank-line separated).
List<String> eventsOf(String fixtureText) =>
    [for (final e in fixtureText.split('\n\n')) if (e.trim().isNotEmpty) '$e\n\n'];

void main() {
  late FakeAnthropic server;
  late http.Client client;

  AnthropicProvider provider({
    Map<String, String> headers = const {},
    Map<String, ModelCapabilities> overrides = const {},
    Uri? baseUrl,
    bool allowLocal = true,
    Clock clock = const SystemClock(),
  }) =>
      AnthropicProvider(
        config: testConfig(baseUrl: baseUrl ?? server.base, allowLocal: allowLocal, headers: headers)
            .copyWith(modelOverrides: overrides),
        apiKey: apiKey,
        client: client,
        clock: clock,
      );

  setUp(() async {
    server = FakeAnthropic();
    await server.start();
    client = http.Client();
  });

  tearDown(() async {
    client.close();
    await server.close();
  });

  group('streaming', () {
    test('POST /v1/messages with auth, version, config headers and a streaming body', () async {
      server.handler = (_) => sse(fixture('text'));
      final p = provider(headers: {'Anthropic-Beta': 'context-management-2025-06-27', 'X-Api-Key': 'not-this-one'});
      final events = await p.stream(simpleRequest()).toList();
      expect(describe(events.last), 'finish:stop:end_turn');
      expect(events.whereType<TextDelta>().map((e) => e.text).join(), 'Hello from Tōkyō, 18°C 日本');

      final r = server.requests.single;
      expect(r.method, 'POST');
      expect(r.path, 'v1/messages');
      expect(r.headers['x-api-key'], apiKey, reason: 'config headers cannot replace the credential');
      expect(r.headers['anthropic-version'], '2023-06-01');
      expect(r.headers['anthropic-beta'], 'context-management-2025-06-27');
      expect(r.headers['content-type'], startsWith('application/json'));
      expect(r.headers['accept'], 'text/event-stream');
      expect(r.json['model'], 'claude-opus-5-5');
      expect(r.json['stream'], isTrue);
      expect(r.json['system'], [
        {
          'type': 'text',
          'text': 'You are Sherpa.',
          'cache_control': {'type': 'ephemeral'},
        },
      ]);
      // Not first-party: no eager_input_streaming (proxies may reject it).
      expect(r.body, isNot(contains('eager_input_streaming')));
    });

    test('a base URL that already ends in /v1 is not doubled', () async {
      server.handler = (_) => sse(fixture('text'));
      await provider(baseUrl: server.base.replace(path: '/v1/')).stream(simpleRequest()).drain<void>();
      expect(server.requests.single.path, 'v1/messages');
      expect(provider().info.location, ExecutionLocation.remote);
      expect(provider().info.kind, ProviderKind.anthropic);
      expect(provider().info.dataLeavesDevice, isTrue);
    });

    test('events are delivered incrementally, not after the body completes', () async {
      final body = StreamController<List<int>>();
      server.handler = (_) => streamed(body.stream);
      final parts = eventsOf(fixture('thinking_signature'));
      final seen = <ModelEvent>[];
      final done = Completer<void>();
      provider().stream(simpleRequest()).listen(seen.add, onDone: done.complete);
      for (final e in parts.take(3)) {
        body.add(utf8.encode(e));
      }
      await eventually(() => seen.whereType<ReasoningDelta>().isNotEmpty);
      expect(seen.whereType<Finish>(), isEmpty, reason: 'the server has not finished yet');
      for (final e in parts.skip(3)) {
        body.add(utf8.encode(e));
      }
      await body.close();
      await done.future;
      expect(describe(seen.last), 'finish:length:max_tokens');
    });

    test('cancelling the token aborts the request (server sees the disconnect) and ends with Finish(cancelled)',
        () async {
      final disconnected = Completer<void>();
      Timer? pinger;
      server.handler = (_) {
        late StreamController<List<int>> body;
        body = StreamController<List<int>>(onCancel: () {
          pinger?.cancel();
          if (!disconnected.isCompleted) disconnected.complete();
          unawaited(body.close());
        });
        for (final e in eventsOf(fixture('text')).take(4)) {
          body.add(utf8.encode(e));
        }
        // Keep writing so the server notices the closed socket.
        pinger = Timer.periodic(const Duration(milliseconds: 20), (_) {
          body.add(utf8.encode('event: ping\ndata: {"type":"ping"}\n\n'));
        });
        return streamed(body.stream);
      };
      final token = CancellationToken();
      final seen = <ModelEvent>[];
      final done = Completer<void>();
      provider().stream(simpleRequest(), cancel: token).listen(seen.add, onDone: done.complete);
      await eventually(() => seen.whereType<TextDelta>().isNotEmpty);
      token.cancel('user pressed stop');
      await done.future.timeout(const Duration(seconds: 5));
      expect(seen.last, isA<Finish>().having((f) => f.reason, 'reason', FinishReason.cancelled));
      expect((seen.last as Finish).rawReason, 'user pressed stop');
      await disconnected.future.timeout(const Duration(seconds: 5));
    });

    test('cancelling the subscription also aborts the request', () async {
      final disconnected = Completer<void>();
      Timer? pinger;
      server.handler = (_) {
        late StreamController<List<int>> body;
        body = StreamController<List<int>>(onCancel: () {
          pinger?.cancel();
          if (!disconnected.isCompleted) disconnected.complete();
          unawaited(body.close());
        });
        body.add(utf8.encode(eventsOf(fixture('text')).first));
        pinger = Timer.periodic(const Duration(milliseconds: 20), (_) {
          body.add(utf8.encode('event: ping\ndata: {"type":"ping"}\n\n'));
        });
        return streamed(body.stream);
      };
      final first = Completer<void>();
      final sub = provider().stream(simpleRequest()).listen((_) {
        if (!first.isCompleted) first.complete();
      });
      await first.future;
      await sub.cancel();
      await disconnected.future.timeout(const Duration(seconds: 5));
    });

    test('a token cancelled before listening never sends a request', () async {
      server.handler = (_) => sse(fixture('text'));
      final token = CancellationToken()..cancel();
      final events = await provider().stream(simpleRequest(), cancel: token).toList();
      expect(events.map(describe), ['finish:cancelled:cancelled']);
      expect(server.requests, isEmpty);
    });

    test('pausing the subscription holds events until resumed', () async {
      final body = StreamController<List<int>>();
      server.handler = (_) => streamed(body.stream);
      final parts = eventsOf(fixture('text'));
      final seen = <ModelEvent>[];
      final done = Completer<void>();
      final sub = provider().stream(simpleRequest()).listen(seen.add, onDone: done.complete);
      body.add(utf8.encode(parts.first));
      await eventually(() => seen.isNotEmpty);
      sub.pause();
      final before = seen.length;
      for (final e in parts.skip(1)) {
        body.add(utf8.encode(e));
      }
      await body.close();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(seen.length, before, reason: 'no events while paused');
      sub.resume();
      await done.future;
      await sub.cancel();
      expect(describe(seen.last), 'finish:stop:end_turn');
    });

    test('mid-stream error: partial output, then ProviderException(overloaded)', () async {
      server.handler = (_) => sse(fixture('error_midstream'));
      final seen = <ModelEvent>[];
      Object? error;
      final done = Completer<void>();
      provider().stream(simpleRequest()).listen(seen.add, onError: (Object e) => error = e, onDone: done.complete);
      await done.future;
      expect(seen.whereType<ReasoningDelta>().single.text, 'Two independent lookups');
      expect(seen.whereType<Finish>(), isEmpty);
      expect(error, isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.overloaded));
    });

    test('a connection that drops before message_stop is a retryable network error', () async {
      final text = fixture('parallel_tool_use');
      server.handler = (_) => sse(text.substring(0, text.indexOf('event: message_delta')));
      await expectLater(
        provider().stream(simpleRequest()).toList(),
        throwsA(isA<ProviderException>()
            .having((e) => e.kind, 'kind', ProviderErrorKind.network)
            .having((e) => e.isRetryable, 'retryable', isTrue)),
      );
    });

    test('a JSON 200 instead of an event stream is reported, not parsed as SSE', () async {
      server.handler = (_) => jsonResponse(200, {'id': 'msg', 'content': <Object?>[]});
      await expectLater(
        provider().stream(simpleRequest()).toList(),
        throwsA(isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.server)),
      );
    });

    test('low rate-limit headroom is surfaced as a notice', () async {
      server.handler = (_) => sse(fixture('text'), headers: {
            'anthropic-ratelimit-input-tokens-limit': '80000',
            'anthropic-ratelimit-input-tokens-remaining': '4000',
            'anthropic-ratelimit-input-tokens-reset': '2026-10-18T12:01:00Z',
            'anthropic-ratelimit-requests-limit': '50',
            'anthropic-ratelimit-requests-remaining': '49',
          });
      final events = await provider().stream(simpleRequest()).toList();
      final n = events.whereType<ProviderNotice>().single;
      expect(n.code, 'anthropic.rate_limit_low');
      expect(n.message, contains('4000/80000 input-tokens'));
    });

    test('debug prefix guard warns when a session edits history before replayed thinking', () async {
      server.handler = (_) => sse(fixture('text'));
      final p = provider();
      final base = [
        user('u1', 'hi'),
        assistant('a1', [thinking('t', 'SIG'), const TextPart('x')]),
        user('u2', 'more'),
      ];
      await p.stream(ModelRequest(modelId: 'claude-opus-5-5', messages: base, cache: const CacheHints(sessionId: 's'))).drain<void>();
      final edited = [user('u1', 'hi (edited)'), ...base.skip(1)];
      final events =
          await p.stream(ModelRequest(modelId: 'claude-opus-5-5', messages: edited, cache: const CacheHints(sessionId: 's'))).toList();
      expect(events.whereType<ProviderNotice>().map((n) => n.code), contains('anthropic.prefix_changed'));
    });
  });

  group('HTTP errors', () {
    final now = DateTime.utc(2026, 10, 18, 12);
    final cases = <(String, Response Function(), ProviderErrorKind, Duration?)>[
      (
        '429 with retry-after → rateLimited',
        () => jsonResponse(429, errorBody('rate_limit_error', 'Number of request tokens has exceeded your per-minute rate limit'),
            headers: {'retry-after': '7'}),
        ProviderErrorKind.rateLimited,
        const Duration(seconds: 7),
      ),
      (
        '429 without retry-after (spend cap) → quotaExceeded',
        () => jsonResponse(429, errorBody('rate_limit_error', 'This request would exceed your organization’s rate limit tier.')),
        ProviderErrorKind.quotaExceeded,
        null,
      ),
      (
        '429 without retry-after but an exhausted bucket with a reset → rateLimited',
        () => jsonResponse(429, errorBody('rate_limit_error', 'rate limited'), headers: {
              'anthropic-ratelimit-tokens-limit': '1000',
              'anthropic-ratelimit-tokens-remaining': '0',
              'anthropic-ratelimit-tokens-reset': '2026-10-18T12:00:30Z',
            }),
        ProviderErrorKind.rateLimited,
        const Duration(seconds: 30),
      ),
      (
        '529 → overloaded',
        () => jsonResponse(529, errorBody('overloaded_error', 'Overloaded')),
        ProviderErrorKind.overloaded,
        null,
      ),
      ('500 → server', () => jsonResponse(500, errorBody('api_error', 'Internal')), ProviderErrorKind.server, null),
      ('504 → timeout', () => jsonResponse(504, errorBody('timeout_error', 'slow')), ProviderErrorKind.timeout, null),
      (
        '401 → auth',
        () => jsonResponse(401, errorBody('authentication_error', 'invalid x-api-key $apiKey')),
        ProviderErrorKind.auth,
        null,
      ),
      ('403 → auth', () => jsonResponse(403, errorBody('permission_error', 'no')), ProviderErrorKind.auth, null),
      (
        '402 → quotaExceeded',
        () => jsonResponse(402, errorBody('billing_error', 'Payment required')),
        ProviderErrorKind.quotaExceeded,
        null,
      ),
      (
        '404 → modelNotFound',
        () => jsonResponse(404, errorBody('not_found_error', 'model: claude-nope')),
        ProviderErrorKind.modelNotFound,
        null,
      ),
      (
        '400 prompt too long → contextOverflow',
        () => jsonResponse(400, errorBody('invalid_request_error', 'prompt is too long: 1048576 tokens > 1000000 maximum')),
        ProviderErrorKind.contextOverflow,
        null,
      ),
      (
        '413 → contextOverflow',
        () => jsonResponse(413, errorBody('request_too_large', 'Request exceeds the maximum allowed number of bytes.')),
        ProviderErrorKind.contextOverflow,
        null,
      ),
      (
        '400 credit balance → quotaExceeded',
        () => jsonResponse(400, errorBody('invalid_request_error', 'Your credit balance is too low to access the Anthropic API.')),
        ProviderErrorKind.quotaExceeded,
        null,
      ),
      (
        '400 other → invalidRequest',
        () => jsonResponse(400, errorBody('invalid_request_error', 'messages: roles must alternate')),
        ProviderErrorKind.invalidRequest,
        null,
      ),
      (
        'non-JSON proxy error page → server',
        () => Response(502, body: '<html>Bad gateway</html>'),
        ProviderErrorKind.server,
        null,
      ),
    ];
    for (final (name, response, kind, retryAfter) in cases) {
      test(name, () async {
        server.handler = (_) => response();
        final p = provider(clock: FakeClock(now));
        try {
          await p.stream(simpleRequest()).toList();
          fail('expected a ProviderException');
        } on ProviderException catch (e) {
          expect(e.kind, kind);
          expect(e.retryAfter, retryAfter);
          expect(e.providerId, providerId);
          expect(e.message, isNot(contains(apiKey)), reason: 'keys are redacted from messages');
        }
      });
    }

    test('signature rejection explains preserved thinking', () async {
      server.handler = (_) => jsonResponse(
            400,
            errorBody('invalid_request_error',
                'messages.1.content.0: Invalid `signature` in `thinking` block. The block is bound to a different conversation.'),
          );
      await expectLater(
        provider().stream(simpleRequest()).toList(),
        throwsA(isA<ProviderException>()
            .having((e) => e.kind, 'kind', ProviderErrorKind.invalidRequest)
            .having((e) => e.statusCode, 'status', 400)
            .having((e) => e.message, 'message', contains('replayed thinking block'))
            .having((e) => e.message, 'message', contains('req_011TEST'))),
      );
    });
  });

  group('URL policy', () {
    test('a local base URL is refused unless the config allows the local network', () async {
      server.handler = (_) => sse(fixture('text'));
      await expectLater(
        provider(allowLocal: false).stream(simpleRequest()).toList(),
        throwsA(isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.invalidRequest)),
      );
      expect(server.requests, isEmpty);
      await expectLater(provider(allowLocal: false).countTokens(simpleRequest()), completion(isNull));
      expect(server.requests, isEmpty);
    });
  });

  group('models', () {
    JsonMap model(String id, {required JsonMap caps, int window = 1000000, int out = 128000, String? lifecycle}) => {
          'type': 'model',
          'id': id,
          'display_name': id.replaceAll('-', ' '),
          'created_at': '2026-09-01T00:00:00Z',
          'max_input_tokens': window,
          'max_tokens': out,
          'lifecycle': ?lifecycle,
          if (lifecycle == 'deprecated') 'retires_at': '2027-01-01',
          'capabilities': caps,
        };
    const alwaysOn = {
      'image_input': {'supported': true},
      'thinking': {
        'supported': true,
        'types': {
          'adaptive': {'supported': true},
          'enabled': {'supported': false},
          'disabled': {'supported': false},
        },
      },
      'effort': {
        'supported': true,
        'low': {'supported': true},
        'medium': {'supported': true},
        'high': {'supported': true},
        'xhigh': {'supported': true},
        'max': {'supported': true},
      },
    };
    const budgetOnly = {
      'image_input': {'supported': true},
      'thinking': {
        'supported': true,
        'types': {
          'adaptive': {'supported': false},
          'enabled': {'supported': true},
          'disabled': {'supported': true},
        },
      },
      'effort': {'supported': false},
    };

    test('listModels follows pagination and maps capabilities; capabilities() then hits the cache', () async {
      server.handler = (r) {
        if (r.path == 'v1/models' && r.query['after_id'] == null) {
          return jsonResponse(200, {
            'data': [model('claude-opus-5-5', caps: alwaysOn)],
            'has_more': true,
            'first_id': 'claude-opus-5-5',
            'last_id': 'claude-opus-5-5',
          });
        }
        if (r.path == 'v1/models' && r.query['after_id'] == 'claude-opus-5-5') {
          return jsonResponse(200, {
            'data': [model('claude-haiku-4-5', caps: budgetOnly, window: 200000, out: 64000, lifecycle: 'deprecated')],
            'has_more': false,
            'first_id': 'claude-haiku-4-5',
            'last_id': 'claude-haiku-4-5',
          });
        }
        return Response.notFound('unexpected ${r.path}');
      };
      final p = provider();
      final models = await p.listModels();
      expect(server.requests.map((r) => r.query), [
        {'limit': '100'},
        {'limit': '100', 'after_id': 'claude-opus-5-5'},
      ]);
      expect(server.requests.first.headers['x-api-key'], apiKey);
      expect(models.map((m) => m.id), ['claude-opus-5-5', 'claude-haiku-4-5']);
      final opus = models.first.capabilities;
      expect(opus.contextLength, 1000000);
      expect(opus.maxOutputTokens, 128000);
      expect(opus.vision, isTrue);
      expect(opus.reasoning, ReasoningSupport.always);
      expect(opus.toolCallFormat, ToolCallFormat.native);
      expect(opus.supportsPromptCache, isTrue);
      expect(opus.historyPolicy, HistoryPolicy.appendOnly);
      expect(opus.tokenizerFamily, 'claude');
      final haiku = models.last;
      expect(haiku.capabilities.contextLength, 200000);
      expect(haiku.capabilities.reasoning, ReasoningSupport.optional);
      expect(haiku.description, 'Lifecycle: deprecated (retires 2027-01-01)');
      expect(haiku.providerId, providerId);

      final before = server.requests.length;
      expect((await p.capabilities('claude-opus-5-5')).contextLength, 1000000);
      expect(server.requests.length, before, reason: 'served from the listModels cache');
    });

    test('capabilities: GET /v1/models/{id}; static fallback when it fails; overrides first', () async {
      server.handler = (r) => r.path == 'v1/models/claude-sonnet-5-5'
          ? jsonResponse(200, model('claude-sonnet-5-5', caps: alwaysOn, window: 900000))
          : jsonResponse(500, errorBody('api_error', 'down'));
      final p = provider(overrides: {'claude-custom': const ModelCapabilities(contextLength: 50000)});
      expect((await p.capabilities('claude-sonnet-5-5')).contextLength, 900000);
      final fallback = await p.capabilities('claude-opus-5-5');
      expect(fallback.contextLength, 1000000);
      expect(fallback.historyPolicy, HistoryPolicy.appendOnly);
      final n = server.requests.length;
      await p.capabilities('claude-opus-5-5');
      expect(server.requests.length, n, reason: 'fallback is cached for a while');
      final custom = await p.capabilities('claude-custom');
      expect(custom.contextLength, 50000);
      expect(custom.historyPolicy, HistoryPolicy.appendOnly, reason: 'Anthropic history is always append-only');
      expect(server.requests.length, n, reason: 'overrides need no lookup');
    });

    test('listModels falls back to the bundled list when the API is down, but surfaces auth errors', () async {
      server.handler = (_) => jsonResponse(503, errorBody('overloaded_error', 'busy'));
      final offline = await provider().listModels();
      expect(offline.map((m) => m.id), contains('claude-opus-5-5'));
      expect(offline.every((m) => m.capabilities.historyPolicy == HistoryPolicy.appendOnly), isTrue);
      server.handler = (_) => jsonResponse(401, errorBody('authentication_error', 'invalid x-api-key'));
      await expectLater(
        provider().listModels(),
        throwsA(isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.auth)),
      );
    });

    test('countTokens posts the prompt fields and returns input_tokens; null on failure', () async {
      server.handler = (r) => r.path == 'v1/messages/count_tokens'
          ? jsonResponse(200, {'input_tokens': 1234})
          : Response.notFound('');
      final p = provider();
      final req = ModelRequest(
        modelId: 'claude-opus-5-5',
        systemPrompt: 'sys',
        messages: [user('u', 'hi')],
        tools: [tool('t')],
        params: const GenerationParams(toolChoice: ToolChoice.required, maxOutputTokens: 100),
      );
      expect(await p.countTokens(req), 1234);
      final body = server.requests.single.json;
      expect(body.keys, ['model', 'system', 'messages', 'tools', 'tool_choice', 'thinking']);
      expect(body['tool_choice'], {'type': 'auto'}, reason: 'forced choice 400s on count_tokens too');
      server.handler = (_) => jsonResponse(500, errorBody('api_error', 'x'));
      expect(await p.countTokens(req), isNull);
    });
  });
}
