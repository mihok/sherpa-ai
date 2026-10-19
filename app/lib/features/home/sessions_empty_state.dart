import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../design/widgets/privacy_badge.dart';
import '../../design/widgets/sherpa_mark.dart';
import '../../design/widgets/state_views.dart';
import '../../routing/routes.dart';
import '../../state/app_providers.dart';
import '../../state/sessions.dart';
import 'home_actions.dart';

/// First-run home: makes the first chat one tap away and says, up front,
/// where it will run.
class SessionsEmptyState extends ConsumerWidget {
  const SessionsEmptyState({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configs = ref.watch(providerConfigsProvider).value ?? const [];
    final onDevice = ref.watch(localModelsProvider).value ?? const [];
    final showingArchived = ref.watch(showArchivedProvider);
    if (showingArchived) {
      return StateView(
        title: 'No archived chats',
        message: 'Swipe a chat to the right to archive it.',
        icon: Icons.archive_outlined,
        primaryAction: TextButton(
          onPressed: () => ref.read(showArchivedProvider.notifier).toggle(),
          child: const Text('Show active chats'),
        ),
      );
    }
    if (configs.isEmpty && onDevice.isEmpty) {
      return StateView(
        illustration: const SherpaMark(),
        title: 'Connect a model to start',
        message: 'Use OpenAI, Anthropic, OpenRouter or Hugging Face with your own key, '
            'or a model server on your own network. It takes about a minute.',
        primaryAction: FilledButton.icon(
          onPressed: () => context.go(Routes.newProvider),
          icon: const Icon(Icons.add),
          label: const Text('Connect a model'),
        ),
      );
    }
    return StateView(
      illustration: const SherpaMark(),
      title: 'Start your first chat',
      message: configs.isEmpty
          ? 'Ask, plan, draft or code. '
              '${onDevice.length == 1 ? 'The model on this phone is' : 'The ${onDevice.length} models on this phone are'} '
              'ready, and chats with ${onDevice.length == 1 ? 'it' : 'them'} stay on your phone.'
          : 'Ask, plan, draft or code. Sherpa runs the agent on your phone '
              'and shows you whenever data leaves it.',
      primaryAction: FilledButton.icon(
        onPressed: () => unawaited(startNewChat(context, ref)),
        icon: const Icon(Icons.edit_square),
        label: const Text('New chat'),
      ),
      secondaryAction: const _DefaultModelLine(),
    );
  }
}

class _DefaultModelLine extends ConsumerWidget {
  const _DefaultModelLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final choice = ref.watch(defaultModelProvider).value;
    if (choice == null) return const SizedBox.shrink();
    final privacy = ref.watch(providerPrivacyProvider(choice.providerId));
    final name = ref.watch(modelDisplayNameProvider(choice));
    final t = SherpaTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(top: t.space.md),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: t.space.sm,
        runSpacing: t.space.xs,
        children: [
          Text('New chats use $name', style: Theme.of(context).textTheme.bodySmall),
          if (privacy != null) PrivacyBadge(location: privacy.location, host: privacy.host),
        ],
      ),
    );
  }
}
