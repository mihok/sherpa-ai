import 'package:material_ui/material_ui.dart';

import '../parse/incremental_parser.dart';
import '../parse/md_block.dart';
import 'block_view.dart';
import 'markdown_scope.dart';
import 'markdown_style.dart';

/// URI schemes rendered as tappable links unless the host says otherwise.
const kDefaultLinkSchemes = <String>{'http', 'https', 'mailto'};

/// Renders [text], which may still be growing while [streaming] is true.
///
/// The text is split into top-level blocks by an incremental parser.
/// Blocks that later text has proven complete are *frozen*: each is built
/// once, wrapped in a [RepaintBoundary] and reused as the identical widget
/// on every later frame, so a new token rebuilds, lays out and repaints
/// only the open block at the end. While streaming, that open block is
/// rendered tentatively — `**bol` is already bold, a half-received link is
/// styled but not tappable, an ambiguous partial line (`-`, `1`, `|--`) is
/// held back for a token — so the text never flips between readings.
///
/// Safety: links are never opened here ([onLinkTap] decides), raw HTML is
/// shown as text, and network images are placeholders until tapped.
///
/// Accessibility: nothing here is a live region (a growing live region
/// makes screen readers re-read the whole message on every token). While
/// [streaming] under TalkBack/VoiceOver, the open block is excluded from
/// semantics so a focused user never hears text rewrite underneath them;
/// it joins the tree once it freezes.
class StreamingMarkdown extends StatefulWidget {
  const StreamingMarkdown({
    super.key,
    required this.text,
    this.streaming = false,
    this.style = const SherpaMarkdownStyle(),
    this.onLinkTap,
    this.onCopyCode,
    this.selectable = true,
    this.linkSchemes = kDefaultLinkSchemes,
    this.parser,
  });

  final String text;
  final bool streaming;
  final SherpaMarkdownStyle style;

  /// Links are never opened directly; the host decides (and may confirm).
  final void Function(Uri uri)? onLinkTap;

  /// Called after a code block's copy button put [code] on the clipboard.
  final void Function(String code)? onCopyCode;

  /// Whether the text takes part in an ancestor `SelectionArea`. The host
  /// owns the `SelectionArea` (one per message keeps selection geometry
  /// bounded); false opts this subtree out.
  final bool selectable;

  /// Lower-case schemes rendered as tappable links. Links with other
  /// schemes (`javascript:`, `file:`, `intent:` …) render as plain text.
  final Set<String> linkSchemes;

  /// Optional externally owned parser, e.g. kept per message id so a
  /// lazily built chat list does not re-parse a message whenever its row
  /// is rebuilt. By default the widget owns one.
  final IncrementalMarkdownParser? parser;

  @override
  State<StreamingMarkdown> createState() => _StreamingMarkdownState();
}

class _StreamingMarkdownState extends State<StreamingMarkdown> {
  late IncrementalMarkdownParser _parser;
  final _callbacks = MarkdownCallbacks();
  final _cache = <String, _CachedBlock>{};
  List<MdBlock> _blocks = const [];

  @override
  void initState() {
    super.initState();
    _parser = widget.parser ?? IncrementalMarkdownParser();
    _syncCallbacks();
    _parse();
  }

  @override
  void didUpdateWidget(StreamingMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncCallbacks();
    if (!identical(widget.parser, oldWidget.parser)) {
      _parser = widget.parser ?? IncrementalMarkdownParser();
      _cache.clear();
      _parse();
    } else if (widget.text != oldWidget.text ||
        widget.streaming != oldWidget.streaming) {
      _parse();
    }
  }

  void _syncCallbacks() {
    _callbacks
      ..onLinkTap = widget.onLinkTap
      ..onCopyCode = widget.onCopyCode;
  }

  void _parse() {
    _blocks = _parser.update(widget.text, complete: !widget.streaming);
  }

  @override
  Widget build(BuildContext context) {
    final theme = MarkdownTheme.resolve(context, widget.style);
    final hideLiveTail =
        widget.streaming &&
        (MediaQuery.maybeAccessibleNavigationOf(context) ?? false);
    final children = <Widget>[];
    final live = <String>{};
    for (final block in _blocks) {
      live.add(block.id);
      children.add(_widgetFor(block, hideLiveTail));
    }
    if (_cache.length > live.length) {
      _cache.removeWhere((id, _) => !live.contains(id));
    }
    Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: theme.blockSpacing,
      children: children,
    );
    if (!widget.selectable) {
      content = SelectionContainer.disabled(child: content);
    }
    return MarkdownScope(
      theme: theme,
      callbacks: _callbacks,
      linkSchemes: widget.linkSchemes,
      child: content,
    );
  }

  /// Returns the cached widget for an unchanged block. Returning the
  /// *identical* widget instance is what makes Flutter skip the subtree:
  /// `Element.updateChild` short-circuits when old and new widget are the
  /// same object.
  Widget _widgetFor(MdBlock block, bool hideLiveTail) {
    final exclude = hideLiveTail && !block.frozen;
    final cached = _cache[block.id];
    if (cached != null &&
        identical(cached.block, block) &&
        cached.excluded == exclude) {
      return cached.widget;
    }
    // The structure is the same for open and frozen blocks, so a block
    // keeps its element (and e.g. a tapped image) when it freezes.
    final widget = RepaintBoundary(
      key: ValueKey(block.id),
      child: ExcludeSemantics(
        excluding: exclude,
        child: MarkdownBlockView(block: block),
      ),
    );
    _cache[block.id] = _CachedBlock(block, widget, excluded: exclude);
    return widget;
  }
}

final class _CachedBlock {
  _CachedBlock(this.block, this.widget, {required this.excluded});

  final MdBlock block;
  final Widget widget;
  final bool excluded;
}
