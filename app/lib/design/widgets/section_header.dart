import 'package:material_ui/material_ui.dart';

import '../tokens.dart';
import 'a11y.dart';

/// Group title inside a list or settings page.
///
/// Exposed as a real heading ([Heading]: `headingLevel`, because since
/// Flutter 3.47 `header: true` alone is not announced as one on iOS or
/// Android), since screen-reader users navigate long pages by headings.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing, this.level = 2, this.padding, this.count});

  final String title;
  final Widget? trailing;
  final int level;
  final EdgeInsetsGeometry? padding;

  /// Spoken after the title ("2 downloads"), so a screen-reader user who
  /// jumps between headings hears how long each list is.
  final String? count;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final style = Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary);
    // A trailing count or button is read after the heading, not merged
    // into a node around it that would be read first.
    return HeadingGroup(
      child: Padding(
        padding: padding ?? EdgeInsets.fromLTRB(t.space.lg, t.space.xl, t.space.lg, t.space.sm),
        child: Row(
          children: [
            Expanded(
              child: Heading(level: level, value: count, child: Text(title, style: style)),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}
