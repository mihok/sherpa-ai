import 'dart:convert';
import 'dart:typed_data';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';
import 'package:test/test.dart';

import '../support/helpers.dart';

void main() {
  final png = Uint8List.fromList([137, 80, 78, 71]);

  Message assistant(List<ContentPart> content, {String id = 'a1'}) =>
      Message(id: id, role: Role.assistant, content: content, createdAt: t0);

  Message toolMsg(List<ToolResultPart> results) =>
      Message(id: 't1', role: Role.tool, content: results, createdAt: t0);

  const call1 = ToolCall(id: 'call_1', name: 'files.read', arguments: {'path': 'a.txt'}, rawArguments: '{"path": "a.txt"}');
  const call2 = ToolCall(id: 'call_2', name: 'get_time', arguments: {'timezone': 'UTC'}, rawArguments: "{'timezone': 'UTC'}",
      repaired: true);

  final transcript = [
    Message(id: 's', role: Role.system, content: [const TextPart('Mid-conversation note')], createdAt: t0),
    Message(
      id: 'u1',
      role: Role.user,
      content: [const TextPart('What is in this photo?'), ImagePart(mimeType: 'image/png', data: png)],
      createdAt: t0,
    ),
    assistant([
      const ReasoningPart(text: 'I should read the file.', providerId: 'me'),
      const ReasoningPart(text: 'Foreign thoughts.', providerId: 'other'),
      const TextPart('Let me check.'),
      const ToolCallPart(call1),
      const ToolCallPart(call2),
      const UiResourcePart(resourceUri: 'ui://x', serverId: 's'),
    ]),
    toolMsg([
      const ToolResultPart(callId: 'call_1', toolName: 'files.read', content: [TextPart('hello')]),
      ToolResultPart(
        callId: 'call_2',
        toolName: 'get_time',
        content: [const TextPart('12:00'), ImagePart(mimeType: 'image/png', data: png)],
        isError: true,
      ),
    ]),
  ];

  MappedMessages map({ReasoningReplay replay = ReasoningReplay.none}) => OpenAiChatMessageMapper(
        providerId: 'me',
        names: ToolNameMapper(['files.read', 'get_time']),
        reasoningReplay: replay,
      ).map(systemPrompt: 'You are Sherpa.', messages: transcript);

  test('roles, images, tool calls and one tool message per result', () {
    final m = map().messages;
    expect(m.map((e) => e['role']), ['system', 'system', 'user', 'assistant', 'tool', 'tool', 'user']);
    expect(m[0]['content'], 'You are Sherpa.');
    final user = m[2]['content']! as List;
    expect((user[1] as Map)['image_url'], {'url': 'data:image/png;base64,${base64Encode(png)}'});
    final a = m[3];
    expect(a['content'], 'Let me check.');
    final calls = (a['tool_calls']! as List).cast<Map<String, Object?>>();
    expect(calls.map((c) => c['id']), ['call_1', 'call_2']);
    expect(calls.map((c) => (c['function']! as Map)['name']), ['files_read', 'get_time']);
    // Exact raw text when it parsed; canonical JSON when it was repaired.
    expect((calls[0]['function']! as Map)['arguments'], '{"path": "a.txt"}');
    expect((calls[1]['function']! as Map)['arguments'], '{"timezone":"UTC"}');
    expect(a.containsKey('reasoning_content'), isFalse);
    expect(m[4], {'role': 'tool', 'tool_call_id': 'call_1', 'content': 'hello'});
    expect(m[5]['content'], '[tool error] 12:00');
    final images = m[6]['content']! as List;
    expect((images.first as Map)['text'], contains('untrusted data'));
    expect((images[1] as Map)['type'], 'image_url');
  });

  test('reasoning replay uses the profile field and only own reasoning', () {
    final rc = map(replay: ReasoningReplay.reasoningContent).messages[3];
    expect(rc['reasoning_content'], 'I should read the file.');
    final r = map(replay: ReasoningReplay.reasoning).messages[3];
    expect(r['reasoning'], 'I should read the file.');
    expect(r.containsKey('reasoning_content'), isFalse);
  });

  test('OpenRouter reasoning_details are replayed verbatim from the signature', () {
    final details = [
      {'type': 'reasoning.text', 'text': 'hmm', 'signature': 'sig', 'format': 'anthropic-claude-v1', 'index': 0},
    ];
    final mapper = OpenAiChatMessageMapper(
      providerId: 'me',
      names: ToolNameMapper.empty(),
      reasoningReplay: ReasoningReplay.reasoningDetails,
    );
    final out = mapper.map(messages: [
      assistant([ReasoningPart(text: 'hmm', signature: jsonEncode(details), providerId: 'me'), const TextPart('ok')]),
    ]).messages;
    expect(out.single['reasoning_details'], details);
  });

  test('assistant with only tool calls has null content; empty system prompt is omitted', () {
    final out = OpenAiChatMessageMapper(providerId: 'me', names: ToolNameMapper.empty())
        .map(systemPrompt: '  ', messages: [assistant([const ToolCallPart(call1)])]).messages;
    expect(out.single['content'], isNull);
    expect(out.single['role'], 'assistant');
  });

  test('local image files and unsupported audio are dropped with notices', () {
    final mapped = OpenAiChatMessageMapper(providerId: 'me', names: ToolNameMapper.empty()).map(messages: [
      Message(
        id: 'u',
        role: Role.user,
        content: [
          const TextPart('see'),
          ImagePart(mimeType: 'image/jpeg', uri: Uri.parse('file:///tmp/a.jpg')),
          ImagePart(mimeType: 'image/jpeg', uri: Uri.parse('https://example.com/a.jpg')),
          AudioPart(mimeType: 'audio/ogg', data: png),
        ],
        createdAt: t0,
      ),
    ]);
    final parts = mapped.messages.single['content']! as List;
    expect(parts, hasLength(2));
    expect(((parts[1] as Map)['image_url'] as Map)['url'], 'https://example.com/a.jpg');
    expect(mapped.notices.map((n) => n.code), ['content_dropped', 'content_dropped']);
  });

  test('resources render as text', () {
    final r = toolResultText(const ToolResultPart(
      callId: 'c',
      toolName: 't',
      content: [
        EmbeddedResourcePart(uri: 'file:///a', text: 'body'),
        ResourceLinkPart(uri: 'https://x/y', title: 'Y', description: 'a doc'),
      ],
    ));
    expect(r, '[resource file:///a]\nbody\n[resource link "Y": https://x/y] a doc');
    expect(toolResultText(const ToolResultPart(callId: 'c', toolName: 't', content: [], structured: {'a': 1})), '{"a":1}');
  });
}
