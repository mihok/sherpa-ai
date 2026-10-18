import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../../design/tokens.dart';
import 'chat_style.dart';

/// Pretty-printed JSON with long values truncated until the user asks for
/// everything.
///
/// Approvals must show the *exact* arguments (MCP SHOULD, docs/research/11
/// §9.7), but a 20 KB file body would bury the decision; so strings and
/// arrays are shortened in place with an explicit "+N more" marker, and one
/// tap reveals the untouched JSON.
class JsonPreview extends StatefulWidget {
  const JsonPreview({
    super.key,
    required this.value,
    this.maxStringLength = 160,
    this.maxItems = 8,
    this.maxHeight,
    this.onCopy,
    this.copyLabel = 'Copy',
  });

  final Object? value;
  final int maxStringLength;
  final int maxItems;

  /// Caps the expanded height (with its own scroll) where the preview is
  /// docked rather than inline in the transcript.
  final double? maxHeight;

  /// Receives the full, untruncated JSON.
  final void Function(String json)? onCopy;
  final String copyLabel;

  @override
  State<JsonPreview> createState() => _JsonPreviewState();
}

class _JsonPreviewState extends State<JsonPreview> {
  bool _expanded = false;
  late String _full;
  late String _short;
  late bool _truncated;

  @override
  void initState() {
    super.initState();
    _format();
  }

  @override
  void didUpdateWidget(JsonPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.value, widget.value)) _format();
  }

  void _format() {
    const encoder = JsonEncoder.withIndent('  ');
    _full = _encode(encoder, widget.value);
    var cut = false;
    final shortened = _shorten(widget.value, () => cut = true);
    _truncated = cut;
    _short = cut ? _encode(encoder, shortened) : _full;
  }

  static String _encode(JsonEncoder encoder, Object? value) {
    try {
      return encoder.convert(value);
    } on Object {
      return value.toString();
    }
  }

  Object? _shorten(Object? v, void Function() onCut) {
    switch (v) {
      case String() when v.length > widget.maxStringLength:
        onCut();
        return '${v.substring(0, widget.maxStringLength)}… (+${v.length - widget.maxStringLength} chars)';
      case List<Object?>():
        final items = [for (final e in v.take(widget.maxItems)) _shorten(e, onCut)];
        if (v.length > widget.maxItems) {
          onCut();
          items.add('… ${v.length - widget.maxItems} more');
        }
        return items;
      case Map<Object?, Object?>():
        return {for (final e in v.entries) e.key.toString(): _shorten(e.value, onCut)};
      default:
        return v;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final text = _expanded ? _full : _short;
    Widget body = SelectableText(text, style: chatMonoStyle(context));
    if (_expanded && widget.maxHeight != null) {
      body = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight!),
        child: SingleChildScrollView(child: body),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.semantic.codeSurface,
        borderRadius: BorderRadius.circular(tokens.radius.sm),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(tokens.space.md, tokens.space.sm, tokens.space.xs, tokens.space.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: Padding(padding: EdgeInsets.only(top: tokens.space.xs), child: body)),
                if (widget.onCopy != null)
                  IconButton(
                    tooltip: widget.copyLabel,
                    icon: const Icon(Icons.copy_rounded),
                    iconSize: ChatIconSize.medium,
                    onPressed: () => widget.onCopy!(_full),
                  ),
              ],
            ),
            if (_truncated)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(_expanded ? Icons.unfold_less_rounded : Icons.unfold_more_rounded, size: ChatIconSize.medium),
                  label: Text(_expanded ? 'Show less' : 'Show everything'),
                  style: TextButton.styleFrom(foregroundColor: theme.colorScheme.primary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
