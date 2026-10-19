import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';
import 'package:sherpa_providers/sherpa_providers.dart';
import 'package:test/test.dart';

import '../support/helpers.dart';

void main() {
  ChatStreamParser parser(ServerProfile profile) => ChatStreamParser(
        names: ToolNameMapper(['get_weather', 'get_time']),
        quirks: ServerQuirks.of(profile),
        newCallId: (i) => 'synth_$i',
      );

  List<ModelEvent> run(ServerProfile profile, List<Map<String, Object?>> deltas, {String finish = 'stop'}) {
    final p = parser(profile);
    return [
      for (final d in deltas)
        ...p.addEvent(SseEvent(data: jsonEncode({
          'choices': [
            {'index': 0, 'delta': d},
          ],
        }))),
      ...p.addEvent(SseEvent(data: jsonEncode({
        'choices': [
          {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': finish},
        ],
      }))),
      ...p.addEvent(const SseEvent(data: '[DONE]')),
      ...p.finish(),
    ];
  }

  test('interleaved OpenRouter reasoning phases produce separate detail groups', () {
    final events = run(ServerProfile.openRouter, [
      {
        'reasoning': 'first',
        'reasoning_details': [
          {'type': 'reasoning.text', 'text': 'first', 'index': 0},
        ],
      },
      {
        'tool_calls': [
          {'index': 0, 'id': 'c1', 'function': {'name': 'get_weather', 'arguments': '{}'}},
        ],
      },
      {
        'reasoning': 'second',
        'reasoning_details': [
          {'type': 'reasoning.text', 'text': 'second', 'index': 1},
        ],
      },
      {
        'tool_calls': [
          {'index': 1, 'id': 'c2', 'function': {'name': 'get_time', 'arguments': '{}'}},
        ],
      },
    ], finish: 'tool_calls');
    final groups = [
      for (final s in events.whereType<ReasoningSignature>()) (jsonDecode(s.signature!) as List).map((d) => (d as Map)['text']).toList(),
    ];
    expect(groups, [
      ['first'],
      ['second'],
    ]);
    // Each group follows its own reasoning text.
    final order = describeAll(events);
    expect(order.indexOf('Reasoning(first)'), lessThan(order.indexWhere((e) => e.startsWith('Signature'))));
  });

  test('inline <think> content is split for local profiles only', () {
    final local = run(ServerProfile.generic, [
      {'content': '<think>hmm'},
      {'content': '</think>\n\nAnswer'},
    ]);
    expect(describeAll(local), ['Reasoning(hmm)', 'Text(Answer)', 'Finish(stop)']);
    final openAi = run(ServerProfile.openAi, [
      {'content': '<think>literal</think>'},
    ]);
    expect(describeAll(openAi), ['Text(<think>literal</think>)', 'Finish(stop)']);
  });

  test('refusal deltas become text and finish as refusal', () {
    final events = run(ServerProfile.openAi, [
      {'refusal': "I can't help with that."},
    ]);
    expect(describeAll(events), ["Text(I can't help with that.)", 'Finish(refusal)']);
  });

  test('finish reasons map and stop-after-calls becomes toolCalls', () {
    expect((run(ServerProfile.generic, [{'content': 'x'}], finish: 'length').last as Finish).reason, FinishReason.length);
    expect((run(ServerProfile.generic, [{'content': 'x'}], finish: 'content_filter').last as Finish).reason,
        FinishReason.contentFilter);
    final ollamaStyle = run(ServerProfile.ollama, [
      {
        'tool_calls': [
          {'index': 0, 'id': 'c', 'function': {'name': 'get_weather', 'arguments': '{"city":"Oslo"}'}},
        ],
      },
    ]);
    expect((ollamaStyle.last as Finish).reason, FinishReason.toolCalls);
    expect((ollamaStyle.last as Finish).rawReason, 'stop');
  });

  test('finish_reason length: a half-written call is invalid, not repaired (finding 12)', () {
    final truncated = run(ServerProfile.openAi, [
      {
        'tool_calls': [
          {'index': 0, 'id': 'c', 'function': {'name': 'get_weather', 'arguments': '{"city":"Line one. Line tw'}},
        ],
      },
    ], finish: 'length');
    final call = truncated.whereType<ToolCallComplete>().single.call;
    expect(call.isValid, isFalse);
    expect(call.repaired, isFalse);
    expect(call.argumentsError, contains('output-token limit'));
    expect(truncated.whereType<ProviderNotice>().map((n) => n.code), ['tool_args_truncated']);
    expect((truncated.last as Finish).reason, FinishReason.length);

    // The same malformed text in a complete turn is still repaired.
    final complete = run(ServerProfile.openAi, [
      {
        'tool_calls': [
          {'index': 0, 'id': 'c', 'function': {'name': 'get_weather', 'arguments': '{"city":"Oslo"'}},
        ],
      },
    ], finish: 'tool_calls');
    final repaired = complete.whereType<ToolCallComplete>().single.call;
    expect(repaired.isValid, isTrue);
    expect(repaired.repaired, isTrue);
    expect(repaired.arguments, {'city': 'Oslo'});
  });

  test('non-JSON data lines are skipped with a single notice', () {
    final p = parser(ServerProfile.generic);
    expect(describeAll(p.addEvent(const SseEvent(data: 'keep-alive'))), ['Notice(malformed_chunk)']);
    expect(p.addEvent(const SseEvent(data: 'again')), isEmpty);
  });

  test('an `event: error` frame is a stream error', () {
    final p = parser(ServerProfile.generic);
    expect(() => p.addEvent(const SseEvent(event: 'error', data: '{"message":"boom","type":"server_error"}')),
        throwsA(isA<ProviderException>()));
  });

  test('`reasoning_content` and `reasoning` are both read whatever the profile', () {
    // The generic profile also records the field the phase arrived in
    // (finding 13), so it can be written back there.
    expect(describeAll(run(ServerProfile.generic, [{'reasoning_content': 'a'}, {'reasoning': 'b'}])),
        ['Reasoning(a)', 'Reasoning(b)', 'Signature({"replay_field":"reasoning_content"})', 'Finish(stop)']);
    expect(describeAll(run(ServerProfile.vllm, [{'reasoning_content': 'a'}, {'reasoning': 'b'}])),
        ['Reasoning(a)', 'Reasoning(b)', 'Finish(stop)']);
  });

  group('reasoning goes back in the field it arrived in (finding 13)', () {
    // DeepSeek behind a gateway: the host is unknown, so the profile is generic.
    Message assistantFrom(List<ModelEvent> events) {
      String? sig;
      final text = StringBuffer();
      for (final e in events) {
        if (e is ReasoningDelta) text.write(e.text);
        if (e is ReasoningSignature) sig = e.signature;
      }
      return Message(
        id: 'a1',
        role: Role.assistant,
        content: [
          ReasoningPart(text: text.toString(), signature: sig, providerId: 'gw'),
          const ToolCallPart(ToolCall(id: 'c1', name: 'get_weather', arguments: {'city': 'Oslo'})),
        ],
        createdAt: t0,
      );
    }

    Map<String, Object?> replayed(ServerProfile profile, Message assistant, {List<ToolDefinition> tools = const [weatherTool]}) {
      final body = buildChatRequest(
        request: weatherRequest(messages: [userText('weather?'), assistant], tools: tools),
        quirks: ServerQuirks.of(profile),
        names: ToolNameMapper(['get_weather']),
        providerId: 'gw',
      ).body;
      return (body['messages']! as List).cast<Map<String, Object?>>().firstWhere((m) => m['role'] == 'assistant');
    }

    test('generic profile: reasoning_content comes back as reasoning_content while tools are present', () {
      final events = run(ServerProfile.generic, [
        {'reasoning_content': 'Need weather.'},
        {
          'tool_calls': [
            {'index': 0, 'id': 'c1', 'function': {'name': 'get_weather', 'arguments': '{"city":"Oslo"}'}},
          ],
        },
      ], finish: 'tool_calls');
      final a = replayed(ServerProfile.generic, assistantFrom(events));
      expect(a['reasoning_content'], 'Need weather.');
      expect(a.containsKey('reasoning'), isFalse);
      // Without tools nothing requires it, so the bytes are not spent.
      expect(replayed(ServerProfile.generic, assistantFrom(events), tools: const []).containsKey('reasoning_content'),
          isFalse);
    });

    test('generic profile: `reasoning` and OpenRouter details come back in their own fields', () {
      final viaReasoning = run(ServerProfile.generic, [
        {'reasoning': 'Think.'},
        {'content': 'ok'},
      ]);
      expect(replayed(ServerProfile.generic, assistantFrom(viaReasoning))['reasoning'], 'Think.');

      final details = [
        {'type': 'reasoning.text', 'text': 'Think.', 'index': 0},
      ];
      final viaDetails = run(ServerProfile.generic, [
        {'reasoning': 'Think.', 'reasoning_details': details},
        {'content': 'ok'},
      ]);
      final a = replayed(ServerProfile.generic, assistantFrom(viaDetails));
      expect(a['reasoning_details'], details);
      expect(a.containsKey('reasoning'), isFalse);
    });

    test('OpenAI keeps dropping reasoning; another provider\'s reasoning is never replayed', () {
      final events = run(ServerProfile.generic, [
        {'reasoning_content': 'Need weather.'},
        {'content': 'ok'},
      ]);
      expect(replayed(ServerProfile.openAi, assistantFrom(events)).containsKey('reasoning_content'), isFalse);
      final m = assistantFrom(events);
      final foreign = Message(
        id: m.id,
        role: m.role,
        createdAt: t0,
        content: [
          for (final c in m.content)
            c is ReasoningPart ? ReasoningPart(text: c.text, signature: c.signature, providerId: 'other') : c,
        ],
      );
      expect(replayed(ServerProfile.generic, foreign).containsKey('reasoning_content'), isFalse);
    });
  });
}
