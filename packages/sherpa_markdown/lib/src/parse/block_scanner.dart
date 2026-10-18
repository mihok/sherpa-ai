/// Line-level block scanner: finds where blocks start and end, and whether
/// each end is *proven*.
///
/// This is the part of the parser that makes streaming correct. A block is
/// `closed` only when the lines after it prove that no future text can
/// change it: a blank line, a line that starts another block, or the
/// block's own closing line (fence, `$$`). Every proof must be a
/// *terminated* line, because an unterminated line can still change kind
/// (`1` → `1. item`). With `complete: true` the end of input proves every
/// block, but the span records that its proof is provisional so a later
/// append can reopen it.
///
/// The scanner is restartable at any block boundary: scanning from the
/// first line after a closed block yields exactly the spans a scan from the
/// document start would yield for the same lines. The incremental parser
/// relies on that to skip frozen blocks.
library;

import 'package:meta/meta.dart';

import 'md_ast.dart' show MdAlign;
import 'source_lines.dart';

/// Kinds of block spans.
enum SpanKind {
  paragraph,
  setextHeading,
  atxHeading,
  fencedCode,
  indentedCode,
  mathBlock,
  quote,
  list,
  table,
  tentativeTable,
  thematicBreak,
  html,
}

/// A contiguous run of lines forming one block.
@immutable
final class BlockSpan {
  const BlockSpan(
    this.kind,
    this.first,
    this.last, {
    required this.closed,
    required this.proofLine,
    this.level = 0,
    this.fence,
    this.fenceCloseLine,
    this.math,
    this.mathCloseLine,
    this.items = const [],
    this.alignments = const [],
  });

  final SpanKind kind;

  /// First and last line index (inclusive) within the scanned line list.
  final int first;
  final int last;

  /// Whether the block can no longer change.
  final bool closed;

  /// Index of the line whose presence proved [closed], or null when the
  /// block is only closed because the input was declared complete
  /// (provisional: an append must re-scan it).
  final int? proofLine;

  /// Heading level for [SpanKind.atxHeading] / [SpanKind.setextHeading].
  final int level;

  final FenceOpen? fence;

  /// Line index of the closing fence, if it has arrived.
  final int? fenceCloseLine;
  final MathOpen? math;
  final int? mathCloseLine;

  /// Items of a [SpanKind.list] span.
  final List<ListItemSpan> items;

  /// Column alignments of a [SpanKind.table] span.
  final List<MdAlign> alignments;

  BlockSpan copyWith({SpanKind? kind, int? first, int? last, bool? closed}) =>
      BlockSpan(
        kind ?? this.kind,
        first ?? this.first,
        last ?? this.last,
        closed: closed ?? this.closed,
        proofLine: proofLine,
        level: level,
        fence: fence,
        fenceCloseLine: fenceCloseLine,
        math: math,
        mathCloseLine: mathCloseLine,
        items: items,
        alignments: alignments,
      );

  @override
  String toString() =>
      'BlockSpan($kind, $first..$last, ${closed ? 'closed' : 'open'})';
}

/// One item of a list span.
@immutable
final class ListItemSpan {
  const ListItemSpan(this.first, this.last, this.marker);

  final int first;

  /// Last non-blank line of the item.
  final int last;
  final ListMarker marker;
}

/// Scans [lines] into block spans.
final class BlockScanner {
  BlockScanner(this.lines, {required this.complete});

  final List<SrcLine> lines;

  /// Whether the end of [lines] is the end of the document.
  final bool complete;

  int get _n => lines.length;

  String _t(int i) => lines[i].text;

  List<BlockSpan> scan() {
    final spans = <BlockSpan>[];
    var i = 0;
    while (i < _n) {
      if (isBlank(_t(i))) {
        i++;
        continue;
      }
      final span = _scanAt(i);
      spans.add(span);
      i = span.last + 1;
    }
    return spans;
  }

  /// The closure of a block whose end is proven by line [proof] (a blank
  /// line or the first line of the next block), if that line exists.
  ({bool closed, int? proofLine}) _provenBy(int proof) {
    if (proof < _n && lines[proof].terminated) {
      return (closed: true, proofLine: proof);
    }
    return (closed: complete, proofLine: null);
  }

  /// The closure of a block that ends at its own line [last] (headings,
  /// closing fences, thematic breaks).
  ({bool closed, int? proofLine}) _selfClosed(int last) {
    if (lines[last].terminated) return (closed: true, proofLine: last);
    return (closed: complete, proofLine: null);
  }

  BlockSpan _scanAt(int i) {
    final line = _t(i);
    if (indentOf(line) >= 4) return _scanIndentedCode(i);
    final fence = fenceOpen(line);
    if (fence != null) return _scanFence(i, fence);
    final math = mathOpen(line);
    if (math != null) {
      final span = _scanMath(i, math);
      if (span != null) return span;
    }
    final atx = atxLevel(line);
    if (atx != null) {
      final c = _selfClosed(i);
      return BlockSpan(
        SpanKind.atxHeading,
        i,
        i,
        closed: c.closed,
        proofLine: c.proofLine,
        level: atx,
      );
    }
    if (isQuoteLine(line)) return _scanQuote(i);
    if (isThematicBreak(line)) {
      final c = _selfClosed(i);
      return BlockSpan(
        SpanKind.thematicBreak,
        i,
        i,
        closed: c.closed,
        proofLine: c.proofLine,
      );
    }
    final marker = listMarker(line);
    if (marker != null) return _scanList(i, marker);
    final html = htmlBlockType(line);
    if (html != null) return _scanHtml(i, html);
    final table = _tableAt(i);
    if (table != null) return _scanTable(i, table);
    return _scanParagraph(i);
  }

  /// Whether [line] ends a paragraph (or a lazy continuation, or a table).
  /// Setext underlines and table starts are handled by the callers because
  /// they need lookahead.
  bool _interrupts(String line) {
    if (indentOf(line) >= 4) return false;
    if (fenceOpen(line) != null) return true;
    if (mathOpen(line) != null) return true;
    if (atxLevel(line) != null) return true;
    if (isQuoteLine(line)) return true;
    if (isThematicBreak(line)) return true;
    final marker = listMarker(line);
    if (marker != null && listMarkerInterruptsParagraph(marker)) return true;
    final html = htmlBlockType(line);
    return html != null && html <= 6;
  }

  /// Alignments if lines [i] (header) and [i]+1 (delimiter) start a table.
  List<MdAlign>? _tableAt(int i) {
    if (i + 1 >= _n) return null;
    final header = _t(i);
    if (indentOf(header) >= 4 || !hasPipe(header)) return null;
    final alignments = parseDelimiterRow(_t(i + 1));
    if (alignments == null) return null;
    if (splitTableCells(header).length != alignments.length) return null;
    return alignments;
  }

  BlockSpan _scanParagraph(int i) {
    var j = i;
    while (true) {
      final k = j + 1;
      if (k >= _n) {
        return BlockSpan(
          SpanKind.paragraph,
          i,
          j,
          closed: complete,
          proofLine: null,
        );
      }
      final next = _t(k);
      if (isBlank(next)) return _paragraph(i, j, _provenBy(k));
      final setext = setextLevel(next);
      if (setext != null && (lines[k].terminated || complete)) {
        final c = _selfClosed(k);
        return BlockSpan(
          SpanKind.setextHeading,
          i,
          k,
          closed: c.closed,
          proofLine: c.proofLine,
          level: setext,
        );
      }
      if (_tableAt(k) != null) {
        // The paragraph ends where the table's header row starts, but the
        // header only *is* a header once the delimiter row is final.
        return _paragraph(i, j, _provenBy(k + 1));
      }
      if (_interrupts(next)) return _paragraph(i, j, _provenBy(k));
      j = k;
    }
  }

  BlockSpan _paragraph(int i, int j, ({bool closed, int? proofLine}) c) =>
      BlockSpan(
        SpanKind.paragraph,
        i,
        j,
        closed: c.closed,
        proofLine: c.proofLine,
      );

  BlockSpan _scanIndentedCode(int i) {
    var j = i;
    var k = i + 1;
    while (k < _n) {
      final t = _t(k);
      if (isBlank(t)) {
        k++;
        continue;
      }
      if (indentOf(t) >= 4) {
        j = k;
        k++;
        continue;
      }
      break;
    }
    final c = k < _n ? _provenBy(k) : (closed: complete, proofLine: null);
    return BlockSpan(
      SpanKind.indentedCode,
      i,
      j,
      closed: c.closed,
      proofLine: c.proofLine,
    );
  }

  BlockSpan _scanFence(int i, FenceOpen fence) {
    for (var k = i + 1; k < _n; k++) {
      if (closesFence(_t(k), fence)) {
        final c = _selfClosed(k);
        return BlockSpan(
          SpanKind.fencedCode,
          i,
          k,
          closed: c.closed,
          proofLine: c.proofLine,
          fence: fence,
          fenceCloseLine: k,
        );
      }
    }
    // Unclosed: runs to the end of input (CommonMark), still open while
    // streaming.
    return BlockSpan(
      SpanKind.fencedCode,
      i,
      _n - 1,
      closed: complete,
      proofLine: null,
      fence: fence,
    );
  }

  /// Returns null when a `$$` block never closes in complete input: the
  /// opening line is then just text, which is the safer reading of a stray
  /// `$$` than "the rest of the message is TeX".
  BlockSpan? _scanMath(int i, MathOpen math) {
    if (math.singleLineTex != null) {
      final c = _selfClosed(i);
      return BlockSpan(
        SpanKind.mathBlock,
        i,
        i,
        closed: c.closed,
        proofLine: c.proofLine,
        math: math,
        mathCloseLine: i,
      );
    }
    for (var k = i + 1; k < _n; k++) {
      if (mathCloseContent(_t(k), math) != null) {
        final c = _selfClosed(k);
        return BlockSpan(
          SpanKind.mathBlock,
          i,
          k,
          closed: c.closed,
          proofLine: c.proofLine,
          math: math,
          mathCloseLine: k,
        );
      }
    }
    if (complete) return null;
    return BlockSpan(
      SpanKind.mathBlock,
      i,
      _n - 1,
      closed: false,
      proofLine: null,
      math: math,
    );
  }

  BlockSpan _scanHtml(int i, int type) {
    if (type <= 5) {
      for (var k = i; k < _n; k++) {
        if (htmlBlockEnds(type, _t(k))) {
          final c = _selfClosed(k);
          return BlockSpan(
            SpanKind.html,
            i,
            k,
            closed: c.closed,
            proofLine: c.proofLine,
          );
        }
      }
      return BlockSpan(
        SpanKind.html,
        i,
        _n - 1,
        closed: complete,
        proofLine: null,
      );
    }
    var k = i + 1;
    while (k < _n && !isBlank(_t(k))) {
      k++;
    }
    final c = k < _n ? _provenBy(k) : (closed: complete, proofLine: null);
    return BlockSpan(
      SpanKind.html,
      i,
      k - 1,
      closed: c.closed,
      proofLine: c.proofLine,
    );
  }

  BlockSpan _scanTable(int i, List<MdAlign> alignments) {
    var j = i + 1;
    while (true) {
      final k = j + 1;
      if (k >= _n) {
        return BlockSpan(
          SpanKind.table,
          i,
          j,
          closed: complete,
          proofLine: null,
          alignments: alignments,
        );
      }
      final t = _t(k);
      if (isBlank(t) || _interrupts(t)) {
        final c = _provenBy(k);
        return BlockSpan(
          SpanKind.table,
          i,
          j,
          closed: c.closed,
          proofLine: c.proofLine,
          alignments: alignments,
        );
      }
      j = k;
    }
  }

  BlockSpan _scanQuote(int i) {
    final inner = _ContainerState();
    var j = i;
    var k = i;
    while (k < _n) {
      final t = _t(k);
      if (isQuoteLine(t)) {
        inner.feed(stripQuoteMarker(t));
        j = k;
        k++;
        continue;
      }
      if (isBlank(t)) break;
      // Lazy continuation: an unprefixed line continues a paragraph that is
      // open inside the quote.
      if (inner.paragraphOpen && !_interrupts(t)) {
        j = k;
        k++;
        continue;
      }
      break;
    }
    final c = k < _n ? _provenBy(k) : (closed: complete, proofLine: null);
    return BlockSpan(
      SpanKind.quote,
      i,
      j,
      closed: c.closed,
      proofLine: c.proofLine,
    );
  }

  BlockSpan _scanList(int i, ListMarker first) {
    final starts = <int>[i];
    final markers = <ListMarker>[first];
    final inner = _ContainerState()..feed(first.content);
    var contentIndent = first.contentIndent;
    var j = i;
    var lastBlank = false;
    var k = i + 1;
    while (k < _n) {
      final t = _t(k);
      if (isBlank(t)) {
        lastBlank = true;
        inner.feed('');
        k++;
        continue;
      }
      final indent = indentOf(t);
      if (indent >= contentIndent) {
        inner.feed(dedent(t, contentIndent));
        j = k;
        lastBlank = false;
        k++;
        continue;
      }
      // Less indented than the item's content: a fence inside the item is
      // closed by the end of the item.
      inner.closeFence();
      if (isThematicBreak(t)) break;
      final marker = listMarker(t);
      if (marker != null) {
        if (!marker.sameListAs(first)) break;
        starts.add(k);
        markers.add(marker);
        contentIndent = marker.contentIndent;
        inner
          ..reset()
          ..feed(marker.content);
        j = k;
        lastBlank = false;
        k++;
        continue;
      }
      if (lastBlank) break;
      if (inner.paragraphOpen && !_interrupts(t)) {
        // Lazy continuation of the item's open paragraph.
        j = k;
        k++;
        continue;
      }
      break;
    }
    final items = <ListItemSpan>[];
    for (var n = 0; n < starts.length; n++) {
      var last = n + 1 < starts.length ? starts[n + 1] - 1 : j;
      while (last > starts[n] && isBlank(_t(last))) {
        last--;
      }
      items.add(ListItemSpan(starts[n], last, markers[n]));
    }
    final c = k < _n ? _provenBy(k) : (closed: complete, proofLine: null);
    return BlockSpan(
      SpanKind.list,
      i,
      j,
      closed: c.closed,
      proofLine: c.proofLine,
      items: items,
    );
  }
}

/// Tracks just enough of a container's (quote / list item) inner state to
/// decide lazy continuation: is a paragraph open, and is a fence open?
final class _ContainerState {
  FenceOpen? _fence;
  bool paragraphOpen = false;

  void reset() {
    _fence = null;
    paragraphOpen = false;
  }

  void closeFence() {
    if (_fence != null) {
      _fence = null;
      paragraphOpen = false;
    }
  }

  void feed(String content) {
    var c = content;
    // Nested quotes: look through every `>` level.
    while (isQuoteLine(c)) {
      c = stripQuoteMarker(c);
    }
    final fence = _fence;
    if (fence != null) {
      if (closesFence(c, fence)) _fence = null;
      paragraphOpen = false;
      return;
    }
    if (isBlank(c)) {
      paragraphOpen = false;
      return;
    }
    final open = fenceOpen(c);
    if (open != null) {
      _fence = open;
      paragraphOpen = false;
      return;
    }
    if (indentOf(c) >= 4) {
      // Indented code unless it continues a paragraph.
      return;
    }
    if (atxLevel(c) != null || isThematicBreak(c)) {
      paragraphOpen = false;
      return;
    }
    if (paragraphOpen && setextLevel(c) != null) {
      paragraphOpen = false;
      return;
    }
    final marker = listMarker(c);
    if (marker != null) {
      // A nested list item: its own first line is paragraph text.
      feed(marker.content);
      return;
    }
    paragraphOpen = true;
  }
}
