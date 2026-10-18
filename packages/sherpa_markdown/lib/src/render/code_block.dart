import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../parse/md_ast.dart';
import 'markdown_scope.dart';
import 'syntax_highlighter.dart';

/// A fenced or indented code block: language label, copy button and
/// horizontally scrolling, syntax-highlighted code.
///
/// Highlighting starts only once the block is complete (fence closed):
/// re-tokenizing a half-written block on every token costs time and makes
/// colours jump as grammar states resolve. Small blocks are highlighted
/// synchronously (sub-millisecond); large ones on a background isolate
/// while the plain text is shown.
class CodeBlockView extends StatefulWidget {
  const CodeBlockView({super.key, required this.node});

  final MdCodeBlock node;

  @override
  State<CodeBlockView> createState() => _CodeBlockViewState();
}

class _CodeBlockViewState extends State<CodeBlockView> {
  List<HighlightToken>? _tokens;
  String? _tokensFor;
  int _request = 0;
  bool _copied = false;
  Timer? _copiedTimer;

  @override
  void initState() {
    super.initState();
    _highlight();
  }

  @override
  void didUpdateWidget(CodeBlockView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node != widget.node) _highlight();
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  void _highlight() {
    final node = widget.node;
    final language = SyntaxHighlighter.resolve(node.language);
    final key = '$language\u0000${node.code}';
    if (!node.complete || language == null) {
      _tokens = null;
      _tokensFor = null;
      return;
    }
    if (_tokensFor == key) return;
    final cached = SyntaxHighlighter.cached(node.code, language);
    if (cached != null) {
      _tokens = cached;
      _tokensFor = key;
      return;
    }
    if (node.code.length <= SyntaxHighlighter.isolateThreshold) {
      _tokens = SyntaxHighlighter.highlightSync(node.code, language);
      _tokensFor = key;
      return;
    }
    _tokens = null;
    _tokensFor = null;
    final request = ++_request;
    SyntaxHighlighter.highlightAsync(node.code, language).then((tokens) {
      if (!mounted || request != _request) return;
      setState(() {
        _tokens = tokens;
        _tokensFor = key;
      });
    }, onError: (Object _) {});
  }

  Future<void> _copy() async {
    final code = widget.node.code;
    await Clipboard.setData(ClipboardData(text: code));
    unawaited(HapticFeedback.lightImpact());
    if (!mounted) return;
    MarkdownScope.of(context).callbacks.copiedCode(code);
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = MarkdownScope.of(context).theme;
    final node = widget.node;
    final tokens = _tokens;
    final span = tokens == null
        ? TextSpan(text: node.code, style: theme.code)
        : SyntaxHighlighter.toSpan(node.code, tokens, theme.code, theme.syntax);
    final label = node.language ?? (node.info == null ? 'code' : node.info!);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.codeBackground,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CodeHeader(label: label, copied: _copied, onCopy: _copy),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: Text.rich(span, softWrap: false),
          ),
        ],
      ),
    );
  }
}

class _CodeHeader extends StatelessWidget {
  const _CodeHeader({
    required this.label,
    required this.copied,
    required this.onCopy,
  });

  final String label;
  final bool copied;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = MarkdownScope.of(context).theme;
    final chrome = theme.body.copyWith(
      color: theme.codeChrome,
      fontSize: theme.fontSize * 0.78,
      fontWeight: FontWeight.w500,
    );
    final tooltip = copied ? 'Copied' : 'Copy code';
    Widget button = IconButton(
      onPressed: onCopy,
      visualDensity: VisualDensity.compact,
      iconSize: theme.fontSize * 1.1,
      color: theme.codeChrome,
      icon: Icon(
        copied ? Icons.check_rounded : Icons.content_copy_rounded,
        semanticLabel: tooltip,
      ),
    );
    // A tooltip needs an Overlay; hosts may render messages outside one.
    if (Overlay.maybeOf(context) != null) {
      button = Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: button,
      );
    }
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 14, end: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: chrome,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // The copy button must not become part of a text selection.
          SelectionContainer.disabled(
            // IconButton needs a Material ancestor for its ink; a
            // transparent one keeps the block usable on any surface.
            child: Material(type: MaterialType.transparency, child: button),
          ),
        ],
      ),
    );
  }
}
