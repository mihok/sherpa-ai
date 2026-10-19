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
import '../../state/providers.dart';
import '../../state/ui_preferences.dart';
import '../chat/model_picker_sheet.dart';
import '../chat/state/chat_controller.dart';
import '../chat/state/chat_errors.dart';
import 'state/context_actions.dart';
import 'state/format.dart';
import 'state/inspector_controller.dart';
import 'state/item_labels.dart';
import 'widgets/budget_overview.dart';
import 'widgets/context_style.dart';
import 'widgets/item_views.dart';
import 'widgets/overlay_views.dart';

/// "What the model sees" for one chat (`/chat/:id/context`).
///
/// Sherpa rewrites the *view* of a conversation, never the conversation
/// (PLAN "Context segments"), so this screen exists to make that visible
/// and reversible: the budget against the ladder's thresholds, every item
/// exactly as it will be sent, and every recorded change with its reason,
/// a before/after diff and undo (docs/research/11 §9).
class ContextInspectorScreen extends ConsumerWidget {
  const ContextInspectorScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(contextInspectorProvider(sessionId));
    return Scaffold(
      appBar: AppBar(
        title: Semantics(headingLevel: 1, child: const Text('What the model sees')),
        actions: [
          IconButton(
            tooltip: 'How context works',
            icon: const Icon(Icons.help_outline_rounded),
            onPressed: () => unawaited(_explain(context)),
          ),
        ],
      ),
      // A refresh (after a run, an undo) keeps the current view on screen
      // instead of flashing the skeleton.
      body: snapshot.hasValue
          ? (snapshot.value == null
              ? _NoModel(sessionId: sessionId)
              : _Loaded(sessionId: sessionId, snapshot: snapshot.value!))
          : snapshot.hasError
              ? ErrorState(
                  title: "Couldn't read this chat's context",
                  message: snapshot.error is StateError
                      ? (snapshot.error! as StateError).message
                      : 'Something went wrong while measuring it.',
                  onRetry: () => ref.invalidate(contextInspectorProvider(sessionId)),
                )
              : const _LoadingSkeleton(),
    );
  }

  static Future<void> _explain(BuildContext context) => showContextSheet(
        context,
        title: 'How Sherpa manages context',
        body: (context) {
          final theme = Theme.of(context);
          final t = SherpaTokens.of(context);
          Widget p(String s) => Padding(
                padding: EdgeInsets.only(bottom: t.space.md),
                child: Text(s, style: theme.textTheme.bodyMedium),
              );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              p('A model can only read a limited amount of text at once: its context window. Every reply needs '
                  'the system prompt, the tool descriptions and the conversation so far to fit in it.'),
              p('When a chat gets long, Sherpa makes room step by step: first it shortens old, large tool results, '
                  'then it clears large old tool inputs, then it summarizes earlier messages and keeps your most '
                  'recent turns word for word. If that is still not enough, it suggests continuing in a new chat '
                  'from a handoff.'),
              p('Your transcript is never edited. Each change only affects what is sent, has a reason you can '
                  'read, and can be undone.'),
              p('Items marked "untrusted" came from tools, web pages or another device. The model is told to treat '
                  'them as information, never as instructions.'),
            ],
          );
        },
      );
}

class _Loaded extends ConsumerWidget {
  const _Loaded({required this.sessionId, required this.snapshot});

  final String sessionId;
  final ContextSnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final gate = ref.watch(contextActionGateProvider(sessionId));
    final chat = chatControllerProvider(sessionId);
    final (modelName, notices, error) = ref.watch(chat.select((s) => (s.model?.modelName, s.notices, s.error)));
    final now = ref.watch(clockProvider).now();
    final i = snapshot.inspection;
    final facts = [for (final item in i.items) ItemFacts.of(item, snapshot)];
    final diffs = [...i.diffs]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final inEffect = [for (final d in diffs) if (d.status != OverlayStatus.shadowed) d];
    final hidden = [for (final d in diffs) if (d.status == OverlayStatus.shadowed) d];
    final actions = _InspectorActions(context, ref, sessionId, snapshot);

    // The runner's own advice (notice or overflow error) wins over ours: it
    // saw the request that was actually prepared.
    final notice = notices.where((n) => n.code == 'handoff_recommended').firstOrNull;
    final recommendation = error?.kind == ChatErrorKind.contextOverflow
        ? ContextRecommendation(ContextRecommendationKind.hardStop, error!.message)
        : snapshot.recommendation ??
            (notice == null ? null : ContextRecommendation(ContextRecommendationKind.handoff, notice.message));
    final canCompact = gate == null && snapshot.canCompact;
    Widget card(ContextDiff d) => OverlayCard(
          diff: d,
          overlay: snapshot.overlay(d.overlayId),
          now: now,
          onShowDiff: () => unawaited(actions.showDiff(d)),
          onUndo: gate == null ? () => unawaited(actions.undo(d)) : null,
          undoDisabledReason: gate,
        );

    return RefreshIndicator(
      onRefresh: () => ref.read(contextInspectorProvider(sessionId).notifier).refresh(),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kContextReadableWidth),
          child: CustomScrollView(
            slivers: [
              if (recommendation != null)
                SliverToBoxAdapter(
                  child: RecommendationBanner(
                    recommendation: recommendation,
                    onHandOff: actions.handOff,
                    onSwitchModel: actions.switchModel,
                    onCompact: canCompact ? actions.compact : null,
                  ),
                ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(t.space.lg, t.space.md, t.space.lg, 0),
                  child: Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: EdgeInsets.all(t.space.lg),
                      child: BudgetOverview(
                        budget: i.budget,
                        level: i.level,
                        thresholds: i.profile.thresholds,
                        modelName: modelName,
                      ),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: _CompactCard(
                  enabled: canCompact,
                  disabledReason: gate ??
                      (snapshot.canCompact ? null : 'This build summarizes only when the context fills up.'),
                  keepTurns: i.profile.keepRecentUserTurns,
                  onCompact: actions.compact,
                ),
              ),
              SliverToBoxAdapter(
                child: SectionHeader(
                  'In the next request',
                  trailing: Text(
                    '${plural(i.items.length + 2, 'part')} · ${groupDigits(i.budget.inputTokens)} tokens',
                    style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(t.space.lg, 0, t.space.lg, t.space.sm),
                  child: Text(
                    'In order, exactly as the next request sends them. Tap an item to read it.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
              SliverToBoxAdapter(child: _SystemTile(snapshot: snapshot)),
              SliverToBoxAdapter(child: _ToolsTile(snapshot: snapshot)),
              SliverList.builder(
                itemCount: facts.length,
                itemBuilder: (context, k) => ContextItemTile(
                  facts: facts[k],
                  onTap: () => unawaited(actions.showItem(facts[k])),
                ),
              ),
              SliverToBoxAdapter(
                child: SectionHeader(
                  'Changes to the context',
                  trailing: diffs.isEmpty
                      ? null
                      : Text(
                          plural(diffs.length, 'change'),
                          style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                ),
              ),
              if (diffs.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: t.space.lg),
                    child: Text(
                      'Nothing has been shortened or summarized. The model sees this conversation word for word.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                )
              else ...[
                SliverList.builder(
                  itemCount: inEffect.length,
                  itemBuilder: (context, k) => card(inEffect[k]),
                ),
                // Changes hidden by a later summary no longer affect what is
                // sent; listing them one by one would bury the ones that do.
                if (hidden.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Theme(
                      data: theme.copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        tilePadding: EdgeInsets.symmetric(horizontal: t.space.lg),
                        leading: const Icon(Icons.layers_outlined),
                        title: Text('${plural(hidden.length, 'older change')} inside a summary'),
                        subtitle: const Text('They no longer affect what is sent. Undo the summary and they apply again.'),
                        children: [for (final d in hidden) card(d)],
                      ),
                    ),
                  ),
              ],
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    t.space.lg,
                    t.space.xl,
                    t.space.lg,
                    t.space.xxxl + MediaQuery.paddingOf(context).bottom,
                  ),
                  child: Text(
                    'Your transcript is never edited. These changes only affect what is sent to the model, and '
                    'undo puts the original back.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The inspector's intents, kept out of the widget tree for readability.
final class _InspectorActions {
  _InspectorActions(this.context, this.ref, this.sessionId, this.snapshot);

  final BuildContext context;
  final WidgetRef ref;
  final String sessionId;
  final ContextSnapshot snapshot;

  ContextInspectorController get _inspector => ref.read(contextInspectorProvider(sessionId).notifier);

  void _toast(String message, {SnackBarAction? action}) {
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action, persist: false));
  }

  void handOff() => unawaited(GoRouter.maybeOf(context)?.push(Routes.chatHandoff(sessionId)));

  Future<void> switchModel() async {
    final current = ref.read(chatControllerProvider(sessionId)).model?.choice;
    final choice = await ModelPickerSheet.show(context, current: current);
    if (choice == null || !context.mounted) return;
    await ref.read(chatControllerProvider(sessionId).notifier).changeModel(choice);
  }

  Future<void> compact() async {
    try {
      final outcome = await _inspector.compactNow();
      if (outcome == null) {
        _toast('Wait for the current reply to finish, then try again.');
        return;
      }
      final o = outcome.overlay;
      if (o == null) {
        _toast('Nothing to summarize yet: ${outcome.skippedReason ?? 'the chat is short'}.');
        return;
      }
      ref.read(hapticsProvider).success();
      _toast(
        'Summarized earlier messages: now ${formatPercent(outcome.ratioAfter)} full, down from '
        '${formatPercent(outcome.ratioBefore)}.',
        action: SnackBarAction(label: 'Undo', onPressed: () => unawaited(_inspector.undo(o.id))),
      );
    } on StateError catch (e) {
      _toast("Couldn't summarize: ${e.message}.");
    } on Object {
      _toast("Couldn't summarize the conversation. Try again.");
    }
  }

  /// Undo is destructive to the *view* only, but it can make the next
  /// request much bigger, so it is confirmed and explained, including any
  /// later summary that has to go with it.
  Future<void> undo(ContextDiff d) async {
    final set = snapshot.inspection.undoSet(d.overlayId);
    final dependents = [
      for (final id in set.skip(1))
        ?snapshot.inspection.diffFor(id),
    ];
    final restored = d.kind == ContextDiffKind.compaction
        ? 'The ${plural(d.messageIds.length, 'message')} it stands in for go back into what the model sees'
        : 'The original goes back into what the model sees';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(d.kind == ContextDiffKind.compaction ? 'Undo this summary?' : 'Undo this change?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$restored, about ${groupDigits(savedTokens(d))} more tokens in each request. Your transcript '
                  'was never changed.'),
              if (dependents.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  dependents.length == 1
                      ? 'A later summary was built on this one, so it is undone too:'
                      : '${dependents.length} later summaries were built on this one, so they are undone too:',
                  style: Theme.of(dialog).textTheme.titleSmall,
                ),
                for (final x in dependents) Text('• ${overlayTitle(x, snapshot.overlay(x.overlayId))}'),
              ],
              const SizedBox(height: 12),
              const Text('If the chat is still too full, Sherpa may need to shorten it again before the next reply.'),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(set.length > 1 ? 'Undo ${set.length} changes' : 'Undo'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final removed = await _inspector.undo(d.overlayId);
      if (removed == null) {
        _toast('Wait for the current reply to finish, then try again.');
      } else {
        ref.read(hapticsProvider).selection();
        _toast(removed.length > 1 ? 'Undid ${removed.length} changes.' : 'Undone. The original is back in context.');
      }
    } on Object {
      _toast("Couldn't undo the change. Try again.");
    }
  }

  Future<void> showItem(ItemFacts f) => showContextSheet(
        context,
        title: f.title,
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: SherpaTokens.of(context).space.xs,
              runSpacing: SherpaTokens.of(context).space.xs,
              children: [
                ContextTag(icon: Icons.token_outlined, label: '${groupDigits(f.item.tokens)} tokens'),
                ...itemTags(context, f),
              ],
            ),
            for (final m in f.markers)
              Padding(
                padding: EdgeInsets.only(top: SherpaTokens.of(context).space.sm),
                child: Text(
                  ItemFacts.markerExplanation(m),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            if (f.message.pinned && f.summary == null)
              Padding(
                padding: EdgeInsets.only(top: SherpaTokens.of(context).space.sm),
                child: Text(
                  'Pinned: never shortened or summarized.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
          ],
        ),
        body: (_) => MessageContentView(facts: f),
      );

  Future<void> showDiff(ContextDiff d) => showContextSheet(
        context,
        title: overlayTitle(d, snapshot.overlay(d.overlayId)),
        header: Text(d.reason, style: Theme.of(context).textTheme.bodyMedium),
        body: (_) => OverlayDiffView(diff: d, snapshot: snapshot),
      );
}

class _CompactCard extends StatelessWidget {
  const _CompactCard({
    required this.enabled,
    required this.keepTurns,
    required this.onCompact,
    this.disabledReason,
  });

  final bool enabled;
  final int keepTurns;
  final String? disabledReason;
  final Future<void> Function() onCompact;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(t.space.lg, t.space.md, t.space.lg, 0),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: EdgeInsets.all(t.space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Make room now', style: theme.textTheme.titleMedium),
              SizedBox(height: t.space.xs),
              Text(
                'Summarize earlier messages now instead of waiting for the context to fill up. Your last '
                '${plural(keepTurns, 'turn')} stay word for word, and you can undo it.',
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              SizedBox(height: t.space.md),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton.tonalIcon(
                  onPressed: enabled ? () => unawaited(onCompact()) : null,
                  icon: const Icon(Icons.compress_rounded),
                  label: const Text('Compact now'),
                ),
              ),
              if (!enabled && disabledReason != null) ...[
                SizedBox(height: t.space.xs),
                Text(disabledReason!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SystemTile extends StatelessWidget {
  const _SystemTile({required this.snapshot});

  final ContextSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final i = snapshot.inspection;
    final text = i.systemPrompt ?? '';
    return _FixedTile(
      icon: Icons.settings_outlined,
      title: 'System prompt',
      subtitle: text.isEmpty ? 'None' : previewLine(text),
      tokens: i.systemTokens,
      onTap: () => unawaited(showContextSheet(
        context,
        title: 'System prompt',
        header: Text(
          'Sent first, before every reply. It includes Sherpa\'s rule that tool output is data, not instructions.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        body: (context) => SelectableText(text.isEmpty ? '(none)' : text, style: contextMonoStyle(context)),
      )),
    );
  }
}

class _ToolsTile extends StatelessWidget {
  const _ToolsTile({required this.snapshot});

  final ContextSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final i = snapshot.inspection;
    final tools = snapshot.tools;
    return _FixedTile(
      icon: Icons.handyman_outlined,
      title: 'Tool definitions',
      subtitle: !snapshot.capabilities.canCallTools
          ? 'This model does not call tools'
          : (tools.isEmpty ? 'No tools offered' : plural(tools.length, 'tool the model can call', 'tools the model can call')),
      tokens: i.toolTokens,
      onTap: () => unawaited(showContextSheet(
        context,
        title: 'Tool definitions',
        header: Text(
          'Sent with every request, so the model knows what it can call.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        body: (context) => tools.isEmpty
            ? const Text('No tools are offered to this model.')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final tool in tools)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(tool.displayName),
                      subtitle: Text(tool.description, maxLines: 3, overflow: TextOverflow.ellipsis),
                    ),
                ],
              ),
      )),
    );
  }
}

class _FixedTile extends StatelessWidget {
  const _FixedTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.tokens,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final int tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      button: true,
      label: '$title, ${groupDigits(tokens)} tokens, $subtitle',
      onTap: onTap,
      excludeSemantics: true,
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Text(
          groupDigits(tokens),
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        onTap: onTap,
      ),
    );
  }
}

class _NoModel extends ConsumerWidget {
  const _NoModel({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => EmptyState(
        icon: Icons.memory_rounded,
        title: 'Choose a model first',
        message: 'How much fits depends on the model\'s context window. Pick the model this chat uses to see '
            'exactly what it would be sent.',
        primaryAction: FilledButton.tonalIcon(
          onPressed: () async {
            final choice = await ModelPickerSheet.show(context);
            if (choice != null) await ref.read(chatControllerProvider(sessionId).notifier).changeModel(choice);
          },
          icon: const Icon(Icons.swap_horiz_rounded),
          label: const Text('Choose model'),
        ),
      );
}

class _LoadingSkeleton extends StatelessWidget {
  const _LoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    return Semantics(
      label: 'Measuring the context…',
      liveRegion: true,
      child: ExcludeSemantics(
        child: ListView(
          padding: EdgeInsets.all(t.space.lg),
          children: [
            const Skeleton(height: 28, width: 160),
            SizedBox(height: t.space.md),
            const Skeleton(height: 16),
            SizedBox(height: t.space.xl),
            for (var i = 0; i < 6; i++) ...[
              const Skeleton(height: 14, width: 220),
              SizedBox(height: t.space.xs),
              const Skeleton(height: 12),
              SizedBox(height: t.space.lg),
            ],
          ],
        ),
      ),
    );
  }
}
