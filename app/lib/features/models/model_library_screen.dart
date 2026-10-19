import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../design/typography.dart';
import '../../design/widgets/section_header.dart';
import '../../design/widgets/state_views.dart';
import '../../routing/routes.dart';
import '../../services/device/device_profile_source.dart';
import '../../services/downloads/downloads.dart';
import '../../state/providers.dart';
import '../../state/ui_preferences.dart';
import '../home/relative_time.dart';
import 'state/local_model_choice.dart';
import 'state/models_providers.dart';
import 'widgets/format.dart';
import 'widgets/pills.dart';

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
            builder: (context) => AlertDialog(
              title: const Text("Couldn't add this file"),
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
        title: Semantics(headingLevel: 1, child: const Text('Models & downloads')),
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
              const SectionHeader('On this phone'),
              if (models.isLoading && list.isEmpty)
                const Padding(padding: EdgeInsets.only(top: 48), child: LoadingState(label: 'Loading your models…'))
              else if (list.isEmpty)
                const _EmptyLibrary()
              else
                for (final m in list) LibraryModelTile(model: m),
            ],
          ),
        ),
      ),
    );
  }
}

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
          padding: EdgeInsets.fromLTRB(t.space.lg, t.space.md, t.space.xs, t.space.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(m.displayName, style: theme.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                        if (m.repo != null)
                          Text(m.repo!,
                              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                              maxLines: 1,
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
                padding: EdgeInsets.only(right: t.space.md),
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
                    ],
                    SizedBox(height: t.space.sm),
                    Tooltip(
                      message: use == null ? 'On-device chat arrives with the local engine.' : 'Start a chat that runs on this phone',
                      child: FilledButton.tonalIcon(
                        onPressed: use == null || !m.usable
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
      builder: (context) => AlertDialog(
        title: Text('Delete ${model.displayName}?'),
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
