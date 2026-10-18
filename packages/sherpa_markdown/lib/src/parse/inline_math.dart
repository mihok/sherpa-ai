/// Inline math recognition: `$…$`, `$$…$$`, `\(…\)`, `\[…\]`.
///
/// The `$` rules follow Pandoc's `tex_math_dollars`, tightened for chat
/// output where currency is far more common than TeX:
/// * the opening `$` must be followed by a non-space character,
/// * the closing `$` must be preceded by a non-space character and must not
///   be followed by a digit,
/// * the content may not contain another unescaped `$` — only the *first*
///   `$` after the opener is a candidate closer.
///
/// So `$5 and $10` is text (the candidate closer before `10` is preceded by
/// a space), `$x$ costs $5` is one formula and text, and
/// `costs $5. Then $x$` renders only `x` as math.
library;

import 'package:markdown/markdown.dart' as md;

/// Longest TeX source we try to match inline; protects the per-token parse
/// from quadratic scans over long paragraphs full of `$`.
const _maxInlineTex = 2000;

/// A recognised inline formula.
typedef InlineMathMatch = ({int end, String tex, bool display});

/// Recognises inline math starting at [start] in [src], or returns null.
InlineMathMatch? matchInlineMath(String src, int start) {
  final len = src.length;
  if (start >= len) return null;
  final c = src.codeUnitAt(start);
  if (c == 0x24) return _dollar(src, start);
  if (c == 0x5C && start + 1 < len) {
    final d = src.codeUnitAt(start + 1);
    if (d == 0x28) return _delimited(src, start, r'\)', display: false);
    if (d == 0x5B) return _delimited(src, start, r'\]', display: true);
  }
  return null;
}

InlineMathMatch? _delimited(
  String src,
  int start,
  String close, {
  required bool display,
}) {
  final contentStart = start + 2;
  final end = src.indexOf(close, contentStart);
  if (end < 0 || end - contentStart > _maxInlineTex) return null;
  final tex = src.substring(contentStart, end).trim();
  if (tex.isEmpty) return null;
  return (end: end + 2, tex: tex, display: display);
}

InlineMathMatch? _dollar(String src, int start) {
  final len = src.length;
  // `$$…$$`: display math inside a paragraph.
  if (start + 1 < len && src.codeUnitAt(start + 1) == 0x24) {
    final contentStart = start + 2;
    final end = src.indexOf(r'$$', contentStart);
    if (end < 0 || end - contentStart > _maxInlineTex) return null;
    final tex = src.substring(contentStart, end).trim();
    if (tex.isEmpty) return null;
    return (end: end + 2, tex: tex, display: true);
  }
  // A `$` directly after another `$` (or a backslash) is never an opener.
  if (start > 0) {
    final p = src.codeUnitAt(start - 1);
    if (p == 0x24 || p == 0x5C) return null;
  }
  if (start + 1 >= len) return null;
  final first = src.codeUnitAt(start + 1);
  if (_isSpace(first)) return null;
  // Only the first unescaped `$` after the opener may close it.
  var k = start + 1;
  while (k < len) {
    final ch = src.codeUnitAt(k);
    if (ch == 0x5C) {
      k += 2;
      continue;
    }
    if (ch == 0x24) break;
    k++;
  }
  if (k >= len || k - start - 1 > _maxInlineTex) return null;
  if (_isSpace(src.codeUnitAt(k - 1))) return null;
  if (k + 1 < len) {
    final after = src.codeUnitAt(k + 1);
    if (after >= 0x30 && after <= 0x39) return null;
    if (after == 0x24) return null;
  }
  final tex = src.substring(start + 1, k);
  if (tex.contains('\n\n')) return null;
  return (end: k + 1, tex: tex, display: false);
}

bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

/// Tag of the custom `package:markdown` element carrying inline TeX.
const kMathTag = 'sherpa-math';

/// `package:markdown` syntax that emits [kMathTag] elements.
///
/// It overrides [tryMatch] instead of using a regex because the closing
/// rules above need a hand-written scan, and because a failed match must
/// leave the parser untouched so `$` falls through to plain text.
final class InlineMathSyntax extends md.InlineSyntax {
  InlineMathSyntax.dollar() : super(r'\$', startCharacter: 0x24);

  InlineMathSyntax.backslash() : super(r'\\[\(\[]', startCharacter: 0x5C);

  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    final start = startMatchPos ?? parser.pos;
    final match = matchInlineMath(parser.source, start);
    if (match == null) return false;
    parser.writeText();
    parser.addNode(
      md.Element.text(kMathTag, match.tex)
        ..attributes['display'] = match.display ? '1' : '0',
    );
    parser.consume(match.end - start);
    return true;
  }

  @override
  bool onMatch(md.InlineParser parser, Match match) => false;
}
