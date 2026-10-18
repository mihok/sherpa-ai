import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';
import 'package:test/test.dart';

import '../support/fake_server.dart';
import '../support/helpers.dart';

Map<String, Object?> chunk(Map<String, Object?> delta, {String? finish}) => {
      'id': 'chatcmpl-x',
      'object': 'chat.completion.chunk',
      'choices': [
        {'index': 0, 'delta': delta, 'finish_reason': finish},
      ],
    };

void main() {
  late FakeServer server;
  late http.Client client;

  setUp(() async {
    server = await FakeServer.start();
    client = http.Client();
  });

  tearDown(() async {
    client.close();
    await server.close();
  });

  OpenAiChatProvider provider({
    ServerProfile profile = ServerProfile.openAi,
    String? apiKey,
    Map<String, String> headers = const {},
  }) =>
      OpenAiChatProvider(
        config: testConfig(server.v1, profile: profile, headers: headers),
        apiKey: apiKey,
        client: client,
      );

  test('tokens are delivered incrementally, not after the body ends', () async {
    final script = SseScript();
    final firstSeen = Completer<void>();
    server.route('POST /v1/chat/completions', (_) {
      unawaited(() async {
        script
          ..data(chunk({'role': 'assistant', 'content': ''}))
          ..data(chunk({'content': 'Hel'}));
        // The rest is only sent after the client proved it already has the
        // first token; a buffering client would deadlock here.
        await firstSeen.future.timeout(const Duration(seconds: 5));
        script
          ..data(chunk({'content': 'lo'}))
          ..data(chunk({}, finish: 'stop'))
          ..send('data: [DONE]\n\n');
        await script.close();
      }());
      return script.response();
    });

    final events = <ModelEvent>[];
    await for (final e in provider().stream(weatherRequest(tools: const []))) {
      events.add(e);
      if (e is TextDelta && !firstSeen.isCompleted) firstSeen.complete();
    }
    expect(describeAll(events), ['Text(Hel)', 'Text(lo)', 'Finish(stop)']);
  });

  test('cancelling the token mid-stream aborts the request; the server sees the disconnect', () async {
    final script = SseScript();
    server.route('POST /v1/chat/completions', (_) {
      script.data(chunk({'content': 'first'}));
      // Keep the stream open with periodic chunks, like a long generation.
      Timer.periodic(const Duration(milliseconds: 20), (t) {
        if (script.disconnected.isCompleted || script.isClosed) {
          t.cancel();
        } else {
          script.data(chunk({'content': '.'}));
        }
      });
      return script.response();
    });

    final token = CancellationToken();
    final events = <ModelEvent>[];
    final done = provider().stream(weatherRequest(tools: const []), cancel: token).forEach((e) {
      events.add(e);
      if (e is TextDelta && e.text == 'first') token.cancel('user pressed stop');
    });
    await done.timeout(const Duration(seconds: 5));
    expect(events.last, isA<Finish>().having((f) => f.reason, 'reason', FinishReason.cancelled));
    expect(events.whereType<Finish>(), hasLength(1));
    await script.disconnected.future.timeout(const Duration(seconds: 5));
  });

  test('cancelling the subscription also aborts the socket', () async {
    final script = SseScript();
    server.route('POST /v1/chat/completions', (_) {
      script.data(chunk({'content': 'first'}));
      Timer.periodic(const Duration(milliseconds: 20), (t) {
        if (script.disconnected.isCompleted) {
          t.cancel();
        } else {
          script.data(chunk({'content': '.'}));
        }
      });
      return script.response();
    });
    final sub = provider().stream(weatherRequest(tools: const [])).listen(null);
    final first = Completer<void>();
    sub.onData((e) {
      if (!first.isCompleted) first.complete();
    });
    await first.future.timeout(const Duration(seconds: 5));
    await sub.cancel().timeout(const Duration(seconds: 2));
    await script.disconnected.future.timeout(const Duration(seconds: 5));
  });

  test('cancelling while waiting for response headers ends promptly', () async {
    final release = Completer<void>();
    server.route('POST /v1/chat/completions', (_) async {
      await release.future;
      return jsonResponse({});
    });
    final token = CancellationToken();
    final stopwatch = Stopwatch()..start();
    final events = provider().stream(weatherRequest(tools: const []), cancel: token).toList();
    await eventually(() => server.requests.isNotEmpty);
    token.cancel();
    final got = await events.timeout(const Duration(seconds: 2));
    expect(describeAll(got), ['Finish(cancelled)']);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    release.complete();
  });

  test('an already-cancelled token sends nothing', () async {
    final token = CancellationToken()..cancel();
    final got = await provider().stream(weatherRequest(), cancel: token).toList();
    expect(describeAll(got), ['Finish(cancelled)']);
    expect(server.requests, isEmpty);
  });

  test('pausing the subscription stops reading the socket (backpressure)', () async {
    var serverPaused = false;
    var sentBytes = 0;
    late final StreamController<List<int>> body;
    final payload = utf8.encode('data: ${jsonEncode(chunk({'content': 'x' * 4000}))}\n\n');
    void pump() {
      // Write as fast as the transport accepts; stop when it pushes back.
      while (!serverPaused && !body.isClosed && sentBytes < 256 << 20) {
        body.add(payload);
        sentBytes += payload.length;
        if (sentBytes % (1 << 20) < payload.length) {
          // Yield to the event loop so socket I/O (and pause signals) run.
          Timer.run(pump);
          return;
        }
      }
    }

    body = StreamController<List<int>>(
      onListen: pump,
      onPause: () => serverPaused = true,
      onResume: () {
        serverPaused = false;
        pump();
      },
    );
    server.route('POST /v1/chat/completions', (_) => Response.ok(body.stream,
        headers: {'content-type': 'text/event-stream'}, context: {'shelf.io.buffer_output': false}));

    late final StreamSubscription<ModelEvent> sub;
    final first = Completer<void>();
    sub = provider().stream(weatherRequest(tools: const [])).listen((e) {
      if (!first.isCompleted) {
        first.complete();
        sub.pause();
      }
    });
    await first.future.timeout(const Duration(seconds: 5));
    await eventually(() => serverPaused, timeout: const Duration(seconds: 10));
    // Kernel socket buffers drain a little after the first push-back; wait
    // until the producer has been blocked for a while.
    var settled = sentBytes;
    for (var stable = 0; stable < 3;) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      stable = sentBytes == settled ? stable + 1 : 0;
      settled = sentBytes;
    }
    // Far less than the 256 MiB the server would send unthrottled: the
    // paused consumer stopped the socket reads all the way to the server.
    expect(sentBytes, lessThan(64 << 20));
    sub.resume();
    await eventually(() => sentBytes > settled, timeout: const Duration(seconds: 10));
    await sub.cancel();
    await body.close();
  });

  group('HTTP errors over the wire', () {
    Future<ProviderException> failWith(int status, Object body, {Map<String, String> headers = const {}}) async {
      server.route('POST /v1/chat/completions', (_) => jsonResponse(body, status: status, headers: headers));
      final (events, error) = await collectWithError(provider().stream(weatherRequest()));
      expect(events, isEmpty);
      return error! as ProviderException;
    }

    test('429 with Retry-After', () async {
      final e = await failWith(429, {
        'error': {'message': 'Rate limit reached', 'type': 'requests', 'code': 'rate_limit_exceeded'},
      }, headers: {'retry-after': '3'});
      expect(e.kind, ProviderErrorKind.rateLimited);
      expect(e.retryAfter, const Duration(seconds: 3));
    });

    test('429 insufficient_quota is not retryable', () async {
      final e = await failWith(429, {
        'error': {'message': 'You exceeded your current quota', 'type': 'insufficient_quota', 'code': 'insufficient_quota'},
      });
      expect(e.kind, ProviderErrorKind.quotaExceeded);
      expect(e.isRetryable, isFalse);
    });

    test('503 overloaded, 401 auth, 404 model, 400 context overflow', () async {
      expect((await failWith(503, {'error': {'message': 'overloaded', 'code': 'server_is_overloaded'}})).kind,
          ProviderErrorKind.overloaded);
      expect((await failWith(401, {'error': {'message': 'bad key'}})).kind, ProviderErrorKind.auth);
      expect((await failWith(404, {'error': {'message': 'model not found'}})).kind, ProviderErrorKind.modelNotFound);
      expect(
        (await failWith(400, {
          'error': {'message': 'maximum context length is 8192 tokens', 'code': 'context_length_exceeded'},
        }))
            .kind,
        ProviderErrorKind.contextOverflow,
      );
    });

    test('the API key never appears in error messages', () async {
      server.route('POST /v1/chat/completions',
          (r) => Response(401, body: 'Bad credentials: ${r.headers['authorization']}', headers: {'content-type': 'text/plain'}));
      final (_, error) = await collectWithError(provider(apiKey: 'sk-test-0123456789abcdefghij').stream(weatherRequest()));
      expect((error! as ProviderException).message, isNot(contains('0123456789abcdefghij')));
    });

    test('connection refused is a retryable network error', () async {
      await server.close();
      final (_, error) = await collectWithError(provider().stream(weatherRequest()));
      expect(error, isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.network));
      expect((error! as ProviderException).isRetryable, isTrue);
    });
  });

  test('a server rejecting stream_options is retried once without it, and remembered', () async {
    server.route('POST /v1/chat/completions', (r) async {
      final body = jsonDecode(await r.readAsString()) as Map<String, Object?>;
      if (body.containsKey('stream_options')) {
        return jsonResponse({
          'error': {
            'message': 'Unrecognized request argument supplied: stream_options',
            'type': 'invalid_request_error',
            'param': 'stream_options',
          },
        }, status: 400);
      }
      return sseFromText(fixture('f3_ollama_whole_tool_calls.sse'));
    });
    final p = provider(profile: ServerProfile.generic);
    final first = await collect(p.stream(weatherRequest()));
    expect(first.whereType<ProviderNotice>().map((n) => n.code), contains('usage_unavailable'));
    expect(first.last, isA<Finish>());
    expect(server.requests.map((r) => r.json.containsKey('stream_options')), [true, false]);
    await collect(p.stream(weatherRequest()));
    expect(server.requests.map((r) => r.json.containsKey('stream_options')), [true, false, false]);
  });

  test('mid-stream llama.cpp error over HTTP', () async {
    server.route('POST /v1/chat/completions', (_) => sseFromText(fixture('f2b_llamacpp_midstream_error.sse'), chunkSize: 7));
    final (events, error) = await collectWithError(provider(profile: ServerProfile.llamaCpp).stream(weatherRequest()));
    expect(describeAll(events), ['Reasoning(Need weather and time; call both.)']);
    expect(error, isA<ProviderException>());
  });

  test('OpenRouter comments and slow tiny chunks over HTTP', () async {
    server.route('POST /v1/chat/completions',
        (_) => sseFromText(fixture('openrouter_reasoning_details.sse'), chunkSize: 13, delay: const Duration(milliseconds: 1)));
    final events = await collect(provider(profile: ServerProfile.openRouter).stream(weatherRequest()));
    expect(events.whereType<TextDelta>().map((e) => e.text).join(), 'Checking.');
    expect(events.last, isA<Finish>().having((f) => f.reason, 'reason', FinishReason.toolCalls));
  });

  test('request shape: path, auth only with a key, user headers, JSON body', () async {
    server.route('POST /v1/chat/completions', (_) => sseFromText(fixture('f1_openai_chat_parallel_tools.sse')));
    await collect(provider(apiKey: 'sk-abc', headers: {'OpenAI-Organization': 'org-1', 'Authorization': 'Bearer evil'})
        .stream(weatherRequest()));
    await collect(provider().stream(weatherRequest()));
    final withKey = server.requests[0];
    final withoutKey = server.requests[1];
    expect(withKey.path, '/v1/chat/completions');
    expect(withKey.headers['authorization'], 'Bearer sk-abc');
    expect(withKey.headers['openai-organization'], 'org-1');
    expect(withKey.headers['content-type'], startsWith('application/json'));
    expect(withKey.headers['accept'], 'text/event-stream');
    expect(withoutKey.headers.containsKey('authorization'), isFalse);
    expect(withKey.json['model'], 'test-model');
    expect(withKey.json['stream'], isTrue);
  });

  test('a non-streamed JSON completion is still understood', () async {
    server.route('POST /v1/chat/completions', (_) => jsonResponse({
          'id': 'x',
          'choices': [
            {
              'index': 0,
              'message': {
                'role': 'assistant',
                'content': 'Calling.',
                'tool_calls': [
                  {
                    'id': 'call_9',
                    'type': 'function',
                    'function': {'name': 'get_weather', 'arguments': '{"city":"Rome"}'},
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
          'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
        }));
    final events = await collect(provider(profile: ServerProfile.generic).stream(weatherRequest()));
    expect(describeAll(events), [
      'Text(Calling.)',
      'ToolCallStart(0, call_9, get_weather)',
      'ToolCallArgsDelta(0, {"city":"Rome"})',
      'ToolCallComplete(0, call_9, get_weather, {"city":"Rome"})',
      'Usage(in 10, cached 0, out 5, reasoning 0)',
      'Finish(toolCalls)',
    ]);
  });

  test('auto profile is detected once and drives the request quirks', () async {
    server
      ..route('GET /props', (_) => jsonResponse({
            'default_generation_settings': {'n_ctx': 4096},
            'build_info': 'b7000',
          }))
      ..route('POST /v1/chat/completions', (_) => sseFromText(fixture('f2_llamacpp_reasoning_tools.sse')));
    final p = provider(profile: ServerProfile.auto);
    expect(await p.resolveProfile(), ServerProfile.llamaCpp);
    await collect(p.stream(weatherRequest(params: const GenerationParams(toolChoice: ToolChoiceSpecific('get_time')))));
    expect(server.requestsTo('/props'), hasLength(1));
    final body = server.requestsTo('/v1/chat/completions').single.json;
    expect(body['tool_choice'], 'required');
    expect((await p.capabilities('qwen3-8b')).contextLength, 4096);
    expect(server.requestsTo('/props').length, greaterThanOrEqualTo(2));
  });

  group('URL policy', () {
    Future<Object?> errorFor(ProviderConfig config) async {
      final sent = <http.BaseRequest>[];
      final mock = MockClient((r) async {
        sent.add(r);
        return http.Response('{}', 200);
      });
      final p = OpenAiChatProvider(config: config, client: mock);
      final (_, error) = await collectWithError(p.stream(weatherRequest()));
      expect(sent, isEmpty, reason: 'nothing may be sent to a blocked URL');
      await expectLater(p.listModels(), throwsA(isA<ProviderException>()));
      return error;
    }

    Matcher blocked() => isA<ProviderException>()
        .having((e) => e.kind, 'kind', ProviderErrorKind.invalidRequest)
        .having((e) => e.message, 'message', contains('Blocked URL'));

    test('http to a public host is refused', () async {
      expect(await errorFor(testConfig(Uri.parse('http://93.184.216.34/v1'), allowLocalNetwork: false)), blocked());
    });

    test('LAN and loopback need allowLocalNetwork', () async {
      expect(await errorFor(testConfig(Uri.parse('https://10.0.0.5/v1'), allowLocalNetwork: false)), blocked());
      expect(await errorFor(testConfig(Uri.parse('http://127.0.0.1:8080/v1'), allowLocalNetwork: false)), blocked());
      expect(await errorFor(testConfig(Uri.parse('https://localhost/v1'), allowLocalNetwork: false)), blocked());
    });

    test('link-local / metadata addresses are refused even for local servers', () async {
      expect(await errorFor(testConfig(Uri.parse('http://169.254.169.254/v1'))), blocked());
    });

    test('a host that does not resolve is a retryable network error, not a policy violation', () async {
      final p = OpenAiChatProvider(
        config: testConfig(Uri.parse('https://sherpa-test.invalid/v1'), allowLocalNetwork: false),
        client: client,
      );
      final (_, error) = await collectWithError(p.stream(weatherRequest()));
      expect(error, isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.network));
    });
  });

  test('redirects are not followed (credentials never go to an unchecked host)', () async {
    server
      ..route('POST /v1/chat/completions', (_) => Response(307, headers: {'location': '${server.root}/elsewhere'}))
      ..route('POST /elsewhere', (_) => sseFromText(fixture('f1_openai_chat_parallel_tools.sse')));
    final (_, error) = await collectWithError(provider(apiKey: 'sk-secret').stream(weatherRequest()));
    expect(error, isA<ProviderException>().having((e) => e.statusCode, 'status', 307));
    expect(server.requestsTo('/elsewhere'), isEmpty);
  });

  test('info.location distinguishes remote and local endpoints', () {
    ExecutionLocation loc(String url) =>
        OpenAiChatProvider(config: testConfig(Uri.parse(url)), client: client).info.location;
    expect(loc('https://api.openai.com/v1'), ExecutionLocation.remote);
    expect(loc('https://openrouter.ai/api/v1'), ExecutionLocation.remote);
    expect(loc('http://192.168.1.20:8080/v1'), ExecutionLocation.localNetwork);
    expect(loc('http://10.0.2.2:11434/v1'), ExecutionLocation.localNetwork);
    expect(loc('http://localhost:1234/v1'), ExecutionLocation.localNetwork);
    expect(loc('http://gpu-box:8000/v1'), ExecutionLocation.localNetwork);
    expect(loc('http://studio.local:1234/v1'), ExecutionLocation.localNetwork);
    expect(loc('http://[::1]:8080/v1'), ExecutionLocation.localNetwork);
    final info = OpenAiChatProvider(config: testConfig(Uri.parse('https://api.openai.com/v1')), client: client).info;
    expect(info.kind, ProviderKind.openAiCompatible);
    expect(info.dataLeavesDevice, isTrue);
  });
}
