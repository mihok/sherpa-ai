import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import '../../design/tokens.dart';
import '../../design/widgets/a11y.dart';
import '../../design/widgets/privacy_badge.dart';
import '../../design/widgets/section_header.dart';
import '../../routing/routes.dart';
import '../../state/app_providers.dart';
import '../../state/provider_location.dart';
import '../../state/ui_preferences.dart';
import '../context/data/data_actions.dart';
import '../providers/fields.dart';
import 'settings_page.dart';

/// Privacy dashboard: which models run where, what crosses the device
/// boundary, and how to read the indicator shown everywhere else.
class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final configs = ref.watch(providerConfigsProvider).value ?? const <ProviderConfig>[];
    ref.watch(localHostVerdictsProvider);
    for (final c in configs) {
      ensureLocalHostVerified(c, ref.read(hostResolverProvider));
    }
    final byLocation = <ExecutionLocation, List<ProviderConfig>>{
      for (final l in ExecutionLocation.values) l: [for (final c in configs) if (locationOf(c) == l) c],
    };
    final body = theme.textTheme.bodyMedium;
    final onDevice = ref.watch(localModelsProvider).value ?? const <ModelDescriptor>[];
    final modelSummaries = ref.watch(uiSettingsProvider.select((s) => s.modelSummaries));

    return SettingsPage(
      title: 'Privacy & data',
      children: [
        const _RightNowCard(),
        const SectionHeader('Where your data goes'),
        _LocationGroup(
          title: 'On this phone',
          empty: 'No models on this phone yet. Download one in Models & downloads, or run a server on this phone.',
          configs: byLocation[ExecutionLocation.onDevice]!,
          leading: [if (onDevice.isNotEmpty) _OnDeviceModelsTile(models: onDevice)],
        ),
        _LocationGroup(
          title: 'Your network',
          empty: 'No servers on your network. Ollama, LM Studio or llama.cpp on a computer you own keep chats off the internet.',
          configs: byLocation[ExecutionLocation.localNetwork]!,
        ),
        _LocationGroup(
          title: 'Internet services',
          empty: 'No cloud providers connected.',
          configs: byLocation[ExecutionLocation.remote]!,
        ),
        const SectionHeader('Long chats'),
        SwitchListTile(
          title: const Text("Let the chat's model write summaries"),
          subtitle: const Text(
            'When a chat gets long, Sherpa summarizes its older messages so it can keep going. On-device '
            'models always write their own summaries. For other models, Sherpa makes a simpler summary on '
            "this phone unless you turn this on: then the older conversation is sent to the chat's "
            'provider once more to be summarized.',
          ),
          isThreeLine: true,
          value: modelSummaries,
          onChanged: (v) {
            ref.read(hapticsProvider).selection();
            unawaited(ref.read(uiSettingsProvider.notifier).update((s) => s.copyWith(modelSummaries: v)));
          },
        ),
        const SectionHeader('The trust boundary'),
        SettingsPadding(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Sherpa has no servers of its own. Chats, settings and keys are stored on this phone.',
                style: body,
              ),
              SizedBox(height: t.space.md),
              Text(
                "When a chat uses a model that isn't on this device, that chat's messages are sent to the "
                "model's provider: what you type, files you attach, and the tool results the agent "
                'includes. The connection is encrypted (plain http only for a server on your own network, '
                "and only if you allowed it). From there, the provider's own privacy policy applies.",
                style: body,
              ),
              SizedBox(height: t.space.md),
              Text(
                'API keys stay in the $secureStoreName and are only ever sent to the provider they belong to.',
                style: body,
              ),
              SizedBox(height: t.space.md),
              Text(
                'Text that comes back from tools and websites is treated as data, never as instructions '
                'to Sherpa.',
                style: body,
              ),
            ],
          ),
        ),
        const SectionHeader('Reading the indicator'),
        const _IndicatorRow(
          badge: PrivacyBadge(location: ExecutionLocation.onDevice),
          meaning: 'The model runs on this phone. Nothing leaves it.',
        ),
        const _IndicatorRow(
          badge: PrivacyBadge(location: ExecutionLocation.localNetwork, host: '192.168.1.20'),
          meaning: 'Sent to a machine on your own network.',
        ),
        const _IndicatorRow(
          badge: PrivacyBadge(location: ExecutionLocation.remote, host: 'api.example.com'),
          meaning: 'Sent over the internet to that host.',
        ),
        SettingsPadding(
          child: Text(
            'You will see it on every chat, in the model picker and in settings. '
            'The "Leaves device" color is a heads-up, not an error.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        const SectionHeader('Your data'),
        ListTile(
          leading: const Icon(Icons.file_download_outlined),
          title: const Text('Export my data'),
          subtitle: const Text('All chats and settings as a JSON file, never keys'),
          onTap: () => unawaited(exportAllData(context, ref)),
        ),
        ListTile(
          leading: const Icon(Icons.move_down_rounded),
          title: const Text('Import a handoff'),
          subtitle: const Text('Continue a task from another device'),
          onTap: () => unawaited(context.push<void>(Routes.handoffImport)),
        ),
        ListTile(
          leading: Icon(Icons.delete_forever_outlined, color: theme.colorScheme.error),
          title: Text('Delete all data', style: TextStyle(color: theme.colorScheme.error)),
          subtitle: const Text('Chats, providers, keys and preferences on this phone'),
          onTap: () => unawaited(deleteAllData(context, ref)),
        ),
      ],
    );
  }
}

class _RightNowCard extends ConsumerWidget {
  const _RightNowCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final choice = ref.watch(defaultModelProvider).value;
    final privacy = choice == null ? null : ref.watch(providerPrivacyProvider(choice.providerId));
    final name = choice == null ? null : ref.watch(modelDisplayNameProvider(choice));
    return Padding(
      padding: EdgeInsets.fromLTRB(t.space.lg, t.space.lg, t.space.lg, 0),
      child: Card(
        child: Padding(
          padding: EdgeInsets.all(t.space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Right now', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
              SizedBox(height: t.space.sm),
              if (choice == null || privacy == null)
                Text('No default model. New chats will ask which model to use.', style: theme.textTheme.bodyLarge)
              else ...[
                Text('New chats use $name.', style: theme.textTheme.bodyLarge),
                SizedBox(height: t.space.sm),
                PrivacyBadge(location: privacy.location, host: privacy.host),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LocationGroup extends StatelessWidget {
  const _LocationGroup({required this.title, required this.empty, required this.configs, this.leading = const []});

  final String title;
  final String empty;
  final List<ProviderConfig> configs;

  /// Rows above the configs (the on-device models).
  final List<Widget> leading;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return HeadingGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(t.space.lg, t.space.md, t.space.lg, t.space.xs),
            child: Heading(level: 3, child: Text(title, style: theme.textTheme.titleSmall)),
          ),
          ...leading,
          if (configs.isEmpty && leading.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: t.space.lg, vertical: t.space.xs),
              child: Text(empty, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          for (final c in configs)
            ListTile(
              title: Text(c.displayName),
              subtitle: Padding(
                padding: EdgeInsets.only(top: t.space.xs),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: PrivacyBadge(location: locationOf(c), host: privacyHostLabel(c)),
                ),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.go(Routes.provider(c.id)),
            ),
        ],
      ),
    );
  }
}

/// "On this phone: 3 on-device models", with their names.
class _OnDeviceModelsTile extends StatelessWidget {
  const _OnDeviceModelsTile({required this.models});

  final List<ModelDescriptor> models;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final n = models.length;
    final names = models.take(3).map((m) => m.displayName).join(', ');
    final more = n > 3 ? ' and ${n - 3} more' : '';
    return ListTile(
      title: Text('$n on-device ${n == 1 ? 'model' : 'models'}'),
      subtitle: Padding(
        padding: EdgeInsets.only(top: t.space.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$names$more', maxLines: 2, overflow: TextOverflow.ellipsis),
            SizedBox(height: t.space.xs),
            const PrivacyBadge(location: ExecutionLocation.onDevice),
          ],
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.go(Routes.models),
    );
  }
}

class _IndicatorRow extends StatelessWidget {
  const _IndicatorRow({required this.badge, required this.meaning});

  final Widget badge;
  final String meaning;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: t.space.lg, vertical: t.space.sm),
      child: Wrap(
        spacing: t.space.md,
        runSpacing: t.space.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          badge,
          Text(meaning, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}
