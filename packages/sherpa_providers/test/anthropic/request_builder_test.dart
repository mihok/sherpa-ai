import 'dart:convert';
import 'dart:typed_data';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/src/anthropic/anthropic.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const builder = AnthropicRequestBuilder(providerId: providerId);

AnthropicWireRequest build(
  List<Message> messages, {
  String model = 'claude-opus-5-5',
  String? system = 'You are Sherpa.',
  List<ToolDefinition> tools = const [],
  GenerationParams params = const GenerationParams(),
  CacheHints cache = const CacheHints(),
  AnthropicRequestBuilder b = builder,
}) =>
    b.build(ModelRequest(
      modelId: model,
      systemPrompt: system,
      messages: messages,
      tools: tools,
      params: params,
      cache: cache,
    ));

List<Object?> messagesOf(AnthropicWireRequest r) => stripCache(r.body['messages'])! as List<Object?>;

/// The R10 F4 conversation: user → assistant(thinking, text, 2 tool_use) →
/// tool results that finished in reverse order.
final List<Message> f4 = [
  user('u1', 'Weather in Paris and the time in Tokyo?'),
  assistant('a1', [
    thinking(
      'Two independent lookups: Paris weather and Tokyo time. Both can run in parallel.',
      'EqQBCgIYAhIM1gbcDa9GJwZA2b3hGgxBdjrkzLoky3dl1pkiMOYds',
    ),
    const TextPart('Checking both now.'),
    const ToolCallPart(ToolCall(id: 'toolu_01AbCdEf', name: 'get_weather', arguments: {'city': 'Paris'})),
    const ToolCallPart(ToolCall(id: 'toolu_01GhIjKl', name: 'get_time', arguments: {'timezone': 'Asia/Tokyo'})),
  ]),
  toolMessage('t1', [
    result('toolu_01GhIjKl', '21:04 JST', tool: 'get_time'),
    result('toolu_01AbCdEf', '18°C, cloudy', tool: 'get_weather'),
  ]),
];

final List<ToolDefinition> f4Tools = [
  tool('get_weather', schema: const {
    'type': 'object',
    'properties': {
      'city': {'type': 'string'},
    },
    'required': ['city'],
  }),
  tool('get_time', schema: const {
    'type': 'object',
    'properties': {
      'timezone': {'type': 'string'},
    },
    'required': ['timezone'],
  }),
];

void main() {
  group('replay', () {
    test('F4 follow-up: assistant replayed exactly, results grouped in call order (R10 §9)', () {
      final r = build(f4, tools: f4Tools);
      expect(messagesOf(r), [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'Weather in Paris and the time in Tokyo?'},
          ],
        },
        {
          'role': 'assistant',
          'content': [
            {
              'type': 'thinking',
              'thinking': 'Two independent lookups: Paris weather and Tokyo time. Both can run in parallel.',
              'signature': 'EqQBCgIYAhIM1gbcDa9GJwZA2b3hGgxBdjrkzLoky3dl1pkiMOYds',
            },
            {'type': 'text', 'text': 'Checking both now.'},
            {
              'type': 'tool_use',
              'id': 'toolu_01AbCdEf',
              'name': 'get_weather',
              'input': {'city': 'Paris'},
            },
            {
              'type': 'tool_use',
              'id': 'toolu_01GhIjKl',
              'name': 'get_time',
              'input': {'timezone': 'Asia/Tokyo'},
            },
          ],
        },
        {
          'role': 'user',
          'content': [
            {'type': 'tool_result', 'tool_use_id': 'toolu_01AbCdEf', 'content': '18°C, cloudy'},
            {'type': 'tool_result', 'tool_use_id': 'toolu_01GhIjKl', 'content': '21:04 JST'},
          ],
        },
      ]);
      expect(r.notices, isEmpty);
    });

    test('interleaved and redacted thinking blocks are replayed verbatim and in order', () {
      final r = build([
        user('u1', 'go'),
        assistant('a1', [
          thinking('plan', 'SIG_A'),
          const TextPart('Let me look.'),
          const ReasoningPart(text: '', redactedData: 'REDACTED==', providerId: providerId),
          thinking('', 'SIG_EMPTY'), // display omitted: empty text, still replayed
          const ToolCallPart(ToolCall(id: 'c1', name: 'read', arguments: {'p': 1})),
          thinking('then list', 'SIG_C'),
          const ToolCallPart(ToolCall(id: 'c2', name: 'list', arguments: {})),
        ]),
        toolMessage('t1', [result('c1', 'r1'), result('c2', 'r2')]),
      ]);
      final content = (messagesOf(r)[1]! as Map)['content'] as List<Object?>;
      expect(content.map((b) => (b! as Map)['type']), [
        'thinking',
        'text',
        'redacted_thinking',
        'thinking',
        'tool_use',
        'thinking',
        'tool_use',
      ]);
      expect(content[0], {'type': 'thinking', 'thinking': 'plan', 'signature': 'SIG_A'});
      expect(content[2], {'type': 'redacted_thinking', 'data': 'REDACTED=='});
      expect(content[3], {'type': 'thinking', 'thinking': '', 'signature': 'SIG_EMPTY'});
      expect(content[6], {'type': 'tool_use', 'id': 'c2', 'name': 'list', 'input': <String, Object?>{}});
    });

    test('foreign-provider, legacy and unsigned reasoning is dropped; own reasoning kept', () {
      final r = build([
        user('u1', 'hi'),
        assistant('a1', [
          thinking('from openai', 'SIG_X', provider: 'openai-main'),
          thinking('legacy, no provider', 'SIG_Y', provider: null),
          const ReasoningPart(text: 'cancelled mid-thinking', providerId: providerId),
          thinking('mine', 'SIG_MINE'),
          const TextPart('answer'),
        ]),
        user('u2', 'more'),
      ]);
      expect((messagesOf(r)[1]! as Map)['content'], [
        {'type': 'thinking', 'thinking': 'mine', 'signature': 'SIG_MINE'},
        {'type': 'text', 'text': 'answer'},
      ]);
    });

    test('consecutive same-role turns merge forward; system notices render as user text', () {
      final r = build([
        user('u1', 'one'),
        user('u2', 'two'),
        Message(id: 's1', role: Role.system, content: const [TextPart('note')], createdAt: t0),
        assistant('a1', [const TextPart('A')]),
        assistant('a2', [const TextPart('B')]),
        user('u3', 'three'),
      ]);
      expect(messagesOf(r), [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'one'},
            {'type': 'text', 'text': 'two'},
            {'type': 'text', 'text': 'note'},
          ],
        },
        {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'A'},
            {'type': 'text', 'text': 'B'},
          ],
        },
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'three'},
          ],
        },
      ]);
    });

    test('unanswered calls get error results; orphan results are dropped with notices', () {
      final r = build([
        user('u1', 'go'),
        assistant('a1', [
          const ToolCallPart(ToolCall(id: 'c1', name: 'x', arguments: {})),
          const ToolCallPart(ToolCall(id: 'c2', name: 'x', arguments: {})),
        ]),
        toolMessage('t1', [result('c2', 'ok'), result('zzz', 'stray')]),
        user('u2', 'next'),
      ]);
      expect(messagesOf(r)[2], {
        'role': 'user',
        'content': [
          {'type': 'tool_result', 'tool_use_id': 'c2', 'content': 'ok'},
          {
            'type': 'tool_result',
            'tool_use_id': 'c1',
            'content': 'No result was recorded for this tool call.',
            'is_error': true,
          },
          {'type': 'text', 'text': 'next'},
        ],
      });
      expect(r.notices.map((n) => n.code), ['anthropic.orphan_tool_result', 'anthropic.missing_tool_result']);
    });

    test('a refused assistant turn is never replayed', () {
      final r = build([
        user('u1', 'bad'),
        assistant('a1', [const TextPart('Running the scan')], finishReason: 'refusal'),
        user('u2', 'something else'),
      ]);
      expect(messagesOf(r), [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'bad'},
            {'type': 'text', 'text': 'something else'},
          ],
        },
      ]);
    });

    test('tool results: is_error, multi-part content, structured fallback, foreign ids sanitized', () {
      final png = Uint8List.fromList([137, 80, 78, 71]);
      final r = build([
        user('u1', 'go'),
        assistant('a1', [
          const ToolCallPart(ToolCall(id: 'call:1/a', name: 'shot', arguments: {})),
          const ToolCallPart(ToolCall(id: 'c2', name: 'shot', arguments: {})),
          const ToolCallPart(ToolCall(id: 'c3', name: 'shot', arguments: {})),
        ]),
        toolMessage('t1', [
          ToolResultPart(
            callId: 'call:1/a',
            toolName: 'shot',
            content: [const TextPart('see image'), ImagePart(mimeType: 'image/png', data: png)],
          ),
          result('c2', 'boom', isError: true),
          const ToolResultPart(callId: 'c3', toolName: 'shot', content: [], structured: {'n': 3}),
        ]),
      ]);
      final asst = (messagesOf(r)[1]! as Map)['content'] as List<Object?>;
      final sanitized = (asst[0]! as Map)['id'] as String;
      expect(sanitized, matches(RegExp(r'^[a-zA-Z0-9_-]+$')));
      expect(messagesOf(r)[2], {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': sanitized,
            'content': [
              {'type': 'text', 'text': 'see image'},
              {
                'type': 'image',
                'source': {'type': 'base64', 'media_type': 'image/png', 'data': base64Encode(png)},
              },
            ],
          },
          {'type': 'tool_result', 'tool_use_id': 'c2', 'content': 'boom', 'is_error': true},
          {'type': 'tool_result', 'tool_use_id': 'c3', 'content': '{"n":3}'},
        ],
      });
    });

    test('user media: base64 and URL images, PDFs; file:// and audio become notes', () {
      final r = build([
        Message(id: 'u1', role: Role.user, createdAt: t0, content: [
          ImagePart(mimeType: 'image/jpg', data: Uint8List.fromList([1, 2, 3])),
          ImagePart(mimeType: 'image/webp', uri: Uri.parse('https://example.com/a.webp')),
          ImagePart(mimeType: 'image/png', uri: Uri.parse('file:///data/a.png')),
          AudioPart(mimeType: 'audio/wav', data: Uint8List.fromList([0])),
          EmbeddedResourcePart(uri: 'file:///doc.pdf', mimeType: 'application/pdf', blob: Uint8List.fromList([37])),
          const TextPart(''),
          const TextPart('Summarize'),
        ]),
      ]);
      expect((messagesOf(r)[0]! as Map)['content'], [
        {
          'type': 'image',
          'source': {'type': 'base64', 'media_type': 'image/jpeg', 'data': 'AQID'},
        },
        {
          'type': 'image',
          'source': {'type': 'url', 'url': 'https://example.com/a.webp'},
        },
        {'type': 'text', 'text': '[image omitted: image/png file:///data/a.png]'},
        {'type': 'text', 'text': '[attachment omitted: audio/wav]'},
        {
          'type': 'document',
          'source': {'type': 'base64', 'media_type': 'application/pdf', 'data': 'JQ=='},
        },
        {'type': 'text', 'text': 'Summarize'},
      ]);
      expect(r.notices.map((n) => n.code), ['anthropic.content_omitted', 'anthropic.content_omitted']);
    });
  });

  group('append-only guarantee', () {
    test('a growing conversation renders byte-identical prefixes', () {
      final tools = f4Tools;
      final step1 = [f4[0]];
      final step2 = f4;
      final step3 = [
        ...f4,
        assistant('a2', [thinking('Both results in.', 'SIG_2'), const TextPart('Paris is 18°C; Tokyo 21:04.')]),
        user('u2', 'Thanks! And Berlin?'),
      ];
      final r1 = build(step1, tools: tools);
      final r2 = build(step2, tools: tools);
      final r3 = build(step3, tools: tools);
      // System and tools are byte-identical, cache markers included.
      expect(bytesOf(r2.body['system']), bytesOf(r1.body['system']));
      expect(bytesOf(r3.body['tools']), bytesOf(r1.body['tools']));
      // Messages: every earlier turn is byte-identical once cache_control
      // (which the API lets move) is set aside.
      for (final (prev, next) in [(r1, r2), (r2, r3)]) {
        final a = messagesOf(prev);
        final b = messagesOf(next);
        for (var i = 0; i < a.length; i++) {
          expect(bytesOf(b[i]), bytesOf(a[i]), reason: 'turn $i changed');
        }
      }
      final guard = AnthropicPrefixGuard();
      expect(guard.check('s', r1.body), isNull);
      expect(guard.check('s', r2.body), isNull);
      expect(guard.check('s', r3.body), isNull);
    });

    test('the prefix guard flags an edit before replayed thinking', () {
      final guard = AnthropicPrefixGuard();
      final step3 = [
        ...f4,
        assistant('a2', [thinking('Both results in.', 'SIG_2'), const TextPart('done')]),
        user('u2', 'next'),
      ];
      expect(guard.check('s', build(step3, tools: f4Tools).body), isNull);
      // An old tool result gets truncated by an overlay mid-loop.
      final edited = [
        ...step3.take(2),
        toolMessage('t1', [result('toolu_01GhIjKl', '21:04'), result('toolu_01AbCdEf', '18°C, cloudy')]),
        ...step3.skip(3),
      ];
      final notice = guard.check('s', build(edited, tools: f4Tools).body);
      expect(notice?.code, 'anthropic.prefix_changed');
      expect(notice?.data['turn'], 2);
      // A changed system prompt is flagged too, unless no thinking is replayed.
      expect(guard.check('s', build(step3, tools: f4Tools, system: 'Changed.').body)?.data['turn'], -1);
      expect(guard.check('t', build([user('u', 'x')]).body), isNull);
      expect(guard.check('t', build([user('u', 'x')], system: 'Other').body), isNull);
    });
  });

  group('cache_control', () {
    test('breakpoints on tools end, system, stable prefix and tail; never on thinking; max 4', () {
      final conversation = [
        ...f4,
        assistant('a2', [const TextPart('Paris is 18°C.'), thinking('trailing', 'S')]),
        user('u2', 'And Berlin?'),
      ];
      final r = build(conversation, tools: f4Tools, cache: const CacheHints(stablePrefixMessages: 4));
      expect(cachePaths(r.body), [
        r'$.system[0]',
        r'$.messages[3].content[0]', // a2's last cacheable block (thinking is skipped)
        r'$.messages[4].content[0]', // tail
        r'$.tools[1]',
      ]);
      expect(cachePaths(r.body).length, lessThanOrEqualTo(AnthropicRequestBuilder.maxCacheBreakpoints));
      expect((r.body['tools']! as List).last, containsPair('cache_control', {'type': 'ephemeral'}));
    });

    test('no system, no tools: only the tail is marked; stable == tail is marked once', () {
      final r = build([user('u1', 'hi')], system: null, cache: const CacheHints(stablePrefixMessages: 1));
      expect(cachePaths(r.body), [r'$.messages[0].content[0]']);
      expect(r.body.containsKey('system'), isFalse);
      expect(r.body.containsKey('tools'), isFalse);
      expect(r.body.containsKey('tool_choice'), isFalse);
    });
  });

  group('model family rules', () {
    test('no sampling params and no budget_tokens for 4.7+ / 5.x, for any reasoning setting', () {
      const ids = [
        'claude-opus-5-5',
        'claude-sonnet-5-5',
        'claude-haiku-5-5',
        'claude-fable-5-1',
        'claude-fable-5',
        'claude-mythos-5-1',
        'claude-opus-5',
        'claude-sonnet-5',
        'claude-opus-4-8',
        'claude-opus-4-7',
        'claude-opus-9', // unknown future id
        'some-proxy-model',
      ];
      for (final id in ids) {
        for (final effort in [null, ...ReasoningEffort.values]) {
          final r = build([user('u', 'x')],
              model: id,
              tools: f4Tools,
              params: GenerationParams(temperature: 0.3, topP: 0.9, topK: 5, reasoning: effort));
          final body = jsonEncode(r.body);
          for (final banned in ['temperature', 'top_p', 'top_k', 'budget_tokens']) {
            expect(body, isNot(contains('"$banned"')), reason: '$id / $effort sent $banned');
          }
          expect(r.notices.map((n) => n.code), contains('anthropic.sampling_dropped'));
        }
      }
    });

    test('thinking and effort per family (R10 §7.3)', () {
      JsonMap? thinkingOf(String id, ReasoningEffort? e) =>
          build([user('u', 'x')], model: id, params: GenerationParams(reasoning: e)).body['thinking'] as JsonMap?;
      Object? effortOf(String id, ReasoningEffort? e) =>
          (build([user('u', 'x')], model: id, params: GenerationParams(reasoning: e)).body['output_config']
                  as Map?)?['effort'];
      const summarized = {'type': 'adaptive', 'display': 'summarized'};

      // Opus 5.5: always on; effort is the only knob; "off" → low + notice.
      expect(thinkingOf('claude-opus-5-5', null), summarized);
      expect(effortOf('claude-opus-5-5', null), isNull);
      expect(effortOf('claude-opus-5-5', ReasoningEffort.high), 'high');
      final off = build([user('u', 'x')], params: const GenerationParams(reasoning: ReasoningEffort.off));
      expect(off.body['thinking'], summarized);
      expect((off.body['output_config']! as Map)['effort'], 'low');
      expect(off.notices.single.code, 'anthropic.thinking_always_on');
      // Sonnet 5.5: off is between_tools with no other field.
      expect(thinkingOf('claude-sonnet-5-5', ReasoningEffort.off), {'type': 'between_tools'});
      expect(effortOf('claude-sonnet-5-5', ReasoningEffort.off), isNull);
      // Haiku 5.5 / Opus 5: disabled allowed (at default effort).
      expect(thinkingOf('claude-haiku-5-5', ReasoningEffort.off), {'type': 'disabled'});
      expect(thinkingOf('claude-opus-5', ReasoningEffort.off), {'type': 'disabled'});
      // Opus 4.8: omitting means off; adaptive must be explicit.
      expect(thinkingOf('claude-opus-4-8', ReasoningEffort.off), isNull);
      expect(thinkingOf('claude-opus-4-8', null), summarized);
      // Opus 4.6: adaptive; display left at its (summarized) default.
      expect(thinkingOf('claude-opus-4-6', ReasoningEffort.medium), {'type': 'adaptive'});
      expect(effortOf('claude-opus-4-6', ReasoningEffort.medium), 'medium');
      // Haiku 4.5: manual budget below max_tokens, no effort.
      final haiku = build([user('u', 'x')],
          model: 'claude-haiku-4-5', params: const GenerationParams(reasoning: ReasoningEffort.high, maxOutputTokens: 4000));
      expect(haiku.body['thinking'], {'type': 'enabled', 'budget_tokens': 3999});
      expect(haiku.body.containsKey('output_config'), isFalse);
      expect(thinkingOf('claude-haiku-4-5', null), isNull);
      // Dated snapshot ids resolve to their family.
      expect(thinkingOf('claude-opus-4-5-20251101', ReasoningEffort.low), {'type': 'enabled', 'budget_tokens': 2048});
      expect(effortOf('claude-opus-4-5-20251101', ReasoningEffort.low), 'low');
    });

    test('older models keep sampling when thinking is off; temperature and top_p never together', () {
      final r = build([user('u', 'x')],
          model: 'claude-sonnet-4-6', params: const GenerationParams(temperature: 0.2, topP: 0.9, reasoning: ReasoningEffort.off));
      expect(r.body['temperature'], 0.2);
      expect(r.body.containsKey('top_p'), isFalse);
      expect(r.notices.single.code, 'anthropic.sampling_dropped');
      // With thinking on, sampling is incompatible and dropped.
      final on = build([user('u', 'x')], model: 'claude-sonnet-4-6', params: const GenerationParams(temperature: 0.2));
      expect(on.body.containsKey('temperature'), isFalse);
    });
  });

  group('tool_choice', () {
    test('forced choice is downgraded to auto with a notice on models that reject it', () {
      for (final model in ['claude-opus-5-5', 'claude-sonnet-5-5', 'claude-fable-5-1']) {
        final r = build([user('u', 'x')],
            model: model, tools: f4Tools, params: const GenerationParams(toolChoice: ToolChoice.required));
        expect(r.body['tool_choice'], {'type': 'auto'}, reason: model);
        expect(r.notices.single.code, 'anthropic.tool_choice_downgraded');
        expect(r.notices.single.data['requested'], 'any');
      }
    });

    test('forced choice is kept where allowed (thinking off); downgraded while thinking', () {
      final any = build([user('u', 'x')],
          model: 'claude-opus-5',
          tools: f4Tools,
          params: const GenerationParams(toolChoice: ToolChoice.required, reasoning: ReasoningEffort.off, parallelToolCalls: false));
      expect(any.body['tool_choice'], {'type': 'any', 'disable_parallel_tool_use': true});
      final specific = build([user('u', 'x')],
          model: 'claude-haiku-4-5',
          tools: [tool('fs.read')],
          params: const GenerationParams(toolChoice: ToolChoiceSpecific('fs.read')));
      expect(specific.body['tool_choice'], {'type': 'tool', 'name': 'fs_read'});
      final thinkingOn = build([user('u', 'x')],
          model: 'claude-opus-5', tools: f4Tools, params: const GenerationParams(toolChoice: ToolChoice.required));
      expect(thinkingOn.body['tool_choice'], {'type': 'auto'});
      expect(thinkingOn.notices.single.data['reason'], contains('thinking'));
    });

    test('none, auto, parallel toggle, unknown specific tool', () {
      expect(build([user('u', 'x')], tools: f4Tools).body['tool_choice'], {'type': 'auto'});
      expect(
        build([user('u', 'x')], tools: f4Tools, params: const GenerationParams(toolChoice: ToolChoice.none))
            .body['tool_choice'],
        {'type': 'none'},
      );
      expect(
        build([user('u', 'x')], tools: f4Tools, params: const GenerationParams(parallelToolCalls: false))
            .body['tool_choice'],
        {'type': 'auto', 'disable_parallel_tool_use': true},
      );
      final unknown = build([user('u', 'x')],
          model: 'claude-opus-5',
          tools: f4Tools,
          params: const GenerationParams(toolChoice: ToolChoiceSpecific('nope'), reasoning: ReasoningEffort.off));
      expect(unknown.body['tool_choice'], {'type': 'auto'});
    });
  });

  group('tools and names', () {
    test('names are sanitized reversibly, collisions disambiguated, schemas made object-typed', () {
      final defs = [
        tool('github_create_issue'),
        tool('github.create_issue'),
        tool('fs/read', schema: const {'properties': {}}),
        tool('${'x' * 70}.y'),
        tool('hidden'),
      ];
      final hidden = ToolDefinition(name: 'app_only', description: '', inputSchema: const {}, modelVisible: false);
      final r = build([user('u', 'x')], tools: [...defs, hidden]);
      final wire = [for (final t in r.body['tools']! as List) (t as Map)['name'] as String];
      expect(wire.length, 5, reason: 'model-invisible tools are not offered');
      expect(wire[0], 'github_create_issue');
      expect(wire[1], startsWith('github_create_issue_'));
      expect(wire[2], 'fs_read');
      expect(wire[3].length, lessThanOrEqualTo(AnthropicToolNames.maxLength));
      for (final w in wire) {
        expect(w, matches(RegExp(r'^[a-zA-Z0-9_-]{1,64}$')));
      }
      expect(wire.toSet().length, wire.length);
      for (final (i, d) in defs.indexed) {
        expect(r.toolNames.fromWire(wire[i]), d.name);
      }
      expect(((r.body['tools']! as List)[2] as Map)['input_schema'], {'type': 'object', 'properties': <String, Object?>{}});
      // Deterministic: the same tool list always yields the same names.
      expect(build([user('u', 'x')], tools: [...defs, hidden]).encode(), r.encode());
    });

    test('replayed calls use the wire name; eager_input_streaming only when enabled', () {
      final r = build(
        [
          user('u', 'x'),
          assistant('a', [const ToolCallPart(ToolCall(id: 'c', name: 'fs/read', arguments: {'p': 'a'}))]),
          toolMessage('t', [result('c', 'ok')]),
        ],
        tools: [tool('fs/read')],
        b: const AnthropicRequestBuilder(providerId: providerId, eagerInputStreaming: true),
      );
      expect(((messagesOf(r)[1]! as Map)['content'] as List).single, containsPair('name', 'fs_read'));
      expect((r.body['tools']! as List).single, containsPair('eager_input_streaming', true));
      expect(jsonEncode(build([user('u', 'x')], tools: [tool('a')]).body), isNot(contains('eager_input_streaming')));
    });
  });

  group('generation settings', () {
    test('max_tokens defaults to min(64000, model cap) and is clamped to the cap', () {
      expect(build([user('u', 'x')]).body['max_tokens'], 64000);
      expect(build([user('u', 'x')], model: 'claude-opus-4-1').body['max_tokens'], 32000);
      final clamped = build([user('u', 'x')], params: const GenerationParams(maxOutputTokens: 500000));
      expect(clamped.body['max_tokens'], 128000);
      expect(clamped.notices.single.code, 'anthropic.max_tokens_clamped');
    });

    test('stop sequences, structured output, stream flag, extra deep-merged last', () {
      final r = build([user('u', 'x')],
          params: const GenerationParams(
            stop: ['\nObservation:'],
            reasoning: ReasoningEffort.medium,
            jsonSchema: {'type': 'object'},
            extra: {
              'output_config': {'effort': 'max'},
              'metadata': {'user_id': 'h'},
            },
          ));
      expect(r.body['stream'], isTrue);
      expect(r.body['stop_sequences'], ['\nObservation:']);
      expect(r.body['output_config'], {
        'effort': 'max',
        'format': {'type': 'json_schema', 'schema': {'type': 'object'}},
      });
      expect(r.body['metadata'], {'user_id': 'h'});
      expect(r.countTokensBody.keys, ['model', 'system', 'messages', 'thinking']);
      expect(r.body.keys.take(3), ['model', 'max_tokens', 'stream']);
    });
  });
}
