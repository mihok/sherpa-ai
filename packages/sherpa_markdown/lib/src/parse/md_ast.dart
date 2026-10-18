/// Typed, immutable Markdown AST produced by the incremental parser.
///
/// Why a typed AST instead of `package:markdown`'s stringly-typed
/// `Element(tag)` nodes: the renderer switches exhaustively over sealed
/// classes, so a new node kind is a compile error instead of a silently
/// dropped tag, and nodes carry streaming state (`complete`, pending links)
/// that HTML tags have no place for. Every class implements value equality
/// so tests can compare "parsed at once" with "parsed while streaming".
library;

import 'package:meta/meta.dart';

/// A block-level node.
@immutable
sealed class MdNode {
  const MdNode();
}

/// A run of inline content (a paragraph's text, a heading, a table cell).
@immutable
sealed class MdInline {
  const MdInline();

  /// The visible text of this node, without markup (used for semantics
  /// labels, copy-as-text and image alt text).
  String get plainText;
}

// ---------------------------------------------------------------------------
// Block nodes
// ---------------------------------------------------------------------------

/// A paragraph of inline content.
final class MdParagraph extends MdNode {
  const MdParagraph(this.inlines);

  final List<MdInline> inlines;

  @override
  bool operator ==(Object other) =>
      other is MdParagraph && mdListEquals(inlines, other.inlines);

  @override
  int get hashCode => Object.hash(MdParagraph, Object.hashAll(inlines));

  @override
  String toString() => 'MdParagraph($inlines)';
}

/// An ATX (`# Title`) or setext (`Title\n===`) heading.
final class MdHeading extends MdNode {
  const MdHeading(this.level, this.inlines);

  /// 1–6.
  final int level;
  final List<MdInline> inlines;

  @override
  bool operator ==(Object other) =>
      other is MdHeading &&
      level == other.level &&
      mdListEquals(inlines, other.inlines);

  @override
  int get hashCode => Object.hash(MdHeading, level, Object.hashAll(inlines));

  @override
  String toString() => 'MdHeading($level, $inlines)';
}

/// A fenced or indented code block.
final class MdCodeBlock extends MdNode {
  const MdCodeBlock(
    this.code, {
    this.language,
    this.info,
    required this.complete,
  });

  final String code;

  /// First word of the fence's info string, lower-cased (`dart`, `py`), or
  /// null for indented code and bare fences.
  final String? language;

  /// The full info string after the opening fence.
  final String? info;

  /// False while the fence is still open during streaming. The renderer
  /// only syntax-highlights complete blocks, so a half-typed block never
  /// flickers between token colourings.
  final bool complete;

  @override
  bool operator ==(Object other) =>
      other is MdCodeBlock &&
      code == other.code &&
      language == other.language &&
      info == other.info &&
      complete == other.complete;

  @override
  int get hashCode => Object.hash(MdCodeBlock, code, language, info, complete);

  @override
  String toString() =>
      'MdCodeBlock(${language ?? '-'}, complete: $complete, ${_q(code)})';
}

/// A display math block (`$$ … $$` or `\[ … \]`).
final class MdMathBlock extends MdNode {
  const MdMathBlock(this.tex, {required this.complete});

  final String tex;

  /// False while the closing delimiter has not arrived. Incomplete TeX is
  /// shown raw: rendering it would flip between "parse error" and "formula"
  /// on every token.
  final bool complete;

  @override
  bool operator ==(Object other) =>
      other is MdMathBlock && tex == other.tex && complete == other.complete;

  @override
  int get hashCode => Object.hash(MdMathBlock, tex, complete);

  @override
  String toString() => 'MdMathBlock(complete: $complete, ${_q(tex)})';
}

/// A block quote (`> …`).
final class MdQuote extends MdNode {
  const MdQuote(this.children);

  final List<MdNode> children;

  @override
  bool operator ==(Object other) =>
      other is MdQuote && mdListEquals(children, other.children);

  @override
  int get hashCode => Object.hash(MdQuote, Object.hashAll(children));

  @override
  String toString() => 'MdQuote($children)';
}

/// An ordered or unordered list.
final class MdList extends MdNode {
  const MdList({
    required this.ordered,
    this.start = 1,
    required this.tight,
    required this.items,
  });

  final bool ordered;

  /// Number of the first item of an ordered list.
  final int start;

  /// CommonMark "tight" list: no blank lines between items or their direct
  /// children, so paragraphs are rendered without paragraph spacing.
  final bool tight;
  final List<MdListItem> items;

  @override
  bool operator ==(Object other) =>
      other is MdList &&
      ordered == other.ordered &&
      start == other.start &&
      tight == other.tight &&
      mdListEquals(items, other.items);

  @override
  int get hashCode =>
      Object.hash(MdList, ordered, start, tight, Object.hashAll(items));

  @override
  String toString() =>
      'MdList(${ordered ? 'ol:$start' : 'ul'}, tight: $tight, $items)';
}

/// One list item. [checked] is non-null for GFM task items (`- [x] done`).
@immutable
final class MdListItem {
  const MdListItem(this.children, {this.checked});

  final List<MdNode> children;
  final bool? checked;

  @override
  bool operator ==(Object other) =>
      other is MdListItem &&
      checked == other.checked &&
      mdListEquals(children, other.children);

  @override
  int get hashCode =>
      Object.hash(MdListItem, checked, Object.hashAll(children));

  @override
  String toString() => 'MdListItem(${checked ?? ''}$children)';
}

/// Column alignment from a GFM delimiter row (`:--`, `:-:`, `--:`).
enum MdAlign { none, left, center, right }

/// A GFM table.
final class MdTable extends MdNode {
  const MdTable({
    required this.alignments,
    required this.header,
    required this.rows,
    this.tentative = false,
  });

  final List<MdAlign> alignments;

  /// Header cells; each cell is a list of inlines.
  final List<List<MdInline>> header;

  /// Body rows; every row has exactly `alignments.length` cells.
  final List<List<List<MdInline>>> rows;

  /// True when the delimiter row has not streamed in yet and this is a
  /// header-only preview of a pipe row. Showing the row as a table straight
  /// away avoids a paragraph→table flip when the `|---|` line lands.
  final bool tentative;

  int get columnCount => alignments.length;

  @override
  bool operator ==(Object other) =>
      other is MdTable &&
      tentative == other.tentative &&
      mdListEquals(alignments, other.alignments) &&
      _deepEquals(header, other.header) &&
      _deepEquals(rows, other.rows);

  @override
  int get hashCode => Object.hash(
    MdTable,
    tentative,
    Object.hashAll(alignments),
    _deepHash(header),
    _deepHash(rows),
  );

  @override
  String toString() =>
      'MdTable(${tentative ? 'tentative, ' : ''}$alignments, $header, $rows)';
}

/// A thematic break (`---`, `***`, `___`).
final class MdThematicBreak extends MdNode {
  const MdThematicBreak();

  @override
  bool operator ==(Object other) => other is MdThematicBreak;

  @override
  int get hashCode => (MdThematicBreak).hashCode;

  @override
  String toString() => 'MdThematicBreak()';
}

/// A raw HTML block. Sherpa never interprets model-authored HTML (it is an
/// injection and exfiltration vector), so this is rendered as plain text.
final class MdHtmlBlock extends MdNode {
  const MdHtmlBlock(this.text);

  final String text;

  @override
  bool operator ==(Object other) => other is MdHtmlBlock && text == other.text;

  @override
  int get hashCode => Object.hash(MdHtmlBlock, text);

  @override
  String toString() => 'MdHtmlBlock(${_q(text)})';
}

// ---------------------------------------------------------------------------
// Inline nodes
// ---------------------------------------------------------------------------

/// Plain text. Soft line breaks are kept as `\n`.
final class MdText extends MdInline {
  const MdText(this.text);

  final String text;

  @override
  String get plainText => text;

  @override
  bool operator ==(Object other) => other is MdText && text == other.text;

  @override
  int get hashCode => Object.hash(MdText, text);

  @override
  String toString() => _q(text);
}

/// Shared shape of emphasis-like containers.
sealed class MdInlineContainer extends MdInline {
  const MdInlineContainer(this.children);

  final List<MdInline> children;

  @override
  String get plainText => children.map((c) => c.plainText).join();

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is MdInlineContainer &&
      mdListEquals(children, other.children);

  @override
  int get hashCode => Object.hash(runtimeType, Object.hashAll(children));
}

/// `*emphasis*` / `_emphasis_`.
final class MdEmphasis extends MdInlineContainer {
  const MdEmphasis(super.children);

  @override
  String toString() => 'em$children';
}

/// `**strong**` / `__strong__`.
final class MdStrong extends MdInlineContainer {
  const MdStrong(super.children);

  @override
  String toString() => 'strong$children';
}

/// `~~strikethrough~~` (double tilde only: a single `~` is far more often
/// "approximately" in model output than a deletion).
final class MdStrikethrough extends MdInlineContainer {
  const MdStrikethrough(super.children);

  @override
  String toString() => 'del$children';
}

/// `` `inline code` ``.
final class MdInlineCode extends MdInline {
  const MdInlineCode(this.code);

  final String code;

  @override
  String get plainText => code;

  @override
  bool operator ==(Object other) => other is MdInlineCode && code == other.code;

  @override
  int get hashCode => Object.hash(MdInlineCode, code);

  @override
  String toString() => 'code(${_q(code)})';
}

/// A link or autolink.
final class MdLink extends MdInline {
  const MdLink({required this.href, this.title, required this.children});

  /// Destination, or null while the destination is still streaming in
  /// (`[text](htt`). A pending link is styled as a link but is not
  /// tappable, so a half-received URL can never be opened.
  final String? href;
  final String? title;
  final List<MdInline> children;

  bool get pending => href == null;

  @override
  String get plainText => children.map((c) => c.plainText).join();

  @override
  bool operator ==(Object other) =>
      other is MdLink &&
      href == other.href &&
      title == other.title &&
      mdListEquals(children, other.children);

  @override
  int get hashCode =>
      Object.hash(MdLink, href, title, Object.hashAll(children));

  @override
  String toString() => 'link(${href ?? 'pending'}, $children)';
}

/// An image. Rendered as a tap-to-load placeholder for network sources.
final class MdImage extends MdInline {
  const MdImage({required this.src, required this.alt, this.title});

  /// Source URL, or null while it is still streaming in.
  final String? src;
  final String alt;
  final String? title;

  @override
  String get plainText => alt;

  @override
  bool operator ==(Object other) =>
      other is MdImage &&
      src == other.src &&
      alt == other.alt &&
      title == other.title;

  @override
  int get hashCode => Object.hash(MdImage, src, alt, title);

  @override
  String toString() => 'img(${src ?? 'pending'}, ${_q(alt)})';
}

/// Inline math: `$…$`, `\(…\)` (text style) or `$$…$$`, `\[…\]` inside a
/// paragraph (display style).
final class MdInlineMath extends MdInline {
  const MdInlineMath(this.tex, {this.display = false});

  final String tex;
  final bool display;

  @override
  String get plainText => tex;

  @override
  bool operator ==(Object other) =>
      other is MdInlineMath && tex == other.tex && display == other.display;

  @override
  int get hashCode => Object.hash(MdInlineMath, tex, display);

  @override
  String toString() => 'math(${display ? 'display, ' : ''}${_q(tex)})';
}

/// A hard line break (two trailing spaces or a trailing backslash).
final class MdLineBreak extends MdInline {
  const MdLineBreak();

  @override
  String get plainText => '\n';

  @override
  bool operator ==(Object other) => other is MdLineBreak;

  @override
  int get hashCode => (MdLineBreak).hashCode;

  @override
  String toString() => 'br';
}

// ---------------------------------------------------------------------------
// Helpers (kept here so the parse layer has no Flutter/collection imports)
// ---------------------------------------------------------------------------

/// Element-wise equality of two lists.
bool mdListEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _deepEquals(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

int _deepHash(Object? value) =>
    value is List ? Object.hashAll(value.map(_deepHash)) : value.hashCode;

String _q(String s) {
  final short = s.length > 40 ? '${s.substring(0, 40)}…' : s;
  return '"${short.replaceAll('\n', r'\n')}"';
}

/// Concatenated plain text of [inlines].
String plainTextOf(List<MdInline> inlines) =>
    inlines.map((i) => i.plainText).join();
