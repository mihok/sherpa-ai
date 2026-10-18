/// Turns scanned [BlockSpan]s into [MdNode]s, recursing into containers.
///
/// Containers (quotes, list items) are parsed by stripping their prefix
/// from each line and running the same scanner on the result, so nested
/// content follows exactly the rules the top level does. Streaming state
/// flows down: a container that is closed parses its content as complete,
/// and only the deepest *last* open block receives the streaming repairs.
library;

import 'block_scanner.dart';
import 'inline_parser.dart';
import 'md_ast.dart';
import 'source_lines.dart';

/// Builds AST nodes from block spans.
final class BlockBuilder {
  BlockBuilder(this.inline);

  final InlineMarkdownParser inline;

  /// Scans and builds all blocks in [lines] (a container's content).
  ///
  /// [streamingTail] marks content that ends at the live end of a
  /// streaming message: its last open block gets the tentative treatment
  /// (repaired inline tail, header-only table preview).
  List<MdNode> buildAll(
    List<SrcLine> lines, {
    required bool complete,
    required bool streamingTail,
  }) =>
      _children(lines, complete: complete, streamingTail: streamingTail).nodes;

  ({List<MdNode> nodes, List<BlockSpan> spans}) _children(
    List<SrcLine> lines, {
    required bool complete,
    required bool streamingTail,
  }) {
    var spans = BlockScanner(lines, complete: complete).scan();
    if (streamingTail) spans = splitTentativeTable(spans, lines);
    final nodes = <MdNode>[
      for (var i = 0; i < spans.length; i++)
        build(
          spans[i],
          lines,
          tentative: streamingTail && i == spans.length - 1 && !spans[i].closed,
        ),
    ];
    return (nodes: nodes, spans: spans);
  }

  /// Builds the node for one span. [tentative] is set only for the open
  /// block at the live end of a stream.
  MdNode build(BlockSpan span, List<SrcLine> lines, {required bool tentative}) {
    switch (span.kind) {
      case SpanKind.paragraph:
        return MdParagraph(
          inline.parse(
            paragraphText(lines, span.first, span.last),
            streamingTail: tentative,
          ),
        );
      case SpanKind.setextHeading:
        return MdHeading(
          span.level,
          inline.parse(paragraphText(lines, span.first, span.last - 1)),
        );
      case SpanKind.atxHeading:
        return MdHeading(
          span.level,
          inline.parse(
            atxContent(lines[span.first].text),
            streamingTail: tentative,
          ),
        );
      case SpanKind.fencedCode:
        return _fencedCode(span, lines);
      case SpanKind.indentedCode:
        return MdCodeBlock(
          [
            for (var k = span.first; k <= span.last; k++)
              dedent(lines[k].text, 4),
          ].join('\n'),
          complete: span.closed,
        );
      case SpanKind.mathBlock:
        return _math(span, lines);
      case SpanKind.quote:
        return MdQuote(
          buildAll(
            [
              for (var k = span.first; k <= span.last; k++)
                isQuoteLine(lines[k].text)
                    ? lines[k].derive(stripQuoteMarker(lines[k].text))
                    : lines[k],
            ],
            complete: span.closed,
            streamingTail: tentative,
          ),
        );
      case SpanKind.list:
        return _list(span, lines, tentative: tentative);
      case SpanKind.table:
        return _table(span, lines, tentative: tentative);
      case SpanKind.tentativeTable:
        final cells = splitTableCells(lines[span.first].text);
        return MdTable(
          alignments: List.filled(cells.length, MdAlign.none),
          header: [
            for (var c = 0; c < cells.length; c++)
              inline.parse(cells[c], streamingTail: c == cells.length - 1),
          ],
          rows: const [],
          tentative: true,
        );
      case SpanKind.thematicBreak:
        return const MdThematicBreak();
      case SpanKind.html:
        return MdHtmlBlock(
          [for (var k = span.first; k <= span.last; k++) lines[k].text]
              .join('\n'),
        );
    }
  }

  MdNode _fencedCode(BlockSpan span, List<SrcLine> lines) {
    final fence = span.fence!;
    final end = span.fenceCloseLine ?? span.last + 1;
    final code = [
      for (var k = span.first + 1; k < end; k++)
        dedent(lines[k].text, fence.indent),
    ].join('\n');
    // While the opening line is still streaming its info string is
    // incomplete (`j` → `js` → `json`); show no language until it is final.
    final infoFinal = lines[span.first].terminated || span.closed;
    final info = fence.info.isEmpty || !infoFinal ? null : fence.info;
    return MdCodeBlock(
      code,
      language: info == null ? null : fenceLanguage(info),
      info: info,
      complete: span.closed,
    );
  }

  MdNode _math(BlockSpan span, List<SrcLine> lines) {
    final open = span.math!;
    final single = open.singleLineTex;
    if (single != null) return MdMathBlock(single, complete: span.closed);
    final close = span.mathCloseLine;
    final parts = <String>[
      for (var k = span.first + 1; k < (close ?? span.last + 1); k++)
        lines[k].text,
      if (close != null) mathCloseContent(lines[close].text, open)!,
    ];
    return MdMathBlock(parts.join('\n').trim(), complete: span.closed);
  }

  MdNode _list(BlockSpan span, List<SrcLine> lines, {required bool tentative}) {
    final items = <MdListItem>[];
    var tight = true;
    for (var n = 0; n < span.items.length; n++) {
      final item = span.items[n];
      final marker = item.marker;
      final isLast = n == span.items.length - 1;
      var firstContent = marker.content;
      bool? checked;
      final task = taskPrefix(firstContent);
      if (task != null) {
        checked = task.checked;
        firstContent = task.rest;
      }
      final childLines = <SrcLine>[
        lines[item.first].derive(firstContent),
        for (var k = item.first + 1; k <= item.last; k++)
          isBlank(lines[k].text)
              ? lines[k].derive('')
              : indentOf(lines[k].text) >= marker.contentIndent
              ? lines[k].derive(dedent(lines[k].text, marker.contentIndent))
              : lines[k].derive(lines[k].text.trimLeft()),
      ];
      final children = _children(
        childLines,
        complete: span.closed || !isLast,
        streamingTail: tentative && isLast,
      );
      items.add(MdListItem(children.nodes, checked: checked));
      // Loose if a blank line separates two items, or two direct children
      // of one item.
      if (!isLast && span.items[n + 1].first > item.last + 1) tight = false;
      for (var c = 1; c < children.spans.length; c++) {
        if (children.spans[c].first > children.spans[c - 1].last + 1) {
          tight = false;
        }
      }
    }
    final first = span.items.first.marker;
    return MdList(
      ordered: first.ordered,
      start: first.ordered ? first.number : 1,
      tight: tight,
      items: items,
    );
  }

  MdNode _table(
    BlockSpan span,
    List<SrcLine> lines, {
    required bool tentative,
  }) {
    final columns = span.alignments.length;
    List<String> normalize(List<String> cells) => [
      for (var c = 0; c < columns; c++) c < cells.length ? cells[c] : '',
    ];
    final header = normalize(splitTableCells(lines[span.first].text));
    final rowCells = [
      for (var k = span.first + 2; k <= span.last; k++)
        normalize(splitTableCells(lines[k].text)),
    ];
    final lastRow = rowCells.length - 1;
    // Only the cell being typed gets the streaming repair.
    final typingCell = tentative && lastRow >= 0
        ? _lastNonEmpty(splitTableCells(lines[span.last].text), columns)
        : -1;
    return MdTable(
      alignments: span.alignments,
      header: [for (final cell in header) inline.parse(cell)],
      rows: [
        for (var r = 0; r < rowCells.length; r++)
          [
            for (var c = 0; c < columns; c++)
              inline.parse(
                rowCells[r][c],
                streamingTail: r == lastRow && c == typingCell,
              ),
          ],
      ],
    );
  }

  static int _lastNonEmpty(List<String> cells, int columns) {
    final n = cells.length < columns ? cells.length : columns;
    for (var c = n - 1; c >= 0; c--) {
      if (cells[c].isNotEmpty) return c;
    }
    return 0;
  }
}

/// A paragraph's inline source: lines joined with `\n`, leading whitespace
/// stripped per line (trailing spaces kept: they encode hard breaks).
String paragraphText(List<SrcLine> lines, int first, int last) {
  final b = StringBuffer();
  for (var k = first; k <= last; k++) {
    if (k > first) b.write('\n');
    b.write(lines[k].text.trimLeft());
  }
  return b.toString().trimRight();
}

/// Language from a fence info string: first word, lower-cased, with pandoc
/// attribute braces (`{.python}`) removed.
String? fenceLanguage(String info) {
  var word = info.split(RegExp(r'[ \t]')).first;
  if (word.startsWith('{')) word = word.substring(1);
  if (word.endsWith('}')) word = word.substring(0, word.length - 1);
  if (word.startsWith('.')) word = word.substring(1);
  word = word.trim().toLowerCase();
  return word.isEmpty ? null : word;
}

/// While streaming, a pipe row at the very end of an open paragraph is
/// shown as a header-only table: it is almost always the first row of a
/// table whose `|---|` delimiter has not arrived yet, and previewing it as
/// a table avoids a paragraph→table flip.
List<BlockSpan> splitTentativeTable(
  List<BlockSpan> spans,
  List<SrcLine> lines,
) {
  if (spans.isEmpty) return spans;
  final last = spans.last;
  if (last.kind != SpanKind.paragraph ||
      last.closed ||
      last.last != lines.length - 1) {
    return spans;
  }
  final row = afterUpTo3Spaces(lines[last.last].text);
  if (row == null || !row.startsWith('|')) return spans;
  final table = BlockSpan(
    SpanKind.tentativeTable,
    last.last,
    last.last,
    closed: false,
    proofLine: null,
  );
  return [
    ...spans.take(spans.length - 1),
    if (last.first < last.last) last.copyWith(last: last.last - 1),
    table,
  ];
}
