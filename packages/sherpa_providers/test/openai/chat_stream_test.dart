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
    expect(describeAll(run(ServerProfile.generic, [{'reasoning_content': 'a'}, {'reasoning': 'b'}])),
        ['Reasoning(a)', 'Reasoning(b)', 'Finish(stop)']);
  });
}
