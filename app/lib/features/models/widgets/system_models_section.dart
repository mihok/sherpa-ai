import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart' show ExecutionLocation;

import '../../../design/tokens.dart';
import '../../../design/widgets/privacy_badge.dart';
import '../../../design/widgets/section_header.dart';
import '../../../services/inference/on_device_ids.dart';
import '../../../services/inference/platform_models.dart';
import '../../../state/services.dart';
import '../../../state/ui_preferences.dart';
import '../state/local_model_choice.dart';
import '../state/local_model_fit.dart' show systemModelIds;
import '../state/platform_models_providers.dart';
import 'format.dart';
import 'pills.dart';

/// "System models": the model the phone's own system ships (Apple
/// Intelligence on iOS, Gemini Nano on Android) with its status in plain
/// words, a download with progress for Gemini Nano, and "Use in chat" once
/// it is ready. Renders nothing when the platform has none or the platform
/// providers are not wired.
class SystemModelsSection extends ConsumerWidget {
  const SystemModelsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ids = ref.watch(systemModelIdsProvider);
    if (ids.isEmpty) return const SizedBox.shrink();
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('System models'),
        Padding(
          padding: EdgeInsets.fromLTRB(t.space.lg, 0, t.space.lg, t.space.sm),
          child: Text(
            "Built into this phone's operating system: nothing to download from Hugging Face, and like every "
            'model on this phone, nothing you type leaves the device. They are small, so they suit short '
            'questions and quick edits more than long tasks.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        for (final id in ids) SystemModelCard(key: ValueKey('system-model-$id'), providerId: id),
      ],
    );
  }
}

/// One system model's card.
class SystemModelCard extends ConsumerWidget {
  const SystemModelCard({super.key, required this.providerId});

  final String providerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = ref.watch(systemModelStatusProvider(providerId));
    final nano = providerId == geminiNanoProviderId;
    final download = nano ? ref.watch(nanoDownloadProvider) : const NanoDownloadState();
    final a = status.value;
    final use = ref.watch(useLocalModelInChatProvider);
    final name = onDeviceProviderName(providerId) ?? providerId;
    final about = nano
        ? 'Google\'s on-device model, run by Android\'s AICore service. Android downloads and updates it; '
            'Sherpa only asks for it.'
        : "Apple's on-device model, part of Apple Intelligence (iOS 26 and later). The system downloads and "
            'updates it.';

    final (String label, PillTone tone, IconData icon) = switch (a?.state) {
      _ when download.running => ('Downloading', PillTone.accent, Icons.downloading_rounded),
      EngineAvailabilityState.available => ('Ready', PillTone.success, Icons.check_circle_outline_rounded),
      EngineAvailabilityState.downloadable => (nano ? 'Not downloaded' : 'Not ready', PillTone.warning, Icons.download_outlined),
      EngineAvailabilityState.downloading => ('Downloading', PillTone.accent, Icons.downloading_rounded),
      EngineAvailabilityState.unsupported => ('Unavailable', PillTone.neutral, Icons.block_rounded),
      null => ('Checking…', PillTone.neutral, Icons.hourglass_top_rounded),
    };

    final actions = <Widget>[
      if (a != null && a.isAvailable)
        FilledButton.tonalIcon(
          onPressed: use == null
              ? null
              : () async {
                  ref.read(hapticsProvider).light();
                  await use(context, ModelChoice(providerId: providerId, modelId: systemModelIds[providerId]!));
                },
          icon: const Icon(Icons.chat_bubble_outline_rounded),
          label: const Text('Use in chat'),
        ),
      if (nano && a?.state == EngineAvailabilityState.downloadable && !download.running)
        FilledButton.icon(
          onPressed: () => unawaited(ref.read(nanoDownloadProvider.notifier).start()),
          icon: const Icon(Icons.download_rounded),
          label: const Text('Download Gemini Nano'),
        ),
      if (a != null && !a.isAvailable && !download.running && a.state != EngineAvailabilityState.unsupported)
        TextButton.icon(
          onPressed: () {
            ref.invalidate(systemModelStatusProvider(providerId));
            ref.read(platformModelProvidersProvider)?.refreshSystemModels();
          },
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Check again'),
        ),
    ];

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: t.space.lg, vertical: t.space.xs),
      child: DecoratedBox(
        decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(t.radius.lg)),
        child: Padding(
          padding: EdgeInsets.fromLTRB(t.space.lg, t.space.md, t.space.md, t.space.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: t.space.sm,
                runSpacing: t.space.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(name, style: theme.textTheme.titleSmall),
                  InfoPill(label: label, icon: icon, tone: tone, semanticPrefix: 'Status', explanation: a?.reason ?? about),
                  const PrivacyBadge(location: ExecutionLocation.onDevice),
                ],
              ),
              SizedBox(height: t.space.xs),
              Text(about, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              if (a != null) ...[
                SizedBox(height: t.space.xs),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _statusText(a, nano: nano),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: a.isAvailable ? scheme.onSurface : (a.state == EngineAvailabilityState.unsupported ? scheme.onSurfaceVariant : t.semantic.warning),
                    ),
                  ),
                ),
              ],
              if (download.running) ...[
                SizedBox(height: t.space.sm),
                LinearProgressIndicator(value: download.fraction, semanticsLabel: 'Downloading Gemini Nano'),
                SizedBox(height: t.space.xxs),
                Text(
                  download.totalBytes != null && download.downloadedBytes != null
                      ? '${formatBytesOf(download.downloadedBytes!, download.totalBytes!)} · keep Sherpa open or come back later'
                      : 'Starting the download…',
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
              if (download.error != null && !download.running) ...[
                SizedBox(height: t.space.xs),
                Text("The download didn't finish: ${download.error}",
                    style: theme.textTheme.bodySmall?.copyWith(color: t.semantic.danger)),
              ],
              if (nano && a?.state != EngineAvailabilityState.unsupported) ...[
                SizedBox(height: t.space.sm),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.visibility_outlined, size: 16, color: scheme.onSurfaceVariant),
                    SizedBox(width: t.space.xs),
                    Expanded(
                      child: Text(kForegroundOnlyExplanation,
                          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                    ),
                  ],
                ),
              ],
              if (actions.isNotEmpty) ...[
                SizedBox(height: t.space.sm),
                Wrap(spacing: t.space.sm, runSpacing: t.space.sm, children: actions),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The platform's sentence, plus what to do about it.
  static String _statusText(EngineAvailability a, {required bool nano}) {
    if (a.isAvailable) return a.reason;
    if (!nano && a.code == 'appleIntelligenceNotEnabled') {
      return '${a.reason} (Settings › Apple Intelligence & Siri), then tap Check again.';
    }
    return a.reason;
  }
}
