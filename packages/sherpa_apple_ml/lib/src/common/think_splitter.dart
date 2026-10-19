import 'package:sherpa_core/sherpa_core.dart';

/// Splits MLX's raw text chunks into reasoning and answer deltas.
///
/// mlx-swift-lm's `ChatSession` streams reasoning inline (`<think>…</think>`
/// for Qwen3/DeepSeek-style models); `ModelConfiguration.reasoningConfig`
/// says which delimiters a model uses. Two prompt shapes exist:
/// * the model opens the span itself (Qwen3 with thinking on): the stream
///   starts with the start delimiter;
/// * the template pre-fills the opening delimiter ("primed", Qwen3.5,
///   DeepSeek-R1): the stream starts inside reasoning and only the end
///   delimiter appears.
///
/// [primed] comes from Swift (`AmMlxModelInfo.reasoningPrimed`: the rendered
/// prompt tail ends with the start delimiter) and applies only when thinking
/// is on for the request. Partial delimiters straddling chunks are held back.
/// A tool call ([closeOnToolCall]) or an implicit end delimiter closes an
/// open span; a start delimiter outside a span always opens one.
final class ThinkSplitter {
  ThinkSplitter({required this.start, required this.end, this.implicitEnds = const [], required this.primed})
    : _state = primed ? _State.inside : _State.outside;

  /// A splitter that never routes anything to reasoning.
  ThinkSplitter.disabled() : start = '', end = '', implicitEnds = const [], primed = false, _state = _State.off;

  final String start;
  final String end;
  final List<String> implicitEnds;

  /// The stream starts inside a reasoning span.
  final bool primed;

  _State _state;
  String _pending = '';
  bool _sawReasoning = false;

  /// True once any text was routed to reasoning.
  bool get sawReasoning => _sawReasoning;

  List<ModelEvent> add(String chunk) {
    if (_state == _State.off) return chunk.isEmpty ? const [] : [TextDelta(chunk)];
    _pending += chunk;
    final out = <ModelEvent>[];
    while (_pending.isNotEmpty) {
      switch (_state) {
        case _State.off:
          break;
        case _State.outside:
          final i = _pending.indexOf(start);
          if (i >= 0) {
            _emit(out, _pending.substring(0, i), reasoning: false);
            _pending = _pending.substring(i + start.length);
            _state = _State.inside;
            continue;
          }
          final keep = _partialSuffix(_pending, [start]);
          _emit(out, _pending.substring(0, _pending.length - keep), reasoning: false);
          _pending = _pending.substring(_pending.length - keep);
          return out;
        case _State.inside:
          final (idx, len, consumes) = _firstEnd(_pending);
          if (idx >= 0) {
            _emit(out, _pending.substring(0, idx), reasoning: true);
            // An implicit end stays in the stream; the canonical one is eaten.
            _pending = _pending.substring(consumes ? idx + len : idx).replaceFirst(RegExp(r'^\s+'), '');
            _state = _State.outside;
            continue;
          }
          final keep = _partialSuffix(_pending, [end, ...implicitEnds]);
          _emit(out, _pending.substring(0, _pending.length - keep), reasoning: true);
          _pending = _pending.substring(_pending.length - keep);
          return out;
      }
    }
    return out;
  }

  /// A tool call arrived: an open reasoning span is over.
  List<ModelEvent> closeOnToolCall() {
    if (_state == _State.inside) {
      final out = <ModelEvent>[];
      _emit(out, _pending, reasoning: true);
      _pending = '';
      _state = _State.outside;
      return out;
    }
    return const [];
  }

  /// End of stream: flush held-back text.
  List<ModelEvent> flush() {
    final out = <ModelEvent>[];
    if (_pending.isNotEmpty) _emit(out, _pending, reasoning: _state == _State.inside);
    _pending = '';
    return out;
  }

  void _emit(List<ModelEvent> out, String text, {required bool reasoning}) {
    if (text.isEmpty) return;
    if (reasoning) {
      _sawReasoning = true;
      out.add(ReasoningDelta(text));
    } else {
      out.add(TextDelta(text));
    }
  }

  (int, int, bool) _firstEnd(String s) {
    var best = -1;
    var len = 0;
    var consumes = true;
    final i = s.indexOf(end);
    if (i >= 0) {
      best = i;
      len = end.length;
    }
    for (final d in implicitEnds) {
      if (d.isEmpty) continue;
      final j = s.indexOf(d);
      if (j >= 0 && (best < 0 || j < best)) {
        best = j;
        len = d.length;
        consumes = false;
      }
    }
    return (best, len, consumes);
  }

  /// Length of the longest suffix of [s] that is a proper prefix of one of
  /// [delims] (held back until the next chunk decides).
  static int _partialSuffix(String s, List<String> delims) {
    var keep = 0;
    for (final d in delims) {
      for (var n = d.length - 1; n > keep; n--) {
        if (n <= s.length && s.endsWith(d.substring(0, n))) {
          keep = n;
          break;
        }
      }
    }
    return keep;
  }
}

enum _State { off, outside, inside }
