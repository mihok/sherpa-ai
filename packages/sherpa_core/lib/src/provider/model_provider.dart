import 'package:meta/meta.dart';

import '../common/cancellation.dart';
import '../common/json.dart';
import '../model/message.dart';
import '../model/tool.dart';
import 'capabilities.dart';
import 'model_event.dart';

enum ProviderKind { localLlamaCpp, localMlx, localLiteRt, localSystem, openAiCompatible, anthropic, fake }

@immutable
final class ProviderInfo {
  const ProviderInfo({
    required this.id,
    required this.kind,
    required this.displayName,
    required this.location,
    this.baseUrl,
  });

  final String id;
  final ProviderKind kind;
  final String displayName;
  final ExecutionLocation location;
  final Uri? baseUrl;

  /// True whenever prompts leave the device (drives the privacy indicator).
  bool get dataLeavesDevice => location != ExecutionLocation.onDevice;
}

sealed class ToolChoice {
  const ToolChoice();
  static const auto = ToolChoiceAuto();
  static const none = ToolChoiceNone();
  static const required = ToolChoiceRequired();
}

final class ToolChoiceAuto extends ToolChoice {
  const ToolChoiceAuto();
}

final class ToolChoiceNone extends ToolChoice {
  const ToolChoiceNone();
}

final class ToolChoiceRequired extends ToolChoice {
  const ToolChoiceRequired();
}

final class ToolChoiceSpecific extends ToolChoice {
  const ToolChoiceSpecific(this.name);
  final String name;
}

/// Reasoning effort request. Providers map it to their own knobs
/// (Anthropic `output_config.effort`, OpenAI `reasoning.effort`, the
/// `enable_thinking` template switch for local models).
enum ReasoningEffort { off, low, medium, high }

@immutable
final class GenerationParams {
  const GenerationParams({
    this.temperature,
    this.topP,
    this.topK,
    this.minP,
    this.repeatPenalty,
    this.maxOutputTokens,
    this.stop = const [],
    this.seed,
    this.reasoning,
    this.toolChoice = ToolChoice.auto,
    this.parallelToolCalls = true,
    this.jsonSchema,
    this.extra = const {},
  });

  factory GenerationParams.fromJson(JsonMap j) => GenerationParams(
        temperature: j.optDouble('temperature'),
        topP: j.optDouble('topP'),
        topK: j.optInt('topK'),
        minP: j.optDouble('minP'),
        repeatPenalty: j.optDouble('repeatPenalty'),
        maxOutputTokens: j.optInt('maxOutputTokens'),
        stop: (j.opt<List<Object?>>('stop') ?? const []).cast<String>(),
        seed: j.optInt('seed'),
        reasoning: j.opt<String>('reasoning') == null
            ? null
            : ReasoningEffort.values.byName(j.req<String>('reasoning')),
        parallelToolCalls: j.opt<bool>('parallelToolCalls') ?? true,
        extra: j.optObj('extra') ?? const {},
      );

  final double? temperature;
  final double? topP;
  final int? topK;
  final double? minP;
  final double? repeatPenalty;
  final int? maxOutputTokens;
  final List<String> stop;
  final int? seed;
  final ReasoningEffort? reasoning;
  final ToolChoice toolChoice;
  final bool parallelToolCalls;

  /// Constrain the final answer to this JSON schema (structured output).
  final JsonMap? jsonSchema;

  /// Provider-specific passthrough (merged into the request body last).
  final JsonMap extra;

  GenerationParams copyWith({
    int? maxOutputTokens,
    ToolChoice? toolChoice,
    ReasoningEffort? reasoning,
    double? temperature,
  }) =>
      GenerationParams(
        temperature: temperature ?? this.temperature,
        topP: topP,
        topK: topK,
        minP: minP,
        repeatPenalty: repeatPenalty,
        maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
        stop: stop,
        seed: seed,
        reasoning: reasoning ?? this.reasoning,
        toolChoice: toolChoice ?? this.toolChoice,
        parallelToolCalls: parallelToolCalls,
        jsonSchema: jsonSchema,
        extra: extra,
      );

  JsonMap toJson() => compact({
        'temperature': temperature,
        'topP': topP,
        'topK': topK,
        'minP': minP,
        'repeatPenalty': repeatPenalty,
        'maxOutputTokens': maxOutputTokens,
        'stop': stop.isEmpty ? null : stop,
        'seed': seed,
        'reasoning': reasoning?.name,
        'parallelToolCalls': parallelToolCalls ? null : false,
        'extra': extra.isEmpty ? null : extra,
      });
}

/// Hints that let local runtimes reuse KV state and remote APIs place
/// cache breakpoints. [stablePrefixMessages] counts leading messages that
/// are identical to the previous request (system prompt, tool schemas,
/// compacted summary).
@immutable
final class CacheHints {
  const CacheHints({this.sessionId, this.stablePrefixMessages = 0});
  final String? sessionId;
  final int stablePrefixMessages;
}

@immutable
final class ModelRequest {
  const ModelRequest({
    required this.modelId,
    required this.messages,
    this.systemPrompt,
    this.tools = const [],
    this.params = const GenerationParams(),
    this.cache = const CacheHints(),
  });

  final String modelId;

  /// Rendered separately because providers place it differently
  /// (Anthropic `system`, OpenAI first message, local chat template).
  final String? systemPrompt;
  final List<Message> messages;
  final List<ToolDefinition> tools;
  final GenerationParams params;
  final CacheHints cache;
}

/// The single abstraction over every model backend.
///
/// Contract:
/// * The returned stream is single-subscription and cold: work starts on
///   listen. Cancelling the subscription or [cancel] aborts the underlying
///   HTTP request or native decode and frees compute promptly.
/// * Pausing the subscription applies backpressure (the provider stops
///   reading the socket / stops decoding when its buffer fills).
/// * Ends with exactly one [Finish] on success; failures are delivered as a
///   [ProviderException] stream error. Cancellation ends the stream with
///   `Finish(FinishReason.cancelled)` rather than an error.
/// * Parallel tool calls are reported with distinct indexes.
abstract interface class ModelProvider {
  ProviderInfo get info;

  Future<List<ModelDescriptor>> listModels();

  Future<ModelCapabilities> capabilities(String modelId);

  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel});
}

/// Exact or estimated token counting. Local providers implement it with the
/// model's real tokenizer; others fall back to a calibrated estimator.
abstract interface class TokenCounter {
  /// True when counts come from the model's own tokenizer.
  bool get isExact;

  int countText(String text);

  int countMessage(Message message);

  int countTools(List<ToolDefinition> tools);
}

enum ProviderErrorKind {
  network,
  timeout,
  auth,
  rateLimited,

  /// Spend cap / insufficient quota: a 429 that must NOT be retried.
  quotaExceeded,
  contextOverflow,
  invalidRequest,
  server,
  overloaded,
  modelNotFound,
  outOfMemory,
  engineCrashed,
  unsupported,
  unknown,
}

final class ProviderException implements Exception {
  const ProviderException(
    this.kind,
    this.message, {
    this.statusCode,
    this.retryAfter,
    this.providerId,
    this.cause,
  });

  final ProviderErrorKind kind;
  final String message;
  final int? statusCode;
  final Duration? retryAfter;
  final String? providerId;
  final Object? cause;

  bool get isRetryable => switch (kind) {
        ProviderErrorKind.network ||
        ProviderErrorKind.timeout ||
        ProviderErrorKind.rateLimited ||
        ProviderErrorKind.server ||
        ProviderErrorKind.overloaded ||
        ProviderErrorKind.engineCrashed =>
          true,
        _ => false,
      };

  @override
  String toString() =>
      'ProviderException(${kind.name}${statusCode == null ? '' : ' $statusCode'}): $message';
}
