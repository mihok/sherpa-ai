import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';

import '../engine/engine_types.dart';
import '../ffi/bindings.dart';

/// Maps engine status codes to the core's error kinds.
///
/// `SE_ERR_OOM` and `SE_ERR_CONTEXT_CREATE` (in practice: KV or compute
/// buffers did not fit) are [ProviderErrorKind.outOfMemory];
/// `SE_ERR_CONTEXT_FULL` (the prompt does not fit into n_ctx) is
/// [ProviderErrorKind.contextOverflow], which the context manager answers by
/// compacting; template/grammar/parse/argument errors are requests this
/// model cannot serve.
ProviderErrorKind errorKindFor(int status) => switch (status) {
      SeStatus.oom || SeStatus.contextCreate => ProviderErrorKind.outOfMemory,
      SeStatus.contextFull => ProviderErrorKind.contextOverflow,
      SeStatus.invalidArg || SeStatus.template || SeStatus.grammar || SeStatus.parse => ProviderErrorKind.invalidRequest,
      SeStatus.unsupported => ProviderErrorKind.unsupported,
      SeStatus.io || SeStatus.modelLoad => ProviderErrorKind.modelNotFound,
      SeStatus.busy => ProviderErrorKind.overloaded,
      SeStatus.decode => ProviderErrorKind.server,
      SeStatus.timeout => ProviderErrorKind.timeout,
      _ => ProviderErrorKind.unknown,
    };

/// Converts any failure from the engine layer into a [ProviderException].
ProviderException providerErrorFor(Object error, {required String providerId}) => switch (error) {
      ProviderException() => error,
      EngineException(:final code, :final message) =>
        ProviderException(errorKindFor(code), message, providerId: providerId, cause: error),
      EngineCrashedException(:final message) => ProviderException(ProviderErrorKind.engineCrashed,
          'The on-device engine stopped unexpectedly ($message); it is restarting.',
          providerId: providerId, cause: error),
      StaleHandleException() => ProviderException(
          ProviderErrorKind.engineCrashed, 'The on-device engine restarted; the model is being reloaded.',
          providerId: providerId, cause: error),
      _ => ProviderException(ProviderErrorKind.unknown, '$error', providerId: providerId, cause: error),
    };

/// Stateful translation of one generation's [EngineEvent]s into
/// [ModelEvent]s.
///
/// * USAGE becomes [UsageUpdate] with the core's normalization
///   (`inputTokens` = uncached prompt tokens, `cacheReadTokens` = prompt
///   tokens served from the KV cache, so the full prompt is their sum).
/// * PERF becomes [PerfSample] (with the prompt/cached counts of USAGE).
/// * TOOL_CALL_DONE becomes [ToolCallComplete] with parsed arguments; the
///   lazy grammar normally guarantees valid JSON, otherwise the core's
///   repair runs and the call is marked `repaired` (which forces approval of
///   non-read-only tools, R11 §9.6.7).
/// * FINISH maps to exactly one [Finish]; FINISH(error) after ERROR becomes
///   a [ProviderException] stream error instead.
final class EngineEventMapper {
  EngineEventMapper({required this.providerId});

  final String providerId;
  EngineEvent? _error;
  Usage? _usage;
  int _prompt = 0;
  int _cached = 0;
  bool _finished = false;

  bool get finished => _finished;

  /// The usage reported for this generation, if any.
  Usage? get usage => _usage;

  /// Events to emit for [e]. Throws [ProviderException] for FINISH(error).
  List<ModelEvent> map(EngineEvent e) {
    switch (e.type) {
      case EngineEventType.textDelta:
        return e.text.isEmpty ? const [] : [TextDelta(e.text)];
      case EngineEventType.reasoningDelta:
        return e.text.isEmpty ? const [] : [ReasoningDelta(e.text)];
      case EngineEventType.toolCallStart:
        return [ToolCallStart(index: e.index, id: e.id, name: e.name)];
      case EngineEventType.toolCallArgsDelta:
        return [ToolCallArgsDelta(index: e.index, fragment: e.text)];
      case EngineEventType.toolCallDone:
        return [ToolCallComplete(index: e.index, call: parseToolCall(e.id, e.name, e.text))];
      case EngineEventType.usage:
        _prompt = e.promptTokens;
        _cached = e.cachedTokens;
        final u = Usage(
          inputTokens: e.promptTokens - e.cachedTokens,
          outputTokens: e.completionTokens,
          cacheReadTokens: e.cachedTokens,
        );
        _usage = u;
        return [UsageUpdate(u)];
      case EngineEventType.perf:
        return [
          PerfSample(
            timeToFirstTokenMs: e.ttftMs,
            prefillTokensPerSec: e.prefillTps,
            decodeTokensPerSec: e.decodeTps,
            promptTokens: _prompt,
            cachedPromptTokens: _cached,
            draftAcceptRate: e.nDrafted > 0 ? e.draftAcceptRate : null,
            backend: e.name.isEmpty ? null : e.name,
          ),
        ];
      case EngineEventType.promptProgress:
        return [
          ProviderNotice('prompt_progress', 'Reading the conversation (${e.progressDone}/${e.progressTotal} tokens)',
              data: {'done': e.progressDone, 'total': e.progressTotal}),
        ];
      case EngineEventType.error:
        _error = e;
        return const [];
      case EngineEventType.finish:
        _finished = true;
        final reason = switch (e.code) {
          SeFinish.stop => FinishReason.stop,
          SeFinish.length => FinishReason.length,
          SeFinish.toolCalls => FinishReason.toolCalls,
          SeFinish.cancelled => FinishReason.cancelled,
          _ => FinishReason.error,
        };
        if (reason == FinishReason.error) {
          final err = _error;
          final code = err?.code ?? SeStatus.internal;
          throw ProviderException(errorKindFor(code), err?.text.isNotEmpty ?? false ? err!.text : 'generation failed',
              providerId: providerId, cause: EngineException(code, err?.text ?? ''));
        }
        return [Finish(reason, rawReason: e.name)];
      case EngineEventType.unknown:
        return const [];
    }
  }

  /// Builds a [ToolCall] from the engine's complete argument JSON.
  static ToolCall parseToolCall(String id, String name, String raw) {
    final text = raw.trim();
    if (text.isEmpty) return ToolCall(id: id, name: name, arguments: const {}, rawArguments: raw);
    try {
      final v = jsonDecode(text);
      if (v is Map) return ToolCall(id: id, name: name, arguments: v.cast<String, Object?>(), rawArguments: raw);
      return ToolCall(
          id: id, name: name, arguments: const {}, rawArguments: raw, argumentsError: 'arguments must be a JSON object');
    } on FormatException catch (e) {
      final repaired = JsonRepair.decodeObject(text);
      if (repaired != null) {
        return ToolCall(id: id, name: name, arguments: repaired, rawArguments: raw, repaired: true);
      }
      return ToolCall(id: id, name: name, arguments: const {}, rawArguments: raw, argumentsError: 'malformed JSON (${e.message})');
    }
  }
}
