import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';

import '../common/error_mapping.dart';
import '../common/json_read.dart';
import '../common/tool_call_accumulator.dart';
import '../common/tool_names.dart';
import 'usage.dart';

/// Turns Responses API stream events into [ModelEvent]s (R10 §8, F5).
///
/// * Function calls are separate output items keyed by `output_index`
///   (several may be open in parallel); their ordinals become the
///   agent-facing indexes, so reasoning/message items do not leave gaps.
/// * A call completes at its `response.output_item.done`, whose `arguments`
///   are authoritative.
/// * A reasoning item's `encrypted_content` is emitted as
///   [ReasoningSignature.signature] after its summary text (see
///   [ResponsesInputMapper] for the storage contract).
/// * The stream ends on `response.completed|incomplete|failed` or `error`;
///   whether OpenAI also sends `[DONE]` is UNVERIFIED, so it is accepted
///   but not required.
final class ResponsesStreamParser {
  ResponsesStreamParser({
    required ToolNameMapper names,
    required String Function(int ordinal) newCallId,
    this.providerId,
  }) : _calls = ToolCallAccumulator(newId: newCallId, resolveName: names.fromWire);

  final ToolCallAccumulator _calls;
  final String? providerId;

  final Map<String, int> _indexByItemId = {};
  final Set<int> _textStreamed = {};
  final Set<int> _reasoningStreamed = {};
  final Map<int, int> _summaryIndex = {};
  bool _done = false;
  bool _sawRefusal = false;
  bool _hasOutput = false;
  String? _status;
  String? _incompleteReason;
  Usage? _usage;

  bool get isDone => _done;

  bool get hasOutput => _hasOutput;

  List<ModelEvent> addEvent(SseEvent event) {
    final data = event.data.trim();
    if (data.isEmpty) return const [];
    if (data == '[DONE]') {
      _done = true;
      return const [];
    }
    final json = tryDecodeObject(data);
    if (json == null) return const [];
    final type = json.str('type') ?? event.event;
    return addPayload(type, json);
  }

  List<ModelEvent> addPayload(String type, JsonMap e) {
    final out = <ModelEvent>[];
    switch (type) {
      case 'response.output_item.added':
        _itemAdded(e, out);
      case 'response.output_item.done':
        _itemDone(e, out);
      case 'response.output_text.delta':
        final delta = e.text('delta');
        if (delta != null) {
          _textStreamed.add(_indexOf(e));
          _hasOutput = true;
          out.add(TextDelta(delta));
        }
      case 'response.refusal.delta':
        final delta = e.text('delta');
        if (delta != null) {
          _textStreamed.add(_indexOf(e));
          _sawRefusal = true;
          _hasOutput = true;
          out.add(TextDelta(delta));
        }
      case 'response.reasoning_summary_text.delta' || 'response.reasoning_text.delta':
        _reasoningDelta(e, out);
      case 'response.function_call_arguments.delta':
        final delta = e.str('delta');
        if (delta != null && delta.isNotEmpty) {
          _hasOutput = true;
          out.addAll(_calls.append(_indexOf(e), delta));
        }
      case 'response.function_call_arguments.done':
        final args = e.str('arguments');
        if (args != null) _calls.setArguments(_indexOf(e), args);
      case 'response.completed' || 'response.incomplete':
        _terminal(e.child('response') ?? const {}, type == 'response.incomplete');
      case 'response.failed':
        final response = e.child('response') ?? const <String, Object?>{};
        final error = response.child('error');
        throw mapStreamError(error == null ? {'error': {'message': 'The response failed.'}} : {'error': error},
            providerId: providerId);
      case 'error':
        throw mapStreamError(e, providerId: providerId);
      default:
        // Lifecycle (created, in_progress, queued), content_part, *.done
        // text events and hosted-tool events carry nothing new for Sherpa.
        break;
    }
    return out;
  }

  int _indexOf(JsonMap e) {
    final idx = e.integer('output_index');
    if (idx != null) return idx;
    final itemId = e.str('item_id');
    return itemId == null ? -1 : (_indexByItemId[itemId] ?? -1);
  }

  void _itemAdded(JsonMap e, List<ModelEvent> out) {
    final item = e.child('item');
    if (item == null) return;
    final index = e.integer('output_index') ?? _indexByItemId.length;
    if (item.str('id') case final id?) _indexByItemId[id] = index;
    if (item.str('type') == 'function_call') {
      _hasOutput = true;
      out.addAll(_calls.open(index, id: item.text('call_id'), name: item.text('name'), arguments: item.str('arguments')));
    }
  }

  void _itemDone(JsonMap e, List<ModelEvent> out) {
    final item = e.child('item');
    if (item == null) return;
    final index = e.integer('output_index') ?? _indexOf({'item_id': item['id']});
    switch (item.str('type')) {
      case 'function_call':
        _hasOutput = true;
        // Opening is idempotent; it covers a missed `output_item.added`.
        out.addAll(_calls.open(index, id: item.text('call_id'), name: item.text('name')));
        if (item.str('arguments') case final args?) _calls.setArguments(index, args);
        out.addAll(_calls.complete(index));
      case 'reasoning':
        if (!_reasoningStreamed.contains(index)) {
          final summary = [for (final s in item.maps('summary')) s.str('text') ?? ''].where((s) => s.isNotEmpty);
          if (summary.isNotEmpty) {
            _hasOutput = true;
            out.add(ReasoningDelta(summary.join('\n\n')));
          }
        }
        final encrypted = item.text('encrypted_content');
        if (encrypted != null) out.add(ReasoningSignature(signature: encrypted));
      case 'message':
        if (_textStreamed.contains(index)) return;
        for (final part in item.maps('content')) {
          final text = part.text('text') ?? part.text('refusal');
          if (text == null) continue;
          if (part.str('type') == 'refusal') _sawRefusal = true;
          _hasOutput = true;
          out.add(TextDelta(text));
        }
    }
  }

  void _reasoningDelta(JsonMap e, List<ModelEvent> out) {
    final delta = e.text('delta');
    if (delta == null) return;
    final index = _indexOf(e);
    final summaryIndex = e.integer('summary_index');
    final previous = _summaryIndex[index];
    // Separate summary parts the way the UI expects paragraphs.
    if (summaryIndex != null && previous != null && summaryIndex != previous) out.add(const ReasoningDelta('\n\n'));
    if (summaryIndex != null) _summaryIndex[index] = summaryIndex;
    _reasoningStreamed.add(index);
    _hasOutput = true;
    out.add(ReasoningDelta(delta));
  }

  void _terminal(JsonMap response, bool incomplete) {
    _done = true;
    _status = response.str('status') ?? (incomplete ? 'incomplete' : 'completed');
    _incompleteReason = response.child('incomplete_details')?.str('reason');
    final usage = response.child('usage');
    if (usage != null) _usage = parseResponsesUsage(usage);
  }

  /// Ends the turn; throws a retryable network error for a stream that
  /// closed before a terminal event.
  List<ModelEvent> finish() {
    if (!_done) {
      throw ProviderException(ProviderErrorKind.network, 'The stream ended before the response was complete.',
          providerId: providerId);
    }
    final out = <ModelEvent>[..._calls.completeAll()];
    if (_usage case final u?) out.add(UsageUpdate(u));
    out.add(Finish(_reason(), rawReason: _incompleteReason ?? _status));
    return out;
  }

  FinishReason _reason() {
    if (_status == 'incomplete') {
      // Reason names beyond max_output_tokens/content_filter are UNVERIFIED.
      return _incompleteReason == 'content_filter' ? FinishReason.contentFilter : FinishReason.length;
    }
    if (!_calls.isEmpty) return FinishReason.toolCalls;
    if (_sawRefusal) return FinishReason.refusal;
    return FinishReason.stop;
  }
}
