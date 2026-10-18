import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:material_ui/material_ui.dart';

import '../parse/md_ast.dart';
import 'block_view.dart';
import 'markdown_scope.dart';

/// An ordered, unordered or task list.
///
/// Markers sit in a column as wide as the widest marker (measured with the
/// user's text scale) so item text lines up across `9.` and `10.`, and are
/// baseline-aligned with the first line of their item.
class ListBlockView extends StatelessWidget {
  const ListBlockView({super.key, required this.list, required this.context});

  final MdList list;
  final NodeContext context;

  // Glyphs present in Roboto and the platform UI fonts.
  static const _bullets = ['•', '◦', '–'];

  @override
  Widget build(BuildContext buildContext) {
    final theme = MarkdownScope.of(buildContext).theme;
    final scaler = MediaQuery.textScalerOf(buildContext);
    final textStyle = context.bodyStyle(theme);
    final depth = context.listDepth;
    String markerText(int i) => list.ordered
        ? '${list.start + i}.'
        : _bullets[math.min(depth, _bullets.length - 1)];
    final hasTasks = list.items.any((item) => item.checked != null);
    final iconSize = scaler.scale(theme.fontSize) * 1.15;
    var markerWidth = hasTasks ? iconSize : 0.0;
    for (var i = 0; i < list.items.length; i++) {
      if (list.items[i].checked != null) continue;
      final painter = TextPainter(
        text: TextSpan(text: markerText(i), style: textStyle),
        textDirection: Directionality.of(buildContext),
        textScaler: scaler,
      )..layout();
      markerWidth = math.max(markerWidth, painter.width);
      painter.dispose();
    }
    final itemGap = list.tight ? theme.blockSpacing * 0.25 : theme.blockSpacing;
    final childContext = context.copyWith(
      listDepth: depth + 1,
      tight: list.tight,
    );
    return Semantics(
      container: true,
      role: SemanticsRole.list,
      explicitChildNodes: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: itemGap,
        children: [
          for (var i = 0; i < list.items.length; i++)
            Semantics(
              container: true,
              role: SemanticsRole.listItem,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  SizedBox(
                    width: markerWidth,
                    child: list.items[i].checked == null
                        ? ExcludeSemantics(
                            child: Text(
                              markerText(i),
                              style: textStyle,
                              textAlign: TextAlign.end,
                            ),
                          )
                        : _TaskBox(
                            checked: list.items[i].checked!,
                            size: iconSize,
                          ),
                  ),
                  SizedBox(width: theme.fontSize * 0.5),
                  Expanded(
                    child: BlockChildren(
                      nodes: list.items[i].children,
                      context: childContext,
                      spacing: itemGap,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A read-only task checkbox. An icon rather than `Checkbox`: a disabled
/// Material checkbox reads as "unavailable", and this one is not an input
/// at all — screen readers get the checked state, not a control.
class _TaskBox extends StatelessWidget {
  const _TaskBox({required this.checked, required this.size});

  final bool checked;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = MarkdownScope.of(context).theme;
    // Only the state: it merges into the list item, which then reads as
    // "checked, <item text>".
    return Semantics(
      checked: checked,
      child: ExcludeSemantics(
        child: Icon(
          checked
              ? Icons.check_box_rounded
              : Icons.check_box_outline_blank_rounded,
          size: size,
          color: checked ? theme.taskChecked : theme.taskUnchecked,
        ),
      ),
    );
  }
}
