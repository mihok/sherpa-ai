import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../parse/md_ast.dart';
import 'image_view.dart';
import 'markdown_scope.dart';
import 'math_view.dart';

/// Renders a run of inline Markdown as one `Text.rich`.
///
/// One paragraph is one text layout, so selection inside a host
/// `SelectionArea` flows across emphasis and links, and long words or URLs
/// wrap (the text engine breaks overlong words) instead of overflowing.
/// The state owns the link recognizers: they must be disposed, and a frozen
/// block builds once, so its recognizers live as long as the block.
class InlineText extends StatefulWidget {
  const InlineText(
    this.inlines, {
    super.key,
    required this.style,
    this.textAlign = TextAlign.start,
  });

  final List<MdInline> inlines;
  final TextStyle style;
  final TextAlign textAlign;

  @override
  State<InlineText> createState() => _InlineTextState();
}

class _InlineTextState extends State<InlineText> {
  final _recognizers = <TapGestureRecognizer>[];

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Build and layout happen in the same frame, so the old spans are gone
    // before any pointer event can reach a disposed recognizer.
    _disposeRecognizers();
    final scope = MarkdownScope.of(context);
    final span = InlineSpanBuilder(scope, _recognizers.add).build(
      widget.inlines,
      widget.style,
    );
    return Text.rich(span, textAlign: widget.textAlign);
  }
}

/// Converts [MdInline]s to [InlineSpan]s.
final class InlineSpanBuilder {
  InlineSpanBuilder(this.scope, this.onRecognizer);

  final MarkdownScope scope;
  final void Function(TapGestureRecognizer recognizer) onRecognizer;

  InlineSpan build(List<MdInline> inlines, TextStyle style) =>
      TextSpan(style: style, children: _spans(inlines, style, null));

  List<InlineSpan> _spans(
    List<MdInline> nodes,
    TextStyle style,
    GestureRecognizer? link,
  ) {
    final out = <InlineSpan>[];
    for (final node in nodes) {
      switch (node) {
        case MdText(:final text):
          out.add(TextSpan(text: text, style: style, recognizer: link));
        case MdEmphasis(:final children):
          out.addAll(
            _spans(children, style.copyWith(fontStyle: FontStyle.italic), link),
          );
        case MdStrong(:final children):
          out.addAll(
            _spans(children, style.copyWith(fontWeight: FontWeight.w700), link),
          );
        case MdStrikethrough(:final children):
          out.addAll(
            _spans(
              children,
              style.copyWith(
                decoration: TextDecoration.combine([
                  if (style.decoration != null) style.decoration!,
                  TextDecoration.lineThrough,
                ]),
              ),
              link,
            ),
          );
        case MdInlineCode(:final code):
          out.add(
            TextSpan(text: code, style: _codeStyle(style), recognizer: link),
          );
        case MdLink():
          out.addAll(_link(node, style));
        case MdImage():
          out.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              // WidgetSpan children are scaled with the text already.
              child: MediaQuery.withNoTextScaling(
                child: MarkdownImage(image: node, inline: true),
              ),
            ),
          );
        case MdInlineMath(:final tex, :final display):
          out.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: MathView(
                tex: tex,
                display: display,
                style: style,
                inline: true,
                fallbackStyle: _codeStyle(style),
              ),
            ),
          );
        case MdLineBreak():
          out.add(TextSpan(text: '\n', style: style));
      }
    }
    return out;
  }

  List<InlineSpan> _link(MdLink node, TextStyle style) {
    final theme = scope.theme;
    final href = node.href;
    final uri = href == null ? null : Uri.tryParse(href);
    final tappable = uri != null && scope.allowsLink(uri);
    if (!tappable && !node.pending) {
      // A scheme the host does not allow (javascript:, file:, intent:…) is
      // shown as plain text: styling it as a link would invite a tap that
      // does nothing.
      return _spans(node.children, style, null);
    }
    final linkStyle = style.copyWith(
      color: theme.link,
      decoration: TextDecoration.combine([
        if (style.decoration != null) style.decoration!,
        TextDecoration.underline,
      ]),
      decorationColor: theme.link,
    );
    TapGestureRecognizer? recognizer;
    if (tappable) {
      final callbacks = scope.callbacks;
      recognizer = TapGestureRecognizer()..onTap = () => callbacks.linkTap(uri);
      onRecognizer(recognizer);
    }
    return _spans(node.children, linkStyle, recognizer);
  }

  TextStyle _codeStyle(TextStyle style) {
    final theme = scope.theme;
    final inline = theme.inlineCode;
    final ratio = (inline.fontSize ?? theme.fontSize * 0.9) / theme.fontSize;
    return inline.copyWith(
      fontSize: (style.fontSize ?? theme.fontSize) * ratio,
      fontWeight: style.fontWeight,
      fontStyle: style.fontStyle,
      // Inline code inherits the surrounding colour (quote, heading) unless
      // the host chose an inline-code colour explicitly.
      color: theme.inlineCodeColor ?? style.color,
      decoration: style.decoration,
      decorationColor: style.decorationColor,
    );
  }
}
