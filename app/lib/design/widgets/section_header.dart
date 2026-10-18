import 'package:material_ui/material_ui.dart';

import '../tokens.dart';

/// Group title inside a list or settings page.
///
/// Exposed as a real heading (`headingLevel`), because since Flutter 3.47
/// `header: true` is a no-op on iOS/Android and screen-reader users navigate
/// long settings pages by headings.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing, this.level = 2, this.padding});

  final String title;
  final Widget? trailing;
  final int level;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final style = Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary);
    return Padding(
      padding: padding ?? EdgeInsets.fromLTRB(t.space.lg, t.space.xl, t.space.lg, t.space.sm),
      child: Row(
        children: [
          Expanded(
            child: Semantics(headingLevel: level, child: Text(title, style: style)),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
