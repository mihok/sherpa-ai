import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_inference/sherpa_inference.dart' show EngineCrashReport, InferencePhase;

import '../../design/motion.dart';
import '../../design/tokens.dart';
import '../../design/typography.dart';
import '../../design/widgets/a11y.dart';
import '../../design/widgets/section_header.dart';
import '../../design/widgets/state_views.dart';
import '../../routing/routes.dart';
import '../../services/device/device_profile_source.dart';
import '../../services/downloads/downloads.dart';
import '../../services/inference/local_model_specs.dart' show isRunnableLocally;
import '../../services/inference/on_device_ids.dart';
import '../../services/inference/platform_models.dart' show EngineAvailability;
import '../../state/providers.dart';
import '../../state/ui_preferences.dart';
import '../home/relative_time.dart';
import 'state/local_inference_providers.dart';
import 'state/local_model_choice.dart';
import 'state/models_providers.dart';
import 'state/platform_models_providers.dart';
import 'widgets/format.dart';
import 'widgets/pills.dart';
import 'widgets/system_models_section.dart';

/// Opens the system file picker. A provider so tests can hand in a file.
final modelFilePickerProvider = Provider<Future<LocalModelFile?> Function()>((ref) => pickModelFile);

/// "Models & downloads": the models on this phone, how much space they
/// take, and the ways to get more (browse the Hub, import a file).
class ModelLibraryScreen extends ConsumerStatefulWidget {
  const ModelLibraryScreen({super.key});

  @override
  ConsumerState<ModelLibraryScreen> createState() => _ModelLibraryScreenState();
}

class _ModelLibraryScreenState extends ConsumerState<ModelLibraryScreen> {
  bool _importing = false;

  Future<void> _import() async {
    if (_importing) return;
    final file = await ref.read(modelFilePickerProvider)();
    if (file == null || !mounted) return;
    setState(() => _importing = true);
    final haptics = ref.read(hapticsProvider);
    try {
      final device = await ref.read(deviceProfileSourceProvider).current();
      final manager = ref.read(downloadManagerProvider);
      await manager.init();
      final o = await manager.library.importFile(file, freeStorageBytes: device.freeStorageBytes, device: device);
      if (!mounted) return;
      // The work is done; don't keep the progress bar running under a dialog.
      setState(() => _importing = false);
      switch (o) {
        case Imported(:final model, :final warnings):
          haptics.success();
          _snack(warnings.isEmpty ? 'Added ${model.displayName}' : 'Added ${model.displayName}. ${warnings.first}');
        case AlreadyImported(:final model):
          _snack('${model.displayName} is already in your library');
        case ImportRefused(:final reason):
          haptics.error();
          await showDialog<void>(
            context: context,
            animationStyle: motionStyleOf(context),
            builder: (context) => AlertDialog(
              title: const Heading(child: Text("Couldn't add this file")),
              content: Text(reason),
              actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
            ),
          );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _snack(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final models = ref.watch(libraryModelsProvider);
    final jobs = ref.watch(downloadJobsProvider).value ?? const <DownloadJobView>[];
    final running = jobs.where((j) => j.phase.isActive || j.phase.isWaiting).length;
    final failed = jobs.where((j) => j.phase == JobPhase.failed).length;
    final list = models.value ?? const <LibraryModel>[];
    final free = ref.watch(deviceProfileProvider).value?.freeStorageBytes;

    return Scaffold(
      appBar: AppBar(
        title: Heading(level: 1, child: const Text('Models & downloads')),
        bottom: _importing
            ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator(semanticsLabel: 'Adding model'))
            : null,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importing ? null : () => unawaited(_import()),
        icon: const Icon(Icons.file_open_outlined),
        label: const Text('Add a model file…'),
        tooltip: 'Copy a GGUF file from this phone into Sherpa',
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: t.layout.maxContentWidth),
          child: ListView(
            padding: EdgeInsets.only(bottom: 96 + MediaQuery.paddingOf(context).bottom),
            children: [
              _UsageHeader(models: list, freeBytes: free),
              const LocalEngineBanner(),
              ListTile(
                leading: const Icon(Icons.travel_explore_rounded),
                title: const Text('Browse Hugging Face'),
                subtitle: const Text('Find models that fit this phone'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go(Routes.modelBrowse),
              ),
              ListTile(
                leading: Badge(
                  isLabelVisible: running + failed > 0,
                  backgroundColor: failed > 0 ? t.semantic.danger : null,
                  label: Text('${running + failed}'),
                  child: const Icon(Icons.download_outlined),
                ),
                title: const Text('Downloads'),
                subtitle: Text(switch ((running, failed)) {
                  (0, 0) => 'Nothing in progress',
                  (final r, 0) => '$r in progress',
                  (0, final f) => '$f need${f == 1 ? 's' : ''} attention',
                  (final r, final f) => '$r in progress, $f need${f == 1 ? 's' : ''} attention',
                }),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go(Routes.downloads),
              ),
              SectionHeader('On this phone', count: list.isEmpty ? null : _models(list.length)),
              if (models.isLoading && list.isEmpty)
                const Padding(padding: EdgeInsets.only(top: 48), child: LoadingState(label: 'Loading your models…'))
              else if (list.isEmpty)
                const _EmptyLibrary()
              else
                for (final m in list) LibraryModelTile(model: m),
              const SystemModelsSection(),
            ],
          ),
        ),
      ),
    );
  }
}

String _models(int n) => n == 1 ? '1 model' : '$n models';

class _UsageHeader extends StatelessWidget {
  const _UsageHeader({required this.models, required this.freeBytes});

  final List<LibraryModel> models;
  final int? freeBytes;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final used = models.fold<int>(0, (a, m) => a + m.sizeBytes);
    final n = models.length;
    return Padding(
      padding: EdgeInsets.fromLTRB(t.space.lg, t.space.md, t.space.lg, t.space.sm),
      child: DecoratedBox(
        decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerLow, borderRadius: BorderRadius.circular(t.radius.lg)),
        child: Padding(
          padding: EdgeInsets.all(t.space.lg),
          child: Row(
            children: [
              Icon(Icons.sd_storage_outlined, color: theme.colorScheme.primary),
              SizedBox(width: t.space.md),
              Expanded(
                child: Tooltip(
                  message: 'Space the verified model files take in Sherpa. Deleting a model frees it at once.',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(formatBytes(used), style: theme.textTheme.metricLarge),
                      Text(
                        n == 0 ? 'No models on this phone yet' : 'Used by $n model${n == 1 ? '' : 's'}',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
              if (freeBytes != null)
                Tooltip(
                  message: 'Free space on this phone. Sherpa keeps at least 1 GB free for the system.',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(formatBytes(freeBytes!), style: theme.textTheme.metricLarge),
                      Text('free', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
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

/// The on-device engine's news, above the library: the previous run's
/// crash report (until dismissed) and why local models can't run, if so.
class LocalEngineBanner extends ConsumerWidget {
  const LocalEngineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final status = ref.watch(localEngineStatusProvider).value;
    final crash = status?.crashReport;
    final unavailable = status?.unavailableMessage;
    if (crash == null && unavailable == null) return const SizedBox.shrink();
    Widget card({required IconData icon, required Color color, required String title, required String body, Widget? action}) =>
        Padding(
          padding: EdgeInsets.fromLTRB(t.space.lg, t.space.xs, t.space.lg, t.space.xs),
          child: Semantics(
            container: true,
            liveRegion: true,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(t.radius.lg),
                border: Border.all(color: color.withValues(alpha: 0.5)),
              ),
              child: Padding(
                padding: EdgeInsetsDirectional.fromSTEB(t.space.lg, t.space.md, t.space.sm, t.space.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, color: color),
                    SizedBox(width: t.space.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: theme.textTheme.titleSmall),
                          SizedBox(height: t.space.xxs),
                          Text(body, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                          ?action,
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
    return Column(
      children: [
        if (crash != null)
          card(
            icon: Icons.report_problem_outlined,
            color: t.semantic.warning,
            title: 'The on-device engine stopped last time',
            body: '${crash.description} '
                '${_downgraded(crash) ? 'Sherpa now opens that model with a shorter context. ' : ''}'
                'Your chats are safe.',
            action: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                onPressed: () => ref.read(localInferenceProvider)?.acknowledgeCrashReport(),
                child: const Text('Dismiss'),
              ),
            ),
          ),
        if (unavailable != null)
          card(
            icon: Icons.memory_rounded,
            color: theme.colorScheme.outline,
            title: "On-device chat isn't available",
            body: '$unavailable Models stay in your library; chats can use a provider meanwhile.',
            action: status!.canRetry
                ? Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton(
                      onPressed: () => unawaited(ref.read(localInferenceProvider)?.retryEngine()),
                      child: const Text('Try again'),
                    ),
                  )
                : null,
          ),
      ],
    );
  }
}

/// "MLX: Ready." / "LiteRT-LM: Runs on GPU (falls back to CPU)." / why it
/// can't run here, from the platform engine's availability check.
class _EngineLine extends StatelessWidget {
  const _EngineLine({required this.name, required this.availability});

  final String name;
  final EngineAvailability? availability;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final a = availability;
    final ok = a?.isAvailable ?? false;
    final color = ok ? theme.colorScheme.onSurfaceVariant : t.semantic.warning;
    return Semantics(
      container: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? Icons.memory_rounded : Icons.block_rounded, size: 16, color: color),
          SizedBox(width: t.space.xs),
          Expanded(
            child: Text(
              '$name: ${a?.reason ?? 'not available in this build of Sherpa.'}',
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// The lifecycle halves a model's context after a crash while loading or
/// generating with it (ModelLifecycleManager.start).
bool _downgraded(EngineCrashReport crash) {
  final p = crash.phase;
  return p.modelId != null &&
      p.nCtx != null &&
      (p.phase == InferencePhase.loading || p.phase == InferencePhase.generating);
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) => EmptyState(
        icon: Icons.smartphone_outlined,
        title: 'No on-device models yet',
        message: 'Download one from Hugging Face, or add a GGUF file you already have. '
            'Models on this phone keep working offline, and nothing you type leaves the device.',
        primaryAction: FilledButton.tonal(
          onPressed: () => context.go(Routes.modelBrowse),
          child: const Text('Browse models'),
        ),
      );
}

/// One installed model with its facts and actions.
class LibraryModelTile extends ConsumerWidget {
  const LibraryModelTile({super.key, required this.model});

  final LibraryModel model;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final m = model;
    final use = ref.watch(useLocalModelInChatProvider);
    final provider = libraryProviderIdFor(m.format);
    final platformModel = provider == mlxProviderId || provider == liteRtProviderId;
    // MLX / LiteRT: the platform engine's verdict on this model (with its
    // reason); GGUF: llama.cpp's status.
    final availability = platformModel ? ref.watch(libraryModelAvailabilityProvider(m.id)) : null;
    final engineName = provider == mlxProviderId ? 'MLX' : 'LiteRT-LM';
    final String? engineProblem;
    if (!platformModel) {
      engineProblem = ref.watch(localEngineStatusProvider).value?.unavailableMessage;
    } else if (availability!.isLoading && !availability.hasValue) {
      engineProblem = 'Checking whether $engineName can run it here…';
    } else {
      final a = availability.value;
      engineProblem = a == null ? '$engineName is not available in this build of Sherpa.' : (a.isAvailable ? null : a.reason);
    }
    final now = ref.watch(clockProvider).now();
    final ctx = m.defaultContextLength;
    final facts = <Widget>[
      Metric(icon: Icons.sd_storage_outlined, value: formatBytes(m.sizeBytes), explanation: 'Space on this phone'),
      if (m.quant != null)
        Metric(
          icon: Icons.grain_rounded,
          value: m.quant!,
          explanation: 'Quantization: how many bits each weight uses. Lower is smaller and faster, higher is closer '
              'to the original model.',
        ),
      if (ctx != null)
        Metric(
          icon: Icons.notes_rounded,
          value: '${formatContext(ctx)} context',
          explanation: 'Default context: the longest conversation that fit with headroom on this phone when it was '
              'installed${m.contextLength == null ? '' : ' (trained for ${formatContext(m.contextLength!)})'}.',
        ),
      Metric(
        icon: Icons.history_rounded,
        value: m.lastUsedAt == null ? 'Not used yet' : 'Used ${formatRelativeShort(m.lastUsedAt!, now)}',
        explanation: 'When a chat last ran on this model',
      ),
    ];
    final tags = <Widget>[
      if (m.hasVision) const InfoPill(label: 'Vision', icon: Icons.image_outlined, explanation: 'Has a vision projector: accepts images'),
      if (m.toolUse)
        const InfoPill(label: 'Tool use', icon: Icons.build_outlined, explanation: 'Its own chat template renders tools'),
      if (m.reasoning)
        const InfoPill(label: 'Reasoning', icon: Icons.psychology_alt_outlined, explanation: 'Supports a thinking phase'),
      if (m.source == LibrarySource.imported)
        const InfoPill(label: 'Imported', icon: Icons.file_open_outlined, explanation: 'Added from a file on this phone'),
    ];

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: t.space.lg, vertical: t.space.xs),
      child: DecoratedBox(
        decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(t.radius.lg)),
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(t.space.lg, t.space.md, t.space.xs, t.space.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          m.displayName,
                          style: theme.textTheme.titleSmall,
                          maxLines: scaledMaxLines(context),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (m.repo != null)
                          Text(m.repo!,
                              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                              maxLines: scaledMaxLines(context),
                              overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Delete ${m.displayName}',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () => unawaited(_confirmDelete(context, ref)),
                  ),
                ],
              ),
              SizedBox(height: t.space.sm),
              Padding(
                padding: EdgeInsetsDirectional.only(end: t.space.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(spacing: t.space.md, runSpacing: t.space.xs, children: facts),
                    if (tags.isNotEmpty) ...[
                      SizedBox(height: t.space.sm),
                      Wrap(spacing: t.space.xs, runSpacing: t.space.xs, children: tags),
                    ],
                    if (!m.usable) ...[
                      SizedBox(height: t.space.sm),
                      Text(m.issue.message, style: theme.textTheme.bodySmall?.copyWith(color: t.semantic.danger)),
                    ] else if (platformModel && availability!.hasValue) ...[
                      SizedBox(height: t.space.sm),
                      _EngineLine(name: engineName, availability: availability.value),
                    ],
                    SizedBox(height: t.space.sm),
                    Wrap(
                      spacing: t.space.sm,
                      runSpacing: t.space.sm,
                      children: [
                        Tooltip(
                          message: use == null
                              ? 'On-device chat arrives with the local engine.'
                              : engineProblem ?? 'Start a chat that runs on this phone',
                          child: FilledButton.tonalIcon(
                            onPressed: use == null || !m.usable || engineProblem != null
                                ? null
                                : () async {
                                    ref.read(hapticsProvider).light();
                                    await ref.read(modelLibraryProvider).markUsed(m.id);
                                    if (context.mounted) await use(context, localModelChoice(m));
                                  },
                            icon: const Icon(Icons.chat_bubble_outline_rounded),
                            label: const Text('Use in chat'),
                          ),
                        ),
                        // The lab explains an unavailable engine itself.
                        if (ref.watch(localInferenceProvider) != null && isRunnableLocally(m))
                          Tooltip(
                            message: 'Speed, memory and settings of ${m.displayName} on this phone',
                            child: OutlinedButton.icon(
                              onPressed: () => context.go(Routes.modelPerformance(m.id)),
                              icon: const Icon(Icons.speed_rounded),
                              label: const Text('Performance'),
                            ),
                          ),
                      ],
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

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      animationStyle: motionStyleOf(context),
      builder: (context) => AlertDialog(
        title: Heading(child: Text('Delete ${model.displayName}?')),
        content: Text('This frees ${formatBytes(model.sizeBytes)}. You can download it again later.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: SherpaTokens.of(context).semantic.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!(ok ?? false)) return;
    ref.read(hapticsProvider).warning();
    await ref.read(modelLibraryProvider).delete(model.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Deleted ${model.displayName}')));
    }
  }
}
