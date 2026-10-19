import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_litert/sherpa_litert.dart';
import 'package:sherpa_litert/testing.dart';

import 'support.dart';

LiteRtModelInfo info({bool functionCalling = true, bool thinking = false, bool vision = false}) =>
    LiteRtModelInfo.fromMsg(
        FakeLiteRtBackend.modelInfo(functionCalling: functionCalling, thinking: thinking, vision: vision));

LiteRtRequestMapper mapper({LiteRtModelInfo? i, bool vision = false, bool toolCalling = true}) => LiteRtRequestMapper(
      providerId: 'litert_lm',
      spec: LiteRtModelSpec(id: 'gemma', path: '/m/gemma.litertlm', vision: vision, toolCalling: toolCalling),
      info: i ?? info(),
    );

void main() {
  const call = ToolCall(id: 'c1', name: 'get_weather', arguments: {'city': 'Oslo'}, rawArguments: '{ "city":"Oslo" }');
  const call2 = ToolCall(id: 'c2', name: 'search', arguments: {'q': 'news'});

  test('system prompt and leading system messages form the system instruction; the last user turn is the tail', () {
    final t = mapper().map(request([system('Be brief.'), user('Hi'), assistant('Hello!'), user('Weather?')]));
    expect(t.systemInstruction, 'You are Sherpa.\n\nBe brief.');
    expect(t.history.map((m) => m.role), ['user', 'model']);
    expect(t.history.map((m) => m.text), ['Hi', 'Hello!']);
    expect(t.tail.role, 'user');
    expect(t.tail.text, 'Weather?');
    expect(t.historyKeys, hasLength(2));
    expect(t.continuation, isFalse);
    expect(t.toolsJson, isEmpty);
  });

  test('native tools: OpenAPI schemas, calls with canonical arguments, results in call order as JSON strings', () {
    final t = mapper().map(request(
      [
        user('Weather and news?'),
        assistant('', calls: [call, call2]),
        toolResults([result('c2', 'search', 'Headlines'), result('c1', 'get_weather', 'Sunny', isError: true)]),
      ],
      tools: [weatherTool, searchTool],
    ));
    expect(t.promptedTools, isFalse);
    final schema = jsonDecode(t.toolsJson.first) as Map<String, Object?>;
    expect(schema['name'], 'get_weather');
    expect((schema['parameters']! as Map).containsKey('title'), isFalse);
    final model = t.history[1];
    expect(model.role, 'model');
    expect(model.text, isNull);
    expect(model.toolCalls!.map((c) => [c.name, c.argumentsJson]), [
      ['get_weather', '{"city":"Oslo"}'],
      ['search', '{"q":"news"}'],
    ]);
    expect(t.tail.role, 'tool');
    expect(t.tail.toolResponses!.map((r) => r.name), ['get_weather', 'search'], reason: 'ordered like the calls');
    expect(t.tail.toolResponses!.first.responseJson, jsonEncode('[tool error] Sunny'));
    expect(t.toolNames, {'get_weather', 'search'});
  });

  test('prompted tools: instructions in the system prompt, envelopes and untrusted results as text', () {
    final t = mapper(i: info(functionCalling: false)).map(request(
      [user('Weather?'), assistant('Checking.', calls: [call]), toolResults([result('c1', 'get_weather', 'Sunny')])],
      tools: [weatherTool],
    ));
    expect(t.promptedTools, isTrue);
    expect(t.toolsJson, isEmpty);
    expect(t.systemInstruction, contains('## Tools'));
    expect(t.history[1].text, 'Checking.\n{"tool_calls":[{"name":"get_weather","arguments":{"city":"Oslo"}}]}');
    expect(t.tail.role, 'user');
    expect(t.tail.text, startsWith('Tool results:'));
    expect(t.tail.text, contains('<untrusted_data source="tool:get_weather">'));
  });

  test('a request ending with an assistant message sends the continue nudge', () {
    final t = mapper().map(request([user('Write a poem'), assistant('Roses are', finishReason: 'pause')]));
    expect(t.continuation, isTrue);
    expect(t.tail.text, kContinueNudge);
    expect(t.history.last.text, 'Roses are');
    expect(t.notices.map((n) => n.code), contains('continue_prompted'));
  });

  test('images need vision on both the spec and the file; otherwise they are dropped with a notice', () {
    final img = ImagePart(mimeType: 'image/png', data: Uint8List.fromList([1, 2, 3]));
    final noVision = mapper().map(request([user('What is this?', extra: [img])]));
    expect(noVision.tail.images, isNull);
    expect(noVision.notices.map((n) => n.code), contains('content_dropped'));
    final withVision = mapper(i: info(vision: true), vision: true).map(request([user('What is this?', extra: [img])]));
    expect(withVision.tail.images!.single, [1, 2, 3]);
    expect(withVision.notices, isEmpty);
  });

  test('consecutive messages of one role are merged; mid-conversation system notes become user turns', () {
    final t = mapper().map(request([user('a'), user('b'), system('Summary: x'), assistant('ok'), user('c')]));
    expect(t.history.map((m) => m.role), ['user', 'model']);
    expect(t.history.first.text, 'a\n\nb\n\n[System note]\nSummary: x');
  });

  test('tools plus a JSON schema: the schema is dropped; without tools it is a response format', () {
    const schema = {'type': 'object'};
    final withTools = mapper().map(request([user('x')], tools: [weatherTool], params: const GenerationParams(jsonSchema: schema)));
    expect(withTools.responseSchemaJson, isNull);
    expect(withTools.notices.map((n) => n.code), contains('json_schema_dropped'));
    final plain = mapper().map(request([user('x')], params: const GenerationParams(jsonSchema: schema)));
    expect(plain.responseSchemaJson, '{"type":"object"}');
    expect(plain.enableResponseFormat, isTrue);
    expect(plain.configKey, isNot(withTools.configKey));
  });

  test('tool choice none and disabled tool calling offer no tools', () {
    final none = mapper().map(request([user('x')], tools: [weatherTool], params: const GenerationParams(toolChoice: ToolChoice.none)));
    expect(none.toolsJson, isEmpty);
    expect(none.toolNames, isEmpty);
    final off = mapper(toolCalling: false).map(request([user('x')], tools: [weatherTool]));
    expect(off.toolsJson, isEmpty);
    expect(off.notices.map((n) => n.code), contains('tools_disabled'));
  });

  test('reasoning effort maps to thinking only for thinking models', () {
    const high = GenerationParams(reasoning: ReasoningEffort.high);
    final plain = mapper().map(request([user('x')], params: high));
    expect(plain.enableThinking, isNull);
    final m = mapper(i: info(thinking: true));
    expect(m.map(request([user('x')], params: high)).thinkingBudget, -1);
    expect(m.map(request([user('x')], params: const GenerationParams(reasoning: ReasoningEffort.low))).thinkingBudget, 512);
    final off = m.map(request([user('x')], params: const GenerationParams(reasoning: ReasoningEffort.off)));
    expect(off.enableThinking, isFalse);
    expect(off.thinkingBudget, 0);
  });

  test('sampler values are all or nothing, filled from the model defaults', () {
    expect(mapper().map(request([user('x')])).sampler, isNull);
    final s = mapper().map(request([user('x')], params: const GenerationParams(temperature: 0.2))).sampler!;
    expect([s.temperature, s.topK, s.topP, s.seed], [0.2, 64, 0.95, 0]);
  });

  test('history renders identically across turns (stable fingerprints)', () {
    final m = mapper();
    final a = m.map(request([user('Hi'), assistant('', calls: [call]), toolResults([result('c1', 'get_weather', 'Sunny')])]));
    final b = m.map(request([user('Hi'), assistant('', calls: [call]), toolResults([result('c1', 'get_weather', 'Sunny')])]));
    expect(a.historyKeys, b.historyKeys);
    expect(a.tailKey, b.tailKey);
    expect(a.configKey, b.configKey);
    final reply = m.assistantMessage('', [call], prompted: false)!;
    expect(LiteRtRequestMapper.keyOf(reply), a.historyKeys[1]);
  });
}
