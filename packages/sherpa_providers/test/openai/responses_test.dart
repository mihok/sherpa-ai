import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';
import 'package:test/test.dart';

import '../support/fake_server.dart';
import '../support/helpers.dart';

void main() {
  ResponsesRequestBody build({
    String model = 'gpt-6-astra',
    GenerationParams params = const GenerationParams(),
    List<Message>? messages,
    List<ToolDefinition> tools = const [weatherTool, timeTool],
    Set<String> rejected = const {},
  }) {
    final request = ModelRequest(
      modelId: model,
      systemPrompt: 'You are Sherpa.',
      messages: messages ?? [userText('hi')],
      tools: tools,
      params: params,
      cache: const CacheHints(sessionId: 's1'),
    );
    return buildResponsesRequest(
      request: request,
      names: ToolNameMapper(visibleTools(request).map((t) => t.name)),
      providerId: 'me',
      rejected: rejected,
    );
  }

  test('stateless body: store false, encrypted reasoning, flat tools, instructions', () {
    final r = build(
      params: const GenerationParams(
        maxOutputTokens: 900,
        reasoning: ReasoningEffort.medium,
        toolChoice: ToolChoiceSpecific('get_time'),
        parallelToolCalls: false,
        jsonSchema: {'type': 'object'},
        stop: ['x'],
        seed: 1,
      ),
    );
    final b = r.body;
    expect(b['store'], isFalse);
    expect(b['stream'], isTrue);
    expect(b['include'], ['reasoning.encrypted_content']);
    expect(b['instructions'], 'You are Sherpa.');
    expect(b['reasoning'], {'effort': 'medium', 'summary': 'auto'});
    expect(b['max_output_tokens'], 900);
    expect(b['tool_choice'], {'type': 'function', 'name': 'get_time'});
    expect(b['parallel_tool_calls'], isFalse);
    expect((b['tools']! as List).first, {
      'type': 'function',
      'name': 'get_weather',
      'description': 'Current weather for a city.',
      'parameters': weatherTool.inputSchema,
      'strict': false,
    });
    expect((b['text']! as Map)['format'], containsPair('type', 'json_schema'));
    expect(b['prompt_cache_key'], startsWith('sherpa-'));
    expect(r.notices.map((n) => n.code), ['param_unsupported', 'param_unsupported']);
    expect(b['input'], [
      {
        'role': 'user',
        'content': 'hi',
      },
    ]);
  });

  test('known non-reasoning models get no reasoning object; rejected params are stripped', () {
    final b = build(model: 'gpt-4o').body;
    expect(b.containsKey('reasoning'), isFalse);
    expect(b.containsKey('include'), isFalse);
    final stripped = build(rejected: {'reasoning.summary', 'include'}).body;
    expect(stripped.containsKey('reasoning'), isFalse);
    expect(stripped.containsKey('include'), isFalse);
    final withEffort = build(rejected: {'reasoning.summary'}, params: const GenerationParams(reasoning: ReasoningEffort.off));
    expect(withEffort.body['reasoning'], {'effort': 'none'});
  });

  test('input items: own encrypted reasoning, function calls and outputs, no ids', () {
    final png = Uint8List.fromList([1, 2, 3]);
    final r = build(messages: [
      userText('weather?'),
      Message(
        id: 'a1',
        role: Role.assistant,
        content: const [
          ReasoningPart(text: 'Two lookups.', signature: 'enc-1', providerId: 'me'),
          ReasoningPart(text: 'foreign', signature: 'enc-x', providerId: 'someone-else'),
          ReasoningPart(text: 'no state', providerId: 'me'),
          TextPart('Checking.'),
          ToolCallPart(ToolCall(id: 'call_1', name: 'get_weather', arguments: {'city': 'Paris'}, rawArguments: '{"city":"Paris"}')),
        ],
        createdAt: t0,
      ),
      Message(
        id: 't1',
        role: Role.tool,
        content: [
          ToolResultPart(
            callId: 'call_1',
            toolName: 'get_weather',
            content: [const TextPart('18C'), ImagePart(mimeType: 'image/png', data: png)],
          ),
        ],
        createdAt: t0,
      ),
      Message(
        id: 'a2',
        role: Role.assistant,
        content: const [ReasoningPart(text: 'dangling', signature: 'enc-2', providerId: 'me')],
        createdAt: t0,
      ),
    ]);
    final input = (r.body['input']! as List).cast<Map<String, Object?>>();
    expect(input, [
      {'role': 'user', 'content': 'weather?'},
      {
        'type': 'reasoning',
        'summary': [
          {'type': 'summary_text', 'text': 'Two lookups.'},
        ],
        'encrypted_content': 'enc-1',
      },
      {'role': 'assistant', 'content': 'Checking.'},
      {'type': 'function_call', 'call_id': 'call_1', 'name': 'get_weather', 'arguments': '{"city":"Paris"}'},
      {
        'type': 'function_call_output',
        'call_id': 'call_1',
        'output': [
          {'type': 'input_text', 'text': '18C'},
          {'type': 'input_image', 'image_url': 'data:image/png;base64,${base64Encode(png)}'},
        ],
      },
    ]);
    expect(input.any((i) => i.containsKey('id')), isFalse);
  });

  group('over HTTP', () {
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

    OpenAiResponsesProvider provider({String? apiKey}) => OpenAiResponsesProvider(
          config: testConfig(server.v1, flavor: ApiFlavor.openAiResponses),
          apiKey: apiKey,
          client: client,
        );

    test('streams F5 from /v1/responses with bearer auth', () async {
      server.route('POST /v1/responses', (_) => sseFromText(fixture('f5_responses_parallel_function_calls.sse'), chunkSize: 11));
      final events = await collect(provider(apiKey: 'sk-k').stream(weatherRequest(model: 'gpt-6-astra')));
      expect(events.last, isA<Finish>().having((f) => f.reason, 'reason', FinishReason.toolCalls));
      expect(server.requests.single.headers['authorization'], 'Bearer sk-k');
      expect(server.requests.single.json['store'], isFalse);
    });

    test('a rejected optional field is stripped once, announced, and remembered per model', () async {
      server.route('POST /v1/responses', (r) async {
        final body = jsonDecode(await r.readAsString()) as Map<String, Object?>;
        final reasoning = body['reasoning'];
        if (reasoning is Map && reasoning.containsKey('summary')) {
          return jsonResponse({
            'error': {
              'message': 'Your organization must be verified to generate reasoning summaries.',
              'type': 'invalid_request_error',
              'param': 'reasoning.summary',
              'code': 'unsupported_value',
            },
          }, status: 400);
        }
        return sseFromText(fixture('responses_reasoning_text.sse'));
      });
      final p = provider();
      final events = await collect(p.stream(weatherRequest(model: 'gpt-6-astra')));
      expect(events.whereType<ProviderNotice>().map((n) => n.code), contains('param_dropped'));
      expect(events.last, isA<Finish>());
      await collect(p.stream(weatherRequest(model: 'gpt-6-astra')));
      expect(server.requests, hasLength(3));
      expect(server.requests.map((r) => (r.json['reasoning'] as Map?)?.containsKey('summary') ?? false), [true, false, false]);
    });

    test('a non-optional rejection surfaces as invalidRequest', () async {
      server.route('POST /v1/responses',
          (_) => jsonResponse({'error': {'message': 'Invalid input', 'type': 'invalid_request_error', 'param': 'input'}}, status: 400));
      final (_, error) = await collectWithError(provider().stream(weatherRequest()));
      expect(error, isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.invalidRequest));
      expect(server.requests, hasLength(1));
    });

    test('listModels uses the static table for capabilities', () async {
      server.route('GET /v1/models', (_) => jsonResponse({
            'object': 'list',
            'data': [
              {'id': 'gpt-6-astra', 'object': 'model', 'owned_by': 'openai'},
              {'id': 'whisper-9', 'object': 'model', 'owned_by': 'openai'},
            ],
          }));
      final models = await provider().listModels();
      expect(models.map((m) => m.capabilities.contextLength), [1050000, ModelCapabilities.unknown.contextLength]);
    });
  });

  group('agent loop round trip', () {
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

    Future<AgentRunner> runner(ModelProvider provider, String model, InMemorySessionStore store) async {
      final clock = FakeClock();
      await store.putSession(SessionRecord(id: 's1', title: 'New chat', createdAt: clock.now(), updatedAt: clock.now()));
      return AgentRunner(
        store: store,
        provider: provider,
        modelId: model,
        tools: LocalToolRouter([
          _Tool(weatherTool, (_) => '18°C, cloudy'),
          _Tool(timeTool, (_) => '21:04 JST'),
        ]),
        approvals: ApprovalPolicy(clock: clock),
        approvalHandler: const StaticApprovalHandler.approveAll(),
        clock: clock,
        ids: SequentialIdGenerator(),
        sleep: (_) async {},
      );
    }

    test('Responses: F5 → tools run → next input replays reasoning, calls and outputs', () async {
      var turn = 0;
      server.route('POST /v1/responses', (_) {
        turn++;
        return sseFromText(fixture(turn == 1 ? 'f5_responses_parallel_function_calls.sse' : 'responses_reasoning_text.sse'));
      });
      final provider = OpenAiResponsesProvider(
        config: testConfig(server.v1, flavor: ApiFlavor.openAiResponses, id: 'openai-resp'),
        client: client,
      );
      final r = await runner(provider, 'gpt-6-astra', InMemorySessionStore());
      final events = await r.send('s1', [const TextPart('Weather in Paris and the time in Tokyo?')]).toList();
      expect(events.whereType<RunFinished>().single.outcome, RunOutcome.completed);
      expect(server.requests, hasLength(2));
      final input = (server.requests[1].json['input']! as List).cast<Map<String, Object?>>();
      expect(input.map((i) => i['type'] ?? i['role']), [
        'user',
        'reasoning',
        'function_call',
        'function_call',
        'function_call_output',
        'function_call_output',
      ]);
      expect(input[1]['encrypted_content'], 'gAAAAABo...');
      expect(input[2], {'type': 'function_call', 'call_id': 'call_1', 'name': 'get_weather', 'arguments': '{"city":"Paris"}'});
      expect(input[4], {'type': 'function_call_output', 'call_id': 'call_1', 'output': '18°C, cloudy'});
      expect(input[5], {'type': 'function_call_output', 'call_id': 'call_2', 'output': '21:04 JST'});
    });

    test('Chat: F1 → tools run → assistant tool_calls then one tool message per result, in order', () async {
      var turn = 0;
      server.route('POST /v1/chat/completions', (_) {
        turn++;
        if (turn == 1) return sseFromText(fixture('f1_openai_chat_parallel_tools.sse'));
        return sseFromText('data: {"choices":[{"index":0,"delta":{"content":"Done."},"finish_reason":"stop"}]}\n\n'
            'data: [DONE]\n\n');
      });
      final provider = OpenAiChatProvider(config: testConfig(server.v1, profile: ServerProfile.openAi), client: client);
      final r = await runner(provider, 'gpt-6-luna', InMemorySessionStore());
      final events = await r.send('s1', [const TextPart('Weather in Paris and the time in Tokyo?')]).toList();
      expect(events.whereType<RunFinished>().single.outcome, RunOutcome.completed);
      final messages = (server.requests[1].json['messages']! as List).cast<Map<String, Object?>>();
      expect(messages.map((m) => m['role']), ['system', 'user', 'assistant', 'tool', 'tool']);
      final calls = (messages[2]['tool_calls']! as List).cast<Map<String, Object?>>();
      expect(calls.map((c) => c['id']), ['call_wX1', 'call_tY2']);
      expect((calls[0]['function']! as Map)['arguments'], '{"city": "Paris"}');
      expect(messages[3], {'role': 'tool', 'tool_call_id': 'call_wX1', 'content': '18°C, cloudy'});
      expect(messages[4], {'role': 'tool', 'tool_call_id': 'call_tY2', 'content': '21:04 JST'});
    });

    test('llama.cpp: reasoning_content from this provider is passed back', () async {
      var turn = 0;
      server.route('POST /v1/chat/completions', (_) {
        turn++;
        if (turn == 1) return sseFromText(fixture('f2_llamacpp_reasoning_tools.sse'));
        return sseFromText('data: {"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\n');
      });
      final provider = OpenAiChatProvider(config: testConfig(server.v1, profile: ServerProfile.llamaCpp), client: client);
      final r = await runner(provider, 'qwen3-8b', InMemorySessionStore());
      await r.send('s1', [const TextPart('go')]).toList();
      // Other requests are capability discovery (/props).
      final chats = server.requestsTo('/v1/chat/completions');
      expect(chats, hasLength(2));
      final messages = (chats[1].json['messages']! as List).cast<Map<String, Object?>>();
      final assistant = messages.firstWhere((m) => m['role'] == 'assistant');
      expect(assistant['reasoning_content'], 'Need weather and time; call both.');
    });
  });
}

final class _Tool implements LocalTool {
  _Tool(this.definition, this._run);

  @override
  final ToolDefinition definition;
  final String Function(Map<String, Object?> args) _run;

  @override
  Future<ToolResult> run(Map<String, Object?> arguments, ToolExecutionContext context) async =>
      ToolResult.text(_run(arguments));
}
