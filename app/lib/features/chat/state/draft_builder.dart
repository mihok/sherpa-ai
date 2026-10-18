import 'package:sherpa_core/sherpa_core.dart';

import 'chat_view_state.dart';

/// Mutable accumulator for the assistant message being streamed.
///
/// Deltas are appended here as they arrive (cheap, no allocation of view
/// state) and [snapshot] is taken at most once per frame. Timing comes from
/// the injected clock so "Thought for Ns" is deterministic in tests.
final class DraftBuilder {
  DraftBuilder(this.messageId);

  final String messageId;
  final StringBuffer _text = StringBuffer();
  final StringBuffer _reasoning = StringBuffer();
  final Map<int, _CallDraft> _calls = {};
  bool _redacted = false;
  DateTime? _reasoningStartedAt;
  DateTime? _reasoningEndedAt;
  int _version = 0;
  int _snapshotVersion = -1;
  LiveDraft? _snapshot;

  bool get hasOutput => _text.isNotEmpty || _reasoning.isNotEmpty || _redacted || _calls.isNotEmpty;

  /// How long the model reasoned, once it moved on to text or tools.
  Duration? get reasoningDuration {
    final start = _reasoningStartedAt;
    final end = _reasoningEndedAt;
    return start == null || end == null ? null : end.difference(start);
  }

  void apply(ModelEvent event, DateTime now) {
    switch (event) {
      case TextDelta(:final text):
        if (text.isEmpty) return;
        _endReasoning(now);
        _text.write(text);
      case ReasoningDelta(:final text):
        if (text.isEmpty) return;
        _reasoningStartedAt ??= now;
        _reasoning.write(text);
      case ReasoningSignature(:final redactedData):
        if (redactedData == null) return;
        _reasoningStartedAt ??= now;
        _redacted = true;
      case ToolCallStart(:final index, :final id, :final name):
        _endReasoning(now);
        _calls[index] = _CallDraft(id, name);
      case ToolCallArgsDelta(:final index, :final fragment):
        final c = _calls[index];
        if (c == null) return;
        c.args.write(fragment);
      case ToolCallComplete(:final index, :final call):
        _endReasoning(now);
        (_calls[index] ??= _CallDraft(call.id, call.name)).complete = true;
      case Finish():
        _endReasoning(now);
      case UsageUpdate() || ProviderNotice() || PerfSample():
        return;
    }
    _version++;
  }

  /// Marks the end of reasoning (idempotent; only the first end counts).
  void finish(DateTime now) {
    if (_endReasoning(now)) _version++;
  }

  bool _endReasoning(DateTime now) {
    if (_reasoningStartedAt == null || _reasoningEndedAt != null) return false;
    _reasoningEndedAt = now;
    return true;
  }

  /// Immutable view of everything received so far. Returns the same
  /// instance when nothing changed, so `select` sees no update.
  LiveDraft snapshot() {
    if (_snapshot != null && _snapshotVersion == _version) return _snapshot!;
    final keys = _calls.keys.toList()..sort();
    _snapshot = LiveDraft(
      messageId: messageId,
      text: _text.toString(),
      reasoning: _reasoning.toString(),
      reasoningRedacted: _redacted,
      reasoningStartedAt: _reasoningStartedAt,
      reasoningDuration: reasoningDuration,
      toolCalls: [
        for (final k in keys)
          ToolCallDraft(
            index: k,
            id: _calls[k]!.id,
            name: _calls[k]!.name,
            argsText: _calls[k]!.args.toString(),
            complete: _calls[k]!.complete,
          ),
      ],
    );
    _snapshotVersion = _version;
    return _snapshot!;
  }
}

final class _CallDraft {
  _CallDraft(this.id, this.name);
  final String id;
  final String name;
  final StringBuffer args = StringBuffer();
  bool complete = false;
}
