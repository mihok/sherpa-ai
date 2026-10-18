import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import '../../design/tokens.dart';
import '../../design/widgets/privacy_badge.dart';
import '../../design/widgets/state_views.dart';
import '../../routing/routes.dart';
import '../../state/app_providers.dart';
import '../../state/provider_location.dart';
import '../../state/providers.dart';
import '../../state/services.dart';
import '../../state/ui_preferences.dart';
import '../providers/presets.dart';
import '../providers/status_chip.dart';

/// Configured providers with live status. Pull to re-check all of them.
class ProvidersScreen extends ConsumerStatefulWidget {
  const ProvidersScreen({super.key});

  @override
  ConsumerState<ProvidersScreen> createState() => _ProvidersScreenState();
}

class _ProvidersScreenState extends ConsumerState<ProvidersScreen> {
  /// Rows swiped away whose removal is still being written; hidden at once
  /// because a dismissed `Dismissible` must leave the tree in the same frame.
  final Set<String> _removing = {};

  @override
  Widget build(BuildContext context) {
    final configs = ref.watch(providerConfigsProvider);
    final list = [
      for (final c in configs.value ?? const <ProviderConfig>[])
        if (!_removing.contains(c.id)) c,
    ];
    final addButton = FloatingActionButton.extended(
      onPressed: () => context.go(Routes.newProvider),
      icon: const Icon(Icons.add),
      label: const Text('Add provider'),
    );
    if (configs.hasValue && list.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Semantics(headingLevel: 1, child: const Text('Model providers'))),
        body: EmptyState(
          icon: Icons.dns_outlined,
          title: 'No providers yet',
          message: 'Connect a cloud service with your own key, or a model server on your network.',
          primaryAction: FilledButton.icon(
            onPressed: () => context.go(Routes.newProvider),
            icon: const Icon(Icons.add),
            label: const Text('Add provider'),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Semantics(headingLevel: 1, child: const Text('Model providers'))),
      floatingActionButton: addButton,
      body: RefreshIndicator(
        onRefresh: () async {
          for (final c in list) {
            ref.invalidate(providerStatusProvider(c.id));
          }
          await Future.wait([for (final c in list) ref.read(providerStatusProvider(c.id).future)]);
        },
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: SherpaTokens.of(context).layout.maxContentWidth),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                for (final c in list)
                  _ProviderRow(
                    config: c,
                    onSwipedAway: () => setState(() => _removing.add(c.id)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProviderRow extends ConsumerWidget {
  const _ProviderRow({required this.config, required this.onSwipedAway});

  final ProviderConfig config;
  final VoidCallback onSwipedAway;

  Future<bool> _confirmRemove(BuildContext context) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text('Remove ${config.displayName}?'),
          content: const Text(
            'Its key is deleted from this phone. Chats that used it stay, '
            "but can't continue until you pick another model.",
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dialog).colorScheme.error,
                foregroundColor: Theme.of(dialog).colorScheme.onError,
              ),
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Remove'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _remove(WidgetRef ref) async {
    final prefs = ref.read(preferencesProvider);
    if (prefs.defaultModel?.providerId == config.id) await prefs.setDefaultModel(null);
    await ref.read(providerRegistryProvider).remove(config.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final status = ref.watch(providerStatusProvider(config.id));
    final isDefault = ref.watch(defaultModelProvider).value?.providerId == config.id;
    final location = locationOf(config);
    final host = hostLabel(config.baseUrl);
    void edit() => context.go(Routes.provider(config.id));
    Future<void> removeWithConfirm() async {
      if (await _confirmRemove(context)) await _remove(ref);
    }

    return Dismissible(
      key: ValueKey('provider:${config.id}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _confirmRemove(context),
      onDismissed: (_) {
        onSwipedAway();
        ref.read(hapticsProvider).warning();
        unawaited(_remove(ref));
      },
      background: Container(
        color: scheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: EdgeInsets.symmetric(horizontal: t.space.xl),
        child: Icon(Icons.delete_outline, color: scheme.onErrorContainer),
      ),
      child: Semantics(
        customSemanticsActions: {
          const CustomSemanticsAction(label: 'Remove'): () => unawaited(removeWithConfirm()),
        },
        child: ListTile(
          isThreeLine: true,
          onTap: edit,
          title: Text(config.displayName),
          subtitle: Padding(
            padding: EdgeInsets.only(top: t.space.xxs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [flavorLabel(config.flavor), if (isDefault) 'default for new chats'].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: t.space.xs),
                Wrap(
                  spacing: t.space.xs,
                  runSpacing: t.space.xs,
                  children: [
                    PrivacyBadge(location: location, host: host),
                    EndpointStatusChip(
                      status: status.value ?? EndpointStatus.unknown,
                      checking: status.isLoading,
                    ),
                  ],
                ),
              ],
            ),
          ),
          trailing: PopupMenuButton<String>(
            tooltip: 'More for ${config.displayName}',
            onSelected: (v) => switch (v) {
              'check' => ref.invalidate(providerStatusProvider(config.id)),
              'edit' => edit(),
              _ => unawaited(removeWithConfirm()),
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'check', child: Text('Check again')),
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'remove', child: Text('Remove')),
            ],
          ),
        ),
      ),
    );
  }
}
