import 'dart:math';

import 'package:sherpa_markdown/parse.dart';

/// Nodes of [text] parsed in one go.
List<MdNode> nodesOf(String text, {bool complete = true}) => [
  for (final b in IncrementalMarkdownParser().update(text, complete: complete))
    b.node,
];

/// The single node of [text].
MdNode nodeOf(String text, {bool complete = true}) {
  final nodes = nodesOf(text, complete: complete);
  if (nodes.length != 1) {
    throw StateError('expected one block, got ${nodes.length}: $nodes');
  }
  return nodes.single;
}

/// Inlines of a one-paragraph [text].
List<MdInline> inlinesOf(String text, {bool complete = true}) {
  final node = nodeOf(text, complete: complete);
  if (node is! MdParagraph) throw StateError('not a paragraph: $node');
  return node.inlines;
}

/// Plain text of a paragraph's inlines.
String plain(List<MdInline> inlines) => plainTextOf(inlines);

/// Feeds [text] to a fresh parser in chunks; returns the parser.
IncrementalMarkdownParser stream(
  String text,
  Iterable<int> chunkSizes, {
  void Function(IncrementalMarkdownParser parser, List<MdBlock> blocks)?
  onUpdate,
}) {
  final parser = IncrementalMarkdownParser();
  var pos = 0;
  final sizes = chunkSizes.iterator;
  while (pos < text.length) {
    final step = sizes.moveNext() ? max(1, sizes.current) : 1;
    pos = min(text.length, pos + step);
    final blocks = parser.update(text.substring(0, pos));
    onUpdate?.call(parser, blocks);
  }
  return parser;
}

/// Endless seeded random chunk sizes in `[1, maxChunk]`.
Iterable<int> randomChunks(int seed, {int maxChunk = 16}) sync* {
  final r = Random(seed);
  while (true) {
    yield 1 + r.nextInt(maxChunk);
  }
}

/// Endless chunks of one character.
Iterable<int> charByChar() sync* {
  while (true) {
    yield 1;
  }
}
