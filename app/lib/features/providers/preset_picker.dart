import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../design/motion.dart';
import '../../design/tokens.dart';
import '../../design/widgets/a11y.dart';
import '../../design/widgets/privacy_badge.dart';
import '../../design/widgets/section_header.dart';
import 'presets.dart';

/// Grouped choice of where to run models, each with its privacy badge, plus
/// the upcoming on-device option (which explains itself instead of
/// dead-ending).
class PresetPicker extends StatelessWidget {
  const PresetPicker({super.key, required this.onSelected, this.showLocalTeaser = true});

  final ValueChanged<ProviderPreset> onSelected;
  final bool showLocalTeaser;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final children = <Widget>[
      if (showLocalTeaser) ...[
        const SectionHeader('On this phone', padding: EdgeInsets.zero),
        SizedBox(height: t.space.sm),
        _LocalModelsTeaser(onPickNetwork: () => onSelected(ProviderPresets.ollama)),
      ],
      for (final group in PresetGroup.values) ...[
        SectionHeader(group.label, padding: EdgeInsets.only(top: t.space.xl, bottom: t.space.sm)),
        for (final p in ProviderPresets.all.where((p) => p.group == group))
          Padding(
            padding: EdgeInsets.only(bottom: t.space.sm),
            child: PresetCard(preset: p, onTap: () => onSelected(p)),
          ),
      ],
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

class PresetCard extends StatelessWidget {
  const PresetCard({super.key, required this.preset, required this.onTap});

  final ProviderPreset preset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final host = preset.baseUrl == null ? null : Uri.parse(preset.baseUrl!).host;
    final location = preset.isLocalServer ? ExecutionLocation.localNetwork : ExecutionLocation.remote;
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(t.space.lg),
          child: Row(
            children: [
              Icon(preset.icon, color: theme.colorScheme.primary),
              SizedBox(width: t.space.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(preset.name, style: theme.textTheme.titleMedium),
                    SizedBox(height: t.space.xxs),
                    Text(
                      preset.blurb,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    SizedBox(height: t.space.sm),
                    PrivacyBadge(location: location, host: host ?? (preset.isLocalServer ? 'your network' : null)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _LocalModelsTeaser extends StatelessWidget {
  const _LocalModelsTeaser({required this.onPickNetwork});

  final VoidCallback onPickNetwork;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.surfaceContainer,
      child: InkWell(
        onTap: () => unawaited(_explain(context)),
        child: Padding(
          padding: EdgeInsets.all(t.space.lg),
          child: Row(
            children: [
              Icon(Icons.download_for_offline_outlined, color: t.semantic.onDevice),
              SizedBox(width: t.space.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Local models (download)', style: theme.textTheme.titleMedium),
                    SizedBox(height: t.space.xxs),
                    Text(
                      'Coming next: run open models fully offline on this phone.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    SizedBox(height: t.space.sm),
                    const PrivacyBadge(location: ExecutionLocation.onDevice),
                  ],
                ),
              ),
              Icon(Icons.info_outline_rounded, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _explain(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        sheetAnimationStyle: motionStyleOf(context),
        builder: (sheet) {
          final t = SherpaTokens.of(sheet);
          final theme = Theme.of(sheet);
          return SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(t.space.xl, 0, t.space.xl, t.space.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Heading(level: 2, child: Text('On-device models are next', style: theme.textTheme.titleLarge)),
                  SizedBox(height: t.space.md),
                  Text(
                    'Sherpa will download open models from Hugging Face, check they fit your phone, '
                    'and run them without any network. That arrives in the next release.\n\n'
                    'For a private setup today, connect Ollama, LM Studio or llama.cpp running on a '
                    'computer you own. Your messages then stay on your network.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  SizedBox(height: t.space.xl),
                  Wrap(
                    spacing: t.space.sm,
                    runSpacing: t.space.sm,
                    children: [
                      FilledButton(
                        onPressed: () {
                          Navigator.pop(sheet);
                          onPickNetwork();
                        },
                        child: const Text('Use a server on my network'),
                      ),
                      TextButton(onPressed: () => Navigator.pop(sheet), child: const Text('Not now')),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );
}
