import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/engine.dart';
import 'package:sherpa_providers/tool_arguments.dart';

/// The engine path parses tool arguments exactly like the remote adapters
/// (`ToolArgumentsRepair`), strict mode included.
void main() {
  ToolCall parse(String raw) => EngineEventMapper.parseToolCall('c1', 'get_weather', raw);

  test('every corpus slip gets the same verdict as on the provider path', () {
    for (final raw in [
      '{"city": "Paris"}',
      '',
      'null',
      jsonEncode('{"city":"Paris","unit":"celsius"}'),
      "{'city': 'Paris',}",
      '{"city": "Paris", "city": "Rome"}',
      '{city:<|"|>Paris<|"|>,unit:<|"|>celsius<|"|>}',
      '{"city": Paris Tokyo, "unit": celsius]',
      '[{"city": "Paris"}]',
      '}}}',
    ]) {
      final call = parse(raw);
      final want = ToolArgumentsRepair.parseArguments(raw);
      expect(call.arguments, want.value ?? const <String, Object?>{}, reason: raw);
      expect(call.argumentsError, want.error, reason: raw);
      expect(call.repaired, want.repaired, reason: raw);
      expect(call.rawArguments, raw);
    }
  });

  test('null means no arguments; stringified arguments are decoded again (both flagged repaired)', () {
    final none = parse('null');
    expect(none.isValid, isTrue);
    expect(none.arguments, isEmpty);
    expect(none.repaired, isTrue);
    final twice = parse(jsonEncode('{"city":"Paris","unit":"celsius"}'));
    expect(twice.arguments, {'city': 'Paris', 'unit': 'celsius'});
    expect(twice.repaired, isTrue);
  });

  test('duplicate keys, leaked Gemma delimiters and ambiguous values are invalid calls', () {
    expect(parse('{"city": "Paris", "city": "Rome"}').argumentsError, contains('"city" appears twice'));
    expect(parse('{city:<|"|>Paris<|"|>,unit:<|"|>celsius<|"|>}').argumentsError, contains('<|"|>'));
    expect(parse('{"city": Paris Tokyo, "unit": celsius]').argumentsError, contains('ambiguous'));
  });

  test('TOOL_CALL_DONE with repaired arguments is followed by a tool_args_repaired notice', () {
    final m = EngineEventMapper(providerId: 'llama_cpp');
    final out = m.map(const EngineEvent(type: EngineEventType.toolCallDone, index: 0, id: 'c1', name: 'f', text: "{'a': 1,}"));
    expect((out.first as ToolCallComplete).call.repaired, isTrue);
    expect(out.last, isA<ProviderNotice>().having((n) => n.code, 'code', 'tool_args_repaired'));
    final clean = m.map(const EngineEvent(type: EngineEventType.toolCallDone, index: 1, id: 'c2', name: 'f', text: '{"a": 1}'));
    expect(clean.single, isA<ToolCallComplete>());
  });
}
