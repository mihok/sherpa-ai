import 'package:meta/meta.dart';

import '../common/openai_messages.dart';
import '../config.dart';
import 'known_models.dart';

/// How much of `tool_choice` a server honours.
enum ToolChoiceSupport {
  /// `none`/`auto`/`required` and the named-function object.
  full,

  /// String forms only. llama.cpp silently ignores the object form and
  /// falls back to `auto` (R10 §0.6), so a named choice is downgraded to
  /// `required` and announced.
  stringOnly,

  /// `auto` and `none` only (conservative default for unknown servers).
  basic,

  /// Not accepted at all (Ollama `/v1`): the field is omitted.
  none,
}

/// Which request field caps the output length.
enum MaxTokensField {
  maxTokens,

  /// OpenAI's replacement; includes reasoning tokens and is the only form
  /// reasoning models accept.
  maxCompletionTokens,
}

/// How the server learns about context length (R10 §6).
enum ContextDiscovery {
  /// No API field: bundled table of known model ids (OpenAI).
  staticTable,

  /// `GET /props` → `default_generation_settings.n_ctx` (per slot).
  llamaCppProps,

  /// `POST /api/show` + `GET /api/ps`.
  ollamaShow,

  /// `GET /api/v1/models` (`loaded_instances[].config.context_length`,
  /// `max_context_length`), falling back to `/api/v0/models`.
  lmStudioModels,

  /// `GET /v1/models` → `max_model_len`.
  vllmModels,

  /// `GET /api/v1/models` → `context_length`, `top_provider`.
  openRouterModels,

  /// `GET /v1/models` → `providers[].context_length`.
  huggingFaceModels,

  /// Nothing to ask; use overrides or the conservative default.
  none,
}

/// How a reasoning-effort request is expressed.
enum EffortStyle {
  /// Not sent (the server's support is unknown); a notice is emitted.
  unsupported,

  /// Top-level `reasoning_effort` (`none` disables thinking).
  reasoningEffort,

  /// OpenRouter `reasoning: {effort}`.
  openRouterObject,

  /// DeepSeek `thinking: {type}` plus `reasoning_effort: low|high`.
  deepSeekThinking,
}

/// Whether a server takes PDFs as file content parts (Chat Completions
/// `{type: file, file: {filename, file_data}}`, Responses `input_file`).
enum PdfInputSupport {
  /// Never: the PDF is left out with a notice instead of earning a 400.
  /// llama.cpp's server rejects any part other than text, image_url,
  /// input_audio and video ("unsupported content[].type",
  /// tools/server/server-common.cpp:1199 at the pinned commit; its Responses
  /// shim says "'input_file' is not supported by llamacpp"). Ollama, vLLM,
  /// LM Studio, DeepSeek and the HF router document no file part, and an
  /// unknown server gets the conservative choice.
  none,

  /// OpenAI: "models with vision capabilities, such as gpt-4o and later"
  /// (developers.openai.com/api/docs/guides/pdf-files), per
  /// [openAiModelTakesPdf].
  openAiModels,

  /// Every model: OpenRouter "works on any model" (native file input, else
  /// its file-parser plugin, which may bill OCR for scans). The capability
  /// still comes from the model list (`input_modalities` has `file`), so the
  /// app only offers PDFs to models that read them natively.
  all,
}

/// Per-server differences behind the OpenAI Chat Completions wire format,
/// captured from R10 §2 and §4. Anything marked UNVERIFIED in the digest
/// gets the conservative choice here.
@immutable
final class ServerQuirks {
  const ServerQuirks({
    required this.profile,
    this.reasoningReplay = ReasoningReplay.none,
    this.replayReasoningOnlyWithTools = false,
    this.toolChoice = ToolChoiceSupport.basic,
    this.maxTokensField = MaxTokensField.maxTokens,
    this.includeUsage = true,
    this.disableObfuscation = false,
    this.sendParallelToolCalls = false,
    this.contextDiscovery = ContextDiscovery.none,
    this.effort = EffortStyle.unsupported,
    this.splitThinkTags = false,
    this.promptCacheKey = false,
    this.topKField,
    this.minPField,
    this.repeatPenaltyField,
    this.pdfInput = PdfInputSupport.none,
  });

  final ServerProfile profile;

  /// Field used to pass this server's own reasoning back on earlier turns.
  final ReasoningReplay reasoningReplay;

  /// DeepSeek needs reasoning back only when `tools` are present (and
  /// ignores it otherwise), so don't spend the bytes without tools. The
  /// [ReasoningReplay.asReceived] profiles follow the same rule, since tool
  /// loops are where a server requires it (DeepSeek, R10 §4.6).
  final bool replayReasoningOnlyWithTools;
  final ToolChoiceSupport toolChoice;
  final MaxTokensField maxTokensField;

  /// Send `stream_options.include_usage` (a server that rejects it is
  /// retried once without it, and remembered).
  final bool includeUsage;

  /// OpenAI pads every chunk with an `obfuscation` string unless told not
  /// to; other servers may reject the unknown option.
  final bool disableObfuscation;

  /// Whether `parallel_tool_calls: false` is understood. Only `false` is
  /// ever sent: `true` is the default where supported, and llama.cpp picks
  /// its default from the chat template's capabilities, which is the right
  /// call for small models (R11 §9.6.2).
  final bool sendParallelToolCalls;
  final ContextDiscovery contextDiscovery;
  final EffortStyle effort;

  /// Route a leading `<think>…</think>` in content to reasoning.
  final bool splitThinkTags;

  /// Send `prompt_cache_key` derived from the session (OpenAI).
  final bool promptCacheKey;

  /// Request field names for samplers outside the OpenAI set; null means
  /// the server does not take it and the value is dropped with a notice.
  final String? topKField;
  final String? minPField;
  final String? repeatPenaltyField;

  /// Which models may receive PDF file parts.
  final PdfInputSupport pdfInput;

  /// Why [modelId] on this server cannot be sent a PDF, or null when it can.
  String? pdfRefusal(String modelId) => switch (pdfInput) {
        PdfInputSupport.none => '${_serverName(profile)} does not accept PDF file parts',
        PdfInputSupport.openAiModels => openAiModelTakesPdf(modelId)
            ? null
            : '$modelId does not read PDFs (OpenAI reads them on vision models, gpt-4o and later)',
        PdfInputSupport.all => null,
      };

  static String _serverName(ServerProfile p) => switch (p) {
        ServerProfile.openAi => 'OpenAI',
        ServerProfile.llamaCpp => 'A llama.cpp server',
        ServerProfile.ollama => 'Ollama',
        ServerProfile.lmStudio => 'LM Studio',
        ServerProfile.vllm => 'vLLM',
        ServerProfile.openRouter => 'OpenRouter',
        ServerProfile.deepSeek => 'DeepSeek',
        ServerProfile.huggingFaceRouter => 'The Hugging Face router',
        ServerProfile.generic || ServerProfile.auto => 'This server',
      };

  /// The quirks for [profile]. [ServerProfile.auto] (not yet detected)
  /// gets the generic set.
  static ServerQuirks of(ServerProfile profile) => _table[profile] ?? _table[ServerProfile.generic]!;

  static const Map<ServerProfile, ServerQuirks> _table = {
    ServerProfile.openAi: ServerQuirks(
      profile: ServerProfile.openAi,
      toolChoice: ToolChoiceSupport.full,
      maxTokensField: MaxTokensField.maxCompletionTokens,
      disableObfuscation: true,
      sendParallelToolCalls: true,
      contextDiscovery: ContextDiscovery.staticTable,
      effort: EffortStyle.reasoningEffort,
      promptCacheKey: true,
      pdfInput: PdfInputSupport.openAiModels,
    ),
    ServerProfile.llamaCpp: ServerQuirks(
      profile: ServerProfile.llamaCpp,
      reasoningReplay: ReasoningReplay.reasoningContent,
      toolChoice: ToolChoiceSupport.stringOnly,
      sendParallelToolCalls: true,
      contextDiscovery: ContextDiscovery.llamaCppProps,
      effort: EffortStyle.reasoningEffort,
      splitThinkTags: true,
      topKField: 'top_k',
      minPField: 'min_p',
      repeatPenaltyField: 'repeat_penalty',
    ),
    ServerProfile.ollama: ServerQuirks(
      profile: ServerProfile.ollama,
      reasoningReplay: ReasoningReplay.reasoning,
      toolChoice: ToolChoiceSupport.none,
      contextDiscovery: ContextDiscovery.ollamaShow,
      effort: EffortStyle.reasoningEffort,
      splitThinkTags: true,
    ),
    // LM Studio: reasoning_effort support is UNVERIFIED; `required` is
    // documented as "llama.cpp engine only". Its reasoning field depends on
    // the model and a setting (R10 §2), so reasoning goes back in the field
    // it came in.
    ServerProfile.lmStudio: ServerQuirks(
      profile: ServerProfile.lmStudio,
      reasoningReplay: ReasoningReplay.asReceived,
      replayReasoningOnlyWithTools: true,
      toolChoice: ToolChoiceSupport.stringOnly,
      contextDiscovery: ContextDiscovery.lmStudioModels,
      splitThinkTags: true,
      topKField: 'top_k',
      minPField: 'min_p',
      repeatPenaltyField: 'repeat_penalty',
    ),
    ServerProfile.vllm: ServerQuirks(
      profile: ServerProfile.vllm,
      reasoningReplay: ReasoningReplay.reasoning,
      toolChoice: ToolChoiceSupport.full,
      maxTokensField: MaxTokensField.maxCompletionTokens,
      sendParallelToolCalls: true,
      contextDiscovery: ContextDiscovery.vllmModels,
      effort: EffortStyle.reasoningEffort,
      splitThinkTags: true,
      topKField: 'top_k',
      minPField: 'min_p',
      repeatPenaltyField: 'repetition_penalty',
    ),
    // OpenRouter: tool_choice support is provider-dependent (UNVERIFIED);
    // the OpenAI forms are passed through and the upstream decides.
    ServerProfile.openRouter: ServerQuirks(
      profile: ServerProfile.openRouter,
      reasoningReplay: ReasoningReplay.reasoningDetails,
      toolChoice: ToolChoiceSupport.full,
      sendParallelToolCalls: true,
      contextDiscovery: ContextDiscovery.openRouterModels,
      effort: EffortStyle.openRouterObject,
      topKField: 'top_k',
      minPField: 'min_p',
      repeatPenaltyField: 'repetition_penalty',
      pdfInput: PdfInputSupport.all,
    ),
    // DeepSeek: only the reasoning replay rule is verified; tool_choice,
    // max-tokens field and usage options follow the OpenAI shape it
    // documents for its compat API (UNVERIFIED in R10), with fallbacks.
    ServerProfile.deepSeek: ServerQuirks(
      profile: ServerProfile.deepSeek,
      reasoningReplay: ReasoningReplay.reasoningContent,
      replayReasoningOnlyWithTools: true,
      toolChoice: ToolChoiceSupport.stringOnly,
      effort: EffortStyle.deepSeekThinking,
    ),
    // HF router: parameters depend on the selected inference provider
    // (UNVERIFIED), so stay with the most common subset.
    ServerProfile.huggingFaceRouter: ServerQuirks(
      profile: ServerProfile.huggingFaceRouter,
      reasoningReplay: ReasoningReplay.asReceived,
      replayReasoningOnlyWithTools: true,
      contextDiscovery: ContextDiscovery.huggingFaceModels,
      splitThinkTags: true,
    ),
    // Unknown server: R10 §5 conservative defaults. Reasoning is written
    // back in the field it arrived in (R10 §0.4), so DeepSeek or OpenRouter
    // behind a gateway keep working in tool loops.
    ServerProfile.generic: ServerQuirks(
      profile: ServerProfile.generic,
      reasoningReplay: ReasoningReplay.asReceived,
      replayReasoningOnlyWithTools: true,
      splitThinkTags: true,
    ),
  };
}
