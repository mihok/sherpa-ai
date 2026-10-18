/// The incremental, streaming-aware Markdown parser.
library;

import 'package:meta/meta.dart';

import 'block_builder.dart';
import 'block_scanner.dart';
import 'inline_parser.dart';
import 'md_ast.dart';
import 'md_block.dart';
import 'source_lines.dart';

/// Parses a Markdown document that grows while a model streams it.
///
/// Call [update] with the *full* text so far after every delta. The parser
/// keeps the blocks that are already proven complete ("frozen") and only
/// re-scans and re-parses the text after the last frozen block, so the cost
/// of an update is proportional to the open tail, not to the message:
///
/// ```text
///  frozen (cached, identical instances)        open tail (re-parsed)
/// ├──────────┼────────┼──────────────────────┼───────────────────────┤
///  heading    para     code (fence closed)     paragraph being typed
/// ```
///
/// Text may also be replaced arbitrarily (a regenerate, an edit): frozen
/// blocks are kept only while the text up to the line that proved them is
/// unchanged, and blocks after a replacement get fresh ids.
///
/// Guarantees (enforced by tests):
/// * Feeding a text in any chunking yields the same block list as one
///   [update] with the whole text.
/// * A frozen block is never re-parsed and never changes.
final class IncrementalMarkdownParser {
  IncrementalMarkdownParser({InlineMarkdownParser? inline})
    : _builder = BlockBuilder(inline ?? InlineMarkdownParser());

  final BlockBuilder _builder;

  String _text = '';
  bool _complete = false;
  final List<_Frozen> _frozen = [];
  List<_Open> _open = const [];
  List<MdBlock> _blocks = const [];
  int _generation = 0;

  /// Number of top-level block parses performed so far. Frozen blocks are
  /// never counted again; tests use this to prove the caching.
  int get parseCount => _parseCount;
  int _parseCount = 0;

  /// The current blocks (frozen prefix first, then open blocks).
  List<MdBlock> get blocks => _blocks;

  /// The text of the last [update].
  String get text => _text;

  /// Parses [text] once, as a complete document.
  static List<MdBlock> parse(String text) =>
      IncrementalMarkdownParser().update(text, complete: true);

  /// Updates the parse with the full [text] so far.
  ///
  /// [complete] declares that no more text will arrive: the last block is
  /// then frozen too and no streaming repairs are applied. Leaving it false
  /// while streaming holds back an ambiguous partial last line and renders
  /// the open block tentatively (auto-closed emphasis, pending links).
  List<MdBlock> update(String text, {bool complete = false}) {
    if (complete == _complete && text == _text) return _blocks;
    _invalidate(text);
    final resume = _frozen.isEmpty ? 0 : _frozen.last.resumeAt;
    final lines = splitLines(text, resume);
    if (!complete &&
        lines.isNotEmpty &&
        !lines.last.terminated &&
        isAmbiguousPartialLine(lines.last.text)) {
      lines.removeLast();
    }
    var spans = BlockScanner(lines, complete: complete).scan();
    if (!complete) spans = splitTentativeTable(spans, lines);

    final previousOpen = _open;
    final open = <_Open>[];
    var prefixClosed = true;
    for (var i = 0; i < spans.length; i++) {
      final span = spans[i];
      final freeze = prefixClosed && span.closed;
      prefixClosed = freeze;
      final tentative = !complete && !span.closed && i == spans.length - 1;
      final index = _frozen.length + open.length;
      final start = lines[span.first].start;
      final end = lines[span.last].end;
      final source = text.substring(start, end);
      final id = _idFor(index);

      // An open block whose inputs did not change keeps its instance (and
      // so its widget) — e.g. a paragraph above a heading being typed. If
      // only its frozen flag flips, the parsed node is still reused.
      MdBlock? block;
      final prev = open.length < previousOpen.length
          ? previousOpen[open.length]
          : null;
      // `extent` includes the last line's terminator: a block's source
      // excludes its final newline, but whether that line has ended
      // changes how it parses (a fence's info string becomes final).
      final extent = lines[span.last].nextStart;
      if (prev != null &&
          prev.kind == span.kind &&
          prev.closed == span.closed &&
          prev.tentative == tentative &&
          prev.extent == extent &&
          prev.block.id == id &&
          prev.block.start == start &&
          prev.block.source == source) {
        block = prev.block.frozen == freeze
            ? prev.block
            : MdBlock(
                id: id,
                index: index,
                start: start,
                end: end,
                source: source,
                frozen: freeze,
                node: prev.block.node,
              );
      }
      block ??= _build(
        span,
        lines,
        id: id,
        index: index,
        start: start,
        end: end,
        source: source,
        frozen: freeze,
        tentative: tentative,
      );
      if (freeze) {
        final proof = span.proofLine;
        _frozen.add(
          _Frozen(
            block,
            resumeAt: lines[span.last].nextStart,
            // A provisional block (closed only by `complete`) must not
            // survive any change of the text.
            proofEnd: proof == null ? -1 : lines[proof].nextStart,
          ),
        );
      } else {
        open.add(
          _Open(
            block,
            kind: span.kind,
            closed: span.closed,
            tentative: tentative,
            extent: extent,
          ),
        );
      }
    }
    _open = open;
    _text = text;
    _complete = complete;
    _blocks = List.unmodifiable([
      for (final f in _frozen) f.block,
      for (final o in open) o.block,
    ]);
    return _blocks;
  }

  /// Forgets everything (e.g. when a different message is shown).
  void reset() {
    _text = '';
    _complete = false;
    _frozen.clear();
    _open = const [];
    _blocks = const [];
    _generation++;
  }

  /// Drops frozen blocks that [text] no longer supports.
  void _invalidate(String text) {
    // Fast path: pure append keeps every block with a real proof.
    final appended = text.length >= _text.length && text.startsWith(_text);
    final common = appended ? _text.length : _commonPrefix(_text, text);
    var keep = _frozen.length;
    while (keep > 0) {
      final proofEnd = _frozen[keep - 1].proofEnd;
      if (proofEnd >= 0 && proofEnd <= common) break;
      keep--;
    }
    if (keep == _frozen.length) return;
    final droppedReal = _frozen
        .skip(keep)
        .any((f) => f.proofEnd >= 0 && !appended);
    _frozen.removeRange(keep, _frozen.length);
    if (droppedReal || !appended) {
      // Content at or before these blocks was replaced: their ids must not
      // be reused for different content.
      _generation++;
      _open = const [];
    }
  }

  String _idFor(int index) =>
      _generation == 0 ? 'b$index' : 'b$index.g$_generation';

  MdBlock _build(
    BlockSpan span,
    List<SrcLine> lines, {
    required String id,
    required int index,
    required int start,
    required int end,
    required String source,
    required bool frozen,
    required bool tentative,
  }) {
    _parseCount++;
    final MdNode node = _builder.build(span, lines, tentative: tentative);
    return MdBlock(
      id: id,
      index: index,
      start: start,
      end: end,
      source: source,
      frozen: frozen,
      node: node,
    );
  }

  static int _commonPrefix(String a, String b) {
    final n = a.length < b.length ? a.length : b.length;
    var i = 0;
    while (i < n && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
    }
    return i;
  }
}

@immutable
final class _Frozen {
  const _Frozen(this.block, {required this.resumeAt, required this.proofEnd});

  final MdBlock block;

  /// Offset of the first line after the block: scanning resumes here.
  final int resumeAt;

  /// Offset just past the line that proved the block complete; the block
  /// stays valid while the text up to here is unchanged. -1 = provisional.
  final int proofEnd;
}

@immutable
final class _Open {
  const _Open(
    this.block, {
    required this.kind,
    required this.closed,
    required this.tentative,
    required this.extent,
  });

  final MdBlock block;
  final SpanKind kind;
  final bool closed;
  final bool tentative;
  final int extent;
}
