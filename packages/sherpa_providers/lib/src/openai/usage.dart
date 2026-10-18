import 'package:sherpa_core/sherpa_core.dart';

import '../common/json_read.dart';

/// Chat Completions `usage` → [Usage].
///
/// Sherpa's [Usage] follows Anthropic's convention: [Usage.inputTokens]
/// excludes cache reads and writes, so `input + cacheRead + cacheWrite` is
/// the prompt size (the agent loop calibrates its estimator on
/// `input + cacheRead`). OpenAI's `prompt_tokens` includes cached tokens,
/// so they are subtracted. Every `*_details` field is optional (llama.cpp
/// sends only `cached_tokens`; Ollama sends it when set) (R10 §3.3).
Usage parseChatUsage(JsonMap u) {
  final prompt = u.integer('prompt_tokens') ?? 0;
  final promptDetails = u.child('prompt_tokens_details');
  final cached = promptDetails?.integer('cached_tokens') ?? 0;
  final cacheWrite = promptDetails?.integer('cache_write_tokens') ?? 0;
  final reasoning = u.child('completion_tokens_details')?.integer('reasoning_tokens') ?? 0;
  final uncached = prompt - cached - cacheWrite;
  return Usage(
    inputTokens: uncached < 0 ? 0 : uncached,
    outputTokens: u.integer('completion_tokens') ?? 0,
    cacheReadTokens: cached,
    cacheWriteTokens: cacheWrite,
    reasoningTokens: reasoning,
  );
}

/// Responses `response.usage` → [Usage] (same convention as
/// [parseChatUsage]; `input_tokens` includes cached tokens).
Usage parseResponsesUsage(JsonMap u) {
  final input = u.integer('input_tokens') ?? 0;
  final details = u.child('input_tokens_details');
  final cached = details?.integer('cached_tokens') ?? 0;
  final cacheWrite = details?.integer('cache_write_tokens') ?? 0;
  final uncached = input - cached - cacheWrite;
  return Usage(
    inputTokens: uncached < 0 ? 0 : uncached,
    outputTokens: u.integer('output_tokens') ?? 0,
    cacheReadTokens: cached,
    cacheWriteTokens: cacheWrite,
    reasoningTokens: u.child('output_tokens_details')?.integer('reasoning_tokens') ?? 0,
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
