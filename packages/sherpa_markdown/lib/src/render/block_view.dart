import 'package:material_ui/material_ui.dart';

import '../parse/md_ast.dart';
import '../parse/md_block.dart';
import 'code_block.dart';
import 'image_view.dart';
import 'inline_text.dart';
import 'list_view.dart';
import 'markdown_scope.dart';
import 'markdown_style.dart';
import 'math_view.dart';
import 'table_view.dart';

/// Rendering context passed down through containers.
@immutable
final class NodeContext {
  const NodeContext({this.listDepth = 0, this.tight = false, this.quoted = false});

  /// Nesting depth of lists (selects the bullet glyph).
  final int listDepth;

  /// Inside a tight list item: paragraphs get no paragraph spacing.
  final bool tight;

  /// Inside a block quote: text is dimmed.
  final bool quoted;

  NodeContext copyWith({int? listDepth, bool? tight, bool? quoted}) => NodeContext(
    listDepth: listDepth ?? this.listDepth,
    tight: tight ?? this.tight,
    quoted: quoted ?? this.quoted,
  );

  TextStyle bodyStyle(MarkdownTheme theme) =>
      quoted ? theme.body.copyWith(color: theme.quoteText) : theme.body;

  TextStyle headingStyle(MarkdownTheme theme, int level) {
    final style = theme.headings[(level - 1).clamp(0, 5)];
    return quoted ? style.copyWith(color: theme.quoteText) : style;
  }
}

/// Renders one top-level block. The `StreamingMarkdown` state memoizes
/// these per frozen block, so their `build` runs once per block, not once
/// per token.
class MarkdownBlockView extends StatelessWidget {
  const MarkdownBlockView({super.key, required this.block});

  final MdBlock block;

  /// Test hook: called whenever a block view builds.
  @visibleForTesting
  static void Function(MdBlock block)? debugOnBuild;

  @override
  Widget build(BuildContext context) {
    debugOnBuild?.call(block);
    return MdNodeView(node: block.node, context: const NodeContext());
  }
}

/// Renders a list of sibling blocks (container content).
class BlockChildren extends StatelessWidget {
  const BlockChildren({
    super.key,
    required this.nodes,
    required this.context,
    this.spacing,
  });

  final List<MdNode> nodes;
  final NodeContext context;
  final double? spacing;

  @override
  Widget build(BuildContext buildContext) {
    final theme = MarkdownScope.of(buildContext).theme;
    if (nodes.length == 1) return MdNodeView(node: nodes.single, context: context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: spacing ?? (context.tight ? theme.blockSpacing * 0.25 : theme.blockSpacing),
      children: [for (final n in nodes) MdNodeView(node: n, context: context)],
    );
  }
}

/// Dispatches an [MdNode] to its widget.
class MdNodeView extends StatelessWidget {
  const MdNodeView({super.key, required this.node, required this.context});

  final MdNode node;
  final NodeContext context;

  @override
  Widget build(BuildContext buildContext) {
    final theme = MarkdownScope.of(buildContext).theme;
    return switch (node) {
      MdParagraph(:final inlines) => _paragraph(inlines, theme),
      MdHeading(:final level, :final inlines) => Semantics(
        container: true,
        headingLevel: level,
        child: Padding(
          padding: EdgeInsets.only(top: level <= 2 ? theme.blockSpacing * 0.5 : 0),
          child: InlineText(inlines, style: context.headingStyle(theme, level)),
        ),
      ),
      MdCodeBlock() => CodeBlockView(node: node as MdCodeBlock),
      MdMathBlock(:final tex, :final complete) => MathBlockView(
        tex: tex,
        complete: complete,
      ),
      MdQuote(:final children) => _QuoteView(
        children: children,
        context: context.copyWith(quoted: true, tight: false),
      ),
      MdList() => ListBlockView(list: node as MdList, context: context),
      MdTable() => TableBlockView(table: node as MdTable),
      MdThematicBreak() => Divider(
        height: theme.fontSize,
        thickness: 1,
        color: theme.divider,
      ),
      // Raw HTML is shown as the text it is; it is never interpreted.
      MdHtmlBlock(:final text) => Text(text, style: context.bodyStyle(theme)),
    };
  }

  Widget _paragraph(List<MdInline> inlines, MarkdownTheme theme) {
    if (inlines.isEmpty) return const SizedBox.shrink();
    // A paragraph that is just an image renders the image as a block.
    if (inlines.length == 1 && inlines.single is MdImage) {
      return MarkdownImage(image: inlines.single as MdImage);
    }
    return InlineText(inlines, style: context.bodyStyle(theme));
  }
}

class _QuoteView extends StatelessWidget {
  const _QuoteView({required this.children, required this.context});

  final List<MdNode> children;
  final NodeContext context;

  @override
  Widget build(BuildContext buildContext) {
    final theme = MarkdownScope.of(buildContext).theme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: BorderDirectional(
          start: BorderSide(color: theme.quoteBar, width: 3),
        ),
      ),
      child: Padding(
        padding: EdgeInsetsDirectional.only(start: theme.fontSize * 0.75),
        child: BlockChildren(nodes: children, context: context),
      ),
    );
  }
}
