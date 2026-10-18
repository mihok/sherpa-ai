import 'dart:convert';
import 'dart:math';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';
import 'package:test/test.dart';

import '../support/helpers.dart';

/// Golden tests: the raw SSE fixtures from docs/research/10 §9 (F1–F5) and
/// variants derived from the documented shapes, replayed through the real
/// providers via a streaming MockClient.
void main() {
  Future<List<ModelEvent>> chat(String text, ServerProfile profile, {List<int> splitAt = const []}) => collect(
        OpenAiChatProvider(config: testConfig(mockBase, profile: profile), client: mockSse(text, splitAt: splitAt))
            .stream(weatherRequest()),
      );

  Future<List<ModelEvent>> responses(String text, {List<int> splitAt = const []}) => collect(
        OpenAiResponsesProvider(
          config: testConfig(mockBase, flavor: ApiFlavor.openAiResponses),
          client: mockSse(text, splitAt: splitAt),
        ).stream(weatherRequest(model: 'gpt-6-astra')),
      );

  group('F1 OpenAI Chat parallel tool calls', () {
    const expected = [
      'ToolCallStart(0, call_wX1, get_weather)',
      'ToolCallArgsDelta(0, {"ci)',
      'ToolCallArgsDelta(0, ty": "Paris"})',
      'ToolCallStart(1, call_tY2, get_time)',
      'ToolCallArgsDelta(1, {"timezone": )',
      'ToolCallArgsDelta(1, "Asia/Tokyo"})',
      'ToolCallComplete(0, call_wX1, get_weather, {"city":"Paris"})',
      'ToolCallComplete(1, call_tY2, get_time, {"timezone":"Asia/Tokyo"})',
      'Usage(in 182, cached 0, out 41, reasoning 0)',
      'Finish(toolCalls)',
    ];

    test('matches the expected event sequence', () async {
      expect(describeAll(await chat(fixture('f1_openai_chat_parallel_tools.sse'), ServerProfile.openAi)), expected);
    });

    test('is identical when split at every byte offset', () async {
      final text = fixture('f1_openai_chat_parallel_tools.sse');
      final length = utf8.encode(text).length;
      for (var cut = 1; cut < length; cut++) {
        final events = await chat(text, ServerProfile.openAi, splitAt: [cut]);
        expect(describeAll(events), expected, reason: 'split at byte $cut');
      }
    });

    test('is identical under random multi-way splits', () async {
      final text = fixture('f1_openai_chat_parallel_tools.sse');
      final length = utf8.encode(text).length;
      final rnd = Random(7);
      for (var i = 0; i < 200; i++) {
        final cuts = {for (var k = 0; k < 1 + rnd.nextInt(30); k++) 1 + rnd.nextInt(length - 1)}.toList()..sort();
        expect(describeAll(await chat(text, ServerProfile.openAi, splitAt: cuts)), expected, reason: '$cuts');
      }
    });
  });

  test('F2 llama.cpp: reasoning_content, ping comment, timings', () async {
    final events = await chat(fixture('f2_llamacpp_reasoning_tools.sse'), ServerProfile.llamaCpp);
    expect(describeAll(events), [
      'Reasoning(Need weather and time; call both.)',
      'ToolCallStart(0, Vd9q2LxR8sTn4KbP, get_weather)',
      'ToolCallArgsDelta(0, {"city":)',
      'ToolCallArgsDelta(0, "Paris"})',
      'ToolCallStart(1, Hc3mW7yZ0aQe5UjD, get_time)',
      'ToolCallArgsDelta(1, {"timezone":"Asia/Tokyo"})',
      'ToolCallComplete(0, Vd9q2LxR8sTn4KbP, get_weather, {"city":"Paris"})',
      'ToolCallComplete(1, Hc3mW7yZ0aQe5UjD, get_time, {"timezone":"Asia/Tokyo"})',
      'Usage(in 28, cached 212, out 58, reasoning 0)',
      'Perf(240, 212)',
      'Finish(toolCalls)',
    ]);
    final usage = events.whereType<UsageUpdate>().single.usage;
    // R10: context used = prompt_n + cache_n + predicted_n = 298.
    expect(usage.inputTokens + usage.cacheReadTokens + usage.outputTokens, 298);
  });

  test('F2 mid-stream error tail (no [DONE]) becomes a stream error after the deltas', () async {
    final provider = OpenAiChatProvider(
      config: testConfig(mockBase, profile: ServerProfile.llamaCpp),
      client: mockSse(fixture('f2b_llamacpp_midstream_error.sse')),
    );
    final (seen, error) = await collectWithError(provider.stream(weatherRequest()));
    expect(describeAll(seen), ['Reasoning(Need weather and time; call both.)']);
    expect(error, isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.server));
    expect((error! as ProviderException).message, contains('slot 0 crashed'));
  });

  test('F3 Ollama: whole tool calls in one chunk, `reasoning` field', () async {
    final events = await chat(fixture('f3_ollama_whole_tool_calls.sse'), ServerProfile.ollama);
    expect(describeAll(events), [
      'Reasoning(Two lookups needed.)',
      'ToolCallStart(0, call_a1b2c3d4, get_weather)',
      'ToolCallArgsDelta(0, {"city":"Paris"})',
      'ToolCallStart(1, call_e5f6g7h8, get_time)',
      'ToolCallArgsDelta(1, {"timezone":"Asia/Tokyo"})',
      'ToolCallComplete(0, call_a1b2c3d4, get_weather, {"city":"Paris"})',
      'ToolCallComplete(1, call_e5f6g7h8, get_time, {"timezone":"Asia/Tokyo"})',
      'Usage(in 231, cached 0, out 44, reasoning 0)',
      'Finish(toolCalls)',
    ]);
  });

  test('OpenRouter: comment lines, reasoning_details, repeated finish_reason in usage frame', () async {
    final events = await chat(fixture('openrouter_reasoning_details.sse'), ServerProfile.openRouter);
    final described = describeAll(events);
    expect(described.first, 'Reasoning(Need the )');
    expect(described[1], 'Reasoning(weather.)');
    expect(described[2], startsWith('Signature('));
    expect(described.sublist(3), [
      'Text(Checking.)',
      'ToolCallStart(0, toolu_OR1, get_weather)',
      'ToolCallArgsDelta(0, {"city":"Paris"})',
      'ToolCallComplete(0, toolu_OR1, get_weather, {"city":"Paris"})',
      'Usage(in 20, cached 100, out 30, reasoning 12)',
      'Finish(toolCalls)',
    ]);
    final details = jsonDecode(events.whereType<ReasoningSignature>().single.signature!) as List;
    expect(details, [
      {
        'type': 'reasoning.text',
        'text': 'Need the weather.',
        'format': 'anthropic-claude-v1',
        'index': 0,
        'signature': 'ErUBCkYIBhgCIkA',
      },
    ]);
  });

  test('OpenRouter mid-stream error chunk (finish_reason "error")', () async {
    final provider = OpenAiChatProvider(
      config: testConfig(mockBase, profile: ServerProfile.openRouter),
      client: mockSse(fixture('openrouter_midstream_error.sse')),
    );
    final (seen, error) = await collectWithError(provider.stream(weatherRequest()));
    expect(error, isA<ProviderException>().having((e) => e.statusCode, 'status', 502));
    expect(describeAll(seen), ['Text(Partial)']);
  });

  test('LM Studio: empty and repeated names are never concatenated', () async {
    final events = await chat(fixture('lmstudio_empty_name_repeat.sse'), ServerProfile.lmStudio);
    expect(describeAll(events), [
      'ToolCallStart(0, 145863524, get_weather)',
      'ToolCallArgsDelta(0, {"city":)',
      'ToolCallArgsDelta(0, "Paris"})',
      'ToolCallComplete(0, 145863524, get_weather, {"city":"Paris"})',
      'Finish(toolCalls)',
    ]);
  });

  test('several fragments for the same index in one chunk', () async {
    final events = await chat(fixture('multi_fragment_chunk.sse'), ServerProfile.generic);
    expect(describeAll(events.whereType<ToolCallComplete>()), [
      'ToolCallComplete(0, call_m0, get_weather, {"city":"Paris"})',
      'ToolCallComplete(1, call_m1, get_time, {"timezone":"Asia/Tokyo"})',
    ]);
    expect(events.whereType<ToolCallStart>().map((e) => e.index), [0, 1]);
  });

  group('F5 OpenAI Responses', () {
    const expected = [
      'Signature(gAAAAABo...)',
      'ToolCallStart(0, call_1, get_weather)',
      'ToolCallArgsDelta(0, {"city":"Paris"})',
      'ToolCallComplete(0, call_1, get_weather, {"city":"Paris"})',
      'ToolCallStart(1, call_2, get_time)',
      'ToolCallArgsDelta(1, {"timezone":"Asia/Tokyo"})',
      'ToolCallComplete(1, call_2, get_time, {"timezone":"Asia/Tokyo"})',
      'Usage(in 201, cached 0, out 77, reasoning 40)',
      'Finish(toolCalls)',
    ];

    test('parallel function calls with encrypted reasoning', () async {
      expect(describeAll(await responses(fixture('f5_responses_parallel_function_calls.sse'))), expected);
    });

    test('identical at every split offset', () async {
      final text = fixture('f5_responses_parallel_function_calls.sse');
      final length = utf8.encode(text).length;
      for (var cut = 1; cut < length; cut += 3) {
        expect(describeAll(await responses(text, splitAt: [cut])), expected, reason: 'split at $cut');
      }
    });

    test('reasoning summary parts and text output', () async {
      expect(describeAll(await responses(fixture('responses_reasoning_text.sse'))), [
        'Reasoning(Plan the answer.)',
        'Reasoning(\n\n)',
        'Reasoning(Keep it short.)',
        'Signature(gAAAAABoT1enc)',
        'Text(Hello)',
        'Text( there.)',
        'Usage(in 30, cached 20, out 30, reasoning 18)',
        'Finish(stop)',
      ]);
    });

    test('response.incomplete maps to length', () async {
      expect(describeAll(await responses(fixture('responses_incomplete.sse'))), [
        'Text(Truncated ans)',
        'Usage(in 10, cached 0, out 5, reasoning 0)',
        'Finish(length)',
      ]);
    });

    test('response.failed and error events are stream errors', () async {
      await expectLater(
        responses(fixture('responses_failed.sse')),
        throwsA(isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.server)),
      );
      await expectLater(
        responses(fixture('responses_error_event.sse')),
        throwsA(isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.rateLimited)),
      );
    });

    test('a stream cut before a terminal event is a retryable network error', () async {
      final text = fixture('f5_responses_parallel_function_calls.sse');
      final cut = text.indexOf('event: response.completed');
      await expectLater(
        responses(text.substring(0, cut)),
        throwsA(isA<ProviderException>().having((e) => e.isRetryable, 'retryable', isTrue)),
      );
    });
  });

  test('a chat stream cut before finish_reason/[DONE] is a retryable network error', () async {
    final text = fixture('f1_openai_chat_parallel_tools.sse');
    final cut = text.indexOf('"finish_reason":"tool_calls"');
    final truncated = text.substring(0, text.lastIndexOf('data:', cut));
    await expectLater(
      chat(truncated, ServerProfile.openAi),
      throwsA(isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.network)),
    );
  });

  test('EOF after a finish_reason without [DONE] is a normal end', () async {
    final text = fixture('f1_openai_chat_parallel_tools.sse').replaceAll('data: [DONE]\n\n', '');
    expect(describeAll(await chat(text, ServerProfile.openAi)).last, 'Finish(toolCalls)');
  });
}
