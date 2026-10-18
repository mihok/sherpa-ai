import 'package:http/http.dart' as http;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';
import 'package:test/test.dart';

import '../support/fake_server.dart';
import '../support/helpers.dart';

void main() {
  late FakeServer server;
  late http.Client client;

  setUp(() async {
    server = await FakeServer.start();
    client = http.Client();
  });

  tearDown(() async {
    client.close();
    await server.close();
  });

  OpenAiChatProvider chat(ServerProfile profile, {Map<String, ModelCapabilities> overrides = const {}, Clock? clock}) =>
      OpenAiChatProvider(
        config: testConfig(server.v1, profile: profile, overrides: overrides),
        client: client,
        clock: clock ?? const SystemClock(),
      );

  group('llama.cpp', () {
    test('/props n_ctx (per slot), modalities and template caps', () async {
      server.route('GET /props', (_) => jsonResponse({
            'default_generation_settings': {'n_ctx': 8192, 'params': {'n_predict': -1}},
            'modalities': {'vision': true, 'audio': false},
            'chat_template_caps': {'supports_parallel_tool_calls': false, 'supports_system_role': true},
            'build_info': 'b7000',
          }));
      final caps = await chat(ServerProfile.llamaCpp).capabilities('qwen3-8b');
      expect(caps.contextLength, 8192);
      expect(caps.vision, isTrue);
      expect(caps.parallelToolCalls, isFalse);
      expect(caps.toolCallFormat, ToolCallFormat.native);
      expect(caps.historyPolicy, HistoryPolicy.mutable);
      // Router mode is asked per model.
      expect(server.requestsTo('/props').first.query['model'], 'qwen3-8b');
    });

    test('falls back to /v1/models meta.n_ctx when /props is unavailable', () async {
      server.route('GET /v1/models', (_) => jsonResponse({
            'data': [
              {
                'id': 'm',
                'owned_by': 'llamacpp',
                'meta': {'n_ctx': 4096, 'n_ctx_train': 40960},
              },
            ],
          }));
      expect((await chat(ServerProfile.llamaCpp).capabilities('m')).contextLength, 4096);
    });
  });

  group('Ollama', () {
    void show({String? parameters, List<String> caps = const ['completion', 'tools', 'thinking']}) =>
        server.route('POST /api/show', (_) => jsonResponse({
              'model_info': {'general.architecture': 'qwen3', 'qwen3.context_length': 40960},
              'parameters': ?parameters,
              'capabilities': caps,
            }));

    test('loaded models report their allocated context via /api/ps', () async {
      show(parameters: 'num_ctx 16384\nstop "<|im_end|>"');
      server.route('GET /api/ps', (_) => jsonResponse({
            'models': [
              {'name': 'qwen3:latest', 'model': 'qwen3:latest', 'context_length': 32768},
            ],
          }));
      final caps = await chat(ServerProfile.ollama).capabilities('qwen3');
      expect(caps.contextLength, 32768);
      expect(caps.reasoning, ReasoningSupport.optional);
      expect(caps.toolCallFormat, ToolCallFormat.native);
      expect(server.requestsTo('/api/show').single.json['model'], 'qwen3');
    });

    test('Modelfile num_ctx when not loaded', () async {
      show(parameters: 'temperature 0.7\nnum_ctx 16384');
      server.route('GET /api/ps', (_) => jsonResponse({'models': <Object>[]}));
      expect((await chat(ServerProfile.ollama).capabilities('qwen3:8b')).contextLength, 16384);
    });

    test('otherwise the conservative server default, not the trained window', () async {
      show(caps: ['completion', 'vision']);
      server.route('GET /api/ps', (_) => jsonResponse({'models': <Object>[]}));
      final caps = await chat(ServerProfile.ollama).capabilities('gemma4');
      expect(caps.contextLength, ModelDiscovery.ollamaFallbackContext);
      expect(caps.vision, isTrue);
      expect(caps.toolCallFormat, ToolCallFormat.none, reason: 'no "tools" capability');
    });
  });

  group('LM Studio', () {
    test('loaded instance context, else max_context_length', () async {
      server.route('GET /api/v1/models', (_) => jsonResponse({
            'models': [
              {
                'type': 'llm',
                'key': 'qwen3-8b',
                'max_context_length': 32768,
                'loaded_instances': [
                  {
                    'id': 'qwen3-8b',
                    'config': {'context_length': 12288},
                  },
                ],
                'capabilities': {'vision': false, 'trained_for_tool_use': true},
              },
              {'type': 'vlm', 'key': 'gemma-3', 'max_context_length': 131072, 'loaded_instances': <Object>[], 'capabilities': {'vision': true}},
            ],
          }));
      final p = chat(ServerProfile.lmStudio);
      expect((await p.capabilities('qwen3-8b')).contextLength, 12288);
      final gemma = await p.capabilities('gemma-3');
      expect(gemma.contextLength, 131072);
      expect(gemma.vision, isTrue);
    });

    test('legacy /api/v0/models', () async {
      server.route('GET /api/v0/models', (_) => jsonResponse({
            'data': [
              {'id': 'phi', 'type': 'llm', 'state': 'not-loaded', 'max_context_length': 16384},
            ],
          }));
      expect((await chat(ServerProfile.lmStudio).capabilities('phi')).contextLength, 16384);
    });
  });

  test('vLLM: max_model_len from /v1/models', () async {
    server.route('GET /v1/models', (_) => jsonResponse({
          'data': [
            {'id': 'Qwen/Qwen3-8B', 'owned_by': 'vllm', 'max_model_len': 32768},
          ],
        }));
    final p = chat(ServerProfile.vllm);
    expect((await p.capabilities('Qwen/Qwen3-8B')).contextLength, 32768);
    final listed = await p.listModels();
    expect(listed.single.capabilities.contextLength, 32768);
  });

  test('OpenRouter: context_length, top_provider, supported_parameters, modalities', () async {
    server.route('GET /v1/models', (_) => jsonResponse({
          'data': [
            {
              'id': 'anthropic/claude-sonnet-5.5',
              'name': 'Anthropic: Claude Sonnet 5.5',
              'context_length': 1000000,
              'top_provider': {'context_length': 1000000, 'max_completion_tokens': 128000},
              'supported_parameters': ['tools', 'tool_choice', 'reasoning', 'max_tokens'],
              'architecture': {
                'input_modalities': ['text', 'image'],
              },
              'reasoning': {'mandatory': false},
            },
            {
              'id': 'some/no-tools',
              'context_length': 8192,
              'supported_parameters': ['max_tokens'],
            },
          ],
        }));
    final p = chat(ServerProfile.openRouter);
    final caps = await p.capabilities('anthropic/claude-sonnet-5.5');
    expect(caps.contextLength, 1000000);
    expect(caps.maxOutputTokens, 128000);
    expect(caps.vision, isTrue);
    expect(caps.reasoning, ReasoningSupport.optional);
    expect((await p.capabilities('some/no-tools')).toolCallFormat, ToolCallFormat.none);
    final models = await p.listModels();
    expect(models.first.displayName, 'Anthropic: Claude Sonnet 5.5');
    // The list is fetched once and shared across capability lookups.
    expect(server.requestsTo('/v1/models').length, lessThanOrEqualTo(2));
  });

  test('HF router: provider suffix, else the smallest live provider window', () async {
    server.route('GET /v1/models', (_) => jsonResponse({
          'data': [
            {
              'id': 'openai/gpt-oss-120b',
              'architecture': {
                'input_modalities': ['text'],
              },
              'providers': [
                {'provider': 'groq', 'status': 'live', 'context_length': 131072, 'supports_tools': true},
                {'provider': 'cerebras', 'status': 'live', 'context_length': 65536, 'supports_tools': true},
                {'provider': 'slowco', 'status': 'staging', 'context_length': 8192},
              ],
            },
          ],
        }));
    final p = chat(ServerProfile.huggingFaceRouter);
    expect((await p.capabilities('openai/gpt-oss-120b')).contextLength, 65536);
    expect((await p.capabilities('openai/gpt-oss-120b:groq')).contextLength, 131072);
    expect((await p.capabilities('openai/gpt-oss-120b:fastest')).contextLength, 65536);
    expect((await p.capabilities('openai/gpt-oss-120b')).toolCallFormat, ToolCallFormat.native);
  });

  test('OpenAI: static table, no network; tool calling gated to Responses where required', () async {
    final p = chat(ServerProfile.openAi);
    final astra = await p.capabilities('gpt-6-astra');
    expect(astra.contextLength, 1050000);
    expect(astra.maxOutputTokens, 128000);
    expect(astra.toolCallFormat, ToolCallFormat.none, reason: 'Chat Completions has no tools for gpt-6-astra');
    expect((await p.capabilities('gpt-6.1-sol')).toolCallFormat, ToolCallFormat.none);
    expect((await p.capabilities('gpt-4o-2024-08-06')).contextLength, 128000);
    expect((await p.capabilities('gpt-4o-mini')).maxOutputTokens, 16384);
    expect(await p.capabilities('brand-new-model'), same(ModelCapabilities.unknown));
    expect(server.requests, isEmpty);

    final responses = OpenAiResponsesProvider(
      config: testConfig(server.v1, flavor: ApiFlavor.openAiResponses),
      client: client,
    );
    expect((await responses.capabilities('gpt-6-astra')).toolCallFormat, ToolCallFormat.native);
  });

  test('overrides win without any request; results are cached; failures degrade to unknown', () async {
    const override = ModelCapabilities(contextLength: 65536);
    final p = chat(ServerProfile.vllm, overrides: {'pinned': override});
    expect(await p.capabilities('pinned'), same(override));
    expect(server.requests, isEmpty);

    server.route('GET /v1/models', (_) => jsonResponse({
          'data': [
            {'id': 'm', 'max_model_len': 2048},
          ],
        }));
    expect((await p.capabilities('m')).contextLength, 2048);
    expect((await p.capabilities('m')).contextLength, 2048);
    expect(server.requestsTo('/v1/models'), hasLength(1));
    p.invalidateCapabilities();
    await p.capabilities('m');
    expect(server.requestsTo('/v1/models'), hasLength(2));

    await server.close();
    final dead = chat(ServerProfile.llamaCpp);
    expect(await dead.capabilities('x'), same(ModelCapabilities.unknown));
    server = await FakeServer.start();
  });

  test('provisional answers expire quickly so a later load is seen', () async {
    final clock = FakeClock();
    var loaded = false;
    server
      ..route('POST /api/show', (_) => jsonResponse({
            'model_info': {'general.architecture': 'llama', 'llama.context_length': 131072},
            'capabilities': ['completion', 'tools'],
          }))
      ..route('GET /api/ps', (_) => jsonResponse({
            'models': [
              if (loaded) {'name': 'llama3.2:latest', 'context_length': 65536},
            ],
          }));
    final p = chat(ServerProfile.ollama, clock: clock);
    expect((await p.capabilities('llama3.2')).contextLength, 4096);
    loaded = true;
    expect((await p.capabilities('llama3.2')).contextLength, 4096, reason: 'still cached');
    clock.advance(ModelDiscovery.provisionalTtl + const Duration(seconds: 1));
    expect((await p.capabilities('llama3.2')).contextLength, 65536);
  });

  test('listModels maps errors to ProviderException', () async {
    server.route('GET /v1/models', (_) => jsonResponse({'error': {'message': 'bad key'}}, status: 401));
    await expectLater(chat(ServerProfile.generic).listModels(),
        throwsA(isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.auth)));
  });
}
