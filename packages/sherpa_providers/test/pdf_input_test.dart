// PDF input across the remote APIs: request-builder goldens per API
// (test/fixtures/requests/*.json; `UPDATE_GOLDENS=1 dart test test/pdf_input_test.dart`
// rewrites them) plus the per-server and per-model gating.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';
import 'package:test/test.dart';

import 'support/helpers.dart';

/// The smallest thing that starts like a PDF.
final Uint8List _pdf = Uint8List.fromList(utf8.encode('%PDF-1.4\n%%EOF\n'));

const _fetchDoc = ToolDefinition(
  name: 'fetch_doc',
  description: 'Fetch a document by id.',
  inputSchema: {
    'type': 'object',
    'properties': {
      'id': {'type': 'string'},
    },
    'required': ['id'],
  },
);

/// A user PDF (as the app sends it after inlining) and a tool that returns one.
ModelRequest _request(String model) => ModelRequest(
      modelId: model,
      systemPrompt: 'You are Sherpa.',
      tools: const [_fetchDoc],
      messages: [
        Message(id: 'u1', role: Role.user, createdAt: t0, content: [
          const TextPart('Summarize the attached report, then fetch Q3.'),
          EmbeddedResourcePart(
              uri: 'file:///chats/s1/att1-report.pdf', mimeType: 'application/pdf', blob: _pdf, size: 15, pages: 1),
        ]),
        Message(id: 'a1', role: Role.assistant, createdAt: t0, content: const [
          ToolCallPart(ToolCall(id: 'call_1', name: 'fetch_doc', arguments: {'id': 'q3'}, rawArguments: '{"id":"q3"}')),
        ]),
        Message(id: 't1', role: Role.tool, createdAt: t0, content: [
          ToolResultPart(callId: 'call_1', toolName: 'fetch_doc', content: [
            const TextPart('Fetched q3.'),
            EmbeddedResourcePart(uri: 'https://docs.example.com/reports/q3', mimeType: 'application/pdf', blob: _pdf),
          ]),
        ]),
      ],
    );

ChatRequestBody _chat(ServerProfile profile, {String model = 'gpt-5'}) {
  final r = _request(model);
  return buildChatRequest(
    request: r,
    quirks: ServerQuirks.of(profile),
    names: ToolNameMapper(visibleTools(r).map((t) => t.name)),
    providerId: 'p',
  );
}

ResponsesRequestBody _responses({String model = 'gpt-5'}) {
  final r = _request(model);
  return buildResponsesRequest(request: r, names: ToolNameMapper(visibleTools(r).map((t) => t.name)), providerId: 'p');
}

void _golden(String name, Object? actual) {
  final file = File('test/fixtures/requests/$name.json');
  final text = '${const JsonEncoder.withIndent('  ').convert(actual)}\n';
  if (Platform.environment['UPDATE_GOLDENS'] == '1') {
    file
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
  }
  expect(file.existsSync(), isTrue, reason: 'missing golden ${file.path} (run with UPDATE_GOLDENS=1)');
  expect(text, file.readAsStringSync(), reason: 'golden ${file.path}');
}

List<Map<String, Object?>> _messages(ChatRequestBody b) => (b.body['messages']! as List).cast<Map<String, Object?>>();

void main() {
  group('goldens', () {
    test('OpenAI Chat Completions: file parts with filename and a data URL, tool PDFs after the tool message', () {
      final b = _chat(ServerProfile.openAi);
      expect(b.notices, isEmpty);
      final user = _messages(b)[1]['content']! as List;
      expect(user.last, {
        'type': 'file',
        'file': {'filename': 'att1-report.pdf', 'file_data': 'data:application/pdf;base64,${base64Encode(_pdf)}'},
      });
      _golden('openai_chat_pdf', b.body);
    });

    test('OpenAI Responses: input_file in user content and inside function_call_output', () {
      final b = _responses();
      expect(b.notices, isEmpty);
      final input = (b.body['input']! as List).cast<Map<String, Object?>>();
      expect((input.first['content']! as List).last, {
        'type': 'input_file',
        'filename': 'att1-report.pdf',
        'file_data': 'data:application/pdf;base64,${base64Encode(_pdf)}',
      });
      final output = input.firstWhere((i) => i['type'] == 'function_call_output')['output']! as List;
      expect(output.last, containsPair('filename', 'q3.pdf'));
      _golden('openai_responses_pdf', b.body);
    });

    test('Anthropic Messages: document blocks', () {
      final r = const AnthropicRequestBuilder(providerId: 'p').build(_request('claude-sonnet-5-5'));
      expect(r.notices, isEmpty);
      _golden('anthropic_pdf', r.body);
    });
  });

  group('gating', () {
    test('compatible servers without file parts get a reason instead of a 400', () {
      for (final (profile, server) in [
        (ServerProfile.llamaCpp, 'llama.cpp'),
        (ServerProfile.ollama, 'Ollama'),
        (ServerProfile.vllm, 'vLLM'),
        (ServerProfile.lmStudio, 'LM Studio'),
        (ServerProfile.deepSeek, 'DeepSeek'),
        (ServerProfile.generic, 'This server'),
      ]) {
        final b = _chat(profile, model: 'qwen3:8b');
        final dropped = b.notices.where((n) => n.code == 'content_dropped').toList();
        expect(dropped, hasLength(2), reason: '$profile: the user PDF and the tool PDF');
        expect(dropped.first.message, allOf(contains('att1-report.pdf'), contains(server), contains('PDF file parts')));
        expect(dropped.first.data, containsPair('kind', 'pdf'));
        expect(jsonEncode(b.body), isNot(contains('"type":"file"')), reason: '$profile');
        expect(_messages(b)[1]['content'], 'Summarize the attached report, then fetch Q3.',
            reason: 'the text still goes, as a plain string');
      }
    });

    test('OpenRouter takes file parts for any model', () {
      final b = _chat(ServerProfile.openRouter, model: 'meta-llama/llama-4-scout');
      expect(b.notices.where((n) => n.code == 'content_dropped'), isEmpty);
      expect(jsonEncode(b.body), contains('"type":"file"'));
    });

    test('OpenAI models without vision get the reason on both APIs', () {
      final chat = _chat(ServerProfile.openAi, model: 'o3-mini');
      expect(chat.notices.first.message, contains('o3-mini does not read PDFs'));
      expect(jsonEncode(chat.body), isNot(contains('"type":"file"')));
      final responses = _responses(model: 'o3-mini');
      expect(responses.notices.where((n) => n.code == 'content_dropped'), hasLength(2));
      expect(jsonEncode(responses.body), isNot(contains('input_file')));
    });

    test('a PDF still referenced by file (not inlined) is reported, not sent empty', () {
      final r = ModelRequest(modelId: 'gpt-5', messages: [
        Message(id: 'u', role: Role.user, createdAt: t0, content: const [
          TextPart('read this'),
          EmbeddedResourcePart(uri: 'file:///chats/s1/att1-report.pdf', mimeType: 'application/pdf'),
        ]),
      ]);
      final b = buildChatRequest(request: r, quirks: ServerQuirks.of(ServerProfile.openAi), names: ToolNameMapper(const []), providerId: 'p');
      expect(b.notices.single.message, contains('could not be read'));
      expect(pdfFileName('file:///'), 'document.pdf');
      expect(pdfFileName('https://h/reports/q3'), 'q3.pdf');
    });
  });

  group('pdfInput capability', () {
    test('OpenAI by model family', () {
      for (final id in ['gpt-4o', 'gpt-4o-2024-08-06', 'gpt-4o-mini', 'gpt-4.1-nano', 'gpt-5', 'gpt-5-mini', 'gpt-6-astra',
        'gpt-6.1-sol', 'o1', 'o3', 'o3-pro', 'o4-mini']) {
        expect(openAiModelTakesPdf(id), isTrue, reason: id);
      }
      for (final id in ['gpt-4', 'gpt-4-turbo', 'gpt-3.5-turbo', 'o1-mini', 'o3-mini', 'gpt-4o-audio-preview',
        'gpt-4o-realtime-preview', 'gpt-4o-mini-tts', 'gpt-4o-transcribe', 'gpt-image-1', 'text-embedding-3-large',
        'omni-moderation-latest', 'gpt-oss-120b']) {
        expect(openAiModelTakesPdf(id), isFalse, reason: id);
      }
    });

    Future<ModelCapabilities> discover(ServerProfile profile, String model, Map<String, Object?> Function(Uri) answer) {
      final client = MockClient((r) async => http.Response(jsonEncode(answer(r.url)), 200,
          headers: {'content-type': 'application/json'}));
      return OpenAiChatProvider(config: testConfig(mockBase, profile: profile), client: client).capabilities(model);
    }

    test('discovery reports it per server', () async {
      expect((await discover(ServerProfile.openAi, 'gpt-4o', (_) => {})).pdfInput, isTrue);
      expect((await discover(ServerProfile.openAi, 'o3-mini', (_) => {})).pdfInput, isFalse);
      expect((await discover(ServerProfile.openAi, 'gpt-5.4', (_) => {})).pdfInput, isTrue, reason: 'unlisted ids by family');
      final llama = await discover(ServerProfile.llamaCpp, 'qwen', (u) => {
            'default_generation_settings': {'n_ctx': 8192},
            'modalities': {'vision': true},
          });
      expect((llama.vision, llama.pdfInput), (true, false));
      Map<String, Object?> openRouter(Uri _) => {
            'data': [
              {
                'id': 'anthropic/claude-sonnet-5',
                'context_length': 200000,
                'architecture': {
                  'input_modalities': ['text', 'image', 'file'],
                },
              },
              {
                'id': 'meta-llama/llama-4-scout',
                'context_length': 128000,
                'architecture': {
                  'input_modalities': ['text', 'image'],
                },
              },
            ],
          };
      expect((await discover(ServerProfile.openRouter, 'anthropic/claude-sonnet-5', openRouter)).pdfInput, isTrue);
      expect((await discover(ServerProfile.openRouter, 'meta-llama/llama-4-scout', openRouter)).pdfInput, isFalse,
          reason: 'no native file input: OpenRouter would parse (and may bill) it');
    });

    test('Anthropic from the model traits, refined by /v1/models', () {
      expect(AnthropicModelTraits.forModel('claude-sonnet-5-5').toCapabilities().pdfInput, isTrue);
      expect(AnthropicModelTraits.forModel('claude-haiku-4-5').toCapabilities().pdfInput, isTrue);
      expect(AnthropicModelTraits.forModel('claude-3-5-sonnet-20241022').pdfInput, isTrue);
      expect(AnthropicModelTraits.forModel('claude-3-haiku-20240307').pdfInput, isFalse);
      expect(AnthropicModelTraits.forModel('claude-new-thing').pdfInput, isTrue, reason: 'unknown ids are newer');
      final refined = AnthropicModelTraits.forModel('claude-opus-5').refine({
        'pdf_input': {'supported': false},
      });
      expect(refined.toCapabilities().pdfInput, isFalse);
    });
  });
}
