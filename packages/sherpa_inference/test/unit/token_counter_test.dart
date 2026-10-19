import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';
import 'package:sherpa_inference/testing.dart';

Message _m(String id, Role role, List<ContentPart> c) => Message(id: id, role: role, content: c, createdAt: DateTime.utc(2026));

const _tool = ToolDefinition(name: 'get_weather', description: 'Weather', inputSchema: {'type': 'object'});

void main() {
  late FakeEngineHost host;
  const model = ModelRef(1, 0);

  setUp(() => host = FakeEngineHost());

  EngineTokenCounter counter({bool sync = false}) =>
      EngineTokenCounter(host: host, providerId: 'llama_cpp', resolveModel: () async => model, useSyncTokenizer: sync);

  final messages = [
    _m('u', Role.user, const [TextPart('What is the weather in Paris today?')]),
    _m('a', Role.assistant, const [
      ReasoningPart(text: 'Need the tool.', providerId: 'llama_cpp'),
      ToolCallPart(ToolCall(id: 'c1', name: 'get_weather', arguments: {'city': 'Paris'}, rawArguments: '{"city":"Paris"}')),
    ]),
    _m('t', Role.tool, const [
      ToolResultPart(callId: 'c1', toolName: 'get_weather', content: [TextPart('{"temp":21}')]),
    ]),
  ];

  test('before warm-up: pessimistic estimates and not exact', () {
    final c = counter();
    expect(c.isExact, isFalse);
    final heuristic = HeuristicTokenCounter().countText('hello world, this is a test');
    expect(c.countText('hello world, this is a test'), greaterThanOrEqualTo(heuristic));
    expect(c.misses, 1);
  });

  test('warm() fills every count in one engine round trip', () async {
    final c = counter();
    await c.warm(systemPrompt: 'Be brief.', messages: messages, tools: const [_tool]);
    expect(host.countBatchCalls, 1);
    expect(c.isExact, isTrue);
    final misses = c.misses;
    final user = c.countMessage(messages[0]);
    // The fake template: 5 scaffold tokens + content.
    expect(user, 5 + FakeEngineHost.fakeTokenCount('What is the weather in Paris today?'));
    expect(c.countText('Be brief.'), FakeEngineHost.fakeTokenCount('Be brief.'));
    final assistant = c.countMessage(messages[1]);
    expect(assistant, greaterThan(5 + FakeEngineHost.fakeTokenCount('Need the tool.')),
        reason: 'own reasoning is always added on top of the lone render');
    c
      ..countMessage(messages[2])
      ..countTools(const [_tool]);
    expect(c.misses, misses, reason: 'all served from the cache');
    // A second warm-up with nothing new does not call the engine.
    await c.warm(systemPrompt: 'Be brief.', messages: messages, tools: const [_tool]);
    expect(host.countBatchCalls, 1);
  });

  test('tools include the fixed prompt scaffolding once', () async {
    final c = counter();
    await c.warm(tools: const [_tool]);
    final withTools = c.countTools(const [_tool]);
    await c.warm();
    final none = c.countTools(const []);
    expect(none, greaterThan(0), reason: 'BOS/system wrapper/generation prompt');
    expect(withTools - none, FakeEngineHost.fakeTokenCount(jsonEncodeTool()));
  });

  test('editing a message changes its key', () async {
    final c = counter();
    await c.warm(messages: messages);
    final edited = _m('u', Role.user, const [TextPart('What is the weather in Rome today, please, right now?')]);
    final before = c.misses;
    c.countMessage(edited);
    expect(c.misses, before + 1);
  });

  test('a synchronous tokenizer answers misses exactly', () {
    final c = counter(sync: true);
    // No model resolved yet: still a miss.
    c.countText('abc');
    expect(c.misses, 1);
  });

  test('the sync path is used once a model is resolved', () async {
    final c = counter(sync: true);
    await c.warm();
    final misses = c.misses;
    expect(c.countText('abcdefgh'), 2);
    expect(c.countMessage(_m('x', Role.user, const [TextPart('abcd')])), 6);
    expect(c.misses, misses);
    expect(c.isExact, isTrue);
  });

  test('countRequestJson is the full render', () async {
    final c = counter();
    expect(await c.countRequestJson('{"messages":[{"role":"user","content":"abcd"}]}'), 5 + 1 + 3);
  });

  test('WarmingContextManager warms before the inner manager counts', () async {
    final c = counter();
    final ctx = await const WarmingContextManager(PassthroughContextManager()).prepare(ContextRequest(
      sessionId: 's',
      path: messages,
      overlays: const [],
      tools: const [_tool],
      capabilities: const ModelCapabilities(contextLength: 4096),
      counter: c,
      systemPrompt: 'sys',
    ));
    expect(ctx.messages, isNotEmpty);
    expect(host.countBatchCalls, 1);
    expect(c.misses, 0);
  });
}

String jsonEncodeTool() => '[{"type":"function","function":{"name":"get_weather","description":"Weather","parameters":{"type":"object"}}}]';
