import 'package:material_ui/material_ui.dart';

import '../tokens.dart';
import 'a11y.dart';

/// Shared layout for empty, error, offline and loading states, so every
/// "nothing to show" moment in the app looks deliberate and offers a way on.
///
/// Scrolls instead of overflowing at large text sizes, and caps its width so
/// copy stays readable on tablets.
class StateView extends StatelessWidget {
  const StateView({
    super.key,
    required this.title,
    this.message,
    this.icon,
    this.illustration,
    this.primaryAction,
    this.secondaryAction,
    this.tone = StateTone.neutral,
    this.liveRegion = false,
  });

  final String title;
  final String? message;
  final IconData? icon;

  /// Replaces [icon] with a custom graphic (e.g. the Sherpa mark).
  final Widget? illustration;
  final Widget? primaryAction;
  final Widget? secondaryAction;
  final StateTone tone;

  /// Announce the title when it appears (errors, offline); the message is
  /// read next, on focus.
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (fg, bg) = switch (tone) {
      StateTone.neutral => (scheme.onSecondaryContainer, scheme.secondaryContainer),
      StateTone.error => (scheme.onErrorContainer, scheme.errorContainer),
      StateTone.warning => (scheme.onTertiaryContainer, scheme.tertiaryContainer),
    };
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(t.space.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          // Title (a heading), message and actions are read in that order,
          // as separate nodes; a live state announces its title.
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (illustration != null)
                  illustration!
                else if (icon != null)
                  ExcludeSemantics(
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(t.radius.xl)),
                      child: Icon(icon, size: 32, color: fg),
                    ),
                  ),
                SizedBox(height: t.space.xl),
                Heading(
                  child: Semantics(
                    liveRegion: liveRegion,
                    child: Text(title, style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
                  ),
                ),
                if (message != null) ...[
                  SizedBox(height: t.space.sm),
                  Text(
                    message!,
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                ],
                if (primaryAction != null || secondaryAction != null) SizedBox(height: t.space.xl),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: t.space.sm,
                  runSpacing: t.space.sm,
                  children: [?primaryAction, ?secondaryAction],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum StateTone { neutral, error, warning }

/// Nothing here yet — and what to do about it.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.inbox_outlined,
    this.illustration,
    this.primaryAction,
    this.secondaryAction,
  });

  final String title;
  final String? message;
  final IconData icon;
  final Widget? illustration;
  final Widget? primaryAction;
  final Widget? secondaryAction;

  @override
  Widget build(BuildContext context) => StateView(
        title: title,
        message: message,
        icon: icon,
        illustration: illustration,
        primaryAction: primaryAction,
        secondaryAction: secondaryAction,
      );
}

/// Something failed. Says what, in plain words, and offers a retry.
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    this.title = 'Something went wrong',
    this.message,
    this.onRetry,
    this.retryLabel = 'Try again',
  });

  final String title;
  final String? message;
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) => StateView(
        title: title,
        message: message,
        icon: Icons.error_outline_rounded,
        tone: StateTone.error,
        liveRegion: true,
        primaryAction: onRetry == null
            ? null
            : FilledButton.tonalIcon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: Text(retryLabel)),
      );
}

/// No network. Remote models are out of reach; on-device work still is.
class OfflineState extends StatelessWidget {
  const OfflineState({super.key, this.onRetry, this.message});

  final VoidCallback? onRetry;
  final String? message;

  @override
  Widget build(BuildContext context) => StateView(
        title: "You're offline",
        message: message ?? 'Remote models need a connection. Chats with models on this device keep working.',
        icon: Icons.wifi_off_rounded,
        tone: StateTone.warning,
        liveRegion: true,
        primaryAction: onRetry == null
            ? null
            : OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Retry')),
      );
}

/// Indeterminate wait with a label, for waits we can't skeletonize.
class LoadingState extends StatelessWidget {
  const LoadingState({super.key, this.label = 'Loading…'});

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    return Center(
      child: Semantics(
        liveRegion: true,
        label: label,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            SizedBox(height: t.space.lg),
            ExcludeSemantics(child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
          ],
        ),
      ),
    );
  }
}
