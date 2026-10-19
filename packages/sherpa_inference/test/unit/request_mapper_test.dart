import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';
import 'package:sherpa_inference/testing.dart';

final _t0 = DateTime.utc(2026, 10, 18);

Message _msg(String id, Role role, List<ContentPart> content) =>
    Message(id: id, role: role, content: content, createdAt: _t0);

EngineRequestMapper _mapper({
  int nParams = 596049920,
  bool thinking = true,
  bool parallel = true,
  Map<String, String> sampling = const {},
}) =>
    EngineRequestMapper(
      providerId: 'llama_cpp',
      model: EngineModelInfo.parse(
          fakeModelInfoJson(nParams: nParams, thinking: thinking, templateParallel: parallel, recommendedSampling: sampling)),
    );

const _weather = ToolDefinition(
  name: 'get_weather',
  description: 'Get the weather',
  inputSchema: {
    r'$schema': 'http://json-schema.org/draft-07/schema#',
    'title': 'GetWeatherArgs',
    'type': 'object',
    'properties': {
      'city': {'type': 'string', 'title': 'City', 'examples': ['Paris']},
      'title': {'type': 'string', 'description': 'a property literally named title'},
    },
    'required': ['city'],
  },
);

void main() {
  group('EngineRequestMapper', () {
    test('system prompt, user text and defaults', () {
      final m = _mapper().map(ModelRequest(
        modelId: 'm',
        systemPrompt: 'Be brief.',
        messages: [
          _msg('u', Role.user, const [TextPart('Hello'), TextPart('there')]),
        ],
      ));
      expect(m.body['messages'], [
        {'role': 'system', 'content': 'Be brief.'},
        {'role': 'user', 'content': 'Hello\nthere'},
      ]);
      expect(m.body['cache_prompt'], isTrue);
      expect(m.body.containsKey('tools'), isFalse);
      expect(m.body.containsKey('enable_thinking'), isFalse, reason: 'null reasoning keeps the template default');
      expect(m.body.containsKey('continue_final_message'), isFalse);
      expect(jsonDecode(m.encode()), m.body);
    });

    test('assistant tool calls keep the exact argument text unless repaired', () {
      final m = _mapper().map(ModelRequest(modelId: 'm', messages: [
        _msg('u', Role.user, const [TextPart('weather?')]),
        _msg('a', Role.assistant, const [
          ToolCallPart(ToolCall(id: 'c1', name: 'get_weather', arguments: {'city': 'Paris'}, rawArguments: '{"city": "Paris"}')),
          ToolCallPart(ToolCall(
              id: 'c2', name: 'get_weather', arguments: {'city': 'Rome'}, rawArguments: "{'city': 'Rome',}", repaired: true)),
        ]),
        _msg('t', Role.tool, const [
          ToolResultPart(callId: 'c1', toolName: 'get_weather', content: [TextPart('21C')]),
          ToolResultPart(callId: 'c2', toolName: 'get_weather', content: [TextPart('boom')], isError: true),
        ]),
      ]));
      final msgs = (m.body['messages']! as List).cast<Map<String, Object?>>();
      expect(msgs[1]['content'], isNull, reason: 'tool-call-only replies send null content');
      final calls = (msgs[1]['tool_calls']! as List).cast<Map<String, Object?>>();
      expect((calls[0]['function']! as Map)['arguments'], '{"city": "Paris"}');
      expect((calls[1]['function']! as Map)['arguments'], '{"city":"Rome"}');
      expect(calls[0]['type'], 'function');
      expect(msgs[2], {'role': 'tool', 'tool_call_id': 'c1', 'name': 'get_weather', 'content': '21C'});
      expect(msgs[3]['content'], '[tool error] boom');
    });

    test('reasoning is replayed only for this provider\'s replies', () {
      final m = _mapper().map(ModelRequest(modelId: 'm', messages: [
        _msg('u', Role.user, const [TextPart('q')]),
        _msg('a1', Role.assistant, const [ReasoningPart(text: 'mine', providerId: 'llama_cpp'), TextPart('A')]),
        _msg('a2', Role.assistant, const [ReasoningPart(text: 'theirs', providerId: 'anthropic'), TextPart('B')]),
        _msg('u2', Role.user, const [TextPart('q2')]),
      ]));
      final msgs = (m.body['messages']! as List).cast<Map<String, Object?>>();
      expect(msgs[1]['reasoning_content'], 'mine');
      expect(msgs[2].containsKey('reasoning_content'), isFalse);
    });

    test('tools are mapped with a normalized schema; property names survive', () {
      final m = _mapper().map(const ModelRequest(modelId: 'm', messages: [], tools: [_weather]));
      final fn = ((m.body['tools']! as List).single as Map)['function']! as Map;
      expect(fn['name'], 'get_weather');
      final params = fn['parameters']! as Map;
      expect(params.containsKey(r'$schema'), isFalse);
      expect(params.containsKey('title'), isFalse);
      final props = params['properties']! as Map;
      expect(props.keys, ['city', 'title']);
      expect(props['city'], {'type': 'string'});
      expect(params['required'], ['city']);
      expect(m.body['tool_choice'], 'auto');
      expect(m.body['parallel_tool_calls'], isFalse, reason: 'models under 8B never get parallel calls');
      expect(m.body['messages'], [
        {'role': 'user', 'content': ''},
      ]);
    });

    test('tool_choice variants and parallel calls for large models', () {
      Map<String, Object?> body(ToolChoice c, {int nParams = 596049920, bool parallel = true}) =>
          _mapper(nParams: nParams, parallel: parallel)
              .map(ModelRequest(modelId: 'm', messages: const [], tools: const [_weather], params: GenerationParams(toolChoice: c)))
              .body;
      expect(body(ToolChoice.none)['tool_choice'], 'none');
      expect(body(ToolChoice.required)['tool_choice'], 'required');
      expect(body(const ToolChoiceSpecific('get_weather'))['tool_choice'], {
        'type': 'function',
        'function': {'name': 'get_weather'},
      });
      expect(body(ToolChoice.auto, nParams: 8000000000)['parallel_tool_calls'], isTrue);
      expect(body(ToolChoice.auto, nParams: 8000000000, parallel: false)['parallel_tool_calls'], isFalse);
    });

    test('reasoning effort maps to enable_thinking and budgets', () {
      Map<String, Object?> body(ReasoningEffort e, {bool thinking = true}) => _mapper(thinking: thinking)
          .map(ModelRequest(modelId: 'm', messages: const [], params: GenerationParams(reasoning: e)))
          .body;
      expect(body(ReasoningEffort.off)['enable_thinking'], isFalse);
      expect(body(ReasoningEffort.low), containsPair('reasoning_budget_tokens', 512));
      expect(body(ReasoningEffort.medium), containsPair('reasoning_budget_tokens', 2048));
      expect(body(ReasoningEffort.high)['enable_thinking'], isTrue);
      expect(body(ReasoningEffort.high).containsKey('reasoning_budget_tokens'), isFalse);
      expect(body(ReasoningEffort.high, thinking: false).containsKey('enable_thinking'), isFalse);
    });

    test('sampling params win over the GGUF recommendation, which fills gaps', () {
      final m = _mapper(sampling: {'general.sampling.temp': '0.6', 'general.sampling.top_k': '20'}).map(const ModelRequest(
        modelId: 'm',
        messages: [],
        params: GenerationParams(topP: 0.9, seed: 7, maxOutputTokens: 64, stop: ['END'], repeatPenalty: 1.1),
      ));
      expect(m.body, containsPair('temperature', 0.6));
      expect(m.body, containsPair('top_k', 20));
      expect(m.body, containsPair('top_p', 0.9));
      expect(m.body, containsPair('seed', 7));
      expect(m.body, containsPair('max_tokens', 64));
      expect(m.body, containsPair('stop', ['END']));
      expect(m.body, containsPair('repeat_penalty', 1.1));
      final explicit = _mapper(sampling: {'general.sampling.temp': '0.6'})
          .map(const ModelRequest(modelId: 'm', messages: [], params: GenerationParams(temperature: 0)))
          .body;
      expect(explicit['temperature'], 0);
    });

    test('json schema applies without tools and is dropped (with a notice) with tools', () {
      const schema = {'type': 'object'};
      final plain = _mapper().map(const ModelRequest(modelId: 'm', messages: [], params: GenerationParams(jsonSchema: schema)));
      expect(plain.body['json_schema'], schema);
      expect(plain.notices, isEmpty);
      final withTools = _mapper().map(
          const ModelRequest(modelId: 'm', messages: [], tools: [_weather], params: GenerationParams(jsonSchema: schema)));
      expect(withTools.body.containsKey('json_schema'), isFalse);
      expect(withTools.notices.single.code, 'json_schema_dropped');
    });

    test('a trailing assistant message is continued (paused reply)', () {
      final m = _mapper().map(ModelRequest(modelId: 'm', messages: [
        _msg('u', Role.user, const [TextPart('story')]),
        _msg('a', Role.assistant, const [TextPart('Once upon')]),
      ]));
      expect(m.body['continue_final_message'], isTrue);
    });

    test('media is dropped with a notice; extra is merged last', () {
      final m = _mapper().map(ModelRequest(
        modelId: 'm',
        messages: [
          _msg('u', Role.user, [const TextPart('look'), ImagePart(mimeType: 'image/png', data: Uint8List(4))]),
        ],
        params: const GenerationParams(extra: {'min_p': 0.1, 'cache_prompt': false}),
      ));
      expect(m.notices.single.code, 'content_dropped');
      expect((m.body['messages']! as List).single, {'role': 'user', 'content': 'look'});
      expect(m.body['min_p'], 0.1);
      expect(m.body['cache_prompt'], isFalse, reason: 'extra is an explicit override');
    });

    test('tool results misfiled on a user message still answer their calls', () {
      final out = const EngineMessageMapper('llama_cpp').mapMessage(_msg('u', Role.user, const [
        ToolResultPart(callId: 'c1', toolName: 't', content: [TextPart('r')]),
      ]));
      expect(out, [
        {'role': 'tool', 'tool_call_id': 'c1', 'name': 't', 'content': 'r'},
      ]);
    });
  });

  test('EngineSystemInfo reads runtime CPU facts', () {
    final s = EngineSystemInfo.parse(jsonEncode({
      'cpu_variant': 'android_armv8.2_2',
      'backends': [
        {'name': 'CPU', 'n_devices': 1},
      ],
      'cpu': {
        'performance_cores': 4,
        'logical_cores': 8,
        'features': {'dotprod': true, 'i8mm': false},
      },
    }));
    expect(s.performanceCores, 4);
    expect(s.logicalCores, 8);
    expect(s.cpuVariant, 'android_armv8.2_2');
    expect(s.cpuFeatures, {'dotprod'});
    expect(s.backends, ['CPU']);
  });

  group('EngineModelInfo', () {
    test('maps the template classification onto capabilities', () {
      final info = EngineModelInfo.parse(fakeModelInfoJson());
      final caps = info.capabilities(contextLength: 4096, ramBytes: 900);
      expect(caps.contextLength, 4096);
      expect(caps.toolCallFormat, ToolCallFormat.jsonGrammar);
      expect(caps.parallelToolCalls, isFalse);
      expect(caps.reasoning, ReasoningSupport.optional);
      expect(caps.historyPolicy, HistoryPolicy.appendOnly);
      expect(caps.supportsPromptCache, isTrue);
      expect(caps.tokenizerFamily, 'qwen');
      expect(caps.ramEstimateBytes, 900);
      expect(EngineModelInfo.parse(fakeModelInfoJson(toolSupport: 'parsed_without_grammar')).toolCallFormat,
          ToolCallFormat.prompted);
      expect(EngineModelInfo.parse(fakeModelInfoJson(toolSupport: 'none')).toolCallFormat, ToolCallFormat.none);
      expect(EngineModelInfo.parse(fakeModelInfoJson(nParams: 9000000000)).allowParallelToolCalls, isTrue);
    });

    test('ignores unknown keys', () {
      final j = (jsonDecode(fakeModelInfoJson()) as Map).cast<String, Object?>()..['future_key'] = {'x': 1};
      expect(EngineModelInfo.parse(jsonEncode(j)).arch, 'qwen3');
    });
  });
}
