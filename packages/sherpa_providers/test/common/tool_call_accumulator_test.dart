import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';
import 'package:test/test.dart';

import '../support/helpers.dart';

void main() {
  ToolCallAccumulator acc({String Function(String)? resolve}) =>
      ToolCallAccumulator(newId: (i) => 'synth_$i', resolveName: resolve);

  Map<String, Object?> frag(int? index, {String? id, String? name, Object? args}) => {
        'index': ?index,
        'id': ?id,
        'type': 'function',
        'function': {'name': ?name, 'arguments': ?args},
      };

  test('fragments stream live and complete at the end', () {
    final a = acc();
    final events = [
      ...a.addChatDeltas([frag(0, id: 'c1', name: 'get_weather', args: '')]),
      ...a.addChatDeltas([frag(0, args: '{"ci')]),
      ...a.addChatDeltas([frag(0, args: 'ty":"Paris"}')]),
      ...a.completeAll(),
    ];
    expect(describeAll(events), [
      'ToolCallStart(0, c1, get_weather)',
      'ToolCallArgsDelta(0, {"ci)',
      'ToolCallArgsDelta(0, ty":"Paris"})',
      'ToolCallComplete(0, c1, get_weather, {"city":"Paris"})',
    ]);
  });

  test('several fragments for one index inside one chunk', () {
    final a = acc();
    final events = [
      ...a.addChatDeltas([
        frag(0, id: 'c1', name: 'f', args: '{"a"'),
        frag(0, args: ':1'),
        frag(1, id: 'c2', name: 'g', args: '{}'),
        frag(0, args: '}'),
      ]),
      ...a.completeAll(),
    ];
    final complete = events.whereType<ToolCallComplete>().toList();
    expect(complete.map((c) => c.call.arguments), [
      {'a': 1},
      <String, Object?>{},
    ]);
    expect(complete.map((c) => c.index), [0, 1]);
  });

  test('whole calls in one chunk (Ollama / vLLM hf)', () {
    final a = acc();
    final events = [
      ...a.addChatDeltas([
        frag(0, id: 'a', name: 'get_weather', args: '{"city":"Paris"}'),
        frag(1, id: 'b', name: 'get_time', args: '{"timezone":"Asia/Tokyo"}'),
      ]),
      ...a.completeAll(),
    ];
    expect(events.whereType<ToolCallStart>().map((e) => (e.index, e.id, e.name)), [
      (0, 'a', 'get_weather'),
      (1, 'b', 'get_time'),
    ]);
    expect(events.whereType<ToolCallComplete>().map((e) => e.call.isValid), [true, true]);
  });

  test('names are never concatenated (LM Studio empty / repeated names)', () {
    final a = acc();
    a
      ..addChatDeltas([frag(0, id: 'x', name: 'get_weather', args: '')])
      ..addChatDeltas([frag(0, name: '', args: '{"city":')])
      ..addChatDeltas([frag(0, name: 'get_weather', args: '"Paris"}')]);
    final done = a.completeAll().whereType<ToolCallComplete>().single;
    expect(done.call.name, 'get_weather');
    expect(done.call.arguments, {'city': 'Paris'});
  });

  test('missing ids are synthesized and stable', () {
    final a = acc();
    final start = a.addChatDeltas([frag(0, name: 'f', args: '{')]).whereType<ToolCallStart>().single;
    a.addChatDeltas([frag(0, id: 'late_id', args: '}')]);
    final done = a.completeAll().whereType<ToolCallComplete>().single;
    expect(start.id, 'synth_0');
    expect(done.call.id, 'synth_0');
  });

  test('a reused index with a new id opens a new call', () {
    final a = acc();
    a
      ..addChatDeltas([frag(0, id: 'c1', name: 'f', args: '{"a":1}')])
      ..addChatDeltas([frag(0, id: 'c2', name: 'g', args: '{"b":2}')]);
    final done = a.completeAll().whereType<ToolCallComplete>().toList();
    expect(done.map((d) => (d.index, d.call.id, d.call.name)), [(0, 'c1', 'f'), (1, 'c2', 'g')]);
  });

  test('a reused index with a different name (no ids) opens a new call', () {
    final a = acc();
    a
      ..addChatDeltas([frag(0, name: 'f', args: '{"a":1}')])
      ..addChatDeltas([frag(0, name: 'g', args: '{"b":2}')]);
    expect(a.length, 2);
  });

  test('missing index falls back to id, then to the last open call', () {
    final a = acc();
    a
      ..addChatDeltas([frag(null, id: 'c1', name: 'f', args: '{"a":')])
      ..addChatDeltas([frag(null, args: '1}')])
      ..addChatDeltas([frag(null, id: 'c2', name: 'g', args: '{}')]);
    final done = a.completeAll().whereType<ToolCallComplete>().toList();
    expect(done.map((d) => d.call.arguments), [
      {'a': 1},
      <String, Object?>{},
    ]);
  });

  test('arguments sent as an object are encoded', () {
    final a = acc()..addChatDeltas([frag(0, id: 'c', name: 'f', args: {'city': 'Paris'})]);
    expect(a.completeAll().whereType<ToolCallComplete>().single.call.arguments, {'city': 'Paris'});
  });

  test('arguments before the name are emitted after the start', () {
    final a = acc();
    final first = a.addChatDeltas([frag(0, args: '{"a":1}')]);
    expect(first, isEmpty);
    final second = a.addChatDeltas([frag(0, id: 'c', name: 'f')]);
    expect(describeAll(second), ['ToolCallStart(0, c, f)', 'ToolCallArgsDelta(0, {"a":1})']);
  });

  test('broken arguments are repaired or reported, never thrown', () {
    final a = acc()
      ..addChatDeltas([frag(0, id: 'c1', name: 'f', args: "{'a': True,")])
      ..addChatDeltas([frag(1, id: 'c2', name: 'g', args: 'not json at all')]);
    final events = a.completeAll();
    final calls = events.whereType<ToolCallComplete>().map((e) => e.call).toList();
    expect(calls[0].arguments, {'a': true});
    expect(calls[0].repaired, isTrue);
    expect(calls[0].rawArguments, "{'a': True,");
    expect(calls[1].isValid, isFalse);
    expect(calls[1].argumentsError, isNotNull);
    expect(events.whereType<ProviderNotice>().single.code, 'tool_args_repaired');
  });

  test('a call that never got a name completes with an error', () {
    final a = acc()..addChatDeltas([frag(0, id: 'c', args: '{}')]);
    final events = a.completeAll();
    expect(events.first, isA<ToolCallStart>());
    expect(events.whereType<ToolCallComplete>().single.call.argumentsError, contains('no tool name'));
  });

  test('wire names are resolved through the mapper', () {
    final names = ToolNameMapper(['files.read']);
    final a = acc(resolve: names.fromWire)..addChatDeltas([frag(0, id: 'c', name: 'files_read', args: '{}')]);
    expect(a.completeAll().whereType<ToolCallComplete>().single.call.name, 'files.read');
  });

  test('slot API (Responses): open, append, set final arguments, complete', () {
    final a = acc();
    final events = [
      ...a.open(1, id: 'call_1', name: 'f', arguments: ''),
      ...a.append(1, '{"a"'),
      ...a.open(2, id: 'call_2', name: 'g'),
    ];
    a.setArguments(1, '{"a":2}');
    events
      ..addAll(a.complete(1))
      ..addAll(a.complete(1))
      ..addAll(a.completeAll());
    final done = events.whereType<ToolCallComplete>().toList();
    expect(done.map((d) => '${d.index} ${d.call.id} ${jsonEncode(d.call.arguments)}'), [
      '0 call_1 {"a":2}',
      '1 call_2 {}',
    ]);
  });
}
