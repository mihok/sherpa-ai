import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';
import 'package:sherpa_providers/sherpa_providers.dart';
import 'package:test/test.dart';

/// Finding 14: every adapter must produce [Usage] numbers with the core's
/// documented meaning, `full prompt = inputTokens + cacheReadTokens`, with
/// cache writes counted in [Usage.inputTokens] and reported again as the
/// [Usage.cacheWriteTokens] subset.
void main() {
  // One prompt of 50 000 tokens: 1 000 read from cache, 48 000 written to
  // it, 1 000 neither.
  const prompt = 50000;
  const read = 1000;
  const written = 48000;

  void expectCoreMeaning(Usage u) {
    expect(u.inputTokens + u.cacheReadTokens, prompt, reason: 'full prompt = input + cacheRead');
    expect(u.cacheReadTokens, read);
    expect(u.cacheWriteTokens, written);
    expect(u.inputTokens, greaterThanOrEqualTo(u.cacheWriteTokens), reason: 'writes are a subset of input');
    expect(u.outputTokens, 7);
  }

  test('OpenAI Chat: prompt_tokens is the whole prompt; details are subsets', () {
    expectCoreMeaning(parseChatUsage({
      'prompt_tokens': prompt,
      'completion_tokens': 7,
      'prompt_tokens_details': {'cached_tokens': read, 'cache_write_tokens': written},
    }));
  });

  test('OpenAI Responses: input_tokens is the whole prompt; details are subsets', () {
    expectCoreMeaning(parseResponsesUsage({
      'input_tokens': prompt,
      'output_tokens': 7,
      'input_tokens_details': {'cached_tokens': read, 'cache_write_tokens': written},
    }));
  });

  test('Anthropic: disjoint input / cache_creation / cache_read fields', () {
    final decoder = AnthropicStreamDecoder(providerId: 'a');
    decoder.add(SseEvent(
      data: jsonEncode({
        'type': 'message_start',
        'message': {
          'id': 'msg',
          'model': 'm',
          'usage': {
            'input_tokens': prompt - read - written,
            'cache_creation_input_tokens': written,
            'cache_read_input_tokens': read,
            'output_tokens': 7,
          },
        },
      }),
    ));
    expectCoreMeaning(decoder.usage);
  });

  test('inconsistent reports never go negative', () {
    final u = parseChatUsage({
      'prompt_tokens': 10,
      'prompt_tokens_details': {'cached_tokens': 20, 'cache_write_tokens': 30},
    });
    expect(u.inputTokens, 0);
    expect(u.cacheWriteTokens, 0);
  });
}
