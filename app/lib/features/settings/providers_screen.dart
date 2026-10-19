import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart' show ExecutionLocation;
import 'package:sherpa_providers/sherpa_providers.dart';

import '../../design/motion.dart';
import '../../design/tokens.dart';
import '../../design/widgets/a11y.dart';
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
    final onDevice = ref.watch(localModelsProvider).value ?? const [];
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
        appBar: AppBar(title: Heading(level: 1, child: const Text('Model providers'))),
        body: EmptyState(
          icon: Icons.dns_outlined,
          title: 'No providers yet',
          message: onDevice.isEmpty
              ? 'Connect a cloud service with your own key, or a model server on your network.'
              : 'Connect a cloud service with your own key, or a model server on your network. '
                  '${onDevice.length == 1 ? 'The model' : 'The ${onDevice.length} models'} on this phone '
                  'work without one.',
          primaryAction: FilledButton.icon(
            onPressed: () => context.go(Routes.newProvider),
            icon: const Icon(Icons.add),
            label: const Text('Add provider'),
          ),
          secondaryAction: onDevice.isEmpty
              ? null
              : TextButton(onPressed: () => context.go(Routes.models), child: const Text('Models & downloads')),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Heading(level: 1, child: const Text('Model providers'))),
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
                if (onDevice.isNotEmpty) _OnDeviceRow(count: onDevice.length),
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

/// The built-in on-device provider: not editable here (its models live in
/// the model library), but listed so every place models come from is.
class _OnDeviceRow extends StatelessWidget {
  const _OnDeviceRow({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    return ListTile(
      onTap: () => context.go(Routes.models),
      title: const Text('On this device'),
      subtitle: Padding(
        padding: EdgeInsets.only(top: t.space.xxs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Built in · $count ${count == 1 ? 'model' : 'models'}'),
            SizedBox(height: t.space.xs),
            const PrivacyBadge(location: ExecutionLocation.onDevice),
          ],
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
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
        animationStyle: motionStyleOf(context),
        builder: (dialog) => AlertDialog(
          title: Heading(child: Text('Remove ${config.displayName}?')),
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
    ref.watch(localHostVerdictsProvider);
    ensureLocalHostVerified(config, ref.read(hostResolverProvider));
    final location = locationOf(config);
    final host = privacyHostLabel(config);
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
        alignment: AlignmentDirectional.centerEnd,
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
            popUpAnimationStyle: motionStyleOf(context),
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
