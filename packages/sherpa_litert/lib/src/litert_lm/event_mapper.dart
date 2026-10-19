import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/tool_arguments.dart';

import '../common/errors.dart';
import '../common/fingerprint.dart';
import '../common/prompted_tools.dart';
import '../messages.pigeon.dart';

/// Stateful translation of one LiteRT-LM turn's native events into
/// [ModelEvent]s.
///
/// * Text deltas pass through, or through [PromptedToolParser] in the
///   prompted tool format.
/// * `thought`-channel deltas become [ReasoningDelta]s.
/// * Native tool calls become start + one argument fragment + complete, with
///   a fresh id each (LiteRT-LM calls have none) and arguments parsed by the
///   strict shared parser (repaired JSON forces approval; duplicate keys and
///   leaked template tokens are refused).
/// * `done` becomes [UsageUpdate] + [PerfSample] (BenchmarkInfo and the KV
///   token count: `cacheReadTokens` = tokens the conversation already held,
///   `inputTokens` = tokens prefilled this turn, so the full prompt is their
///   sum, as the core expects) and one [Finish]: `toolCalls` when the model
///   called tools, `length` when it used its whole output budget, else
///   `stop`.
/// * `cancelled` becomes `Finish(cancelled)` for a user stop and
///   `Finish(pause)` for a policy stop (memory pressure): the agent loop
///   continues the reply later. An unrequested `cancelled` is a retryable
///   `engineCrashed` error.
/// * `error` throws a [ProviderException] ([liteRtError]).
/// Reasons Kotlin puts in `cancelled` / `engineReleased` on its own.
abstract final class LiteRtCancelReason {
  static const memoryPressure = 'memory_pressure';
}

final class LiteRtEventMapper {
  LiteRtEventMapper({
    required this.providerId,
    required this.prompted,
    Set<String> toolNames = const {},
    this.maxOutputTokens,
    String Function()? newId,
  })  : _newId = newId ?? newToolCallId,
        _parser = prompted ? PromptedToolParser(toolNames: toolNames, newId: newId) : null;

  final String providerId;
  final bool prompted;
  final int? maxOutputTokens;
  final String Function() _newId;
  final PromptedToolParser? _parser;
  int _nextIndex = 0;

  final StringBuffer _text = StringBuffer();
  final List<ToolCall> _calls = [];
  Usage? _usage;

  /// Text emitted so far (the reply as Sherpa will store it).
  String get text => _text.toString();

  /// Tool calls emitted so far.
  List<ToolCall> get calls => List.unmodifiable(_calls);

  Usage? get usage => _usage;

  /// [stopRequested]: Dart asked for this stop (any reason). A `cancelled`
  /// nobody asked for (detail `cancelled`) comes from a native conversation
  /// stuck in its cancelled state, which the host run showed LiteRT-LM does
  /// after `cancelProcess`: reported as a retryable engine error, so the
  /// retry rebuilds the conversation.
  List<ModelEvent> map(LiteRtEvent e, {required bool userCancelled, bool stopRequested = false}) {
    switch (e.kind) {
      case EventKind.textDelta:
        final t = e.text ?? '';
        if (t.isEmpty) return const [];
        return _track(_parser?.add(t) ?? [TextDelta(t)]);
      case EventKind.reasoningDelta:
        final t = e.text ?? '';
        return t.isEmpty ? const [] : [ReasoningDelta(t)];
      case EventKind.toolCalls:
        return _track([for (final c in e.toolCalls ?? const <ToolCallMsg>[]) ..._nativeCall(c)]);
      case EventKind.done:
        final out = <ModelEvent>[..._track(_parser?.finish() ?? const [])];
        final s = e.stats;
        if (s != null) out.addAll(_stats(s));
        final decoded = s?.decodeTokens;
        final reason = _calls.isNotEmpty
            ? FinishReason.toolCalls
            : (maxOutputTokens != null && decoded != null && decoded >= maxOutputTokens!)
                ? FinishReason.length
                : FinishReason.stop;
        out.add(Finish(reason));
        return out;
      case EventKind.cancelled:
        if (userCancelled) return const [Finish(FinishReason.cancelled)];
        if (!stopRequested && e.detail != LiteRtCancelReason.memoryPressure) {
          throw ProviderException(ProviderErrorKind.engineCrashed,
              'LiteRT-LM stopped the reply on its own; the conversation is rebuilt on retry.',
              providerId: providerId, cause: e.detail);
        }
        return [..._track(_parser?.finish() ?? const []), Finish(FinishReason.pause, rawReason: e.detail)];
      case EventKind.error:
        final err = e.error ?? ErrorMsg(source: 'host', code: -1, message: 'generation failed');
        throw liteRtError(err, providerId: providerId);
      default:
        return const [];
    }
  }

  List<ModelEvent> _nativeCall(ToolCallMsg c) {
    final index = _nextIndex++;
    final id = _newId();
    final call = _parseArguments(id, c.name, c.argumentsJson);
    return [
      ToolCallStart(index: index, id: id, name: c.name),
      ToolCallArgsDelta(index: index, fragment: c.argumentsJson),
      ToolCallComplete(index: index, call: call),
    ];
  }

  /// The engine's argument JSON through the strict shared parser
  /// ([ToolArgumentsRepair], like every other tool-call path): strict JSON
  /// as is; repaired JSON flagged `repaired` (forces approval of
  /// non-read-only tools); duplicate keys, leaked chat-template tokens and
  /// ambiguous unquoted values make the call invalid (never run).
  static ToolCall _parseArguments(String id, String name, String raw) {
    final parsed = ToolArgumentsRepair.parseArguments(raw);
    return ToolCall(
      id: id,
      name: name,
      arguments: parsed.value ?? const {},
      rawArguments: raw,
      argumentsError: parsed.error,
      repaired: parsed.repaired,
    );
  }

  List<ModelEvent> _track(List<ModelEvent> events) {
    for (final e in events) {
      switch (e) {
        case TextDelta(:final text):
          _text.write(text);
        case ToolCallComplete(:final call):
          _calls.add(call);
        default:
          break;
      }
    }
    return events;
  }

  List<ModelEvent> _stats(GenerationStatsMsg s) {
    final cached = s.kvTokensBefore ?? 0;
    final decoded = s.decodeTokens;
    var prefilled = s.prefillTokens;
    if (prefilled == null && s.kvTokensAfter != null && s.kvTokensBefore != null && decoded != null) {
      prefilled = s.kvTokensAfter! - s.kvTokensBefore! - decoded;
      if (prefilled < 0) prefilled = null;
    }
    final out = <ModelEvent>[];
    if (prefilled != null || decoded != null) {
      final u = Usage(inputTokens: prefilled ?? 0, outputTokens: decoded ?? 0, cacheReadTokens: cached);
      _usage = u;
      out.add(UsageUpdate(u));
    }
    if (s.timeToFirstTokenMs != null || s.decodeTokensPerSec != null || s.backend != null) {
      out.add(PerfSample(
        timeToFirstTokenMs: s.timeToFirstTokenMs,
        prefillTokensPerSec: s.prefillTokensPerSec,
        decodeTokensPerSec: s.decodeTokensPerSec,
        promptTokens: prefilled == null ? null : prefilled + cached,
        cachedPromptTokens: cached,
        backend: s.backend,
      ));
    }
    return out;
  }
}
