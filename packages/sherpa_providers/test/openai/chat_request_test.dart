import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';
import 'package:test/test.dart';

import '../support/helpers.dart';

void main() {
  ChatRequestBody build(
    ServerProfile profile, {
    GenerationParams params = const GenerationParams(),
    List<ToolDefinition> tools = const [weatherTool, timeTool],
    List<Message>? messages,
    CacheHints cache = const CacheHints(),
    bool includeUsage = true,
  }) {
    final request = ModelRequest(
      modelId: 'm',
      systemPrompt: 'sys',
      messages: messages ?? [userText('hi')],
      tools: tools,
      params: params,
      cache: cache,
    );
    return buildChatRequest(
      request: request,
      quirks: ServerQuirks.of(profile),
      names: ToolNameMapper(visibleTools(request).map((t) => t.name)),
      providerId: 'me',
      includeUsage: includeUsage,
    );
  }

  List<String> codes(ChatRequestBody b) => b.notices.map((n) => n.code).toList();

  final history = [
    userText('weather?'),
    Message(
      id: 'a1',
      role: Role.assistant,
      content: const [
        ReasoningPart(text: 'think', providerId: 'me'),
        ToolCallPart(ToolCall(id: 'c1', name: 'get_weather', arguments: {'city': 'Paris'}, rawArguments: '{"city":"Paris"}')),
      ],
      createdAt: t0,
    ),
    Message(
      id: 't1',
      role: Role.tool,
      content: const [ToolResultPart(callId: 'c1', toolName: 'get_weather', content: [TextPart('18C')])],
      createdAt: t0,
    ),
  ];

  test('OpenAI: max_completion_tokens, usage options, effort, cache key', () {
    final b = build(
      ServerProfile.openAi,
      params: const GenerationParams(maxOutputTokens: 500, reasoning: ReasoningEffort.off, temperature: 0.2, seed: 3),
      cache: const CacheHints(sessionId: 'session-1'),
    ).body;
    expect(b['stream'], isTrue);
    expect(b['max_completion_tokens'], 500);
    expect(b.containsKey('max_tokens'), isFalse);
    expect(b['stream_options'], {'include_usage': true, 'include_obfuscation': false});
    expect(b['reasoning_effort'], 'none');
    expect(b['temperature'], 0.2);
    expect(b['seed'], 3);
    expect(b['prompt_cache_key'], matches(RegExp(r'^sherpa-[0-9a-f]{8}$')));
    expect(b['prompt_cache_key'], isNot(contains('session-1')));
    expect(b.containsKey('tool_choice'), isFalse, reason: 'auto is the default and never sent');
    final tools = (b['tools']! as List).cast<Map<String, Object?>>();
    expect(tools.first, {
      'type': 'function',
      'function': {'name': 'get_weather', 'description': 'Current weather for a city.', 'parameters': weatherTool.inputSchema},
    });
    expect((b['messages']! as List).first, {'role': 'system', 'content': 'sys'});
  });

  test('OpenAI: sampling params dropped while reasoning is on', () {
    final r = build(ServerProfile.openAi,
        params: const GenerationParams(reasoning: ReasoningEffort.high, temperature: 0.5, topP: 0.9, topK: 40));
    expect(r.body['reasoning_effort'], 'high');
    expect(r.body.containsKey('temperature'), isFalse);
    expect(r.body.containsKey('top_p'), isFalse);
    expect(codes(r), containsAll(['param_dropped', 'param_unsupported']));
  });

  test('tool_choice per server support', () {
    const specific = GenerationParams(toolChoice: ToolChoiceSpecific('get_time'));
    final openAi = build(ServerProfile.openAi, params: specific).body;
    expect(openAi['tool_choice'], {
      'type': 'function',
      'function': {'name': 'get_time'},
    });

    // llama.cpp ignores the object form: emulate with required + one tool.
    final llama = build(ServerProfile.llamaCpp, params: specific);
    expect(llama.body['tool_choice'], 'required');
    expect((llama.body['tools']! as List).map((t) => ((t as Map)['function'] as Map)['name']), ['get_time']);
    expect(codes(llama), contains('tool_choice_emulated'));
    expect(build(ServerProfile.llamaCpp, params: const GenerationParams(toolChoice: ToolChoice.required)).body['tool_choice'],
        'required');

    // Ollama has no tool_choice at all.
    final ollamaRequired = build(ServerProfile.ollama, params: const GenerationParams(toolChoice: ToolChoice.required));
    expect(ollamaRequired.body.containsKey('tool_choice'), isFalse);
    expect(codes(ollamaRequired), contains('tool_choice_unsupported'));
    final ollamaNone = build(ServerProfile.ollama, params: const GenerationParams(toolChoice: ToolChoice.none));
    expect(ollamaNone.body.containsKey('tools'), isFalse);
    expect(codes(ollamaNone), contains('tool_choice_emulated'));

    final generic = build(ServerProfile.generic, params: const GenerationParams(toolChoice: ToolChoice.required));
    expect(generic.body.containsKey('tool_choice'), isFalse);
    expect(build(ServerProfile.generic, params: const GenerationParams(toolChoice: ToolChoice.none)).body['tool_choice'],
        'none');
  });

  test('parallel_tool_calls: false only where understood', () {
    const p = GenerationParams(parallelToolCalls: false);
    expect(build(ServerProfile.openAi, params: p).body['parallel_tool_calls'], isFalse);
    expect(build(ServerProfile.llamaCpp, params: p).body['parallel_tool_calls'], isFalse);
    final ollama = build(ServerProfile.ollama, params: p);
    expect(ollama.body.containsKey('parallel_tool_calls'), isFalse);
    expect(codes(ollama), contains('parallel_tool_calls_unsupported'));
    expect(build(ServerProfile.openAi).body.containsKey('parallel_tool_calls'), isFalse);
    expect(build(ServerProfile.openAi, params: p, tools: const []).body.containsKey('parallel_tool_calls'), isFalse);
  });

  test('max tokens field and extended samplers per profile', () {
    const p = GenerationParams(maxOutputTokens: 64, topK: 20, minP: 0.05, repeatPenalty: 1.1);
    final llama = build(ServerProfile.llamaCpp, params: p).body;
    expect(llama['max_tokens'], 64);
    expect([llama['top_k'], llama['min_p'], llama['repeat_penalty']], [20, 0.05, 1.1]);
    final vllm = build(ServerProfile.vllm, params: p).body;
    expect(vllm['max_completion_tokens'], 64);
    expect(vllm['repetition_penalty'], 1.1);
    final ollama = build(ServerProfile.ollama, params: p);
    expect(ollama.body['max_tokens'], 64);
    expect(ollama.body.containsKey('top_k'), isFalse);
    expect(codes(ollama).where((c) => c == 'param_unsupported'), hasLength(3));
  });

  test('reasoning effort styles', () {
    const high = GenerationParams(reasoning: ReasoningEffort.high);
    const off = GenerationParams(reasoning: ReasoningEffort.off);
    expect(build(ServerProfile.llamaCpp, params: off).body['reasoning_effort'], 'none');
    expect(build(ServerProfile.openRouter, params: high).body['reasoning'], {'effort': 'high'});
    final ds = build(ServerProfile.deepSeek, params: const GenerationParams(reasoning: ReasoningEffort.medium)).body;
    expect(ds['thinking'], {'type': 'enabled'});
    expect(ds['reasoning_effort'], 'high');
    expect(build(ServerProfile.deepSeek, params: off).body['thinking'], {'type': 'disabled'});
    final generic = build(ServerProfile.generic, params: high);
    expect(generic.body.containsKey('reasoning_effort'), isFalse);
    expect(codes(generic), contains('reasoning_effort_unsupported'));
  });

  test('reasoning replay per profile', () {
    Map<String, Object?> assistantOf(ChatRequestBody b) =>
        (b.body['messages']! as List).cast<Map<String, Object?>>().firstWhere((m) => m['role'] == 'assistant');
    expect(assistantOf(build(ServerProfile.llamaCpp, messages: history))['reasoning_content'], 'think');
    expect(assistantOf(build(ServerProfile.vllm, messages: history))['reasoning'], 'think');
    expect(assistantOf(build(ServerProfile.ollama, messages: history))['reasoning'], 'think');
    expect(assistantOf(build(ServerProfile.openAi, messages: history)).keys, isNot(contains('reasoning_content')));
    // DeepSeek: required (and only sent) while tools are present.
    expect(assistantOf(build(ServerProfile.deepSeek, messages: history))['reasoning_content'], 'think');
    expect(assistantOf(build(ServerProfile.deepSeek, messages: history, tools: const [])).keys,
        isNot(contains('reasoning_content')));
  });

  test('include_usage can be turned off; extra is merged last and null removes', () {
    final b = build(
      ServerProfile.generic,
      includeUsage: false,
      params: const GenerationParams(extra: {'stream_options': null, 'keep_alive': '5m', 'stream': true, 'stop': null}),
    ).body;
    expect(b.containsKey('stream_options'), isFalse);
    expect(b['keep_alive'], '5m');
    expect(build(ServerProfile.generic, params: const GenerationParams(extra: {'model': 'override'})).body['model'],
        'override');
  });

  test('structured output, stop, and app-only tools', () {
    final b = build(
      ServerProfile.openAi,
      params: const GenerationParams(
        stop: ['END'],
        jsonSchema: {'title': 'My Answer', 'type': 'object'},
      ),
      tools: const [
        weatherTool,
        ToolDefinition(name: 'app.only', description: '', inputSchema: {'type': 'object'}, modelVisible: false),
      ],
    ).body;
    expect(b['stop'], ['END']);
    expect(b['response_format'], {
      'type': 'json_schema',
      'json_schema': {
        'name': 'My_Answer',
        'schema': {'title': 'My Answer', 'type': 'object'},
      },
    });
    expect((b['tools']! as List), hasLength(1));
  });

  test('tool names are sanitized consistently in tools and history', () {
    const mcpTool = ToolDefinition(name: 'github/create.issue', description: 'd', inputSchema: {'type': 'object'});
    final b = build(
      ServerProfile.openAi,
      tools: const [mcpTool],
      messages: [
        Message(
          id: 'a',
          role: Role.assistant,
          content: const [ToolCallPart(ToolCall(id: 'c', name: 'github/create.issue', arguments: {}))],
          createdAt: t0,
        ),
        Message(
          id: 't',
          role: Role.tool,
          content: const [ToolResultPart(callId: 'c', toolName: 'github/create.issue', content: [TextPart('ok')])],
          createdAt: t0,
        ),
      ],
    ).body;
    final toolName = (((b['tools']! as List).single as Map)['function'] as Map)['name'];
    final historyName = (((((b['messages']! as List)[1] as Map)['tool_calls'] as List).single as Map)['function'] as Map)['name'];
    expect(toolName, 'github_create_issue');
    expect(historyName, toolName);
  });
}
