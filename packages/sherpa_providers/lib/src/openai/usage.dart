import 'package:sherpa_core/sherpa_core.dart';

import '../common/json_read.dart';

/// Chat Completions `usage` → [Usage].
///
/// Core convention ([Usage]): [Usage.inputTokens] is every prompt token
/// that was not a cache read, cache writes included, so `inputTokens +
/// cacheReadTokens` is the whole prompt (the agent loop calibrates its
/// estimator on exactly that). [Usage.cacheWriteTokens] is the written
/// subset of [Usage.inputTokens]. The Anthropic decoder produces the same
/// numbers from its disjoint fields.
///
/// OpenAI's `prompt_tokens` is the whole prompt, and the
/// `prompt_tokens_details` counts (`cached_tokens`, `cache_write_tokens`)
/// are subsets of it (R10 §3.3: `text_tokens` equals `prompt_tokens`), so
/// only cache reads are subtracted. Every `*_details` field is optional
/// (llama.cpp sends only `cached_tokens`; Ollama sends it when set).
Usage parseChatUsage(JsonMap u) {
  final details = u.child('prompt_tokens_details');
  return _usage(
    prompt: u.integer('prompt_tokens') ?? 0,
    cacheRead: details?.integer('cached_tokens') ?? 0,
    cacheWrite: details?.integer('cache_write_tokens') ?? 0,
    output: u.integer('completion_tokens') ?? 0,
    reasoning: u.child('completion_tokens_details')?.integer('reasoning_tokens') ?? 0,
  );
}

/// Responses `response.usage` → [Usage], with the same convention as
/// [parseChatUsage]: `input_tokens` is the whole prompt and
/// `input_tokens_details.cached_tokens` / `cache_write_tokens` are subsets.
Usage parseResponsesUsage(JsonMap u) {
  final details = u.child('input_tokens_details');
  return _usage(
    prompt: u.integer('input_tokens') ?? 0,
    cacheRead: details?.integer('cached_tokens') ?? 0,
    cacheWrite: details?.integer('cache_write_tokens') ?? 0,
    output: u.integer('output_tokens') ?? 0,
    reasoning: u.child('output_tokens_details')?.integer('reasoning_tokens') ?? 0,
  );
}

/// [prompt] is the whole prompt; [cacheRead] and [cacheWrite] are subsets.
/// A server reporting inconsistent numbers can never produce a negative
/// input or a cache write larger than the uncached part.
Usage _usage({
  required int prompt,
  required int cacheRead,
  required int cacheWrite,
  required int output,
  required int reasoning,
}) {
  final read = cacheRead < 0 ? 0 : cacheRead;
  final uncached = prompt - read < 0 ? 0 : prompt - read;
  return Usage(
    inputTokens: uncached,
    outputTokens: output,
    cacheReadTokens: read,
    cacheWriteTokens: cacheWrite < 0 ? 0 : (cacheWrite > uncached ? uncached : cacheWrite),
    reasoningTokens: reasoning,
  );
}

/// llama.cpp (and recent Ollama) `timings` → [PerfSample].
PerfSample? parseTimings(JsonMap t, {String? backend}) {
  final promptN = t.integer('prompt_n');
  final cacheN = t.integer('cache_n');
  final prefill = t.number('prompt_per_second');
  final decode = t.number('predicted_per_second');
  if (promptN == null && prefill == null && decode == null) return null;
  final draftN = t.integer('draft_n');
  final accepted = t.integer('draft_n_accepted');
  return PerfSample(
    prefillTokensPerSec: prefill,
    decodeTokensPerSec: decode,
    promptTokens: promptN == null ? null : promptN + (cacheN ?? 0),
    cachedPromptTokens: cacheN,
    draftAcceptRate: draftN != null && draftN > 0 && accepted != null ? accepted / draftN : null,
    backend: backend,
  );
}
