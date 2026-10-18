import 'package:material_ui/material_ui.dart';

import '../parse/md_ast.dart';
import 'inline_text.dart';
import 'markdown_scope.dart';

/// A GFM table that scrolls horizontally instead of squeezing columns.
///
/// Columns size to their content up to a cap (≈18 em, scaled with the
/// user's text size), beyond which cell text wraps; the table as a whole
/// scrolls sideways on narrow screens. Intrinsic column sizing is
/// affordable here because a frozen table is laid out once.
class TableBlockView extends StatelessWidget {
  const TableBlockView({super.key, required this.table});

  final MdTable table;

  @override
  Widget build(BuildContext context) {
    final theme = MarkdownScope.of(context).theme;
    final scaler = MediaQuery.textScalerOf(context);
    final maxCell = scaler.scale(theme.fontSize) * 18;
    final headerStyle = theme.body.copyWith(fontWeight: FontWeight.w600);
    TableRow row(List<List<MdInline>> cells, TextStyle style, {Color? fill}) =>
        TableRow(
          decoration: fill == null ? null : BoxDecoration(color: fill),
          children: [
            for (var c = 0; c < table.columnCount; c++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: InlineText(
                  c < cells.length ? cells[c] : const [],
                  style: style,
                  textAlign: _align(table.alignments[c]),
                ),
              ),
          ],
        );
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: MinColumnWidth(
            const IntrinsicColumnWidth(),
            FixedColumnWidth(maxCell),
          ),
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          border: TableBorder.all(
            color: theme.tableBorder,
            borderRadius: BorderRadius.circular(8),
          ),
          children: [
            row(table.header, headerStyle, fill: theme.tableHeaderBackground),
            for (final r in table.rows) row(r, theme.body),
          ],
        ),
      ),
    );
  }

  static TextAlign _align(MdAlign align) => switch (align) {
    MdAlign.none || MdAlign.left => TextAlign.start,
    MdAlign.center => TextAlign.center,
    MdAlign.right => TextAlign.end,
  };
}
