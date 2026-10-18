import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../design/tokens.dart';
import '../../design/widgets/section_header.dart';
import '../../design/widgets/skeleton.dart';
import '../../design/widgets/state_views.dart';
import '../../routing/routes.dart';
import '../../state/sessions.dart';
import 'home_actions.dart';
import 'relative_time.dart';
import 'session_tile.dart';
import 'sessions_empty_state.dart';

/// The scrollable sessions list with its loading, error, empty and
/// no-results states. Used full-screen on phones and as the left pane on
/// tablets.
class SessionsList extends ConsumerWidget {
  const SessionsList({super.key, this.selectedId, this.header});

  /// Highlighted row (the chat open in the detail pane).
  final String? selectedId;

  /// Sliver shown above the rows (search field), kept in the same scroll
  /// view so it scrolls away on small screens.
  final Widget? header;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(visibleSessionsProvider);
    final query = ref.watch(sessionQueryProvider).trim();
    final now = ref.watch(minuteClockProvider).value ?? DateTime.now().toUtc();

    final Widget body = switch (sessions) {
      AsyncValue(:final value?) when value.isEmpty && query.isNotEmpty => SliverFillRemaining(
          hasScrollBody: false,
          child: StateView(
            title: 'No chats match "$query"',
            message: 'Search looks at chat titles, model names and providers.',
            icon: Icons.search_off_rounded,
            primaryAction: TextButton(
              onPressed: () => ref.read(sessionQueryProvider.notifier).set(''),
              child: const Text('Clear search'),
            ),
          ),
        ),
      AsyncValue(:final value?) when value.isEmpty =>
        const SliverFillRemaining(hasScrollBody: false, child: SessionsEmptyState()),
      AsyncValue(:final value?) => _GroupedSessions(sessions: value, now: now, selectedId: selectedId),
      AsyncError() => SliverFillRemaining(
          hasScrollBody: false,
          child: ErrorState(
            title: "Couldn't load your chats",
            message: 'Your chats are still on this device. Try again.',
            onRetry: () => unawaited(ref.read(sessionListProvider.notifier).refresh()),
          ),
        ),
      _ => const SliverToBoxAdapter(child: SkeletonList(label: 'Loading chats')),
    };

    return CustomScrollView(
      restorationId: 'sessions-list',
      slivers: [
        ?header,
        body,
        // Room for a FAB / the bottom gesture area.
        SliverPadding(padding: EdgeInsets.only(bottom: 88 + MediaQuery.paddingOf(context).bottom)),
      ],
    );
  }
}

class _GroupedSessions extends ConsumerWidget {
  const _GroupedSessions({required this.sessions, required this.now, required this.selectedId});

  final List<SessionRecord> sessions;
  final DateTime now;
  final String? selectedId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    // Flatten groups into one lazily-built list of headers and rows.
    final items = <Object>[];
    DateBucket? current;
    for (final s in sessions) {
      final b = bucketFor(s.updatedAt, now);
      if (b != current) {
        items.add(b);
        current = b;
      }
      items.add(s);
    }
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: t.space.sm),
      sliver: SliverList.builder(
        itemCount: items.length,
        findChildIndexCallback: (Key key) {
          final k = key is ValueKey<String> ? key.value : null;
          final i = items.indexWhere((e) => (e is SessionRecord ? 's:${e.id}' : 'h:${(e as DateBucket).name}') == k);
          return i < 0 ? null : i;
        },
        itemBuilder: (context, i) => switch (items[i]) {
          final DateBucket b => SectionHeader(
              b.label,
              key: ValueKey('h:${b.name}'),
              padding: EdgeInsets.fromLTRB(t.space.sm, t.space.lg, t.space.sm, t.space.xs),
            ),
          final SessionRecord s => _DismissibleSession(
              key: ValueKey('s:${s.id}'),
              session: s,
              now: now,
              selected: s.id == selectedId,
              openSessionId: selectedId,
            ),
          _ => const SizedBox.shrink(),
        },
      ),
    );
  }
}

class _DismissibleSession extends ConsumerWidget {
  const _DismissibleSession({
    super.key,
    required this.session,
    required this.now,
    required this.selected,
    required this.openSessionId,
  });

  final SessionRecord session;
  final DateTime now;
  final bool selected;
  final String? openSessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final t = SherpaTokens.of(context);
    void archive() => archiveSessionWithUndo(context, ref, session, openSessionId: openSessionId);
    void delete() => deleteSessionWithUndo(context, ref, session, openSessionId: openSessionId);

    Widget swipeBackground(Color bg, Color fg, IconData icon, String label, Alignment align) => Container(
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(t.radius.md)),
          padding: EdgeInsets.symmetric(horizontal: t.space.xl),
          alignment: align,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [Icon(icon, color: fg), SizedBox(width: t.space.sm), Text(label, style: TextStyle(color: fg))],
          ),
        );

    return Dismissible(
      key: ValueKey('dismiss:${session.id}'),
      background: swipeBackground(
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
        session.archived ? Icons.unarchive_outlined : Icons.archive_outlined,
        session.archived ? 'Unarchive' : 'Archive',
        Alignment.centerLeft,
      ),
      secondaryBackground: swipeBackground(
        scheme.errorContainer,
        scheme.onErrorContainer,
        Icons.delete_outline,
        'Delete',
        Alignment.centerRight,
      ),
      onDismissed: (direction) {
        if (direction == DismissDirection.endToStart) {
          delete();
        } else {
          // Remove the row this frame (Dismissible requires it), persist after.
          if (!session.archived) ref.read(hiddenSessionIdsProvider.notifier).hide(session.id);
          archive();
        }
      },
      child: SessionTile(
        session: session,
        now: now,
        selected: selected,
        onTap: () {
          if (!selected) context.go(Routes.chat(session.id));
        },
        onArchive: archive,
        onDelete: delete,
        onLongPress: () => _showActions(context, archive: archive, delete: delete),
      ),
    );
  }

  void _showActions(BuildContext context, {required VoidCallback archive, required VoidCallback delete}) {
    unawaited(showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(session.archived ? Icons.unarchive_outlined : Icons.archive_outlined),
              title: Text(session.archived ? 'Unarchive' : 'Archive'),
              onTap: () {
                Navigator.pop(sheet);
                archive();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () {
                Navigator.pop(sheet);
                delete();
              },
            ),
          ],
        ),
      ),
    ));
  }
}
