// Generates data/l1/corpus.json: golden raw model outputs for every parser
// path (OpenAI-compatible Chat under the llama.cpp / Ollama / vLLM /
// LM Studio / proxy quirk profiles, Anthropic Messages, OpenAI Responses,
// and on-device engine events), well-formed and malformed.
//
// Each case's expectation is written from the variant's DEFINITION (R11
// §d.3 repair rules, §9.6.6 pipeline, the agent loop's safety rules), never
// by running a parser, so the corpus measures the parsers rather than
// snapshotting them. Regenerate after editing:
//   dart run tool/gen_l1_corpus.dart
// ignore_for_file: avoid_print
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const List<String> tools = ['get_weather', 'get_time', 'send_email', 'list_files', 'create_event'];

const Map<String, Object?> weather = {'city': 'Paris', 'unit': 'celsius'};
const Map<String, Object?> time = {'timezone': 'Asia/Tokyo'};
const Map<String, Object?> email = {'to': 'ada@example.com', 'subject': 'Hi', 'body': 'Line 1\nShe said "hi" — é'};
const Map<String, Object?> event = {'title': 'Standup', 'days': 3, 'remote': true, 'notes': null};

/// One raw call: the wire name and argument text the model produced, and
/// what a correct harness must make of it.
final class Raw {
  const Raw(this.name, this.args, {this.object});

  final String name;

  /// Argument text as streamed.
  final String args;

  /// Ollama-style non-compliant servers send the object itself.
  final Map<String, Object?>? object;
}

/// Expected outcome.
Map<String, Object?> callsExpect(List<(String, Map<String, Object?>)> calls, {bool? repaired}) => {
      'outcome': 'calls',
      'calls': [
        for (final (n, a) in calls) {'name': n, 'arguments': a, 'repaired': ?repaired},
      ],
    };

const Map<String, Object?> blocked = {'outcome': 'blocked'};
const Map<String, Object?> streamError = {'outcome': 'stream_error'};
Map<String, Object?> textExpect(String contains) => {'outcome': 'text', 'contains': contains};

/// Argument-text variants on a complete turn: (id, raw, expectation, why).
final List<(String, Raw, Map<String, Object?>, String)> argVariants = [
  ('clean', Raw('get_weather', jsonEncode(weather)), callsExpect([('get_weather', weather)], repaired: false), 'well-formed'),
  ('clean_escapes', Raw('send_email', jsonEncode(email)), callsExpect([('send_email', email)], repaired: false),
      'escaped quotes, newline and non-ASCII'),
  ('empty_args', const Raw('list_files', ''), callsExpect([('list_files', {})], repaired: false),
      'no argument text for a parameterless tool'),
  ('trailing_comma', const Raw('get_weather', '{"city": "Paris", "unit": "celsius",}'),
      callsExpect([('get_weather', weather)], repaired: true), 'R11 d.3: trailing commas are stripped'),
  ('python_literals', const Raw('create_event', '{"title": "Standup", "days": 3, "remote": True, "notes": None}'),
      callsExpect([('create_event', event)], repaired: true), 'R11 d.3: Python True/False/None'),
  ('python_dict', const Raw('create_event', "{'title': 'Standup', 'days': 3, 'remote': True, 'notes': None}"),
      callsExpect([('create_event', event)], repaired: true), 'pythonic families: single quotes plus Python literals'),
  ('single_quotes', const Raw('get_weather', "{'city': 'Paris', 'unit': 'celsius'}"),
      callsExpect([('get_weather', weather)], repaired: true), 'R11 d.3: single quotes become double'),
  ('smart_quotes', const Raw('get_weather', '{“city”: “Paris”, “unit”: “celsius”}'),
      callsExpect([('get_weather', weather)], repaired: true), 'R11 d.3: smart quotes are normalised'),
  ('unquoted_keys', const Raw('get_weather', '{city: "Paris", unit: "celsius"}'),
      callsExpect([('get_weather', weather)], repaired: true), 'R11 d.3: missing quotes on keys'),
  ('stringified', Raw('get_weather', jsonEncode(jsonEncode(weather))),
      callsExpect([('get_weather', weather)], repaired: true), 'R11 9.6.6: stringified arguments decoded twice'),
  ('code_fence', const Raw('get_weather', '```json\n{"city": "Paris", "unit": "celsius"}\n```'),
      callsExpect([('get_weather', weather)], repaired: true), 'R11 9.6.6 step 1: code fences stripped'),
  ('missing_closer', const Raw('get_weather', '{"city": "Paris", "unit": "celsius"'),
      callsExpect([('get_weather', weather)], repaired: true), 'complete turn, closing brace missing'),
  ('trailing_eos', const Raw('get_weather', '{"city": "Paris", "unit": "celsius"}</s>'),
      callsExpect([('get_weather', weather)], repaired: true), 'end-of-sequence marker after a complete object'),
  ('leading_prose', const Raw('get_weather', 'Arguments: {"city": "Paris", "unit": "celsius"}'),
      callsExpect([('get_weather', weather)], repaired: true), 'leading prose before the object'),
  ('null_arguments', const Raw('list_files', 'null'), callsExpect([('list_files', {})]), 'literal null means no arguments'),
  ('duplicate_keys', const Raw('get_weather', '{"city": "Paris", "city": "Rome"}'), blocked,
      'R11 d.3 strict mode: duplicate keys are ambiguous, must not execute either value'),
  ('args_array', const Raw('get_weather', '[{"city": "Paris"}]'), blocked, 'arguments must be an object'),
  ('pythonic_call_as_args', const Raw('get_weather', 'get_weather(city="Paris")'), blocked,
      'a pythonic call is not an argument object'),
  ('gemma_delimiters', const Raw('get_weather', '{city:<|"|>Paris<|"|>,unit:<|"|>celsius<|"|>}'), blocked,
      'Gemma 4 string delimiters leaked by a generic parser: not JSON, must not run with garbled values'),
  ('ambiguous_garbage', const Raw('get_weather', '{"city": Paris Tokyo, "unit": celsius]'), blocked,
      'unquoted multi-word value plus a mismatched bracket: ambiguous'),
];

/// Name variants (clean weather arguments).
final List<(String, String, Map<String, Object?>, String)> nameVariants = [
  ('wrong_case', 'Get_Weather', callsExpect([('get_weather', weather)]), 'R11 9.6.6 step 4: case normalisation'),
  ('functions_prefix', 'functions.get_weather', callsExpect([('get_weather', weather)]), 'harmony-style prefix'),
  ('typo_name', 'get_wether', callsExpect([('get_weather', weather)]),
      'R11 9.6.6 step 4: unique match within edit distance 2'),
  ('unknown_name', 'launch_rockets', blocked, 'no such tool'),
  ('empty_name', '', blocked, 'a call without a name'),
];

/// Text a parser failed to turn into a call, per model family (R11 §d.1).
const Map<String, String> familyMarkers = {
  'qwen3_hermes': '<tool_call>\n{"name": "get_weather", "arguments": {"city": "Paris"}}\n</tool_call>',
  'qwen3_5_coder_xml':
      '<tool_call>\n<function=get_weather>\n<parameter=city>\nParis\n</parameter>\n</function>\n</tool_call>',
  'gemma4': '<|tool_call>call:get_weather{city:<|"|>Paris<|"|>}<tool_call|>',
  'lfm2_pythonic': '<|tool_call_start|>[get_weather(city="Paris")]<|tool_call_end|>',
  'llama3_2_pythonic': '[get_weather(city="Paris", unit="celsius")]',
  'mistral_args': '[TOOL_CALLS]get_weather[ARGS]{"city": "Paris"}',
  'phi4_functools': 'functools[{"name": "get_weather", "arguments": {"city": "Paris"}}]',
  'xlam_json_array': '[{"name": "get_weather", "arguments": {"city": "Paris"}}]',
  'granite_hermes': '<tool_call>{"name": "get_weather", "arguments": {"city": "Paris"}}</tool_call>',
};

/// The argument slip each family's server-side parser most often passes
/// through (R11 §d.1 formats; §d.3 repairs).
const Map<String, List<String>> familySlips = {
  'qwen3_hermes': ['trailing_comma', 'missing_closer', 'code_fence'],
  'qwen3_5_coder_xml': ['stringified', 'unquoted_keys'],
  'gemma4': ['gemma_delimiters', 'unquoted_keys'],
  'lfm2_pythonic': ['python_dict', 'pythonic_call_as_args'],
  'llama3_2_pythonic': ['python_literals', 'single_quotes'],
  'mistral_args': ['trailing_eos', 'leading_prose'],
  'phi4_functools': ['stringified', 'smart_quotes'],
  'xlam_json_array': ['args_array', 'duplicate_keys'],
  'granite_hermes': ['code_fence', 'trailing_comma'],
};

// ---------------------------------------------------------------- SSE builders

String sse(List<Object?> datas, {List<String?>? events, bool done = true}) {
  final b = StringBuffer();
  for (final (i, d) in datas.indexed) {
    final ev = events?[i];
    if (ev != null) b.write('event: $ev\n');
    b.write('data: ${d is String ? d : jsonEncode(d)}\n\n');
  }
  if (done) b.write('data: [DONE]\n\n');
  return b.toString();
}

Map<String, Object?> chunk(Map<String, Object?> delta, {String? finish, String model = 'qwen3-0.6b'}) => {
      'id': 'chatcmpl-1',
      'object': 'chat.completion.chunk',
      'created': 1760000000,
      'model': model,
      'choices': [
        {'index': 0, 'delta': delta, 'finish_reason': finish},
      ],
    };

List<String> pieces(String s, int n) => [for (var i = 0; i < s.length; i += n) s.substring(i, i + n > s.length ? s.length : i + n)];

const String id16 = 'Vd9q2LxR8sTn4KbP';

/// OpenAI-compatible Chat stream for [calls] as [profile] streams them.
String chatStream(
  String profile,
  List<Raw> calls, {
  String finish = 'tool_calls',
  String? reasoning,
  String? content,
  bool done = true,
  bool finishChunk = true,
}) {
  final datas = <Object?>[];
  final ids = [for (var i = 0; i < calls.length; i++) switch (profile) {
    'llamaCpp' => '${id16.substring(0, 15)}$i',
    'vllm' => 'chatcmpl-tool-0a1b2c3d$i',
    'ollama' => 'call_${'olm$i'}',
    _ => 'call_$i',
  }];
  datas.add(chunk({'role': 'assistant', 'content': null}));
  if (reasoning != null) {
    final field = profile == 'vllm' || profile == 'ollama' ? 'reasoning' : 'reasoning_content';
    for (final r in pieces(reasoning, 12)) {
      datas.add(chunk({field: r}));
    }
  }
  if (content != null) {
    for (final c in pieces(content, 9)) {
      datas.add(chunk({'content': c}));
    }
  }
  switch (profile) {
    case 'ollama':
      // Whole calls in one chunk; `stop` after tool calls.
      datas.add(chunk({
        'content': '',
        'tool_calls': [
          for (final (i, c) in calls.indexed)
            {
              'id': ids[i],
              'index': i,
              'type': 'function',
              'function': {'name': c.name, 'arguments': c.object ?? c.args},
            },
        ],
      }));
    case 'lmStudio':
      // The name is repeated with every fragment, and 0.3.16 appended an
      // empty name after the first packet (R10 §3.4).
      for (final (i, c) in calls.indexed) {
        datas.add(chunk({
          'tool_calls': [
            {'index': i, 'id': ids[i], 'type': 'function', 'function': {'name': c.name, 'arguments': ''}},
          ],
        }));
        datas.add(chunk({
          'tool_calls': [
            {'index': i, 'type': 'function', 'function': {'name': '', 'arguments': ''}},
          ],
        }));
        for (final f in pieces(c.args, 5)) {
          datas.add(chunk({
            'tool_calls': [
              {'index': i, 'type': 'function', 'function': {'name': c.name, 'arguments': f}},
            ],
          }));
        }
      }
    case 'proxy':
      // A compat proxy that reuses index 0 for every call.
      for (final (i, c) in calls.indexed) {
        datas.add(chunk({
          'tool_calls': [
            {'index': 0, 'id': ids[i], 'type': 'function', 'function': {'name': c.name, 'arguments': ''}},
          ],
        }));
        for (final f in pieces(c.args, 6)) {
          datas.add(chunk({
            'tool_calls': [
              {'index': 0, 'function': {'arguments': f}},
            ],
          }));
        }
      }
    case 'proxy_no_id':
      // No ids at all (synthesized by the client).
      for (final (i, c) in calls.indexed) {
        datas.add(chunk({
          'tool_calls': [
            {'index': i, 'type': 'function', 'function': {'name': c.name, 'arguments': ''}},
          ],
        }));
        for (final f in pieces(c.args, 6)) {
          datas.add(chunk({
            'tool_calls': [
              {'index': i, 'function': {'arguments': f}},
            ],
          }));
        }
      }
    default: // llamaCpp, vllm, openAi: name first, then argument fragments
      for (final (i, c) in calls.indexed) {
        datas.add(chunk({
          'tool_calls': [
            {'index': i, 'id': ids[i], 'type': 'function', 'function': {'name': c.name, 'arguments': ''}},
          ],
        }));
        for (final f in pieces(c.args, profile == 'openAi' ? 7 : 5)) {
          datas.add(chunk({
            'tool_calls': [
              {'index': i, 'function': {'arguments': f}},
            ],
          }));
        }
      }
  }
  if (finishChunk) {
    final f = profile == 'ollama' && finish == 'tool_calls' ? 'stop' : finish;
    datas.add(chunk({}, finish: f));
    datas.add({
      'id': 'chatcmpl-1',
      'object': 'chat.completion.chunk',
      'choices': <Object?>[],
      'usage': {'prompt_tokens': 120, 'completion_tokens': 30, 'total_tokens': 150},
      if (profile == 'llamaCpp') 'timings': {'prompt_n': 120, 'prompt_ms': 300.0, 'predicted_n': 30, 'predicted_ms': 900.0},
    });
  }
  return sse(datas, done: done);
}

String anthropicStream(
  List<Raw> calls, {
  String stop = 'tool_use',
  bool thinking = false,
  bool messageStop = true,
  bool messageDelta = true,
  bool initialInput = false,
}) {
  final datas = <Object?>[];
  final events = <String?>[];
  void add(String type, Map<String, Object?> d) {
    events.add(type);
    datas.add({'type': type, ...d});
  }

  add('message_start', {
    'message': {
      'id': 'msg_01',
      'type': 'message',
      'role': 'assistant',
      'model': 'claude-test',
      'content': <Object?>[],
      'stop_reason': null,
      'usage': {'input_tokens': 50, 'output_tokens': 1},
    },
  });
  var index = 0;
  if (thinking) {
    add('content_block_start', {'index': index, 'content_block': {'type': 'thinking', 'thinking': ''}});
    add('content_block_delta', {'index': index, 'delta': {'type': 'thinking_delta', 'thinking': 'The user wants weather.'}});
    add('content_block_delta', {'index': index, 'delta': {'type': 'signature_delta', 'signature': 'sig123'}});
    add('content_block_stop', {'index': index});
    index++;
  }
  for (final (i, c) in calls.indexed) {
    final whole = initialInput ? (jsonDecode(c.args) as Map).cast<String, Object?>() : <String, Object?>{};
    add('content_block_start', {
      'index': index,
      'content_block': {'type': 'tool_use', 'id': 'toolu_0$i', 'name': c.name, 'input': whole},
    });
    if (!initialInput) {
      for (final f in pieces(c.args, 6)) {
        add('content_block_delta', {'index': index, 'delta': {'type': 'input_json_delta', 'partial_json': f}});
      }
    }
    if (stop != 'max_tokens' || i < calls.length - 1) add('content_block_stop', {'index': index});
    index++;
  }
  if (messageDelta) {
    add('message_delta', {
      'delta': {'stop_reason': stop, 'stop_sequence': null},
      'usage': {'output_tokens': 40},
    });
  }
  if (messageStop) add('message_stop', {});
  return sse(datas, events: events, done: false);
}

String responsesStream(
  List<Raw> calls, {
  String status = 'completed',
  bool lostDelta = false,
  bool itemDone = true,
  bool terminal = true,
}) {
  final datas = <Object?>[];
  final events = <String?>[];
  void add(String type, Map<String, Object?> d) {
    events.add(type);
    datas.add({'type': type, ...d});
  }

  add('response.created', {'response': {'id': 'resp_1', 'status': 'in_progress'}});
  for (final (i, c) in calls.indexed) {
    final item = {'type': 'function_call', 'id': 'fc_$i', 'call_id': 'call_$i', 'name': c.name, 'arguments': ''};
    add('response.output_item.added', {'output_index': i, 'item': item});
    final frags = pieces(c.args, 6);
    for (final (k, f) in frags.indexed) {
      if (lostDelta && k == 1) continue;
      add('response.function_call_arguments.delta', {'output_index': i, 'item_id': 'fc_$i', 'delta': f});
    }
    if (itemDone) {
      add('response.function_call_arguments.done', {'output_index': i, 'item_id': 'fc_$i', 'arguments': c.args});
      add('response.output_item.done', {
        'output_index': i,
        'item': {...item, 'arguments': c.args, 'status': 'completed'},
      });
    }
  }
  if (terminal) {
    add(status == 'completed' ? 'response.completed' : 'response.incomplete', {
      'response': {
        'id': 'resp_1',
        'status': status,
        if (status == 'incomplete') 'incomplete_details': {'reason': 'max_output_tokens'},
        'usage': {'input_tokens': 40, 'output_tokens': 20, 'total_tokens': 60},
      },
    });
  }
  return sse(datas, events: events, done: false);
}

List<Map<String, Object?>> engineEvents(List<Raw> calls, {String finish = 'toolCalls', String? text, bool error = false}) => [
      if (text != null)
        for (final t in pieces(text, 8)) {'type': 'textDelta', 'text': t},
      for (final (i, c) in calls.indexed) ...[
        {'type': 'toolCallStart', 'index': i, 'id': 'call_$i', 'name': c.name},
        for (final f in pieces(c.args, 5)) {'type': 'toolCallArgsDelta', 'index': i, 'text': f},
        {'type': 'toolCallDone', 'index': i, 'id': 'call_$i', 'name': c.name, 'text': c.args},
      ],
      {'type': 'usage', 'promptTokens': 200, 'cachedTokens': 0, 'completionTokens': 30},
      {'type': 'perf', 'ttftMs': 300.0, 'prefillTps': 400.0, 'decodeTps': 25.0},
      if (error) {'type': 'error', 'code': -9, 'text': 'decode failed'},
      {'type': 'finish', 'finish': error ? 'error' : finish},
    ];

// ---------------------------------------------------------------- corpus

final List<Map<String, Object?>> cases = [];

void add(
  String path,
  String id, {
  required String family,
  required String variant,
  required Map<String, Object?> expect,
  required String why,
  String? profile,
  String? sseText,
  List<Map<String, Object?>>? events,
  List<String> toolNames = tools,
}) {
  cases.add({
    'id': '$path.${profile == null ? '' : '$profile.'}$id',
    'path': path,
    'profile': ?profile,
    'family': family,
    'variant': variant,
    'why': why,
    'tools': toolNames,
    'sse': ?sseText,
    'events': ?events,
    'expect': expect,
  });
}

Raw weatherCall([String? name]) => Raw(name ?? 'get_weather', jsonEncode(weather));

Raw timeCall() => Raw('get_time', jsonEncode(time));

void main(List<String> args) {
  // ---- OpenAI-compatible Chat, llama.cpp profile: every family.
  for (final family in familyMarkers.keys) {
    add('openai_chat', '$family.clean', profile: 'llamaCpp', family: family, variant: 'clean',
        sseText: chatStream('llamaCpp', [weatherCall()]), expect: callsExpect([('get_weather', weather)], repaired: false),
        why: 'server-side family parser produced a well-formed call');
    add('openai_chat', '$family.parallel', profile: 'llamaCpp', family: family, variant: 'parallel',
        sseText: chatStream('llamaCpp', [weatherCall(), timeCall()]),
        expect: callsExpect([('get_weather', weather), ('get_time', time)], repaired: false), why: 'two calls');
    add('openai_chat', '$family.markers_in_text', profile: 'llamaCpp', family: family, variant: 'markers_in_text',
        sseText: chatStream('llamaCpp', const [], finish: 'stop', content: 'Let me check. ${familyMarkers[family]}'),
        expect: textExpect(familyMarkers[family]!.substring(0, 6)),
        why: 'the server did not parse the family format: text is never executed as a call');
    for (final slip in familySlips[family]!) {
      final v = argVariants.firstWhere((x) => x.$1 == slip);
      add('openai_chat', '$family.$slip', profile: 'llamaCpp', family: family, variant: slip,
          sseText: chatStream('llamaCpp', [v.$2]), expect: v.$3, why: v.$4);
    }
  }
  // ---- llama.cpp / Qwen3: every argument and name variant, plus stream shapes.
  const fam = 'qwen3_hermes';
  for (final (id, raw, expect, why) in argVariants) {
    if (familySlips[fam]!.contains(id) || id == 'clean') continue;
    add('openai_chat', '$fam.$id', profile: 'llamaCpp', family: fam, variant: id,
        sseText: chatStream('llamaCpp', [raw]), expect: expect, why: why);
  }
  for (final (id, name, expect, why) in nameVariants) {
    add('openai_chat', '$fam.$id', profile: 'llamaCpp', family: fam, variant: id,
        sseText: chatStream('llamaCpp', [weatherCall(name)]), expect: expect, why: why);
  }
  add('openai_chat', '$fam.truncated', profile: 'llamaCpp', family: fam, variant: 'truncated',
      sseText: chatStream('llamaCpp', [const Raw('get_weather', '{"city": "Par')], finish: 'length'),
      expect: blocked, why: 'cut off at max tokens mid-arguments: never repaired, never run');
  add('openai_chat', '$fam.truncated_complete_json', profile: 'llamaCpp', family: fam, variant: 'truncated_complete_json',
      sseText: chatStream('llamaCpp', [weatherCall()], finish: 'length'),
      expect: blocked, why: 'the agent loop never runs calls of a turn that hit the output limit (R10 §7.5)');
  add('openai_chat', '$fam.content_filter_mid_call', profile: 'llamaCpp', family: fam, variant: 'content_filter',
      sseText: chatStream('llamaCpp', [const Raw('send_email', '{"to": "ada@example.com", "body": "Hel')],
          finish: 'content_filter'),
      expect: blocked, why: 'stopped by a content filter mid-arguments');
  add('openai_chat', '$fam.no_finish', profile: 'llamaCpp', family: fam, variant: 'no_finish',
      sseText: chatStream('llamaCpp', [weatherCall()], done: false, finishChunk: false),
      expect: streamError, why: 'socket closed with neither [DONE] nor finish_reason: truncated stream');
  add('openai_chat', '$fam.reasoning_then_call', profile: 'llamaCpp', family: fam, variant: 'reasoning_then_call',
      sseText: chatStream('llamaCpp', [weatherCall()], reasoning: 'The user wants the weather in Paris.'),
      expect: callsExpect([('get_weather', weather)], repaired: false), why: 'reasoning_content before the call');
  add('openai_chat', '$fam.think_tags_then_call', profile: 'llamaCpp', family: fam, variant: 'think_tags_then_call',
      sseText: chatStream('llamaCpp', [weatherCall()], content: '<think>Weather for Paris.</think>'),
      expect: callsExpect([('get_weather', weather)], repaired: false), why: '<think> in content then a call');
  add('openai_chat', '$fam.namespaced', profile: 'llamaCpp', family: fam, variant: 'namespaced',
      toolNames: const ['weather__get_weather', 'weather__get_time', 'mail__send_email'],
      sseText: chatStream('llamaCpp', [Raw('weather__get_weather', jsonEncode(weather))]),
      expect: callsExpect([('weather__get_weather', weather)], repaired: false), why: 'MCP-namespaced tool name');
  add('openai_chat', '$fam.namespace_dropped', profile: 'llamaCpp', family: fam, variant: 'namespace_dropped',
      toolNames: const ['weather__get_weather', 'weather__get_time', 'mail__send_email'],
      sseText: chatStream('llamaCpp', [weatherCall()]),
      expect: callsExpect([('weather__get_weather', weather)]),
      why: 'R11 9.6.6 step 4: the model dropped the server prefix; one unique candidate');

  // ---- Other OpenAI-compatible servers.
  for (final profile in ['ollama', 'vllm', 'lmStudio', 'openAi']) {
    final family = switch (profile) { 'ollama' => 'llama3_2_pythonic', 'openAi' => 'gpt', _ => 'qwen3_hermes' };
    add('openai_chat', 'clean', profile: profile, family: family, variant: 'clean',
        sseText: chatStream(profile, [weatherCall()]), expect: callsExpect([('get_weather', weather)], repaired: false),
        why: 'well-formed call in this server\'s stream shape');
    add('openai_chat', 'parallel', profile: profile, family: family, variant: 'parallel',
        sseText: chatStream(profile, [weatherCall(), timeCall()]),
        expect: callsExpect([('get_weather', weather), ('get_time', time)], repaired: false), why: 'two calls');
    add('openai_chat', 'clean_escapes', profile: profile, family: family, variant: 'clean_escapes',
        sseText: chatStream(profile, [Raw('send_email', jsonEncode(email))]),
        expect: callsExpect([('send_email', email)], repaired: false), why: 'escapes split across fragments');
    add('openai_chat', 'trailing_comma', profile: profile, family: family, variant: 'trailing_comma',
        sseText: chatStream(profile, [const Raw('get_weather', '{"city": "Paris", "unit": "celsius",}')]),
        expect: callsExpect([('get_weather', weather)], repaired: true), why: 'R11 d.3');
    add('openai_chat', 'truncated', profile: profile, family: family, variant: 'truncated',
        sseText: chatStream(profile, [const Raw('get_weather', '{"city": "Par')], finish: 'length'),
        expect: blocked, why: 'cut off at max tokens');
    add('openai_chat', 'wrong_case', profile: profile, family: family, variant: 'wrong_case',
        sseText: chatStream(profile, [weatherCall('GET_WEATHER')]), expect: callsExpect([('get_weather', weather)]),
        why: 'R11 9.6.6 step 4');
  }
  add('openai_chat', 'args_object', profile: 'ollama', family: 'llama3_2_pythonic', variant: 'args_object',
      sseText: chatStream('ollama', [Raw('create_event', '', object: event)]),
      expect: callsExpect([('create_event', event)]), why: 'non-compliant server sends the arguments object itself');
  add('openai_chat', 'python_dict', profile: 'ollama', family: 'llama3_2_pythonic', variant: 'python_dict',
      sseText: chatStream('ollama', [const Raw('create_event', "{'title': 'Standup', 'days': 3, 'remote': True, 'notes': None}")]),
      expect: callsExpect([('create_event', event)], repaired: true), why: 'pythonic family args passed through');
  add('openai_chat', 'reasoning_then_call', profile: 'vllm', family: 'qwen3_hermes', variant: 'reasoning_then_call',
      sseText: chatStream('vllm', [weatherCall()], reasoning: 'Weather in Paris, celsius.'),
      expect: callsExpect([('get_weather', weather)], repaired: false), why: 'vLLM `reasoning` field then a call');
  add('openai_chat', 'index_reuse', profile: 'proxy', family: 'gpt', variant: 'index_reuse',
      sseText: chatStream('proxy', [weatherCall(), timeCall()]),
      expect: callsExpect([('get_weather', weather), ('get_time', time)], repaired: false),
      why: 'compat proxy reuses index 0; a new id opens a new call');
  add('openai_chat', 'missing_ids', profile: 'proxy_no_id', family: 'gpt', variant: 'missing_ids',
      sseText: chatStream('proxy_no_id', [weatherCall(), timeCall()]),
      expect: callsExpect([('get_weather', weather), ('get_time', time)], repaired: false), why: 'ids synthesized');

  // ---- Anthropic Messages.
  add('anthropic', 'clean', family: 'claude', variant: 'clean', sseText: anthropicStream([weatherCall()]),
      expect: callsExpect([('get_weather', weather)], repaired: false), why: 'input_json_delta fragments');
  add('anthropic', 'parallel', family: 'claude', variant: 'parallel', sseText: anthropicStream([weatherCall(), timeCall()]),
      expect: callsExpect([('get_weather', weather), ('get_time', time)], repaired: false), why: 'two tool_use blocks');
  add('anthropic', 'thinking_then_call', family: 'claude', variant: 'thinking_then_call',
      sseText: anthropicStream([weatherCall()], thinking: true),
      expect: callsExpect([('get_weather', weather)], repaired: false), why: 'signed thinking block first');
  add('anthropic', 'clean_escapes', family: 'claude', variant: 'clean_escapes',
      sseText: anthropicStream([Raw('send_email', jsonEncode(email))]),
      expect: callsExpect([('send_email', email)], repaired: false), why: 'escapes split across fragments');
  add('anthropic', 'initial_input', family: 'claude', variant: 'initial_input',
      sseText: anthropicStream([weatherCall()], initialInput: true),
      expect: callsExpect([('get_weather', weather)], repaired: false), why: 'input given whole in content_block_start');
  add('anthropic', 'empty_input', family: 'claude', variant: 'empty_input',
      sseText: anthropicStream([const Raw('list_files', '')]),
      expect: callsExpect([('list_files', {})], repaired: false), why: 'parameterless tool');
  add('anthropic', 'truncated', family: 'claude', variant: 'truncated',
      sseText: anthropicStream([const Raw('get_weather', '{"city": "Par')], stop: 'max_tokens'),
      expect: blocked, why: 'max_tokens mid-input: never repaired, never run');
  add('anthropic', 'refusal', family: 'claude', variant: 'refusal',
      sseText: anthropicStream([weatherCall()], stop: 'refusal'),
      expect: blocked, why: 'a refused turn\'s tool calls must never run (R10 §7.6)');
  add('anthropic', 'malformed_input', family: 'claude', variant: 'malformed_input',
      sseText: anthropicStream([const Raw('get_weather', '{"city": "Paris",}')]),
      expect: blocked, why: 'eager input streaming is unvalidated; malformed input is reported back, not repaired');
  add('anthropic', 'wrong_case', family: 'claude', variant: 'wrong_case',
      sseText: anthropicStream([weatherCall('Get_Weather')]), expect: callsExpect([('get_weather', weather)]),
      why: 'R11 9.6.6 step 4: case normalisation');
  add('anthropic', 'unknown_name', family: 'claude', variant: 'unknown_name',
      sseText: anthropicStream([weatherCall('launch_rockets')]), expect: blocked, why: 'no such tool');
  add('anthropic', 'no_message_stop', family: 'claude', variant: 'no_message_stop',
      sseText: anthropicStream([weatherCall()], messageStop: false, messageDelta: false),
      expect: streamError, why: 'connection dropped before the stop reason');

  // ---- OpenAI Responses.
  add('responses', 'clean', family: 'gpt', variant: 'clean', sseText: responsesStream([weatherCall()]),
      expect: callsExpect([('get_weather', weather)], repaired: false), why: 'function_call item');
  add('responses', 'parallel', family: 'gpt', variant: 'parallel', sseText: responsesStream([weatherCall(), timeCall()]),
      expect: callsExpect([('get_weather', weather), ('get_time', time)], repaired: false), why: 'two items');
  add('responses', 'lost_delta', family: 'gpt', variant: 'lost_delta', sseText: responsesStream([weatherCall()], lostDelta: true),
      expect: callsExpect([('get_weather', weather)], repaired: false), why: '`.done` arguments are authoritative');
  add('responses', 'incomplete', family: 'gpt', variant: 'incomplete',
      sseText: responsesStream([const Raw('get_weather', '{"city": "Par')], status: 'incomplete', itemDone: false),
      expect: blocked, why: 'max_output_tokens mid-arguments');
  add('responses', 'trailing_comma', family: 'gpt', variant: 'trailing_comma',
      sseText: responsesStream([const Raw('get_weather', '{"city": "Paris", "unit": "celsius",}')]),
      expect: callsExpect([('get_weather', weather)], repaired: true), why: 'R11 d.3');
  add('responses', 'wrong_case', family: 'gpt', variant: 'wrong_case', sseText: responsesStream([weatherCall('Get_Weather')]),
      expect: callsExpect([('get_weather', weather)]), why: 'R11 9.6.6 step 4');
  add('responses', 'no_terminal', family: 'gpt', variant: 'no_terminal',
      sseText: responsesStream([weatherCall()], terminal: false), expect: streamError, why: 'no terminal event');

  // ---- On-device engine events (sherpa_engine over llama.cpp's parsers).
  for (final (id, raw, expect, why) in argVariants) {
    add('engine', id, family: 'qwen3_hermes', variant: id, events: engineEvents([raw]), expect: expect, why: why);
  }
  for (final (id, name, expect, why) in nameVariants) {
    add('engine', id, family: 'qwen3_hermes', variant: id, events: engineEvents([weatherCall(name)]), expect: expect, why: why);
  }
  add('engine', 'parallel', family: 'qwen3_hermes', variant: 'parallel', events: engineEvents([weatherCall(), timeCall()]),
      expect: callsExpect([('get_weather', weather), ('get_time', time)], repaired: false), why: 'two calls');
  add('engine', 'truncated', family: 'qwen3_hermes', variant: 'truncated',
      events: engineEvents([const Raw('get_weather', '{"city": "Par')], finish: 'length'),
      expect: blocked, why: 'FINISH(length) mid-call: the agent loop never runs it');
  add('engine', 'engine_error', family: 'qwen3_hermes', variant: 'engine_error',
      events: engineEvents([weatherCall()], error: true), expect: streamError, why: 'ERROR then FINISH(error)');
  for (final family in familyMarkers.keys) {
    add('engine', '$family.markers_in_text', family: family, variant: 'markers_in_text',
        events: engineEvents(const [], finish: 'stop', text: 'Let me check. ${familyMarkers[family]}'),
        expect: textExpect(familyMarkers[family]!.substring(0, 6)),
        why: 'the lazy grammar never triggered: text is never executed as a call');
  }

  final out = File(p.join(p.dirname(p.dirname(Platform.script.toFilePath())), 'data', 'l1', 'corpus.json'));
  out.parent.createSync(recursive: true);
  out.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert({
    'schema': 'sherpa.eval.l1-corpus/1',
    'note': 'Generated by tool/gen_l1_corpus.dart; expectations follow R11 d.3 and 9.6.6, not parser output.',
    'cases': cases,
  })}\n');
  print('wrote ${cases.length} cases to ${out.path}');
}
