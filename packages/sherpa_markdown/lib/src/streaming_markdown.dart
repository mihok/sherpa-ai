import 'package:material_ui/material_ui.dart';

/// Colors and text styles the host app supplies (sherpa_markdown cannot
/// depend on the app's design tokens).
@immutable
class SherpaMarkdownStyle {
  const SherpaMarkdownStyle({
    this.body,
    this.code,
    this.codeBackground,
    this.quoteColor,
    this.linkColor,
    this.dividerColor,
  });

  final TextStyle? body;
  final TextStyle? code;
  final Color? codeBackground;
  final Color? quoteColor;
  final Color? linkColor;
  final Color? dividerColor;
}

/// Renders [text], which may still be growing while [streaming] is true.
///
/// STUB: plain text until the incremental renderer lands. The constructor
/// signature is the contract the chat UI codes against.
class StreamingMarkdown extends StatelessWidget {
  const StreamingMarkdown({
    super.key,
    required this.text,
    this.streaming = false,
    this.style = const SherpaMarkdownStyle(),
    this.onLinkTap,
    this.onCopyCode,
    this.selectable = true,
  });

  final String text;
  final bool streaming;
  final SherpaMarkdownStyle style;

  /// Links are never opened directly; the host decides (and may confirm).
  final void Function(Uri uri)? onLinkTap;

  /// Called after a code block's copy button put [code] on the clipboard.
  final void Function(String code)? onCopyCode;
  final bool selectable;

  @override
  Widget build(BuildContext context) => Text(text, style: style.body);
}
