/// Line model and the line-level predicates shared by the block scanner and
/// the block builder.
///
/// Everything here works on single lines so it is cheap enough to run on
/// the open tail of a streaming message for every token.
library;

import 'package:meta/meta.dart';

import 'md_ast.dart' show MdAlign;

/// One physical line of Markdown source.
@immutable
final class SrcLine {
  const SrcLine(
    this.text, {
    required this.start,
    required this.nextStart,
    required this.terminated,
  });

  /// The line's content without its line terminator (and without `\r`).
  final String text;

  /// Offset of the first character in the full document.
  final int start;

  /// Offset just past this line's terminator (equals the document length
  /// for an unterminated last line).
  final int nextStart;

  /// Whether the line ended with `\n`. While streaming, only terminated
  /// lines may prove that a block is complete: an unterminated line can
  /// still turn into something else (`1` → `1. item`, `--` → `---`).
  final bool terminated;

  /// Offset just past the last content character.
  int get end => start + text.length;

  /// A derived line (container prefix stripped) that keeps the original
  /// line's [terminated] flag; offsets are not meaningful for nested lines.
  SrcLine derive(String text) =>
      SrcLine(text, start: start, nextStart: nextStart, terminated: terminated);

  @override
  String toString() => 'SrcLine(${terminated ? '' : 'partial '}"$text")';
}

/// Splits [text] into lines starting at offset [from] (which must be 0 or
/// a line start). `\r\n` and lone `\r` terminators are accepted; a trailing
/// `\r` at the very end is treated as "terminator still arriving".
List<SrcLine> splitLines(String text, int from) {
  final lines = <SrcLine>[];
  final length = text.length;
  var lineStart = from;
  var i = from;
  while (i < length) {
    final c = text.codeUnitAt(i);
    if (c == 0x0A) {
      lines.add(
        SrcLine(
          text.substring(lineStart, i),
          start: lineStart,
          nextStart: i + 1,
          terminated: true,
        ),
      );
      lineStart = i + 1;
    } else if (c == 0x0D) {
      if (i + 1 < length && text.codeUnitAt(i + 1) == 0x0A) {
        lines.add(
          SrcLine(
            text.substring(lineStart, i),
            start: lineStart,
            nextStart: i + 2,
            terminated: true,
          ),
        );
        i++;
        lineStart = i + 1;
      } else if (i + 1 < length) {
        lines.add(
          SrcLine(
            text.substring(lineStart, i),
            start: lineStart,
            nextStart: i + 1,
            terminated: true,
          ),
        );
        lineStart = i + 1;
      } else {
        // A trailing `\r` may be the first half of `\r\n`: hold the line
        // open until the next chunk decides.
        lines.add(
          SrcLine(
            text.substring(lineStart, i),
            start: lineStart,
            nextStart: length,
            terminated: false,
          ),
        );
        return lines;
      }
    }
    i++;
  }
  if (lineStart < length) {
    lines.add(
      SrcLine(
        text.substring(lineStart),
        start: lineStart,
        nextStart: length,
        terminated: false,
      ),
    );
  }
  return lines;
}

// ---------------------------------------------------------------------------
// Whitespace and indentation
// ---------------------------------------------------------------------------

bool isSpaceOrTab(int c) => c == 0x20 || c == 0x09;

/// Unicode whitespace as CommonMark's flanking rules see it.
bool isWhitespaceChar(int c) =>
    c == 0x20 ||
    c == 0x09 ||
    c == 0x0A ||
    c == 0x0C ||
    c == 0x0D ||
    c == 0xA0 ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200A) ||
    c == 0x202F ||
    c == 0x205F ||
    c == 0x3000;

/// ASCII punctuation plus the common Unicode punctuation ranges; enough for
/// CommonMark's left/right-flanking delimiter rules.
bool isPunctuationChar(int c) =>
    (c >= 0x21 && c <= 0x2F) ||
    (c >= 0x3A && c <= 0x40) ||
    (c >= 0x5B && c <= 0x60) ||
    (c >= 0x7B && c <= 0x7E) ||
    (c >= 0x2010 && c <= 0x2027) ||
    (c >= 0x2030 && c <= 0x205E) ||
    (c >= 0x3001 && c <= 0x3003) ||
    (c >= 0xFF01 && c <= 0xFF0F);

bool isBlank(String s) {
  for (var i = 0; i < s.length; i++) {
    if (!isSpaceOrTab(s.codeUnitAt(i))) return false;
  }
  return true;
}

/// Columns of leading whitespace (tab stops every 4 columns).
int indentOf(String s) {
  var col = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x20) {
      col++;
    } else if (c == 0x09) {
      col += 4 - col % 4;
    } else {
      break;
    }
  }
  return col;
}

/// Index of the first non-space/tab character (or `s.length`).
int firstNonSpace(String s) {
  var i = 0;
  while (i < s.length && isSpaceOrTab(s.codeUnitAt(i))) {
    i++;
  }
  return i;
}

/// Removes up to [columns] columns of leading whitespace. A tab that
/// straddles the cut is split into the spaces it stands for, as CommonMark
/// requires for list-item and block-quote content.
String dedent(String s, int columns) {
  if (columns <= 0) return s;
  var col = 0;
  var i = 0;
  while (i < s.length && col < columns) {
    final c = s.codeUnitAt(i);
    if (c == 0x20) {
      col++;
      i++;
    } else if (c == 0x09) {
      final width = 4 - col % 4;
      if (col + width > columns) {
        final remaining = col + width - columns;
        return '${' ' * remaining}${s.substring(i + 1)}';
      }
      col += width;
      i++;
    } else {
      break;
    }
  }
  return s.substring(i);
}

/// The text after at most three columns of indentation, or null when the
/// line is indented four or more columns (indented code / continuation).
String? afterUpTo3Spaces(String s) {
  if (indentOf(s) >= 4) return null;
  return s.substring(firstNonSpace(s));
}

// ---------------------------------------------------------------------------
// Block starts
// ---------------------------------------------------------------------------

/// An opening code fence.
@immutable
final class FenceOpen {
  const FenceOpen(this.char, this.length, this.indent, this.info);

  /// `` ` `` or `~`.
  final int char;
  final int length;

  /// Indentation of the opening fence; content lines lose up to this much.
  final int indent;

  /// Trimmed info string (may be empty).
  final String info;
}

/// Parses an opening fence (```` ``` ```` or `~~~`, three or more).
FenceOpen? fenceOpen(String line) {
  final indent = indentOf(line);
  if (indent >= 4) return null;
  final s = line.substring(firstNonSpace(line));
  if (s.length < 3) return null;
  final c = s.codeUnitAt(0);
  if (c != 0x60 && c != 0x7E) return null;
  var n = 0;
  while (n < s.length && s.codeUnitAt(n) == c) {
    n++;
  }
  if (n < 3) return null;
  final info = s.substring(n).trim();
  // A backtick fence's info string may not contain backticks, otherwise
  // ``` `` ``` inline code at the start of a line would open a fence.
  if (c == 0x60 && info.contains('`')) return null;
  return FenceOpen(c, n, indent, info);
}

/// Whether [line] closes [fence].
bool closesFence(String line, FenceOpen fence) {
  if (indentOf(line) >= 4) return false;
  final s = line.substring(firstNonSpace(line));
  var n = 0;
  while (n < s.length && s.codeUnitAt(n) == fence.char) {
    n++;
  }
  if (n < fence.length) return false;
  return isBlank(s.substring(n));
}

/// Level of an ATX heading line (`# x` … `###### x`), else null.
int? atxLevel(String line) {
  final s = afterUpTo3Spaces(line);
  if (s == null || s.isEmpty || s.codeUnitAt(0) != 0x23) return null;
  var n = 0;
  while (n < s.length && s.codeUnitAt(n) == 0x23) {
    n++;
  }
  if (n > 6) return null;
  if (n < s.length && !isSpaceOrTab(s.codeUnitAt(n))) return null;
  return n;
}

/// The content of an ATX heading line, with the optional closing `#`
/// sequence removed.
String atxContent(String line) {
  var s = line.substring(firstNonSpace(line));
  var n = 0;
  while (n < s.length && s.codeUnitAt(n) == 0x23) {
    n++;
  }
  s = s.substring(n).trim();
  final closing = RegExp(r'(^|[ \t])#+[ \t]*$').firstMatch(s);
  if (closing != null) s = s.substring(0, closing.start).trimRight();
  return s;
}

final _thematicBreak = RegExp(r'^(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$');

/// `***`, `- - -`, `___` … (three or more of the same char, spaces allowed).
bool isThematicBreak(String line) {
  final s = afterUpTo3Spaces(line);
  return s != null && _thematicBreak.hasMatch(s);
}

final _setext = RegExp(r'^(?:=+|-+)[ \t]*$');

/// Level of a setext underline (`===` → 1, `---` → 2), else null.
int? setextLevel(String line) {
  final s = afterUpTo3Spaces(line);
  if (s == null || !_setext.hasMatch(s)) return null;
  return s.codeUnitAt(0) == 0x3D ? 1 : 2;
}

/// Whether the line starts a block quote (`>`).
bool isQuoteLine(String line) {
  final s = afterUpTo3Spaces(line);
  return s != null && s.isNotEmpty && s.codeUnitAt(0) == 0x3E;
}

/// Strips one level of `>` marker (and one following space) from a quote
/// line.
String stripQuoteMarker(String line) {
  final i = firstNonSpace(line);
  // i points at '>'.
  final rest = line.substring(i + 1);
  if (rest.isEmpty) return rest;
  final c = rest.codeUnitAt(0);
  if (c == 0x20) return rest.substring(1);
  if (c == 0x09) {
    // The tab after '>' counts as one space of marker plus the remainder of
    // its tab stop as content indentation.
    final col = indentOf(line.substring(0, i)) + 1;
    final width = 4 - col % 4;
    return '${' ' * (width - 1)}${rest.substring(1)}';
  }
  return rest;
}

/// A list-item marker at the start of a line.
@immutable
final class ListMarker {
  const ListMarker({
    required this.ordered,
    required this.char,
    required this.number,
    required this.markerIndent,
    required this.contentIndent,
    required this.content,
  });

  final bool ordered;

  /// The bullet (`-`, `+`, `*`) or the ordered delimiter (`.`, `)`).
  /// Changing it starts a new list, per CommonMark.
  final int char;

  /// The number of an ordered item (0 for bullets).
  final int number;
  final int markerIndent;

  /// Column at which the item's content starts; continuation lines must be
  /// indented at least this far to belong to the item.
  final int contentIndent;

  /// Text of the first line after the marker.
  final String content;

  bool get isEmpty => isBlank(content);

  bool sameListAs(ListMarker other) =>
      ordered == other.ordered && char == other.char;
}

/// Parses a list-item marker (`- `, `* `, `+ `, `1. `, `1) `).
ListMarker? listMarker(String line) {
  final markerIndent = indentOf(line);
  if (markerIndent >= 4) return null;
  final start = firstNonSpace(line);
  if (start >= line.length) return null;
  final c = line.codeUnitAt(start);
  var end = start;
  var ordered = false;
  var number = 0;
  int char;
  if (c == 0x2D || c == 0x2B || c == 0x2A) {
    end = start + 1;
    char = c;
  } else if (c >= 0x30 && c <= 0x39) {
    while (end < line.length &&
        end - start < 9 &&
        line.codeUnitAt(end) >= 0x30 &&
        line.codeUnitAt(end) <= 0x39) {
      end++;
    }
    if (end >= line.length) return null;
    final d = line.codeUnitAt(end);
    if (d != 0x2E && d != 0x29) return null;
    number = int.parse(line.substring(start, end));
    char = d;
    end++;
    ordered = true;
  } else {
    return null;
  }
  // The marker must be followed by whitespace or the end of the line.
  if (end < line.length && !isSpaceOrTab(line.codeUnitAt(end))) return null;
  final markerEndCol = markerIndent + (end - start);
  final rest = line.substring(end);
  int contentIndent;
  if (isBlank(rest)) {
    contentIndent = markerEndCol + 1;
  } else {
    final spaces = indentOf(_withColumnPrefix(rest, markerEndCol));
    // 1–4 spaces of padding set the content column; 5+ means the content is
    // indented code, so only one space counts.
    contentIndent = spaces >= 5 ? markerEndCol + 1 : markerEndCol + spaces;
  }
  final content = dedent(
    _withColumnPrefix(rest, markerEndCol),
    contentIndent - markerEndCol,
  );
  return ListMarker(
    ordered: ordered,
    char: char,
    number: number,
    markerIndent: markerIndent,
    contentIndent: contentIndent,
    content: content,
  );
}

/// Re-expresses tabs in the leading whitespace of [rest] as if it started
/// at column [col], so tab stops are computed against the real line.
String _withColumnPrefix(String rest, int col) {
  final i = firstNonSpace(rest);
  if (!rest.substring(0, i).contains('\t')) return rest;
  var c = col;
  final b = StringBuffer();
  for (var k = 0; k < i; k++) {
    if (rest.codeUnitAt(k) == 0x09) {
      final w = 4 - c % 4;
      b.write(' ' * w);
      c += w;
    } else {
      b.write(' ');
      c++;
    }
  }
  b.write(rest.substring(i));
  return b.toString();
}

/// Whether a list item can interrupt a paragraph: it must have content, and
/// an ordered item must start at 1 (so "2015. A year" mid-paragraph is not
/// a list).
bool listMarkerInterruptsParagraph(ListMarker m) =>
    !m.isEmpty && (!m.ordered || m.number == 1);

final _taskPrefix = RegExp(r'^\[([ xX])\](?:[ \t]+|$)');

/// GFM task marker at the start of an item's content: `[ ] `, `[x] `.
({bool checked, String rest})? taskPrefix(String content) {
  final m = _taskPrefix.firstMatch(content);
  if (m == null) return null;
  return (checked: m[1] != ' ', rest: content.substring(m.end));
}

// ---------------------------------------------------------------------------
// $$ / \[ math blocks
// ---------------------------------------------------------------------------

/// A display-math opening line.
@immutable
final class MathOpen {
  const MathOpen({required this.close, this.singleLineTex});

  /// The closing delimiter (`$$` or `\]`).
  final String close;

  /// The TeX when the block opens and closes on the same line.
  final String? singleLineTex;
}

/// Recognises `$$` / `\[` lines. A multi-line block must open on a line of
/// its own; `$$x$$ and more` stays a paragraph with inline display math, and
/// `$$5 million` is not math at all. That restriction keeps a stray `$$` in
/// prose from swallowing the rest of a streaming message as TeX.
MathOpen? mathOpen(String line) {
  final s = afterUpTo3Spaces(line);
  if (s == null) return null;
  final String open;
  final String close;
  if (s.startsWith(r'$$')) {
    open = r'$$';
    close = r'$$';
  } else if (s.startsWith(r'\[')) {
    open = r'\[';
    close = r'\]';
  } else {
    return null;
  }
  final rest = s.substring(open.length).trim();
  if (rest.isEmpty) return MathOpen(close: close);
  if (rest.endsWith(close) && rest.length > close.length) {
    final tex = rest.substring(0, rest.length - close.length).trim();
    if (tex.isEmpty || tex.contains(close)) return null;
    return MathOpen(close: close, singleLineTex: tex);
  }
  return null;
}

/// Whether [line] closes a display-math block, and the TeX before the
/// closing delimiter on that line.
String? mathCloseContent(String line, MathOpen open) {
  final t = line.trimRight();
  if (!t.endsWith(open.close)) return null;
  return t.substring(0, t.length - open.close.length);
}

// ---------------------------------------------------------------------------
// HTML blocks (CommonMark types 1–7)
// ---------------------------------------------------------------------------

final _html1 = RegExp(r'^<(?:script|pre|style|textarea)(?:[ \t>]|$)', caseSensitive: false);
final _html1End = RegExp(r'</(?:script|pre|style|textarea)>', caseSensitive: false);
final _html6 = RegExp(
  r'^</?(?:address|article|aside|base|basefont|blockquote|body|caption|center|'
  r'col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|'
  r'footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|'
  r'link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|search|'
  r'section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul)'
  r'(?:[ \t]|/?>|$)',
  caseSensitive: false,
);
final _html7 = RegExp(
  r'^(?:<[A-Za-z][A-Za-z0-9-]*(?:[ \t]+[A-Za-z_:][A-Za-z0-9_.:-]*'
  r'''(?:[ \t]*=[ \t]*(?:[^ \t"'=<>`]+|'[^']*'|"[^"]*"))?)*[ \t]*/?>'''
  r'|</[A-Za-z][A-Za-z0-9-]*[ \t]*>)[ \t]*$',
);

/// The CommonMark HTML block type (1–7) a line starts, or null.
int? htmlBlockType(String line) {
  final s = afterUpTo3Spaces(line);
  if (s == null || s.isEmpty || s.codeUnitAt(0) != 0x3C) return null;
  if (_html1.hasMatch(s)) return 1;
  if (s.startsWith('<!--')) return 2;
  if (s.startsWith('<?')) return 3;
  if (s.length > 2 && s.startsWith('<!') && _isAsciiLetter(s.codeUnitAt(2))) {
    return 4;
  }
  if (s.startsWith('<![CDATA[')) return 5;
  if (_html6.hasMatch(s)) return 6;
  if (_html7.hasMatch(s)) return 7;
  return null;
}

/// Whether [line] satisfies the end condition of HTML block types 1–5.
bool htmlBlockEnds(int type, String line) => switch (type) {
  1 => _html1End.hasMatch(line),
  2 => line.contains('-->'),
  3 => line.contains('?>'),
  4 => line.contains('>'),
  5 => line.contains(']]>'),
  _ => false,
};

bool _isAsciiLetter(int c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

// ---------------------------------------------------------------------------
// GFM tables
// ---------------------------------------------------------------------------

/// Splits a table row into trimmed cell strings. Leading/trailing pipes are
/// optional; `\|` is a literal pipe and stays in the cell (the inline parser
/// unescapes it).
List<String> splitTableCells(String line) {
  var s = line.trim();
  if (s.startsWith('|')) s = s.substring(1);
  if (s.endsWith('|') && !s.endsWith(r'\|')) s = s.substring(0, s.length - 1);
  final cells = <String>[];
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x5C && i + 1 < s.length && s.codeUnitAt(i + 1) == 0x7C) {
      b.write('|');
      i++;
    } else if (c == 0x7C) {
      cells.add(b.toString().trim());
      b.clear();
    } else {
      b.writeCharCode(c);
    }
  }
  cells.add(b.toString().trim());
  return cells;
}

final _delimiterCell = RegExp(r'^:?-+:?$');

/// Parses a GFM delimiter row (`| :-- | :-: | --: |`) into alignments, or
/// null when [line] is not one. A pipe is required so that `---` stays a
/// thematic break / setext underline.
List<MdAlign>? parseDelimiterRow(String line) {
  if (indentOf(line) >= 4 || !line.contains('|')) return null;
  final cells = splitTableCells(line);
  if (cells.isEmpty) return null;
  final out = <MdAlign>[];
  for (final cell in cells) {
    if (!_delimiterCell.hasMatch(cell)) return null;
    final left = cell.startsWith(':');
    final right = cell.endsWith(':');
    out.add(
      left && right
          ? MdAlign.center
          : left
          ? MdAlign.left
          : right
          ? MdAlign.right
          : MdAlign.none,
    );
  }
  return out;
}

/// Whether [line] looks like a table row: it contains an unescaped pipe.
bool hasPipe(String line) {
  for (var i = 0; i < line.length; i++) {
    final c = line.codeUnitAt(i);
    if (c == 0x5C) {
      i++;
    } else if (c == 0x7C) {
      return true;
    }
  }
  return false;
}

// ---------------------------------------------------------------------------
// Streaming hold-back
// ---------------------------------------------------------------------------

final _markerOnly = RegExp(r'^(?:[-*+_=~`#|:]+[ \t]*)+$');
final _orderedPrefix = RegExp(r'^\d{1,9}[.)]?$');
final _taskPartial = RegExp(r'^\[(?:[ xX]\]?)?$');
final _bulletOrOrdered = RegExp(r'^(?:[-*+]|\d{1,9}[.)])[ \t]+');

/// Whether an unterminated last line is still ambiguous and should be held
/// back from rendering until more text arrives.
///
/// Lines like `-`, `1`, `--`, `` ` ``, `|:-`, `$$` or `- [` can become very
/// different blocks once the next character lands (`1` → `1. item` or
/// `1999 was …`; `--` → setext underline, list item or thematic break).
/// Rendering them now would make the UI flip between interpretations; holding
/// back a few characters for one token is invisible.
bool isAmbiguousPartialLine(String line) {
  var s = line.trimLeft();
  // Block-quote markers.
  while (s.startsWith('>')) {
    s = s.substring(1).trimLeft();
  }
  if (s.isEmpty) return true;
  final bullet = _bulletOrOrdered.firstMatch(s);
  if (bullet != null) {
    final rest = s.substring(bullet.end);
    if (rest.isEmpty || _taskPartial.hasMatch(rest)) return true;
    s = rest;
  }
  if (_markerOnly.hasMatch(s)) return true;
  if (_orderedPrefix.hasMatch(s)) return true;
  if (s == r'$' || s == r'$$' || s == r'\' || s == r'\[' || s == '<') {
    return true;
  }
  return false;
}
