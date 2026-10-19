import 'package:material_ui/material_ui.dart';

import '../../../design/tokens.dart';
import '../state/chat_errors.dart';
import '../state/chat_view_state.dart';
import 'chat_style.dart';

/// A quiet inline line in the transcript: "Retrying…", "You stopped this
/// response.", "Paused after 24 steps [Continue]".
class NoticeTile extends StatelessWidget {
  const NoticeTile({super.key, required this.notice, this.onAction});

  final ChatNotice notice;
  final void Function(ChatNoticeAction action)? onAction;

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final color = notice.kind == ChatNoticeKind.warning ? tokens.semantic.warning : theme.colorScheme.onSurfaceVariant;
    final Widget icon = switch (notice.kind) {
      ChatNoticeKind.progress when !chatMotionOf(context).reduced => SizedBox.square(
          dimension: ChatIconSize.small,
          child: CircularProgressIndicator(strokeWidth: 2, color: color),
        ),
      ChatNoticeKind.progress => Icon(Icons.hourglass_top_rounded, size: ChatIconSize.small, color: color),
      ChatNoticeKind.warning => Icon(Icons.warning_amber_rounded, size: ChatIconSize.small, color: color),
      ChatNoticeKind.info => Icon(
          notice.code == 'stopped' ? Icons.stop_circle_outlined : Icons.info_outline_rounded,
          size: ChatIconSize.small,
          color: color,
        ),
    };
    final action = notice.action;
    return ReadableWidth(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: tokens.space.xs),
        child: Semantics(
          container: true,
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: tokens.space.sm,
            children: [
              icon,
              Text(
                notice.message,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              if (action != null && onAction != null)
                TextButton(
                  onPressed: () => onAction!(action),
                  child: Text(switch (action) {
                    ChatNoticeAction.continueRun => 'Continue',
                    ChatNoticeAction.handOff => 'Hand off…',
                  }),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The final error of a run, with the actions that can fix it.
class ChatErrorCard extends StatefulWidget {
  const ChatErrorCard({super.key, required this.error, required this.onAction, required this.onDismiss});

  final ChatError error;
  final void Function(ChatErrorAction action) onAction;
  final VoidCallback onDismiss;

  static String labelOf(ChatErrorAction a) => switch (a) {
        ChatErrorAction.fixProvider => 'Fix provider',
        ChatErrorAction.addProvider => 'Add provider',
        ChatErrorAction.retry => 'Try again',
        ChatErrorAction.changeModel => 'Switch model',
        ChatErrorAction.newChat => 'New chat',
      };

  static IconData iconOf(ChatErrorAction a) => switch (a) {
        ChatErrorAction.fixProvider => Icons.key_rounded,
        ChatErrorAction.addProvider => Icons.add_rounded,
        ChatErrorAction.retry => Icons.refresh_rounded,
        ChatErrorAction.changeModel => Icons.swap_horiz_rounded,
        ChatErrorAction.newChat => Icons.edit_square,
      };

  @override
  State<ChatErrorCard> createState() => _ChatErrorCardState();
}

class _ChatErrorCardState extends State<ChatErrorCard> {
  bool _details = false;

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final e = widget.error;
    final icon = switch (e.kind) {
      ChatErrorKind.offline || ChatErrorKind.timeout => Icons.wifi_off_rounded,
      ChatErrorKind.auth => Icons.key_off_rounded,
      ChatErrorKind.quotaExceeded => Icons.credit_card_off_outlined,
      ChatErrorKind.rateLimited || ChatErrorKind.overloaded => Icons.hourglass_bottom_rounded,
      ChatErrorKind.contextOverflow => Icons.data_usage_rounded,
      _ => Icons.error_outline_rounded,
    };
    return ReadableWidth(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: tokens.space.sm),
        child: Semantics(
          container: true,
          liveRegion: false,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tokens.semantic.danger.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(tokens.radius.md),
              border: Border.all(color: tokens.semantic.danger.withValues(alpha: 0.5)),
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(tokens.space.lg, tokens.space.md, tokens.space.xs, tokens.space.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: EdgeInsets.only(top: tokens.space.xxs),
                        child: Icon(icon, color: tokens.semantic.danger),
                      ),
                      SizedBox(width: tokens.space.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Semantics(headingLevel: 3, child: Text(e.title, style: theme.textTheme.titleSmall)),
                            SizedBox(height: tokens.space.xs),
                            Text(e.message, style: theme.textTheme.bodyMedium),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Dismiss',
                        onPressed: widget.onDismiss,
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  SizedBox(height: tokens.space.sm),
                  Wrap(
                    spacing: tokens.space.sm,
                    runSpacing: tokens.space.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final (i, a) in e.actions.indexed)
                        i == 0
                            ? FilledButton.tonalIcon(
                                onPressed: () => widget.onAction(a),
                                icon: Icon(ChatErrorCard.iconOf(a)),
                                label: Text(ChatErrorCard.labelOf(a)),
                              )
                            : TextButton(onPressed: () => widget.onAction(a), child: Text(ChatErrorCard.labelOf(a))),
                      if (e.detail != null && e.detail!.isNotEmpty)
                        TextButton(
                          onPressed: () => setState(() => _details = !_details),
                          child: Text(_details ? 'Hide details' : 'Details'),
                        ),
                    ],
                  ),
                  if (_details && e.detail != null)
                    Padding(
                      padding: EdgeInsets.only(top: tokens.space.sm, right: tokens.space.md),
                      child: SelectableText(e.detail!, style: chatMonoStyle(context)),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown in place of the composer when the chat can't reach a model.
class SetupPanel extends StatelessWidget {
  const SetupPanel({
    super.key,
    required this.availability,
    required this.onAddProvider,
    required this.onChooseModel,
    this.providerName,
  });

  final ProviderAvailability availability;
  final VoidCallback onAddProvider;
  final VoidCallback onChooseModel;
  final String? providerName;

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final (title, body, cta, onTap, icon) = switch (availability) {
      ProviderAvailability.noProviders => (
          'Add a model to start chatting',
          'Sherpa works with Anthropic, OpenAI and OpenAI-compatible servers such as llama.cpp, '
              'Ollama or LM Studio. Your key stays in this device\'s secure storage.',
          'Add provider',
          onAddProvider,
          Icons.add_rounded,
        ),
      ProviderAvailability.providerMissing => (
          '${providerName ?? 'This chat\'s provider'} is unavailable',
          'It was removed or could not be set up. Pick another model to continue this chat.',
          'Choose model',
          onChooseModel,
          Icons.swap_horiz_rounded,
        ),
      _ => (
          'Choose a model',
          'Pick which configured model this chat should use.',
          'Choose model',
          onChooseModel,
          Icons.tune_rounded,
        ),
    };
    return Semantics(
      container: true,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.all(tokens.space.lg),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(tokens.radius.xl),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(headingLevel: 2, child: Text(title, style: theme.textTheme.titleMedium)),
            SizedBox(height: tokens.space.xs),
            Text(body, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            SizedBox(height: tokens.space.md),
            FilledButton.icon(onPressed: onTap, icon: Icon(icon), label: Text(cta)),
          ],
        ),
      ),
    );
  }
}

/// "Your last reply was interrupted" with Resume / Discard.
class InterruptedBanner extends StatelessWidget {
  const InterruptedBanner({super.key, required this.run, required this.onResume, required this.onDiscard});

  final InterruptedRun run;
  final VoidCallback onResume;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final message = run.wasAwaitingApproval
        ? 'Sherpa was waiting for your approval when the app closed. Resume to decide again.'
        : 'The last reply was interrupted when the app closed.';
    return Semantics(
      container: true,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.fromLTRB(tokens.space.lg, tokens.space.md, tokens.space.sm, tokens.space.sm),
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
                Icon(Icons.history_rounded, color: theme.colorScheme.onSecondaryContainer),
                SizedBox(width: tokens.space.md),
                Expanded(
                  child: Text(
                    message,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSecondaryContainer),
                  ),
                ),
              ],
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Wrap(
                spacing: tokens.space.sm,
                children: [
                  TextButton(onPressed: onDiscard, child: const Text('Discard')),
                  FilledButton.tonal(onPressed: onResume, child: const Text('Resume')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
