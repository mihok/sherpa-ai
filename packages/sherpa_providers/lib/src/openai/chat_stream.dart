import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';

import '../common/error_mapping.dart';
import '../common/json_read.dart';
import '../common/think_splitter.dart';
import '../common/tool_call_accumulator.dart';
import '../common/tool_names.dart';
import '../config.dart';
import 'quirks.dart';
import 'usage.dart';

/// Turns Chat Completions SSE chunks into [ModelEvent]s.
///
/// Event order at the end of a turn is: completed tool calls, usage, perf
/// sample, then exactly one [Finish] (R10 §9 F1 "Expected"). Calls are only
/// completed when the stream ends because some servers repeat
/// `finish_reason` (OpenRouter's usage frame) and a defensive parser must
/// not freeze arguments before the last delta.
final class ChatStreamParser {
  ChatStreamParser({
    required ToolNameMapper names,
    required ServerQuirks quirks,
    required String Function(int ordinal) newCallId,
    this.providerId,
  })  : _quirks = quirks,
        _calls = ToolCallAccumulator(newId: newCallId, resolveName: names.fromWire),
        _think = quirks.splitThinkTags ? ThinkTagSplitter() : null;

  final ServerQuirks _quirks;
  final ToolCallAccumulator _calls;
  final ThinkTagSplitter? _think;
  final String? providerId;

  bool _done = false;
  String? _finish;
  Usage? _usage;
  PerfSample? _perf;
  bool _sawRefusal = false;
  bool _sawContent = false;
  bool _malformedNoticeSent = false;

  /// OpenRouter `reasoning_details` of the current reasoning phase, merged
  /// by `index`, replayed verbatim.
  final List<JsonMap> _details = [];

  /// True after `[DONE]`.
  bool get isDone => _done;

  /// Marks a non-streamed (single JSON) response as complete.
  void markDone() => _done = true;

  /// Whether any text, reasoning or tool call was emitted (decides whether
  /// a failure may still be retried without duplicating output).
  bool get hasOutput => _sawContent;

  List<ModelEvent> addEvent(SseEvent event) {
    final data = event.data.trim();
    if (data.isEmpty) return const [];
    if (data == '[DONE]') {
      _done = true;
      return const [];
    }
    final chunk = tryDecodeObject(data);
    if (chunk == null) {
      if (_malformedNoticeSent) return const [];
      _malformedNoticeSent = true;
      return [ProviderNotice('malformed_chunk', 'Ignored a stream chunk that is not a JSON object.',
          data: {'sample': Redactor.text(data.length > 200 ? data.substring(0, 200) : data)})];
    }
    if (event.event == 'error' && chunk['error'] == null) throw mapStreamError({'error': chunk}, providerId: providerId);
    return addChunk(chunk);
  }

  List<ModelEvent> addChunk(JsonMap chunk) {
    // Any data object with a top-level `error` is a mid-stream failure:
    // llama.cpp `{"error":{...}}` (no [DONE] follows), OpenRouter error
    // chunks (with finish_reason "error"), and the UNVERIFIED OpenAI shape.
    if (chunk['error'] != null) throw mapStreamError(chunk, providerId: providerId);
    final out = <ModelEvent>[];
    final choices = chunk.maps('choices');
    // n=1 is always requested; other choices are ignored.
    final choice = choices.where((c) => (c.integer('index') ?? 0) == 0).firstOrNull;
    if (choice != null) {
      // Some servers put a whole `message` in the last chunk instead of deltas.
      final delta = choice.child('delta') ?? choice.child('message');
      if (delta != null) _addDelta(delta, out);
      final reason = choice.text('finish_reason');
      if (reason != null) _setFinish(reason);
    }
    final usage = chunk.child('usage');
    if (usage != null) _usage = parseChatUsage(usage);
    final timings = chunk.child('timings');
    if (timings != null) {
      _perf = parseTimings(timings, backend: _quirks.profile == ServerProfile.ollama ? 'ollama' : 'llama.cpp');
    }
    return out;
  }

  void _setFinish(String reason) {
    if (reason == 'error') {
      // OpenRouter normally sends an `error` object alongside; without one
      // the stream still failed.
      throw ProviderException(ProviderErrorKind.server, 'The server ended the stream with finish_reason "error".',
          providerId: providerId);
    }
    // Keep the first real reason; OpenRouter repeats it in the usage frame.
    _finish ??= reason;
  }

  void _addDelta(JsonMap d, List<ModelEvent> out) {
    // R10 §2: `reasoning_content` (DeepSeek, llama.cpp, LM Studio setting)
    // or `reasoning` (vLLM, Ollama, OpenRouter, LM Studio gpt-oss). Parse
    // both whatever the profile; silent empty reasoning is the failure mode.
    final reasoning = d.text('reasoning_content') ?? d.text('reasoning');
    final details = d.maps('reasoning_details');
    if (details.isNotEmpty) _mergeDetails(details);
    final detailText = reasoning == null && details.isNotEmpty ? _detailsText(details) : null;
    final r = reasoning ?? detailText;
    if (r != null && r.isNotEmpty) {
      _sawContent = true;
      out.add(ReasoningDelta(r));
    }

    final content = d.text('content');
    final refusal = d.text('refusal');
    final toolCalls = d.items('tool_calls');
    if (content != null || refusal != null || (toolCalls != null && toolCalls.isNotEmpty)) _endReasoning(out);

    if (content != null) {
      _sawContent = true;
      final think = _think;
      out.addAll(think == null ? [TextDelta(content)] : think.add(content));
    }
    if (refusal != null) {
      _sawContent = true;
      _sawRefusal = true;
      out.add(TextDelta(refusal));
    }
    if (toolCalls != null && toolCalls.isNotEmpty) {
      final events = _calls.addChatDeltas(toolCalls);
      if (events.isNotEmpty) _sawContent = true;
      out.addAll(events);
    }
  }

  /// Emits the `reasoning_details` gathered since the last flush as a
  /// signature right after their reasoning text, so the agent stores both
  /// on one [ReasoningPart]. Each reasoning phase (interleaved thinking
  /// between tool calls) gets its own group, so replay never duplicates.
  void _endReasoning(List<ModelEvent> out) {
    if (_details.isEmpty) return;
    out.add(ReasoningSignature(signature: jsonEncode(_details)));
    _details.clear();
  }

  /// Streamed detail fragments for the same `index` are concatenated
  /// (`text`, `summary`, `data`); other fields keep their latest value.
  /// The exact streaming split is UNVERIFIED in R10, so this errs towards
  /// reconstructing one detail per index.
  void _mergeDetails(List<JsonMap> fragments) {
    for (final f in fragments) {
      final index = f.integer('index');
      final existing = index == null ? null : _details.where((d) => d.integer('index') == index).firstOrNull;
      if (existing == null) {
        _details.add({...f});
        continue;
      }
      for (final e in f.entries) {
        final prev = existing[e.key];
        if ((e.key == 'text' || e.key == 'summary' || e.key == 'data') && prev is String && e.value is String) {
          existing[e.key] = prev + (e.value! as String);
        } else if (e.value != null) {
          existing[e.key] = e.value;
        }
      }
    }
  }

  static String? _detailsText(List<JsonMap> details) {
    final b = StringBuffer();
    for (final d in details) {
      b.write(d.str('text') ?? d.str('summary') ?? '');
    }
    return b.isEmpty ? null : b.toString();
  }

  /// Ends the turn. Throws [ProviderException] (network, retryable) when
  /// the socket closed with neither `[DONE]` nor a finish reason: a
  /// truncated stream (R10 §1).
  List<ModelEvent> finish() {
    if (!_done && _finish == null) {
      throw ProviderException(ProviderErrorKind.network, 'The stream ended before the response was complete.',
          providerId: providerId);
    }
    final out = <ModelEvent>[];
    final think = _think;
    if (think != null) out.addAll(think.flush());
    _endReasoning(out);
    out.addAll(_calls.completeAll());
    if (_usage case final u?) out.add(UsageUpdate(u));
    if (_perf case final p?) out.add(p);
    out.add(Finish(_mapFinish(), rawReason: _finish));
    return out;
  }

  FinishReason _mapFinish() {
    final hasCalls = !_calls.isEmpty;
    return switch (_finish) {
      'length' => FinishReason.length,
      'tool_calls' || 'function_call' => FinishReason.toolCalls,
      'content_filter' => FinishReason.contentFilter,
      // Ollama and older servers say `stop` after tool calls.
      _ when hasCalls => FinishReason.toolCalls,
      _ when _sawRefusal => FinishReason.refusal,
      _ => FinishReason.stop,
    };
  }
}
