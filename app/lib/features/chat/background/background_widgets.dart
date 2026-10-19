import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets/a11y.dart';
import '../../../services/background/background_providers.dart';
import '../../../services/background/run_activity.dart';
import '../../../state/ui_preferences.dart';

/// "Allow notifications?" above the composer, the first time a run could
/// continue in the background (Android 13+ asks for POST_NOTIFICATIONS at
/// runtime). Says why before the system dialog appears; asked once, and
/// "Not now" is remembered. The run goes on either way: without the
/// permission the work still finishes, only the notification is hidden.
class BackgroundNotificationsPrompt extends ConsumerWidget {
  const BackgroundNotificationsPrompt({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ask = ref.watch(runActivitySnapshotProvider.select((s) => s.askForNotifications));
    if (!ask) return const SizedBox.shrink();
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final activity = ref.read(runActivityProvider);
    final fg = theme.colorScheme.onSecondaryContainer;
    return HeadingGroup(
      child: Container(
        width: double.infinity,
        padding: EdgeInsetsDirectional.fromSTEB(tokens.space.lg, tokens.space.md, tokens.space.sm, tokens.space.sm),
        decoration: BoxDecoration(
          color: theme.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(tokens.radius.lg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.notifications_active_outlined, color: fg),
                SizedBox(width: tokens.space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Heading(
                        child: Text('Keep you posted?', style: theme.textTheme.titleSmall?.copyWith(color: fg)),
                      ),
                      SizedBox(height: tokens.space.xxs),
                      Text(
                        'Replies keep going when you leave Sherpa. Allow notifications to see that it is still '
                        'working and to know when a reply is ready. They name the chat, never its messages.',
                        style: theme.textTheme.bodyMedium?.copyWith(color: fg),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Wrap(
                spacing: tokens.space.sm,
                children: [
                  TextButton(
                    onPressed: () => unawaited(activity.answerNotificationPrompt(allow: false)),
                    child: const Text('Not now'),
                  ),
                  FilledButton.tonal(
                    onPressed: () => unawaited(activity.answerNotificationPrompt(allow: true)),
                    child: const Text('Allow notifications'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Keep working in the background" for the settings screen.
///
/// On Android, turning it on asks for the notifications permission when it
/// is missing (the subtitle is the reason, and the tap the user action the
/// system dialog needs).
class BackgroundRunsTile extends ConsumerWidget {
  const BackgroundRunsTile({super.key});

  static String subtitleFor(BackgroundPlatform platform) => switch (platform) {
        BackgroundPlatform.ios => 'Replies from online models finish when you leave Sherpa. Models on this iPhone '
            'pause until you come back.',
        _ => 'A reply or task in progress finishes when you leave Sherpa, with a notification while it works.',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(uiSettingsProvider.select((s) => s.backgroundRuns));
    final platform = ref.watch(backgroundPlatformProvider);
    return SwitchListTile(
      secondary: const Icon(Icons.timelapse_rounded),
      title: const Text('Keep working in the background'),
      subtitle: Text(subtitleFor(platform)),
      value: on,
      onChanged: (v) async {
        await ref.read(uiSettingsProvider.notifier).update((s) => s.copyWith(backgroundRuns: v));
        if (!v || platform != BackgroundPlatform.android) return;
        final activity = ref.read(runActivityProvider);
        if (!await activity.notificationsPermitted()) await activity.requestNotifications();
      },
    );
  }
}

/// A small label on a chat in the list while its run is in flight
/// ("Replying…") or paused ("Paused").
class ChatActivityChip extends StatelessWidget {
  const ChatActivityChip({super.key, required this.state});

  final ChatActivityState state;

  static String labelOf(ChatActivityState s) => switch (s) {
        ChatActivityState.running => 'Replying…',
        ChatActivityState.waitingForApp => 'Paused until you return',
        ChatActivityState.pausedInBackground => 'Paused',
      };

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final running = state == ChatActivityState.running;
    final fg = running ? scheme.onPrimaryContainer : scheme.onTertiaryContainer;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.5,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: running ? scheme.primaryContainer : scheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(t.radius.pill),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: t.space.sm, vertical: t.space.xxs),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(running ? Icons.more_horiz_rounded : Icons.pause_circle_outline_rounded, size: 14, color: fg),
              SizedBox(width: t.space.xxs),
              Text(labelOf(state), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}
