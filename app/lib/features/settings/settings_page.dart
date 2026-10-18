import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';

/// Scaffold for settings pages: app bar with a real heading, and a body
/// capped to a readable width on tablets.
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.title,
    required this.children,
    this.actions,
    this.floatingActionButton,
    this.bottom,
  });

  final String title;
  final List<Widget> children;
  final List<Widget>? actions;
  final Widget? floatingActionButton;

  /// Pinned below the list (e.g. a Save button).
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    return Scaffold(
      appBar: AppBar(title: Semantics(headingLevel: 1, child: Text(title)), actions: actions),
      floatingActionButton: floatingActionButton,
      body: Column(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: t.layout.maxContentWidth),
                child: ListView(
                  padding: EdgeInsets.only(bottom: t.space.xxxl + MediaQuery.paddingOf(context).bottom),
                  children: children,
                ),
              ),
            ),
          ),
          if (bottom != null)
            SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(t.space.lg, t.space.sm, t.space.lg, t.space.lg),
                child: ConstrainedBox(constraints: BoxConstraints(maxWidth: t.layout.maxContentWidth), child: bottom),
              ),
            ),
        ],
      ),
    );
  }
}

/// Body padding for non-tile content inside a [SettingsPage].
class SettingsPadding extends StatelessWidget {
  const SettingsPadding({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    return Padding(padding: EdgeInsets.symmetric(horizontal: t.space.lg), child: child);
  }
}
