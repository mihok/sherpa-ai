import 'package:meta/meta.dart';

import '../common/json.dart';

/// How a model emits tool calls, which decides how the provider asks for
/// them and how strictly it must parse.
enum ToolCallFormat {
  /// The API returns structured tool calls (OpenAI tools, Anthropic tool_use).
  native,

  /// Local runtime constrains sampling with a grammar/JSON schema built from
  /// the chat template's tool-call syntax (llama.cpp lazy grammar).
  jsonGrammar,

  /// Tools described in the prompt; output parsed with parse-and-repair.
  prompted,

  /// The model cannot call tools at all.
  none,
}

enum ReasoningSupport { none, optional, always }

/// Where inference physically happens. Drives the "data leaves device"
/// indicator and the privacy dashboard.
enum ExecutionLocation { onDevice, localNetwork, remote }

/// Capability descriptor for one model on one provider. Local values come
/// from GGUF/MLX metadata and the device-fit engine; remote values from the
/// server's model list or user overrides.
@immutable
final class ModelCapabilities {
  const ModelCapabilities({
    required this.contextLength,
    this.maxOutputTokens,
    this.toolCallFormat = ToolCallFormat.native,
    this.parallelToolCalls = true,
    this.vision = false,
    this.audioInput = false,
    this.reasoning = ReasoningSupport.none,
    this.quantization,
    this.parameterCount,
    this.ramEstimateBytes,
    this.tokenizerFamily,
    this.supportsSystemRole = true,
    this.supportsPromptCache = false,
  });

  factory ModelCapabilities.fromJson(JsonMap j) => ModelCapabilities(
        contextLength: j.optInt('contextLength') ?? 4096,
        maxOutputTokens: j.optInt('maxOutputTokens'),
        toolCallFormat:
            ToolCallFormat.values.byName(j.opt<String>('toolCallFormat') ?? 'native'),
        parallelToolCalls: j.opt<bool>('parallelToolCalls') ?? true,
        vision: j.opt<bool>('vision') ?? false,
        audioInput: j.opt<bool>('audioInput') ?? false,
        reasoning: ReasoningSupport.values.byName(j.opt<String>('reasoning') ?? 'none'),
        quantization: j.opt<String>('quantization'),
        parameterCount: j.optInt('parameterCount'),
        ramEstimateBytes: j.optInt('ramEstimateBytes'),
        tokenizerFamily: j.opt<String>('tokenizerFamily'),
        supportsSystemRole: j.opt<bool>('supportsSystemRole') ?? true,
        supportsPromptCache: j.opt<bool>('supportsPromptCache') ?? false,
      );

  /// Conservative default for unknown remote models.
  static const unknown = ModelCapabilities(contextLength: 8192);

  final int contextLength;
  final int? maxOutputTokens;
  final ToolCallFormat toolCallFormat;
  final bool parallelToolCalls;
  final bool vision;
  final bool audioInput;
  final ReasoningSupport reasoning;
  final String? quantization;
  final int? parameterCount;
  final int? ramEstimateBytes;

  /// Used by the token estimator to pick a calibrated chars/token ratio.
  final String? tokenizerFamily;
  final bool supportsSystemRole;
  final bool supportsPromptCache;

  bool get canCallTools => toolCallFormat != ToolCallFormat.none;

  ModelCapabilities copyWith({
    int? contextLength,
    int? maxOutputTokens,
    ToolCallFormat? toolCallFormat,
    bool? vision,
    ReasoningSupport? reasoning,
  }) =>
      ModelCapabilities(
        contextLength: contextLength ?? this.contextLength,
        maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
        toolCallFormat: toolCallFormat ?? this.toolCallFormat,
        parallelToolCalls: parallelToolCalls,
        vision: vision ?? this.vision,
        audioInput: audioInput,
        reasoning: reasoning ?? this.reasoning,
        quantization: quantization,
        parameterCount: parameterCount,
        ramEstimateBytes: ramEstimateBytes,
        tokenizerFamily: tokenizerFamily,
        supportsSystemRole: supportsSystemRole,
        supportsPromptCache: supportsPromptCache,
      );

  JsonMap toJson() => compact({
        'contextLength': contextLength,
        'maxOutputTokens': maxOutputTokens,
        'toolCallFormat': toolCallFormat.name,
        'parallelToolCalls': parallelToolCalls,
        'vision': vision,
        'audioInput': audioInput,
        'reasoning': reasoning.name,
        'quantization': quantization,
        'parameterCount': parameterCount,
        'ramEstimateBytes': ramEstimateBytes,
        'tokenizerFamily': tokenizerFamily,
        'supportsSystemRole': supportsSystemRole,
        'supportsPromptCache': supportsPromptCache,
      });
}

/// A model a provider can serve.
@immutable
final class ModelDescriptor {
  const ModelDescriptor({
    required this.id,
    required this.providerId,
    required this.displayName,
    required this.capabilities,
    this.description,
  });

  factory ModelDescriptor.fromJson(JsonMap j) => ModelDescriptor(
        id: j.req<String>('id'),
        providerId: j.req<String>('providerId'),
        displayName: j.opt<String>('displayName') ?? j.req<String>('id'),
        capabilities: ModelCapabilities.fromJson(j.optObj('capabilities') ?? const {}),
        description: j.opt<String>('description'),
      );

  final String id;
  final String providerId;
  final String displayName;
  final ModelCapabilities capabilities;
  final String? description;

  JsonMap toJson() => compact({
        'id': id,
        'providerId': providerId,
        'displayName': displayName,
        'capabilities': capabilities.toJson(),
        'description': description,
      });
}
