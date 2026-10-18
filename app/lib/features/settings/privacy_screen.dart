import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import '../../design/tokens.dart';
import '../../design/widgets/privacy_badge.dart';
import '../../design/widgets/section_header.dart';
import '../../routing/routes.dart';
import '../../state/app_providers.dart';
import '../../state/provider_location.dart';
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
    final byLocation = <ExecutionLocation, List<ProviderConfig>>{
      for (final l in ExecutionLocation.values) l: [for (final c in configs) if (locationOf(c) == l) c],
    };
    final body = theme.textTheme.bodyMedium;

    return SettingsPage(
      title: 'Privacy & data',
      children: [
        const _RightNowCard(),
        const SectionHeader('Where your data goes'),
        _LocationGroup(
          title: 'On this phone',
          empty: 'Nothing yet. Downloadable on-device models arrive in the next release.',
          configs: byLocation[ExecutionLocation.onDevice]!,
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
          subtitle: const Text('Coming in a later update'),
          onTap: () => unawaited(_comingSoon(
            context,
            title: 'Export is on the way',
            message: 'A full export of your chats and settings (without keys) arrives with the context '
                'manager update (M3). Until then, everything stays on this phone.',
          )),
        ),
        ListTile(
          leading: const Icon(Icons.delete_forever_outlined),
          title: const Text('Delete all data'),
          subtitle: const Text('Coming in a later update'),
          onTap: () => unawaited(_comingSoon(
            context,
            title: 'One-tap delete is on the way',
            message: 'It arrives in M3. For now, delete chats from the list (swipe left), remove providers '
                'to delete their keys, or clear Sherpa\'s storage in your system settings.',
          )),
        ),
      ],
    );
  }

  Future<void> _comingSoon(BuildContext context, {required String title, required String message}) =>
      showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('OK'))],
        ),
      );
}

class _RightNowCard extends ConsumerWidget {
  const _RightNowCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final choice = ref.watch(defaultModelProvider).value;
    final privacy = choice == null ? null : ref.watch(providerPrivacyProvider(choice.providerId));
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
                Text('New chats use ${choice.modelId}.', style: theme.textTheme.bodyLarge),
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
  const _LocationGroup({required this.title, required this.empty, required this.configs});

  final String title;
  final String empty;
  final List<ProviderConfig> configs;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(t.space.lg, t.space.md, t.space.lg, t.space.xs),
          child: Semantics(headingLevel: 3, child: Text(title, style: theme.textTheme.titleSmall)),
        ),
        if (configs.isEmpty)
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
                child: PrivacyBadge(location: locationOf(c), host: hostLabel(c.baseUrl)),
              ),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go(Routes.provider(c.id)),
          ),
      ],
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
        children: [badge, Text(meaning, style: Theme.of(context).textTheme.bodyMedium)],
      ),
    );
  }
}
