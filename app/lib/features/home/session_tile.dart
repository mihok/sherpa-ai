import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../design/tokens.dart';
import '../../design/typography.dart';
import '../../design/widgets/privacy_badge.dart';
import '../../services/background/background_providers.dart';
import '../../state/app_providers.dart';
import '../../state/services.dart' show ModelChoice;
import '../chat/background/background_widgets.dart' show ChatActivityChip;
import 'relative_time.dart';

/// One chat in the sessions list: title, model, time, where it runs.
///
/// Swipe actions live in the list; this tile exposes the same actions to
/// screen readers (custom semantics actions) and to long-press, because a
/// swipe alone is neither discoverable nor accessible.
class SessionTile extends ConsumerWidget {
  const SessionTile({
    super.key,
    required this.session,
    required this.now,
    required this.onTap,
    required this.onArchive,
    required this.onDelete,
    this.onLongPress,
    this.selected = false,
  });

  final SessionRecord session;
  final DateTime now;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onArchive;
  final VoidCallback onDelete;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final providerId = session.providerId;
    final modelId = session.modelId;
    final providerName = providerId == null ? null : ref.watch(providerDisplayNameProvider(providerId));
    final privacy = providerId == null ? null : ref.watch(providerPrivacyProvider(providerId));
    final modelLabel = modelId == null
        ? 'No model chosen'
        : providerId == null
            ? modelId
            : ref.watch(modelDisplayNameProvider(ModelChoice(providerId: providerId, modelId: modelId)));
    final subtitle = [modelLabel, ?providerName].join(' · ');
    final time = formatRelativeShort(session.updatedAt, now);
    final archiveLabel = session.archived ? 'Unarchive' : 'Archive';
    // A run in flight (or paused by the background) in this chat.
    final activity = ref.watch(chatActivityProvider(session.id));

    final badge = privacy == null
        ? _MissingModelChip(label: providerId == null ? 'Pick a model' : 'Provider removed')
        : PrivacyBadge(location: privacy.location, host: privacy.host, size: PrivacyBadgeSize.compact);

    final spoken = [
      session.title,
      subtitle,
      formatRelativeSpoken(session.updatedAt, now),
      if (activity != null) ChatActivityChip.labelOf(activity),
      if (session.archived) 'Archived',
      if (privacy != null)
        PrivacyBadge(location: privacy.location, host: privacy.host).semanticLabel
      else
        'No model available',
    ].join('. ');

    return Semantics(
      label: spoken,
      selected: selected,
      button: true,
      excludeSemantics: true,
      onTap: onTap,
      onLongPress: onLongPress,
      customSemanticsActions: {
        CustomSemanticsAction(label: archiveLabel): onArchive,
        const CustomSemanticsAction(label: 'Delete'): onDelete,
      },
      child: ListTile(
        selected: selected,
        onTap: onTap,
        onLongPress: onLongPress,
        isThreeLine: true,
        title: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(child: Text(session.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
            SizedBox(width: t.space.sm),
            Text(time, style: theme.textTheme.metricSmall.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
        subtitle: Padding(
          padding: EdgeInsets.only(top: t.space.xxs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
              SizedBox(height: t.space.xs),
              Wrap(
                spacing: t.space.xs,
                runSpacing: t.space.xs,
                children: [
                  badge,
                  if (activity != null) ChatActivityChip(state: activity),
                  if (session.archived) const _ArchivedChip(),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MissingModelChip extends StatelessWidget {
  const _MissingModelChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.5,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(t.radius.pill),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: t.space.sm, vertical: t.space.xxs),
          child: Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
        ),
      ),
    );
  }
}

class _ArchivedChip extends StatelessWidget {
  const _ArchivedChip();

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.5,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(t.radius.pill),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: t.space.sm, vertical: t.space.xxs),
          child: Text('Archived', style: Theme.of(context).textTheme.labelSmall),
        ),
      ),
    );
  }
}
