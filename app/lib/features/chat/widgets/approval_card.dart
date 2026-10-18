import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../../design/tokens.dart';
import '../state/chat_controller.dart';
import '../state/chat_dependencies.dart';
import '../state/chat_view_state.dart';
import 'chat_style.dart';
import 'json_view.dart';

/// Plain-language risk copy per [RiskLevel] (docs/research/11 §9.7).
({IconData icon, String label, String detail, Color color}) riskCopy(BuildContext context, PendingApproval a) {
  final tokens = SherpaTokens.of(context);
  final scheme = Theme.of(context).colorScheme;
  return switch (a.risk) {
    RiskLevel.safe => (
        icon: Icons.visibility_outlined,
        label: 'Reads information',
        detail: a.reason,
        color: scheme.primary,
      ),
    RiskLevel.moderate => (
        icon: Icons.edit_note_rounded,
        label: 'Can make changes',
        detail: a.reason,
        color: tokens.semantic.warning,
      ),
    RiskLevel.destructive => (
        icon: Icons.warning_amber_rounded,
        label: 'Can modify or delete data',
        detail: '${a.reason} It may not be possible to undo.',
        color: tokens.semantic.danger,
      ),
  };
}

/// Expiry choices for "Always allow".
enum AlwaysAllowExpiry {
  day('For 24 hours', Duration(hours: 24)),
  week('For 7 days', Duration(days: 7)),
  forever('Until I turn it off', null);

  const AlwaysAllowExpiry(this.label, this.duration);
  final String label;
  final Duration? duration;
}

/// Asks the user whether one tool call may run, showing exactly what it
/// will do: tool and server, risk in plain words, and the full arguments.
///
/// Buttons map 1:1 to [ApprovalResponse]: Deny, Allow once, Allow for this
/// chat (session scope) and Always allow (with an expiry). "Always" is not
/// offered for destructive tools. Y / N answer from a hardware keyboard.
class ApprovalCard extends ConsumerWidget {
  const ApprovalCard({
    super.key,
    required this.sessionId,
    required this.approval,
    this.inSheet = false,
    this.showActions = true,
    this.onAnswered,
  });

  final String sessionId;
  final PendingApproval approval;

  /// In the compact-screen sheet, which also carries its own Stop.
  final bool inSheet;

  /// False when the host pins [ApprovalActions] outside a scroll view so the
  /// decision is always on screen, however long the arguments are.
  final bool showActions;
  final VoidCallback? onAnswered;

  void _respond(WidgetRef ref, ApprovalResponse r) {
    ref.read(chatControllerProvider(sessionId).notifier).respondToApproval(r);
    onAnswered?.call();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final risk = riskCopy(context, approval);
    final destructive = approval.risk == RiskLevel.destructive;
    final title = 'Allow “${approval.toolDisplayName}”?';

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.keyY) {
          _respond(ref, const ApprovalResponse(UserDecision.approve));
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.keyN) {
          _respond(ref, const ApprovalResponse(UserDecision.deny));
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: 'Approval needed. $title ${risk.label}.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(top: tokens.space.xxs),
                  child: Icon(Icons.shield_outlined, color: risk.color),
                ),
                SizedBox(width: tokens.space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(headingLevel: 2, child: Text(title, style: theme.textTheme.titleMedium)),
                      SizedBox(height: tokens.space.xxs),
                      Text(
                        '${approval.call.name} · ${approval.sourceLabel}',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (inSheet)
                  TextButton.icon(
                    onPressed: () {
                      ref.read(chatControllerProvider(sessionId).notifier).stop();
                      onAnswered?.call();
                    },
                    icon: const Icon(Icons.stop_rounded),
                    label: const Text('Stop'),
                  ),
              ],
            ),
            SizedBox(height: tokens.space.md),
            DecoratedBox(
              decoration: BoxDecoration(
                color: risk.color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(tokens.radius.sm),
                border: Border.all(color: risk.color.withValues(alpha: destructive ? 0.7 : 0.35)),
              ),
              child: Padding(
                padding: EdgeInsets.all(tokens.space.md),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(risk.icon, color: risk.color, size: ChatIconSize.medium),
                    SizedBox(width: tokens.space.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            risk.label,
                            style: theme.textTheme.labelLarge?.copyWith(color: destructive ? risk.color : null),
                          ),
                          SizedBox(height: tokens.space.xxs),
                          Text(risk.detail, style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: tokens.space.md),
            Text('Arguments', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            SizedBox(height: tokens.space.xs),
            JsonPreview(
              value: approval.call.arguments,
              maxHeight: MediaQuery.sizeOf(context).height * 0.3,
              copyLabel: 'Copy arguments',
              onCopy: (json) => ref.read(chatPlatformProvider).copyText(json),
            ),
            if (showActions) ...[
              SizedBox(height: tokens.space.md),
              ApprovalActions(sessionId: sessionId, approval: approval, onAnswered: onAnswered),
            ],
          ],
        ),
      ),
    );
  }
}

/// Deny · Allow for this chat · Always allow ▾ · Allow once.
class ApprovalActions extends ConsumerWidget {
  const ApprovalActions({super.key, required this.sessionId, required this.approval, this.onAnswered});

  final String sessionId;
  final PendingApproval approval;
  final VoidCallback? onAnswered;

  void _respond(WidgetRef ref, ApprovalResponse r) {
    ref.read(chatControllerProvider(sessionId).notifier).respondToApproval(r);
    onAnswered?.call();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final destructive = approval.risk == RiskLevel.destructive;
    final allowOnceStyle = destructive
        ? FilledButton.styleFrom(
            backgroundColor: tokens.semantic.danger,
            foregroundColor: theme.colorScheme.surface,
          )
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: tokens.space.sm,
          runSpacing: tokens.space.sm,
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton(
              onPressed: () => _respond(ref, const ApprovalResponse(UserDecision.deny)),
              child: const Text('Deny'),
            ),
            TextButton(
              onPressed: () => _respond(
                ref,
                const ApprovalResponse(UserDecision.approve, scope: ApprovalScope.session),
              ),
              child: const Text('Allow for this chat'),
            ),
            if (approval.allowsAlways)
              MenuAnchor(
                builder: (context, controller, _) => TextButton.icon(
                  onPressed: () => controller.isOpen ? controller.close() : controller.open(),
                  iconAlignment: IconAlignment.end,
                  icon: const Icon(Icons.expand_more_rounded),
                  label: const Text('Always allow'),
                ),
                menuChildren: [
                  for (final e in AlwaysAllowExpiry.values)
                    MenuItemButton(
                      onPressed: () => _respond(
                        ref,
                        ApprovalResponse(UserDecision.approve, scope: ApprovalScope.always, expiresIn: e.duration),
                      ),
                      child: Text(e.label),
                    ),
                ],
              ),
            FilledButton(
              style: allowOnceStyle,
              onPressed: () => _respond(ref, const ApprovalResponse(UserDecision.approve)),
              child: const Text('Allow once'),
            ),
          ],
        ),
        if (!approval.allowsAlways)
          Padding(
            padding: EdgeInsets.only(top: tokens.space.sm),
            child: Text(
              'Actions that can delete data always ask first.',
              textAlign: TextAlign.end,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

/// The card docked above the composer on wide screens.
class DockedApprovalCard extends StatelessWidget {
  const DockedApprovalCard({super.key, required this.sessionId, required this.approval});

  final String sessionId;
  final PendingApproval approval;

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final risk = riskCopy(context, approval);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(tokens.radius.lg),
          border: Border.all(color: risk.color.withValues(alpha: 0.6)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(tokens.space.lg, tokens.space.lg, tokens.space.lg, tokens.space.sm),
                child: ApprovalCard(
                  key: ValueKey(approval.call.id),
                  sessionId: sessionId,
                  approval: approval,
                  showActions: false,
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(tokens.space.lg, 0, tokens.space.lg, tokens.space.lg),
              child: ApprovalActions(sessionId: sessionId, approval: approval),
            ),
          ],
        ),
      ),
    );
  }
}

/// Slim reminder docked above the composer on compact screens while the
/// approval sheet is closed: the decision is never lost by swiping away.
class ApprovalReminderBar extends StatelessWidget {
  const ApprovalReminderBar({super.key, required this.approval, required this.onReview});

  final PendingApproval approval;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final risk = riskCopy(context, approval);
    return Semantics(
      container: true,
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radius.lg),
          side: BorderSide(color: risk.color.withValues(alpha: 0.6)),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(tokens.space.lg, tokens.space.xs, tokens.space.xs, tokens.space.xs),
          child: Row(
            children: [
              Icon(Icons.shield_outlined, color: risk.color),
              SizedBox(width: tokens.space.md),
              Expanded(
                child: Text(
                  'Approval needed: ${approval.toolDisplayName}',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              FilledButton.tonal(onPressed: onReview, child: const Text('Review')),
            ],
          ),
        ),
      ),
    );
  }
}

/// The approval as a modal bottom sheet (compact screens): modal route
/// semantics move screen-reader focus to the decision.
class ApprovalSheet extends ConsumerWidget {
  const ApprovalSheet({super.key, required this.sessionId});

  final String sessionId;

  static Future<void> show(BuildContext context, String sessionId) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (_) => ApprovalSheet(sessionId: sessionId),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(chatControllerProvider(sessionId).select((s) => s.pendingApproval));
    final tokens = SherpaTokens.of(context);
    if (pending == null) {
      // Answered elsewhere, or the run stopped: close quietly.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.of(context).maybePop();
      });
      return const SizedBox.shrink();
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(tokens.space.xl, 0, tokens.space.xl, tokens.space.sm),
            child: ApprovalCard(
              key: ValueKey(pending.call.id),
              sessionId: sessionId,
              approval: pending,
              inSheet: true,
              showActions: false,
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(tokens.space.xl, tokens.space.sm, tokens.space.xl, tokens.space.xl),
          child: ApprovalActions(sessionId: sessionId, approval: pending),
        ),
      ],
    );
  }
}
