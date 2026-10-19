import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../design/widgets/sherpa_mark.dart';
import '../providers/fields.dart';
import 'onboarding_scaffold.dart';

/// Step 0: what Sherpa is, in three promises, and one button.
class WelcomeStep extends StatelessWidget {
  const WelcomeStep({super.key, required this.onStart, required this.onSkip});

  final VoidCallback onStart;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return OnboardingStepLayout(
      actions: [
        FilledButton(onPressed: onStart, child: const Text('Get started')),
        SizedBox(height: t.space.xs),
        TextButton(onPressed: onSkip, child: const Text('Skip for now')),
      ],
      children: [
        SizedBox(height: t.space.xl),
        const Align(alignment: AlignmentDirectional.centerStart, child: SherpaMark(size: 80)),
        SizedBox(height: t.space.xl),
        Semantics(headingLevel: 1, child: Text('Meet Sherpa', style: theme.textTheme.displaySmall)),
        SizedBox(height: t.space.md),
        Text(
          'An open agent that lives on your phone and works with the models you choose.',
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w400,
          ),
        ),
        SizedBox(height: t.space.xxl),
        const _Promise(
          icon: Icons.alt_route_rounded,
          title: 'You choose where it runs',
          body: 'A model that runs fully on this phone, a cloud model with your own key, or a server on your '
              'own network.',
        ),
        _Promise(
          icon: Icons.lock_outline,
          title: 'Keys stay on this phone',
          body: 'Stored in the $secureStoreName and sent only to the provider they belong to. '
              'Sherpa has no servers of its own.',
        ),
        const _Promise(
          icon: Icons.visibility_outlined,
          title: 'Nothing hidden',
          body: 'Every chat shows whether your data leaves the device, and exactly where it goes.',
        ),
      ],
    );
  }
}

class _Promise extends StatelessWidget {
  const _Promise({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: t.space.xl),
      child: MergeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            SizedBox(width: t.space.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  SizedBox(height: t.space.xxs),
                  Text(body, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
