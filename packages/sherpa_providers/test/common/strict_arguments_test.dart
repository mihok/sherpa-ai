import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';
import 'package:sherpa_providers/sherpa_providers.dart';
import 'package:test/test.dart';

/// Strict mode (R11 §d.3): outputs whose meaning a repair would have to
/// guess are refused as invalid calls, never executed with one reading.
void main() {
  ArgumentsParseResult parse(String s) => ToolArgumentsRepair.parseArguments(s);

  void expectRefused(String raw, String errorPart, String fix) {
    final r = parse(raw);
    expect(r.isOk, isFalse, reason: raw);
    expect(r.value, isNull, reason: raw);
    expect(r.repaired, isFalse, reason: raw);
    expect(r.error, contains(errorPart), reason: raw);
    expect(r.fixes, containsAll([ToolArgumentsRepair.refusedFix, fix]), reason: raw);
  }

  group('duplicate keys', () {
    test('strict JSON: the key is named, neither value is used', () {
      expectRefused('{"city": "Paris", "city": "Rome"}', 'The key "city" appears twice', 'duplicate_key');
      expectRefused('{"a": {"b": 1, "b": 2}}', '"b"', 'duplicate_key');
      expectRefused('{"items": [{"q": 1}, {"q": 2, "q": 3}]}', '"q"', 'duplicate_key');
      // Escapes spell the same key.
      expectRefused(r'{"city": "Paris", "city": "Rome"}', '"city"', 'duplicate_key');
    });

    test('malformed JSON, and arguments stringified twice', () {
      expectRefused("{'city': 'Paris', city: 'Rome'}", '"city"', 'duplicate_key');
      expectRefused(jsonEncode('{"city":"Paris","city":"Rome"}'), '"city"', 'duplicate_key');
    });

    test('equal keys in different objects, keys equal to values, and quotes in strings are fine', () {
      for (final raw in [
        '{"a": {"x": 1}, "b": {"x": 2}}',
        '{"name": "name", "x": "name"}',
        '{"items": [{"id": 1}, {"id": 2}]}',
        r'{"t": "a \"b\": c", "b": 1}',
        '{"s": "{\\"k\\": 1, \\"k\\": 2}"}',
      ]) {
        final r = parse(raw);
        expect(r.isOk, isTrue, reason: '$raw → ${r.error}');
        expect(r.repaired, isFalse, reason: raw);
      }
    });

    test('duplicateKey on its own', () {
      expect(ToolArgumentsRepair.duplicateKey('{"a":1,"b":{"a":2},"a":3}'), 'a');
      expect(ToolArgumentsRepair.duplicateKey('[{"a":1},{"a":2}]'), isNull);
      expect(ToolArgumentsRepair.duplicateKey('{"a" : 1, "a"\n: 2}'), 'a');
      expect(ToolArgumentsRepair.duplicateKey('{}'), isNull);
    });
  });

  group('leaked chat-template tokens', () {
    test('Gemma 4 string delimiters inside the arguments are refused', () {
      expectRefused('{city:<|"|>Paris<|"|>,unit:<|"|>celsius<|"|>}', '<|"|>', 'template_tokens');
      expectRefused('{"city": <|"|>Paris<|"|>}', 'chat-template token', 'template_tokens');
    });

    test('an end-of-turn token after a complete object is still a trailing-text repair', () {
      final r = parse('{"city": "Paris"}<|im_end|>');
      expect(r.isOk, isTrue);
      expect(r.repaired, isTrue);
      expect(r.value, {'city': 'Paris'});
    });

    test('strict JSON that merely mentions such a token is untouched', () {
      final r = parse(jsonEncode({'text': 'The template uses <|"|> as a quote.'}));
      expect(r.isOk, isTrue);
      expect(r.repaired, isFalse);
    });
  });

  group('ambiguous unquoted values', () {
    test('a multi-word bare value plus a structural repair is refused', () {
      expectRefused('{"city": Paris Tokyo, "unit": celsius]', '"Paris Tokyo"', 'ambiguous_value');
      expectRefused('{"city": Paris Tokyo, "unit": "c"]', 'mismatched bracket', 'ambiguous_value');
      // The bare value runs on into the next member.
      expectRefused('{"city": Paris Tokyo "unit": "c"}', 'next key', 'ambiguous_value');
    });

    test('alone, a multi-word bare value or a structural slip is still repaired (and flagged)', () {
      for (final (raw, want) in [
        ('{"city": New York}', {'city': 'New York'}),
        ('{"city": "Paris", "unit": "c"]', {'city': 'Paris', 'unit': 'c'}),
        ('{"unit": celsius]', {'unit': 'celsius'}),
      ]) {
        final r = parse(raw);
        expect(r.value, want, reason: '$raw → ${r.error}');
        expect(r.repaired, isTrue, reason: raw);
      }
    });
  });

  group('adapters surface refusals as invalid calls', () {
    test('Chat accumulator: no repaired call, no repair notice', () {
      final a = ToolCallAccumulator(newId: (i) => 'c$i');
      final events = [
        ...a.addChatDeltas([
          {
            'index': 0,
            'id': 'c1',
            'function': {'name': 'get_weather', 'arguments': '{"city": "Paris", '},
          },
        ]),
        ...a.addChatDeltas([
          {
            'index': 0,
            'function': {'arguments': '"city": "Rome"}'},
          },
        ]),
        ...a.completeAll(),
      ];
      final call = events.whereType<ToolCallComplete>().single.call;
      expect(call.isValid, isFalse);
      expect(call.argumentsError, contains('"city" appears twice'));
      expect(call.arguments, isEmpty);
      expect(call.repaired, isFalse);
      expect(events.whereType<ProviderNotice>().map((n) => n.code), isNot(contains('tool_args_repaired')));
    });

    test('Anthropic decoder: duplicate keys in streamed tool input', () {
      final decoder = AnthropicStreamDecoder(providerId: 'a', toolNames: AnthropicToolNames(const ['get_weather']));
      final events = <ModelEvent>[];
      for (final (type, data) in [
        ('message_start', {
          'type': 'message_start',
          'message': {'id': 'm', 'model': 'claude', 'usage': {'input_tokens': 1, 'output_tokens': 1}},
        }),
        ('content_block_start', {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'tool_use', 'id': 'tu1', 'name': 'get_weather', 'input': <String, Object?>{}},
        }),
        ('content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'input_json_delta', 'partial_json': '{"city": "Paris", "city": "Rome"}'},
        }),
        ('content_block_stop', {'type': 'content_block_stop', 'index': 0}),
        ('message_delta', {
          'type': 'message_delta',
          'delta': {'stop_reason': 'tool_use'},
          'usage': {'output_tokens': 5},
        }),
        ('message_stop', {'type': 'message_stop'}),
      ]) {
        events.addAll(decoder.add(SseEvent(event: type, data: jsonEncode(data))));
      }
      events.addAll(decoder.close());
      final call = events.whereType<ToolCallComplete>().single.call;
      expect(call.argumentsError, contains('"city" appears twice'));
      expect(call.arguments, isEmpty);
    });
  });

  /// Arguments a non-compliant server sends as a JSON object (not a
  /// string): decoding the event keeps only the last of two equal keys, so
  /// the adapters read the object's raw text from the event instead.
  group('arguments sent as an object', () {
    const dupArgs = '{"city": "Paris", "unit": "c", "city": "Rome"}';

    test('rawValueAt finds the raw span, last key wins on the path, never throws', () {
      const doc = '{"a": [1, {"b": {"x":1, "x":2}}, "s"], "e\\u0073c": {"k": true}, "a": [0, {"b": [ ]}]}';
      expect(ToolArgumentsRepair.rawValueAt(doc, const ['a', 1, 'b']), '[ ]', reason: 'like jsonDecode, the last "a"');
      expect(ToolArgumentsRepair.rawValueAt(doc, const ['esc', 'k']), 'true', reason: 'escaped keys are decoded');
      expect(ToolArgumentsRepair.rawValueAt(doc, const []), doc);
      expect(ToolArgumentsRepair.rawValueAt('{"o": {"x":1, "x":2}}', const ['o']), '{"x":1, "x":2}');
      expect(ToolArgumentsRepair.rawValueAt('{"s": "a}\\"]{", "n": -1.5e3}', const ['n']), '-1.5e3');
      for (final path in const [
        ['missing'],
        ['a', 5],
        ['a', 'b'],
        ['esc', 'k', 'deeper'],
      ]) {
        expect(ToolArgumentsRepair.rawValueAt(doc, path), isNull, reason: '$path');
      }
      expect(ToolArgumentsRepair.rawValueAt('{"a": ', const ['a']), isNull, reason: 'malformed input');
      expect(ToolArgumentsRepair.rawValueAt('', const ['a']), isNull);
    });

    test('Chat SSE: duplicate keys in an arguments object are refused; the other calls stand', () {
      final p = ChatStreamParser(
        names: ToolNameMapper(['get_weather', 'get_time']),
        quirks: ServerQuirks.of(ServerProfile.generic),
        newCallId: (i) => 'synth_$i',
      );
      // A second choice and a non-object entry come first, so the
      // position of the chosen choice in the raw text is not 0.
      final chunk = '{"choices": [7, {"index": 1, "delta": {"tool_calls": [{"index": 0, "function": '
          '{"name": "get_time", "arguments": {"tz": "a", "tz": "b"}}}]}}, {"index": 0, "delta": {"tool_calls": ['
          '{"index": 0, "id": "c1", "function": {"name": "get_weather", "arguments": $dupArgs}}, '
          '{"index": 1, "id": "c2", "function": {"name": "get_time", "arguments": {"tz": "UTC", "fmt": {"h": 24}}}}, '
          '{"index": 2, "id": "c3", "function": {"name": "get_time", "arguments": "{\\"tz\\": \\"CET\\"}"}}]}}]}';
      final events = [
        ...p.addEvent(SseEvent(data: chunk)),
        ...p.addEvent(SseEvent(data: jsonEncode({
          'choices': [
            {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': 'tool_calls'},
          ],
        }))),
        ...p.addEvent(const SseEvent(data: '[DONE]')),
        ...p.finish(),
      ];
      final calls = events.whereType<ToolCallComplete>().map((e) => e.call).toList();
      expect(calls, hasLength(3));
      expect(calls[0].isValid, isFalse);
      expect(calls[0].argumentsError, contains('"city" appears twice'));
      expect(calls[0].arguments, isEmpty);
      expect(calls[0].rawArguments, dupArgs, reason: 'the raw text, not a re-encoding');
      expect(calls[1].arguments, {'tz': 'UTC', 'fmt': {'h': 24}});
      expect(calls[1].isValid, isTrue);
      expect(calls[1].repaired, isFalse);
      expect(calls[2].arguments, {'tz': 'CET'});
      expect(events.whereType<ProviderNotice>().map((n) => n.code), isNot(contains('tool_args_repaired')));
    });

    test('Chat non-streamed completion: a whole message with an arguments object', () {
      final p = ChatStreamParser(
        names: ToolNameMapper(['get_weather']),
        quirks: ServerQuirks.of(ServerProfile.generic),
        newCallId: (i) => 'synth_$i',
      );
      final body = '{"choices": [{"index": 0, "finish_reason": "tool_calls", "message": {"role": "assistant", '
          '"tool_calls": [{"id": "c1", "type": "function", "function": {"name": "get_weather", "arguments": $dupArgs}}]}}]}';
      final events = [...p.addChunk(tryDecodeObject(body)!, rawText: body), ...(p..markDone()).finish()];
      final call = events.whereType<ToolCallComplete>().single.call;
      expect(call.argumentsError, contains('"city" appears twice'));
    });

    test('Chat accumulator without the raw text still accepts an object (re-encoded)', () {
      final a = ToolCallAccumulator(newId: (i) => 'c$i');
      final events = [
        ...a.addChatDeltas([
          {
            'index': 0,
            'id': 'c1',
            'function': {'name': 'get_weather', 'arguments': {'city': 'Paris'}},
          },
        ]),
        ...a.completeAll(),
      ];
      expect(events.whereType<ToolCallComplete>().single.call.arguments, {'city': 'Paris'});
    });

    test('Responses: object arguments in output_item.done and arguments.done are read, duplicates refused', () {
      final p = ResponsesStreamParser(names: ToolNameMapper(['get_weather']), newCallId: (i) => 'synth_$i');
      final events = [
        for (final data in [
          '{"type": "response.output_item.added", "output_index": 0, "item": {"type": "function_call", "id": "fc_0", '
              '"call_id": "call_0", "name": "get_weather", "arguments": ""}}',
          '{"type": "response.output_item.done", "output_index": 0, "item": {"type": "function_call", "id": "fc_0", '
              '"call_id": "call_0", "name": "get_weather", "arguments": $dupArgs}}',
          '{"type": "response.output_item.added", "output_index": 1, "item": {"type": "function_call", "id": "fc_1", '
              '"call_id": "call_1", "name": "get_weather", "arguments": {"city": "Oslo"}}}',
          '{"type": "response.function_call_arguments.done", "output_index": 1, "arguments": {"city": "Oslo", "city": "Bergen"}}',
          '{"type": "response.output_item.done", "output_index": 1, "item": {"type": "function_call", "id": "fc_1", '
              '"call_id": "call_1", "name": "get_weather"}}',
          '{"type": "response.output_item.added", "output_index": 2, "item": {"type": "function_call", "id": "fc_2", '
              '"call_id": "call_2", "name": "get_weather", "arguments": {"city": "Oslo"}}}',
          '{"type": "response.output_item.done", "output_index": 2, "item": {"type": "function_call", "id": "fc_2", '
              '"call_id": "call_2", "name": "get_weather", "arguments": {"city": "Oslo", "unit": "c"}}}',
          '{"type": "response.completed", "response": {"status": "completed"}}',
        ])
          ...p.addEvent(SseEvent(data: data)),
        ...p.finish(),
      ];
      final calls = events.whereType<ToolCallComplete>().map((e) => e.call).toList();
      expect(calls, hasLength(3));
      expect(calls[0].argumentsError, contains('"city" appears twice'));
      expect(calls[1].argumentsError, contains('"city" appears twice'));
      expect(calls[2].arguments, {'city': 'Oslo', 'unit': 'c'}, reason: 'objects used to be dropped silently');
      expect(calls[2].isValid, isTrue);
    });

    test('Anthropic: input sent whole in content_block_start, or as an object delta', () {
      List<ToolCall> run(List<String> blockEvents) {
        final decoder = AnthropicStreamDecoder(providerId: 'a', toolNames: AnthropicToolNames(const ['get_weather']));
        final events = <ModelEvent>[
          ...decoder.add(SseEvent(event: 'message_start', data: jsonEncode({
            'type': 'message_start',
            'message': {'id': 'm', 'model': 'claude', 'usage': {'input_tokens': 1, 'output_tokens': 1}},
          }))),
          for (final data in blockEvents) ...decoder.add(SseEvent(data: data)),
          ...decoder.add(SseEvent(data: jsonEncode({
            'type': 'message_delta',
            'delta': {'stop_reason': 'tool_use'},
            'usage': {'output_tokens': 5},
          }))),
          ...decoder.add(SseEvent(data: jsonEncode({'type': 'message_stop'}))),
          ...decoder.close(),
        ];
        return events.whereType<ToolCallComplete>().map((e) => e.call).toList();
      }

      String start(int i, String input) => '{"type": "content_block_start", "index": $i, "content_block": '
          '{"type": "tool_use", "id": "tu$i", "name": "get_weather", "input": $input}}';
      String stop(int i) => '{"type": "content_block_stop", "index": $i}';

      final calls = run([
        start(0, dupArgs),
        stop(0),
        start(1, '{"city": "Oslo", "nested": {"a": 1}}'),
        stop(1),
        start(2, '{}'),
        '{"type": "content_block_delta", "index": 2, "delta": {"type": "input_json_delta", "partial_json": $dupArgs}}',
        stop(2),
        start(3, '{}'),
        '{"type": "content_block_delta", "index": 3, "delta": {"type": "input_json_delta", "partial_json": {"city": "Oslo"}}}',
        stop(3),
      ]);
      expect(calls, hasLength(4));
      expect(calls[0].argumentsError, contains('"city" appears twice'));
      expect(calls[0].arguments, isEmpty);
      expect(calls[1].arguments, {'city': 'Oslo', 'nested': {'a': 1}});
      expect(calls[1].isValid, isTrue);
      expect(calls[2].argumentsError, contains('"city" appears twice'));
      expect(calls[3].arguments, {'city': 'Oslo'});
    });
  });
}
