/// Inline parsing on top of `package:markdown`'s CommonMark inline parser.
///
/// `package:markdown` gets the hard parts right (delimiter-run emphasis,
/// nested brackets, escapes, entities, autolinks), so this layer only
/// configures it for chat output and converts its AST into [MdInline]s:
/// * no inline HTML syntax — tags stay literal text, never markup,
/// * `encodeHtml: false` — text nodes carry raw characters, not entities,
/// * double-tilde-only strikethrough (`~5 min` is "about five minutes"),
/// * inline math syntaxes ahead of the defaults (so `\(` beats escapes).
library;

import 'package:markdown/markdown.dart' as md;

import 'inline_math.dart';
import 'inline_repair.dart';
import 'md_ast.dart';

/// Strikethrough that requires `~~`.
final class _DoubleTildeSyntax extends md.DelimiterSyntax {
  _DoubleTildeSyntax()
    : super(
        '~+',
        requiresDelimiterRun: true,
        allowIntraWord: true,
        startCharacter: 0x7E,
        tags: [md.DelimiterTag('del', 2)],
      );
}

/// Parses inline Markdown into [MdInline] nodes, memoizing exact results.
final class InlineMarkdownParser {
  InlineMarkdownParser({int memoSize = 512}) : _memoSize = memoSize;

  final int _memoSize;

  /// Exact (non-repaired) parses by source text. A long open list or quote
  /// is re-split on every token, but all its items except the last have
  /// the same text as last time; this keeps their inline parse O(1).
  // Map literals are insertion-ordered, which makes this an LRU.
  final _memo = <String, List<MdInline>>{};

  late final md.Document _document = md.Document(
    extensionSet: md.ExtensionSet.none,
    inlineSyntaxes: [
      InlineMathSyntax.dollar(),
      InlineMathSyntax.backslash(),
      _DoubleTildeSyntax(),
      md.AutolinkExtensionSyntax(),
    ],
    encodeHtml: false,
  );

  /// Number of inline parses actually run (memo misses); test hook.
  int parses = 0;

  /// Parses [text]. With [streamingTail] the end of the text is repaired
  /// first (see `inline_repair.dart`); such results are never memoized.
  List<MdInline> parse(String text, {bool streamingTail = false}) {
    if (!streamingTail) {
      final hit = _memo.remove(text);
      if (hit != null) {
        _memo[text] = hit;
        return hit;
      }
    }
    var source = text;
    var pendingUrl = false;
    if (streamingTail) {
      final repair = repairTrailingInline(text);
      source = repair.text;
      pendingUrl = repair.trailingUrlPending;
    }
    parses++;
    var inlines = source.trim().isEmpty
        ? const <MdInline>[]
        : List<MdInline>.unmodifiable(_convert(_document.parseInline(source)));
    if (pendingUrl) inlines = _markTrailingLinkPending(inlines);
    if (!streamingTail) {
      _memo[text] = inlines;
      if (_memo.length > _memoSize) _memo.remove(_memo.keys.first);
    }
    return inlines;
  }
}

List<MdInline> _convert(List<md.Node> nodes) {
  final out = <MdInline>[];
  void addText(String text) {
    if (text.isEmpty) return;
    if (out.isNotEmpty && out.last is MdText) {
      out[out.length - 1] = MdText((out.last as MdText).text + text);
    } else {
      out.add(MdText(text));
    }
  }

  for (final node in nodes) {
    switch (node) {
      case md.Text(:final text):
        addText(text);
      case md.Element():
        final children = node.children ?? const <md.Node>[];
        switch (node.tag) {
          case 'em':
            out.add(MdEmphasis(_convert(children)));
          case 'strong':
            out.add(MdStrong(_convert(children)));
          case 'del':
            out.add(MdStrikethrough(_convert(children)));
          case 'code':
            out.add(MdInlineCode(node.textContent));
          case 'br':
            out.add(const MdLineBreak());
          case 'a':
            final href = node.attributes['href'];
            out.add(
              MdLink(
                href: href == kPendingHref ? null : href,
                title: node.attributes['title'],
                children: _convert(children),
              ),
            );
          case 'img':
            final src = node.attributes['src'];
            out.add(
              MdImage(
                src: src == kPendingHref ? null : src,
                alt: node.attributes['alt'] ?? '',
                title: node.attributes['title'],
              ),
            );
          case kMathTag:
            out.add(
              MdInlineMath(
                node.textContent,
                display: node.attributes['display'] == '1',
              ),
            );
          default:
            // Anything else (should not occur with our syntax set) degrades
            // to its text rather than disappearing.
            for (final child in _convert(children)) {
              if (child is MdText) {
                addText(child.text);
              } else {
                out.add(child);
              }
            }
        }
      default:
        addText(node.textContent);
    }
  }
  return out;
}

final _autolinkTrailer = RegExp(r'''^[?!.,:*_~'")\]]+$''');

/// Makes the right-most link pending (its URL is still streaming in).
///
/// GFM leaves trailing punctuation (`?!.,:*_~`) out of an autolink, so
/// `https://x.com/a_` parses as a link to `…/a` followed by `_`; that link
/// is still the one being typed.
List<MdInline> _markTrailingLinkPending(List<MdInline> inlines) {
  if (inlines.isEmpty) return inlines;
  final last = inlines.last;
  if (last is MdText &&
      inlines.length > 1 &&
      inlines[inlines.length - 2] is MdLink &&
      _autolinkTrailer.hasMatch(last.text)) {
    final head = _markTrailingLinkPending(
      inlines.sublist(0, inlines.length - 1),
    );
    return List.unmodifiable([...head, last]);
  }
  final MdInline? replaced = switch (last) {
    MdLink(:final title, :final children) => MdLink(
      href: null,
      title: title,
      children: children,
    ),
    MdEmphasis(:final children) => _wrapIfChanged(children, MdEmphasis.new),
    MdStrong(:final children) => _wrapIfChanged(children, MdStrong.new),
    MdStrikethrough(:final children) => _wrapIfChanged(
      children,
      MdStrikethrough.new,
    ),
    _ => null,
  };
  if (replaced == null) return inlines;
  return List.unmodifiable([...inlines.take(inlines.length - 1), replaced]);
}

MdInline? _wrapIfChanged(
  List<MdInline> children,
  MdInline Function(List<MdInline>) wrap,
) {
  final updated = _markTrailingLinkPending(children);
  return identical(updated, children) ? null : wrap(updated);
}
