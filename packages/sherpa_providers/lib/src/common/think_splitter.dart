import 'package:sherpa_core/sherpa_core.dart';

/// Splits a leading `<think>…</think>` block out of streamed content.
///
/// Servers that do not extract reasoning themselves (llama.cpp with
/// `--reasoning-format none`, LM Studio with the separate-reasoning setting
/// off, vLLM without `--reasoning-parser`, many generic servers) stream the
/// model's thinking inline. R10 §5 recommends keeping a splitter available
/// as a per-profile fallback.
///
/// Only a block at the very start of the reply (after optional whitespace)
/// is treated as reasoning: that is where reasoning models put it, and it
/// keeps an answer that merely *mentions* `<think>` intact. Tags split
/// across chunks are handled by holding back a short tail.
final class ThinkTagSplitter {
  static const String _open = '<think>';
  static const String _close = '</think>';

  _Mode _mode = _Mode.undecided;
  final StringBuffer _held = StringBuffer();

  /// True once any reasoning was routed out of the content.
  bool get sawReasoning => _sawReasoning;
  bool _sawReasoning = false;

  List<ModelEvent> add(String chunk) {
    if (chunk.isEmpty) return const [];
    switch (_mode) {
      case _Mode.text:
        return [TextDelta(chunk)];
      case _Mode.undecided:
        _held.write(chunk);
        final held = _held.toString();
        final lead = held.trimLeft();
        if (lead.isEmpty || (_open.startsWith(lead) && lead.length < _open.length)) return const [];
        _held.clear();
        if (lead.startsWith(_open)) {
          _mode = _Mode.thinking;
          return _thinking(lead.substring(_open.length));
        }
        _mode = _Mode.text;
        return [TextDelta(held)];
      case _Mode.thinking:
        return _thinking(chunk);
      case _Mode.afterThinking:
        return _afterThinking(chunk);
    }
  }

  List<ModelEvent> _thinking(String chunk) {
    final text = '$_held$chunk';
    _held.clear();
    final end = text.indexOf(_close);
    if (end >= 0) {
      final out = <ModelEvent>[];
      if (end > 0) out.add(_reasoning(text.substring(0, end)));
      _mode = _Mode.afterThinking;
      out.addAll(_afterThinking(text.substring(end + _close.length)));
      return out;
    }
    // Hold back a suffix that could be the start of `</think>`.
    var keep = 0;
    for (var k = _close.length - 1; k > 0; k--) {
      if (text.endsWith(_close.substring(0, k))) {
        keep = k;
        break;
      }
    }
    _held.write(text.substring(text.length - keep));
    final emit = text.substring(0, text.length - keep);
    return emit.isEmpty ? const [] : [_reasoning(emit)];
  }

  /// Drops the blank lines templates put between `</think>` and the answer.
  List<ModelEvent> _afterThinking(String chunk) {
    final rest = chunk.replaceFirst(RegExp(r'^\s+'), '');
    if (rest.isEmpty) return const [];
    _mode = _Mode.text;
    return [TextDelta(rest)];
  }

  ModelEvent _reasoning(String text) {
    _sawReasoning = true;
    return ReasoningDelta(text);
  }

  /// Emits anything still held back when the stream ends.
  List<ModelEvent> flush() {
    final held = _held.toString();
    _held.clear();
    if (held.isEmpty) return const [];
    return switch (_mode) {
      _Mode.thinking => [_reasoning(held)],
      _Mode.undecided || _Mode.text => [TextDelta(held)],
      _Mode.afterThinking => const [],
    };
  }
}

enum _Mode { undecided, thinking, afterThinking, text }
