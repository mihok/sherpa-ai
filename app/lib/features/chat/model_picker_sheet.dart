import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import '../../design/tokens.dart';
import '../../state/providers.dart';
import '../../state/services.dart';
import 'state/chat_dependencies.dart';
import 'state/model_selection.dart';
import 'widgets/chat_style.dart';
import 'widgets/model_chip.dart';

/// Lists every configured provider's models, each section labelled with
/// where messages go (on device, local network, or which remote host), and
/// returns the picked [ModelChoice].
///
/// ```dart
/// final choice = await ModelPickerSheet.show(context, current: selection);
/// ```
///
/// Model lists come from [ProviderRegistry.models] (cached by the
/// registry); a provider whose listing fails still offers its configured
/// default model, so being offline never hides a usable choice.
class ModelPickerSheet extends ConsumerStatefulWidget {
  const ModelPickerSheet({super.key, this.current});

  /// Shown with a check mark.
  final ModelChoice? current;

  /// Opens the picker as a modal bottom sheet; null if dismissed.
  static Future<ModelChoice?> show(BuildContext context, {ModelChoice? current}) =>
      showModalBottomSheet<ModelChoice>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (_) => ModelPickerSheet(current: current),
      );

  @override
  ConsumerState<ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends ConsumerState<ModelPickerSheet> {
  late final ProviderRegistry _registry = ref.read(providerRegistryProvider);
  late List<ProviderConfig> _configs = _registry.configs;
  final Map<String, Future<List<ModelDescriptor>>> _models = {};
  StreamSubscription<List<ProviderConfig>>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = _registry.changes.listen((configs) {
      if (mounted) setState(() => _configs = configs);
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  Future<List<ModelDescriptor>> _load(String providerId, {bool refresh = false}) {
    if (refresh) _models.remove(providerId);
    return _models[providerId] ??= _registry.models(providerId, refresh: refresh);
  }

  void _addProvider() {
    final route = ref.read(chatRoutesProvider).newProvider;
    final router = GoRouter.maybeOf(context);
    Navigator.of(context).pop();
    router?.push(route);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: EdgeInsets.fromLTRB(tokens.space.lg, 0, tokens.space.lg, tokens.space.xl),
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.space.sm),
            child: Semantics(headingLevel: 2, child: Text('Choose a model', style: theme.textTheme.titleLarge)),
          ),
          SizedBox(height: tokens.space.xs),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.space.sm),
            child: Text(
              'Each provider shows where your messages go. Future replies in this chat use the model you pick.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          SizedBox(height: tokens.space.lg),
          if (_configs.isEmpty)
            _EmptyProviders(onAdd: _addProvider)
          else
            for (final c in _configs)
              _ProviderSection(
                key: ValueKey(c.id),
                config: c,
                models: _load(c.id),
                current: widget.current,
                onRetry: () => setState(() => _load(c.id, refresh: true)),
                onPick: (modelId) => Navigator.of(context).pop(ModelChoice(providerId: c.id, modelId: modelId)),
              ),
          if (_configs.isNotEmpty)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: _addProvider,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add provider'),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyProviders extends StatelessWidget {
  const _EmptyProviders({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.all(tokens.space.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('No providers yet', style: theme.textTheme.titleMedium),
          SizedBox(height: tokens.space.xs),
          Text(
            'Add Anthropic, OpenAI, or a compatible server (llama.cpp, Ollama, LM Studio) to choose a model.',
            style: theme.textTheme.bodyMedium,
          ),
          SizedBox(height: tokens.space.md),
          FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add_rounded), label: const Text('Add provider')),
        ],
      ),
    );
  }
}

class _ProviderSection extends StatelessWidget {
  const _ProviderSection({
    super.key,
    required this.config,
    required this.models,
    required this.current,
    required this.onRetry,
    required this.onPick,
  });

  final ProviderConfig config;
  final Future<List<ModelDescriptor>> models;
  final ModelChoice? current;
  final VoidCallback onRetry;
  final void Function(String modelId) onPick;

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final privacy = privacyForConfig(config);
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.space.sm, vertical: tokens.space.xs),
            child: Wrap(
              spacing: tokens.space.md,
              runSpacing: tokens.space.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Semantics(headingLevel: 3, child: Text(config.displayName, style: theme.textTheme.titleSmall)),
                PrivacyBadge(privacy: privacy),
              ],
            ),
          ),
          FutureBuilder<List<ModelDescriptor>>(
            future: models,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return Padding(
                  padding: EdgeInsets.all(tokens.space.md),
                  child: Row(
                    children: [
                      SizedBox.square(
                        dimension: ChatIconSize.medium,
                        child: const CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: tokens.space.md),
                      const Text('Loading models…'),
                    ],
                  ),
                );
              }
              final list = [...?snap.data];
              final failed = snap.hasError;
              final fallback = config.defaultModelId;
              if (fallback != null && !list.any((m) => m.id == fallback)) {
                list.add(ModelDescriptor(
                  id: fallback,
                  providerId: config.id,
                  displayName: fallback,
                  capabilities: config.modelOverrides[fallback] ?? ModelCapabilities.unknown,
                  description: failed ? 'Configured default' : null,
                ));
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (failed)
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: tokens.space.sm),
                      child: Row(
                        children: [
                          Icon(Icons.cloud_off_rounded, size: ChatIconSize.medium, color: theme.colorScheme.onSurfaceVariant),
                          SizedBox(width: tokens.space.sm),
                          Expanded(
                            child: Text("Couldn't load this provider's models.", style: theme.textTheme.bodySmall),
                          ),
                          TextButton(onPressed: onRetry, child: const Text('Retry')),
                        ],
                      ),
                    ),
                  if (!failed && list.isEmpty)
                    Padding(
                      padding: EdgeInsets.all(tokens.space.sm),
                      child: Text('No models offered.', style: theme.textTheme.bodySmall),
                    ),
                  for (final m in list)
                    _ModelRow(
                      model: m,
                      privacy: privacy,
                      selected: current?.providerId == config.id && current?.modelId == m.id,
                      onTap: () => onPick(m.id),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.model, required this.privacy, required this.selected, required this.onTap});

  final ModelDescriptor model;
  final PrivacyBadgeData privacy;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final caps = model.capabilities;
    final facts = [
      '${formatTokenCount(caps.contextLength)} context',
      if (!caps.canCallTools) 'no tools',
      if (caps.reasoning != ReasoningSupport.none) 'reasoning',
      if (caps.vision) 'images',
    ].join(' · ');
    return Semantics(
      button: true,
      selected: selected,
      label: '${model.displayName}. $facts. ${privacy.description}',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(tokens.radius.md),
        child: Container(
          constraints: BoxConstraints(minHeight: tokens.space.minTouchTarget),
          padding: EdgeInsets.symmetric(horizontal: tokens.space.sm, vertical: tokens.space.sm),
          decoration: selected
              ? BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(tokens.radius.md),
                )
              : null,
          child: Row(
            children: [
              Icon(
                selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                color: selected ? theme.colorScheme.primary : theme.colorScheme.outline,
              ),
              SizedBox(width: tokens.space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(model.displayName, style: theme.textTheme.bodyLarge),
                    Text(facts, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    if (model.description != null && model.description!.isNotEmpty)
                      Text(
                        model.description!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
