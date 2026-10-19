import 'package:flutter/semantics.dart';
import 'package:material_ui/material_ui.dart';

import '../../../design/tokens.dart';
import '../state/transcript_model.dart';
import 'attachment_views.dart';
import 'chat_style.dart';
import 'message_actions.dart';
import 'source_chips.dart';
import 'transcript.dart';

/// Callbacks a user bubble needs from the screen.
@immutable
class UserMessageCallbacks {
  const UserMessageCallbacks({
    required this.onEdit,
    required this.onCopy,
    required this.onSwitch,
  });

  final void Function(UserItem item) onEdit;
  final void Function(UserItem item) onCopy;
  final void Function(UserItem item, bool forward) onSwitch;
}

/// A message the user sent: a right-aligned bubble.
///
/// Long-press (or right-click) opens Edit / Copy; screen readers get the
/// same as custom actions. Branch switcher below when edits exist.
class UserMessageTile extends StatelessWidget {
  const UserMessageTile({
    super.key,
    required this.item,
    required this.callbacks,
  });

  final UserItem item;
  final UserMessageCallbacks callbacks;

  /// Test hook: counts builds per message id to prove finished messages are
  /// not rebuilt while a reply streams.
  @visibleForTesting
  static void Function(String messageId)? debugOnBuild;

  Future<void> _showMenu(BuildContext context, Offset globalPosition, {required bool runActive}) async {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
      Offset.zero & overlay.size,
    );
    final choice = await showMenu<String>(
      context: context,
      position: position,
      items: [
        PopupMenuItem(
          value: 'edit',
          enabled: !runActive,
          child: const ListTile(leading: Icon(Icons.edit_outlined), title: Text('Edit message')),
        ),
        const PopupMenuItem(
          value: 'copy',
          child: ListTile(leading: Icon(Icons.copy_rounded), title: Text('Copy text')),
        ),
      ],
    );
    switch (choice) {
      case 'edit':
        callbacks.onEdit(item);
      case 'copy':
        callbacks.onCopy(item);
    }
  }

  @override
  Widget build(BuildContext context) {
    debugOnBuild?.call(item.message.id);
    final runActive = ChatRunScope.runningOf(context);
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final source = item.promptSource;
    final app = item.appSource;
    final resources = item.resources;
    final attachments = item.attachments;
    Offset? pressAt;
    return RepaintBoundary(
      child: ReadableWidth(
        child: Padding(
          padding: EdgeInsets.only(top: tokens.space.lg, bottom: tokens.space.xs),
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            headingLevel: 2,
            label: 'You',
            customSemanticsActions: {
              if (!runActive) const CustomSemanticsAction(label: 'Edit message'): () => callbacks.onEdit(item),
              const CustomSemanticsAction(label: 'Copy text'): () => callbacks.onCopy(item),
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (source != null)
                  Padding(
                    padding: EdgeInsets.only(bottom: tokens.space.xs),
                    child: PromptSourceLabel(source: source),
                  ),
                if (app != null)
                  Padding(
                    padding: EdgeInsets.only(bottom: tokens.space.xs),
                    child: AppSourceLabel(source: app),
                  ),
                if (attachments.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(bottom: tokens.space.xs),
                    child: MessageAttachmentsView(attachments: attachments),
                  ),
                if (item.text.trim().isNotEmpty || (resources.isEmpty && attachments.isEmpty))
                  GestureDetector(
                    onLongPressStart: (d) => pressAt = d.globalPosition,
                    onLongPress: () => _showMenu(context, pressAt ?? Offset.zero, runActive: runActive),
                    onSecondaryTapDown: (d) => _showMenu(context, d.globalPosition, runActive: runActive),
                    child: UserBubble(text: item.text),
                  ),
                if (resources.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: tokens.space.xs),
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: tokens.space.xs,
                      runSpacing: tokens.space.xs,
                      children: [for (final r in resources) ResourceChip.of(r)],
                    ),
                  ),
                if (item.isEdit || item.branch.hasSiblings)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (item.isEdit)
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: tokens.space.sm),
                          child: Text(
                            'Edited',
                            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),
                      if (item.branch.hasSiblings)
                        BranchSwitcher(
                          branch: item.branch,
                          enabled: !runActive,
                          noun: 'Message',
                          onPrevious: () => callbacks.onSwitch(item, false),
                          onNext: () => callbacks.onSwitch(item, true),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The bubble itself, shared by sent and still-sending messages.
class UserBubble extends StatelessWidget {
  const UserBubble({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final r = Radius.circular(tokens.radius.lg);
    return LayoutBuilder(
      builder: (context, constraints) => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.85),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadiusDirectional.only(
              topStart: r,
              topEnd: r,
              bottomStart: r,
              bottomEnd: Radius.circular(tokens.radius.sm),
            ),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.space.lg, vertical: tokens.space.md),
            child: Text(text, style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurface)),
          ),
        ),
      ),
    );
  }
}

/// Shown the instant the user taps send, until the runner persisted it.
class PendingUserTile extends StatelessWidget {
  const PendingUserTile({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    return ReadableWidth(
      child: Padding(
        padding: EdgeInsets.only(top: tokens.space.lg, bottom: tokens.space.xs),
        child: Semantics(
          container: true,
          headingLevel: 2,
          label: 'You',
          explicitChildNodes: true,
          child: Align(alignment: AlignmentDirectional.centerEnd, child: UserBubble(text: text)),
        ),
      ),
    );
  }
}
