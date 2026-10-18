import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';

/// Layout shared by onboarding steps: a scrolling, width-capped body and a
/// bottom action area that stays put, so the primary button is always in
/// thumb reach and never scrolls off at large text sizes.
class OnboardingStepLayout extends StatelessWidget {
  const OnboardingStepLayout({super.key, required this.children, required this.actions, this.title, this.lead});

  final String? title;
  final String? lead;
  final List<Widget> children;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(t.space.xl, t.space.lg, t.space.xl, t.space.xl),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: t.layout.maxFormWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (title != null)
                      Semantics(headingLevel: 1, child: Text(title!, style: theme.textTheme.headlineSmall)),
                    if (lead != null) ...[
                      SizedBox(height: t.space.sm),
                      Text(lead!, style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    ],
                    if (title != null || lead != null) SizedBox(height: t.space.xl),
                    ...children,
                  ],
                ),
              ),
            ),
          ),
        ),
        if (actions.isNotEmpty)
          SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(t.space.xl, t.space.sm, t.space.xl, t.space.lg),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: t.layout.maxFormWidth),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: actions,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A button-sized progress spinner for "working…" states in buttons.
class ButtonSpinner extends StatelessWidget {
  const ButtonSpinner({super.key});

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: DefaultTextStyle.of(context).style.color),
      );
}
