import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import '../../design/tokens.dart';
import '../../design/widgets/privacy_badge.dart';
import '../../design/widgets/section_header.dart';
import '../../state/app_providers.dart';
import '../../state/provider_location.dart';
import '../../state/providers.dart';
import '../../state/services.dart';
import '../../state/ui_preferences.dart';

/// Chooses the model new chats start with, across every provider.
///
/// Each provider is a section headed by its privacy badge, so choosing a
/// default is also choosing where new chats go.
Future<void> showDefaultModelSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => const _DefaultModelSheet(),
    );

class _DefaultModelSheet extends ConsumerWidget {
  const _DefaultModelSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final configs = ref.watch(providerConfigsProvider).value ?? const <ProviderConfig>[];
    final current = ref.watch(defaultModelProvider).value;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) => RadioGroup<ModelChoice>(
        groupValue: current,
        onChanged: (choice) {
          if (choice == null) return;
          ref.read(hapticsProvider).selection();
          ref.read(preferencesProvider).setDefaultModel(choice).ignore();
          Navigator.pop(context);
        },
        child: ListView(
          controller: scroll,
          padding: EdgeInsets.only(bottom: t.space.xl),
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: t.space.xl),
              child: Semantics(
                headingLevel: 2,
                child: Text('Default model', style: Theme.of(context).textTheme.titleLarge),
              ),
            ),
            if (configs.isEmpty)
              Padding(
                padding: EdgeInsets.all(t.space.xl),
                child: const Text('Connect a provider first.'),
              ),
            for (final c in configs) _ProviderModels(config: c),
          ],
        ),
      ),
    );
  }
}

class _ProviderModels extends ConsumerWidget {
  const _ProviderModels({required this.config});

  final ProviderConfig config;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final models = ref.watch(providerModelsProvider(config.id));
    ref.watch(localHostVerdictsProvider);
    ensureLocalHostVerified(config, ref.read(hostResolverProvider));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          config.displayName,
          trailing: PrivacyBadge(location: locationOf(config), host: privacyHostLabel(config)),
        ),
        ...switch (models) {
          AsyncData(:final value) when value.isEmpty => [
              ListTile(title: const Text('No models listed'), subtitle: Text(config.baseUrl.host)),
            ],
          AsyncData(:final value) => [
              for (final m in value)
                RadioListTile<ModelChoice>(
                  value: ModelChoice(providerId: config.id, modelId: m.id),
                  title: Text(m.displayName, maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
            ],
          AsyncError() => [
              ListTile(
                leading: const Icon(Icons.error_outline_rounded),
                title: const Text("Couldn't load models"),
                trailing: TextButton(
                  onPressed: () => ref.invalidate(providerModelsProvider(config.id)),
                  child: const Text('Retry'),
                ),
              ),
            ],
          _ => [
              Padding(
                padding: EdgeInsets.all(t.space.lg),
                child: const Center(child: CircularProgressIndicator()),
              ),
            ],
        },
      ],
    );
  }
}
