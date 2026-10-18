import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

/// A bundled capability entry for a model whose API does not report one.
@immutable
final class KnownModel {
  const KnownModel({
    required this.contextLength,
    required this.maxOutputTokens,
    this.vision = true,
    this.reasoning = ReasoningSupport.none,
    this.chatTools = true,
  });

  final int contextLength;
  final int maxOutputTokens;
  final bool vision;
  final ReasoningSupport reasoning;

  /// False where OpenAI only offers tool calling over Responses (R10 §3.6:
  /// "GPT-6 Astra and GPT-6.1 Sol support Chat Completions, but tool calling
  /// requires Responses").
  final bool chatTools;

  ModelCapabilities capabilities({required bool forChat}) => ModelCapabilities(
        contextLength: contextLength,
        maxOutputTokens: maxOutputTokens,
        toolCallFormat: forChat && !chatTools ? ToolCallFormat.none : ToolCallFormat.native,
        vision: vision,
        reasoning: reasoning,
        supportsPromptCache: true,
      );
}

/// OpenAI's `/v1/models` has no context field, so first-party windows come
/// from model pages (R10 §6). `gpt-6-astra` is from the 2026-10-18 model
/// page; the older entries are long-published values not re-verified in
/// R10. Unknown ids fall back to overrides or [ModelCapabilities.unknown].
const Map<String, KnownModel> openAiKnownModels = {
  'gpt-6-astra': KnownModel(
      contextLength: 1050000, maxOutputTokens: 128000, reasoning: ReasoningSupport.always, chatTools: false),
  'gpt-5': KnownModel(contextLength: 400000, maxOutputTokens: 128000, reasoning: ReasoningSupport.optional),
  'gpt-5-mini': KnownModel(contextLength: 400000, maxOutputTokens: 128000, reasoning: ReasoningSupport.optional),
  'gpt-5-nano': KnownModel(contextLength: 400000, maxOutputTokens: 128000, reasoning: ReasoningSupport.optional),
  'gpt-4.1': KnownModel(contextLength: 1047576, maxOutputTokens: 32768),
  'gpt-4.1-mini': KnownModel(contextLength: 1047576, maxOutputTokens: 32768),
  'gpt-4.1-nano': KnownModel(contextLength: 1047576, maxOutputTokens: 32768),
  'gpt-4o': KnownModel(contextLength: 128000, maxOutputTokens: 16384),
  'gpt-4o-mini': KnownModel(contextLength: 128000, maxOutputTokens: 16384),
  'o3': KnownModel(contextLength: 200000, maxOutputTokens: 100000, reasoning: ReasoningSupport.always),
  'o3-mini': KnownModel(
      contextLength: 200000, maxOutputTokens: 100000, reasoning: ReasoningSupport.always, vision: false),
  'o4-mini': KnownModel(contextLength: 200000, maxOutputTokens: 100000, reasoning: ReasoningSupport.always),
};

/// The entry for [modelId]: an exact match, else the longest key that is a
/// dash-separated prefix (dated snapshots such as `gpt-4o-2024-08-06`).
/// Other variants (`gpt-5.4`, `gpt-6-luna`) are not guessed at.
KnownModel? lookupKnownModel(String modelId) {
  final id = modelId.toLowerCase();
  final exact = openAiKnownModels[id];
  if (exact != null) return exact;
  String? best;
  for (final key in openAiKnownModels.keys) {
    if (id.startsWith('$key-') && (best == null || key.length > best.length)) best = key;
  }
  return best == null ? null : openAiKnownModels[best];
}
