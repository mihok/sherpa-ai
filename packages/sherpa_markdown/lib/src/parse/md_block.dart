/// Top-level blocks as handed to the renderer.
library;

import 'package:meta/meta.dart';

import 'md_ast.dart';

/// Coarse kind of a top-level block (convenience for hosts and tests).
enum MdBlockKind {
  paragraph,
  heading,
  code,
  math,
  quote,
  list,
  table,
  thematicBreak,
  html,
}

/// One top-level block of a (possibly still streaming) Markdown document.
///
/// Blocks are the renderer's unit of caching: a [frozen] block's content
/// can no longer change, so the parser hands out the *identical* instance
/// on every later update and the renderer can skip rebuilding it.
@immutable
final class MdBlock {
  const MdBlock({
    required this.id,
    required this.index,
    required this.start,
    required this.end,
    required this.source,
    required this.frozen,
    required this.node,
  });

  /// Stable identity used as the widget key. It survives growth of the
  /// open block (paragraph → table keeps its id) and changes only when the
  /// text before or at this block is replaced, so per-block UI state (a
  /// tapped image, a copied-code tick) never leaks onto different content.
  final String id;

  /// Position in the document.
  final int index;

  /// Source range `[start, end)` in the full text.
  final int start;
  final int end;

  /// `text.substring(start, end)`.
  final String source;

  /// Whether later text has proven this block complete.
  final bool frozen;

  final MdNode node;

  MdBlockKind get kind => switch (node) {
    MdParagraph() => MdBlockKind.paragraph,
    MdHeading() => MdBlockKind.heading,
    MdCodeBlock() => MdBlockKind.code,
    MdMathBlock() => MdBlockKind.math,
    MdQuote() => MdBlockKind.quote,
    MdList() => MdBlockKind.list,
    MdTable() => MdBlockKind.table,
    MdThematicBreak() => MdBlockKind.thematicBreak,
    MdHtmlBlock() => MdBlockKind.html,
  };

  @override
  bool operator ==(Object other) =>
      other is MdBlock &&
      id == other.id &&
      index == other.index &&
      start == other.start &&
      end == other.end &&
      frozen == other.frozen &&
      source == other.source &&
      node == other.node;

  @override
  int get hashCode => Object.hash(id, index, start, end, frozen, source, node);

  @override
  String toString() =>
      'MdBlock($id, ${frozen ? 'frozen' : 'open'}, [$start,$end), $node)';
}
