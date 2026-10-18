import 'package:material_ui/material_ui.dart';

import '../../../design/tokens.dart';
import '../state/transcript_model.dart';
import 'chat_style.dart';

/// "‹ 2/3 ›" between branches created by edits and retries.
class BranchSwitcher extends StatelessWidget {
  const BranchSwitcher({
    super.key,
    required this.branch,
    required this.onPrevious,
    required this.onNext,
    this.enabled = true,
    this.noun = 'Version',
  });

  final BranchInfo branch;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  /// Disabled while a run is active: switching would move the leaf the
  /// runner is writing to.
  final bool enabled;
  final String noun;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final position = '${branch.index + 1}/${branch.count}';
    return Semantics(
      container: true,
      label: '$noun ${branch.index + 1} of ${branch.count}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Previous ${noun.toLowerCase()}',
            onPressed: enabled && branch.canGoBack ? onPrevious : null,
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          ExcludeSemantics(
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: kChromeMaxTextScale,
              child: Text(
                position,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Next ${noun.toLowerCase()}',
            onPressed: enabled && branch.canGoForward ? onNext : null,
            icon: const Icon(Icons.chevron_right_rounded),
          ),
        ],
      ),
    );
  }
}

/// Copy · Share · Retry (+ branch switcher) under a finished reply.
class AssistantActions extends StatelessWidget {
  const AssistantActions({
    super.key,
    required this.onCopy,
    required this.onShare,
    required this.onRetry,
    this.branch,
    this.onPrevious,
    this.onNext,
    this.enabled = true,
  });

  final VoidCallback onCopy;
  final VoidCallback onShare;
  final VoidCallback onRetry;
  final BranchInfo? branch;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    final b = branch;
    return IconTheme.merge(
      data: IconThemeData(color: color, size: ChatIconSize.medium),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: tokens.space.xxs,
        children: [
          IconButton(tooltip: 'Copy reply', onPressed: onCopy, icon: const Icon(Icons.copy_rounded)),
          IconButton(tooltip: 'Share reply', onPressed: onShare, icon: const Icon(Icons.ios_share_rounded)),
          IconButton(
            tooltip: 'Retry',
            onPressed: enabled ? onRetry : null,
            icon: const Icon(Icons.refresh_rounded),
          ),
          if (b != null && b.hasSiblings && onPrevious != null && onNext != null)
            BranchSwitcher(branch: b, onPrevious: onPrevious!, onNext: onNext!, enabled: enabled, noun: 'Reply'),
        ],
      ),
    );
  }
}
