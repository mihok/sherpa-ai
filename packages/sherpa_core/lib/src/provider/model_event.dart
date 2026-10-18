import 'package:meta/meta.dart';

import '../model/message.dart';
import '../model/tool.dart';

/// Why generation stopped, normalized across providers.
enum FinishReason {
  stop,
  toolCalls,
  length,
  contentFilter,

  /// Remote server paused a long turn (Anthropic `pause_turn`); continue it.
  pause,
  refusal,
  contextOverflow,
  cancelled,
  error,
}

/// Events emitted by [ModelProvider.stream]. Text and reasoning arrive as
/// deltas; tool calls arrive as partial fragments (for live UI) and then as
/// one [ToolCallComplete] per call with parsed, repaired arguments.
@immutable
sealed class ModelEvent {
  const ModelEvent();
}

final class TextDelta extends ModelEvent {
  const TextDelta(this.text);
  final String text;
}

final class ReasoningDelta extends ModelEvent {
  const ReasoningDelta(this.text);
  final String text;
}

/// Opaque reasoning metadata (signature or redacted payload) that must be
/// stored on the reasoning part and echoed back to the same provider.
final class ReasoningSignature extends ModelEvent {
  const ReasoningSignature({this.signature, this.redactedData});
  final String? signature;
  final String? redactedData;
}

/// A new tool call began streaming. [index] orders parallel calls.
final class ToolCallStart extends ModelEvent {
  const ToolCallStart({required this.index, required this.id, required this.name});
  final int index;
  final String id;
  final String name;
}

/// A fragment of a tool call's JSON arguments.
final class ToolCallArgsDelta extends ModelEvent {
  const ToolCallArgsDelta({required this.index, required this.fragment});
  final int index;
  final String fragment;
}

final class ToolCallComplete extends ModelEvent {
  const ToolCallComplete({required this.index, required this.call});
  final int index;
  final ToolCall call;
}

final class UsageUpdate extends ModelEvent {
  const UsageUpdate(this.usage);
  final Usage usage;
}

/// Non-fatal information worth surfacing (e.g. "repaired malformed JSON",
/// "speculative decoding disabled", "prompt cache hit 1532 tokens").
final class ProviderNotice extends ModelEvent {
  const ProviderNotice(this.code, this.message, {this.data = const {}});
  final String code;
  final String message;
  final Map<String, Object?> data;
}

/// Local-runtime performance sample for the perf lab and budgets.
final class PerfSample extends ModelEvent {
  const PerfSample({
    this.timeToFirstTokenMs,
    this.prefillTokensPerSec,
    this.decodeTokensPerSec,
    this.promptTokens,
    this.cachedPromptTokens,
    this.draftAcceptRate,
    this.backend,
  });
  final double? timeToFirstTokenMs;
  final double? prefillTokensPerSec;
  final double? decodeTokensPerSec;
  final int? promptTokens;
  final int? cachedPromptTokens;
  final double? draftAcceptRate;
  final String? backend;
}

/// Always the last event of a successful stream.
final class Finish extends ModelEvent {
  const Finish(this.reason, {this.rawReason});
  final FinishReason reason;
  final String? rawReason;
}
