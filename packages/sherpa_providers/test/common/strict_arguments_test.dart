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
}
