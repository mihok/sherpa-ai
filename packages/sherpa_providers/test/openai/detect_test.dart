import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:sherpa_providers/sherpa_providers.dart';
import 'package:test/test.dart';

import '../support/fake_server.dart';

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

  Future<ServerProfile> detect([Uri? base]) => detectServerProfile(base ?? server.v1, client);

  test('known hosts are recognised without any request', () async {
    final offline = MockClient((_) async => throw StateError('no network expected'));
    for (final (url, profile) in [
      ('https://api.openai.com/v1', ServerProfile.openAi),
      ('https://openrouter.ai/api/v1', ServerProfile.openRouter),
      ('https://router.huggingface.co/v1', ServerProfile.huggingFaceRouter),
      ('https://api.deepseek.com', ServerProfile.deepSeek),
      ('https://ollama.com/v1', ServerProfile.ollama),
    ]) {
      expect(await detectServerProfile(Uri.parse(url), offline), profile, reason: url);
    }
  });

  test('Ollama: /api/version', () async {
    server
      ..route('GET /api/version', (_) => jsonResponse({'version': '0.13.3'}))
      ..route('GET /v1/models', (_) => jsonResponse({
            'object': 'list',
            'data': [
              {'id': 'qwen3:8b', 'object': 'model', 'owned_by': 'library'},
            ],
          }));
    expect(await detect(), ServerProfile.ollama);
    // Probes go to the server root, not under /v1.
    expect(server.requestsTo('/api/version'), hasLength(1));
  });

  test('llama.cpp: /props wins over its Ollama-shaped models key', () async {
    server
      ..route('GET /props', (_) => jsonResponse({
            'default_generation_settings': {'n_ctx': 8192},
            'build_info': 'b7000-abc',
          }))
      ..route('GET /v1/models', (_) => jsonResponse({
            'models': [
              {'name': 'qwen3-8b', 'model': 'qwen3-8b'},
            ],
            'object': 'list',
            'data': [
              {'id': 'qwen3-8b', 'object': 'model', 'owned_by': 'llamacpp'},
            ],
          }));
    expect(await detect(), ServerProfile.llamaCpp);
  });

  test('llama.cpp by owned_by alone, even if /api/version also answers', () async {
    server
      ..route('GET /api/version', (_) => jsonResponse({'version': '1'}))
      ..route('GET /v1/models', (_) => jsonResponse({
            'data': [
              {'id': 'm', 'owned_by': 'llamacpp'},
            ],
          }));
    expect(await detect(), ServerProfile.llamaCpp);
  });

  test('LM Studio: /api/v1/models (0.4+) and /api/v0/models (0.3.x)', () async {
    server.route('GET /api/v1/models', (_) => jsonResponse({
          'models': [
            {'type': 'llm', 'key': 'qwen3-8b', 'max_context_length': 32768},
          ],
        }));
    expect(await detect(), ServerProfile.lmStudio);

    final legacy = await FakeServer.start({
      'GET /api/v0/models': (_) => jsonResponse({
            'data': [
              {'id': 'qwen3-8b', 'type': 'llm', 'state': 'not-loaded', 'max_context_length': 32768},
            ],
          }),
    });
    expect(await detect(legacy.v1), ServerProfile.lmStudio);
    await legacy.close();
  });

  test('vLLM: owned_by or max_model_len', () async {
    server.route('GET /v1/models', (_) => jsonResponse({
          'data': [
            {'id': 'Qwen/Qwen3-8B', 'object': 'model', 'owned_by': 'vllm', 'max_model_len': 32768},
          ],
        }));
    expect(await detect(), ServerProfile.vllm);
  });

  test('OpenAI-compatible proxy exposing the openai-version header', () async {
    server.route('GET /v1/models',
        (_) => jsonResponse({'data': <Object>[]}, headers: {'openai-version': '2020-10-01'}));
    expect(await detect(), ServerProfile.openAi);
  });

  test('nothing conclusive → generic; HTML 200s are not mistaken for JSON', () async {
    server
      ..route('GET /props', (_) => Response.ok('<html>app</html>', headers: {'content-type': 'text/html'}))
      ..route('GET /v1/models', (_) => jsonResponse({
            'data': [
              {'id': 'x', 'owned_by': 'someone'},
            ],
          }));
    expect(await detect(), ServerProfile.generic);
  });

  test('unreachable or slow servers fall back to generic within the timeout, never throwing', () async {
    final dead = server.v1;
    await server.close();
    expect(await detectServerProfile(dead, client), ServerProfile.generic);

    final slow = await FakeServer.start();
    final hang = Completer<void>();
    slow
      ..route('GET /api/version', (_) => hang.future.then((_) => Response.ok('')))
      ..route('GET /props', (_) => hang.future.then((_) => Response.ok('')));
    final sw = Stopwatch()..start();
    expect(await detectServerProfile(slow.v1, client, timeout: const Duration(milliseconds: 300)), ServerProfile.generic);
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
    hang.complete();
    await slow.close();
    server = await FakeServer.start();
  });

  test('probes do not follow redirects', () async {
    server.route('GET /props', (_) => Response.found('http://169.254.169.254/props'));
    expect(await detect(), ServerProfile.generic);
    expect(server.requests.where((r) => r.path == '/props'), hasLength(1));
  });

  test('classifyProbes and profileForKnownHost are usable directly', () {
    expect(classifyProbes(), ServerProfile.generic);
    expect(profileForKnownHost(Uri.parse('https://eu.openrouter.ai/api/v1')), ServerProfile.openRouter);
    expect(profileForKnownHost(Uri.parse('http://192.168.1.2:8080')), isNull);
  });
}
