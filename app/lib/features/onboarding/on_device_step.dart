import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart' show ExecutionLocation;

import '../../design/motion.dart';
import '../../design/tokens.dart';
import '../../design/widgets/a11y.dart';
import '../../design/widgets/privacy_badge.dart';
import '../../design/widgets/section_header.dart';
import '../../services/downloads/downloads.dart';
import '../../services/inference/on_device_ids.dart';
import '../../services/inference/platform_models.dart' show EngineAvailabilityState;
import '../../state/services.dart';
import '../diagnostics/app_error_ring.dart';
import '../models/model_detail_screen.dart';
import '../models/model_directory_screen.dart';
import '../models/state/download_errors.dart';
import '../models/state/local_model_choice.dart';
import '../models/state/local_model_fit.dart';
import '../models/state/models_providers.dart';
import '../models/state/platform_models_providers.dart';
import '../models/state/variant_download.dart';
import '../models/widgets/download_announcement.dart';
import '../models/widgets/format.dart';
import '../models/widgets/pills.dart';
import 'onboarding_scaffold.dart';
import 'starter_model.dart';

/// "Run a model on this phone": a recommended small model that fits this
/// device (the Hub directory's recommended variant of a starter repo,
/// [starterModelProvider]) is downloaded and opened in the first chat; the
/// phone's own system model (Apple Intelligence, Gemini Nano) is offered
/// too when it is available. "Choose a model from Hugging Face" opens the
/// Hub browser on top of onboarding (the app's routes stay closed until
/// onboarding ends); a download started there is followed here the same
/// way, and the first chat opens on it.
class OnDeviceStep extends ConsumerStatefulWidget {
  const OnDeviceStep({super.key, required this.onStart, required this.onUseServer});

  /// Makes [ModelChoice] the default, opens the first chat on it and ends
  /// onboarding.
  final Future<void> Function(ModelChoice choice) onStart;

  /// Back to the remote / own-server choices.
  final VoidCallback onUseServer;

  @override
  ConsumerState<OnDeviceStep> createState() => _OnDeviceStepState();
}

class _OnDeviceStepState extends ConsumerState<OnDeviceStep> {
  String? _jobId;
  bool _enqueueing = false;
  bool _opening = false;
  bool _openScheduled = false;
  String? _error;

  Future<void> _download(StarterPick pick) async {
    if (_enqueueing || _jobId != null) return;
    setState(() {
      _enqueueing = true;
      _error = null;
    });
    try {
      final DownloadManager manager;
      try {
        manager = ref.read(downloadManagerProvider);
      } on Object catch (e) {
        // The download service could not be built. Say what failed, keep it
        // for diagnostics, and rebuild it on the next tap (provider retry
        // is off app-wide, so a failed provider would otherwise stay failed).
        _fail(e, 'download_manager');
        ref
          ..invalidate(networkMonitorProvider)
          ..invalidate(downloadManagerProvider);
        return;
      }
      final EnqueueOutcome o;
      try {
        o = await enqueueVariant(manager, pick.details, pick.row, pick.shape);
      } on Object catch (e) {
        _fail(e, 'enqueue');
        return;
      }
      if (!mounted) return;
      await _follow(o);
    } finally {
      if (mounted) setState(() => _enqueueing = false);
    }
  }

  void _fail(Object error, String code) {
    recordDownloadError(ref.read(appErrorRingProvider), error, source: 'onboarding', step: code);
    if (mounted) setState(() => _error = downloadStartMessage(error));
  }

  /// Shows the job's progress here, or opens the chat on an installed model.
  Future<void> _follow(EnqueueOutcome o) async {
    switch (o) {
      case Enqueued(:final jobId):
        setState(() {
          _jobId = jobId;
          _error = null;
        });
      case AlreadyPresent(:final libraryModelId?):
        await _openLibraryModel(libraryModelId);
      case AlreadyPresent(:final jobId):
        setState(() {
          _jobId = jobId;
          _error = null;
        });
      case EnqueueRefused(:final reasons):
        setState(() => _error = reasons.isEmpty ? refusedWithoutReason : reasons.first);
    }
  }

  /// The Hub browser and a repo's page, pushed over onboarding. A download
  /// started there comes back here.
  Future<void> _browse() async {
    final navigator = Navigator.of(context);
    final o = await navigator.push<EnqueueOutcome>(MotionPageRoute(
      builder: (browseContext) => ModelDirectoryScreen(
        onOpenModel: (id) => unawaited(_openModel(browseContext, id)),
      ),
    ));
    if (o == null || !mounted) return;
    await _follow(o);
  }

  Future<void> _openModel(BuildContext browseContext, String repoId) async {
    final picked = await Navigator.of(browseContext).push<EnqueueOutcome>(MotionPageRoute(
      builder: (detailContext) => ModelDetailScreen(
        repoId: repoId,
        onDownloadStarted: (o) => Navigator.of(detailContext).pop(o),
      ),
    ));
    if (picked != null && browseContext.mounted) Navigator.of(browseContext).pop(picked);
  }

  Future<void> _openLibraryModel(String id) async {
    if (_opening) return;
    final library = ref.read(modelLibraryProvider);
    await library.load();
    final m = library.byId(id);
    if (m == null || !mounted) return;
    await _open(localModelChoice(m));
  }

  Future<void> _open(ModelChoice choice) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      await widget.onStart(choice);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final starter = ref.watch(starterModelProvider);
    final system = ref.watch(systemModelOptionsProvider).value ?? const <SystemModelOption>[];
    final jobId = _jobId;
    DownloadJobView? job;
    if (jobId != null) {
      final jobs = ref.watch(downloadJobsProvider).value ?? const <DownloadJobView>[];
      job = jobs.where((j) => j.id == jobId).firstOrNull;
      final installed = job?.job.libraryModelId;
      if (installed != null && !_openScheduled) {
        // Once: every rebuild until the chat opens would schedule another.
        _openScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_openLibraryModel(installed));
        });
      }
    }
    final pick = starter.value;
    final busy = _enqueueing || _opening || job != null;

    return OnboardingStepLayout(
      title: 'Run a model on this phone',
      lead: 'Sherpa downloads a small open model that fits this phone. It works offline, and nothing you type '
          'leaves the device. You can also choose another model from Hugging Face, now or later in '
          'Models & downloads.',
      actions: [
        if (job != null)
          _JobProgress(job: job, onAllowCellular: () => unawaited(ref.read(downloadManagerProvider).allowCellular(job!.id)),
              onRetry: () => unawaited(ref.read(downloadManagerProvider).resume(job!.id)))
        else
          FilledButton.icon(
            onPressed: pick == null || busy ? null : () => unawaited(_download(pick)),
            icon: _enqueueing || _opening ? const ButtonSpinner() : const Icon(Icons.download_rounded),
            label: Text(pick == null ? 'Download and start' : 'Download ${formatBytes(pick.row.downloadBytes)} and start'),
          ),
        if (job == null) ...[
          SizedBox(height: t.space.xs),
          // The way forward when the starter can't be picked or downloaded.
          if (starter.hasError || _error != null)
            FilledButton.tonalIcon(
              onPressed: busy ? null : () => unawaited(_browse()),
              icon: const Icon(Icons.travel_explore_rounded),
              label: const Text('Choose a model from Hugging Face'),
            )
          else
            TextButton.icon(
              onPressed: busy ? null : () => unawaited(_browse()),
              icon: const Icon(Icons.travel_explore_rounded),
              label: const Text('Choose another model from Hugging Face'),
            ),
        ],
        SizedBox(height: t.space.xs),
        TextButton(onPressed: widget.onUseServer, child: const Text('Use a cloud model or my own server instead')),
      ],
      children: [
        Text('Recommended for this phone', style: theme.textTheme.titleSmall),
        SizedBox(height: t.space.sm),
        switch (starter) {
          AsyncData(:final value) => _StarterCard(pick: value),
          AsyncError(:final error) => _StarterProblem(
              message: error is StarterUnavailable ? error.reason : "Couldn't pick a model for this phone right now.",
              onRetry: () => ref.invalidate(starterModelProvider),
            ),
          _ => Row(
              children: [
                const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: t.space.md),
                const Expanded(child: Text('Finding a model that fits this phone…')),
              ],
            ),
        },
        if (_error != null) ...[
          SizedBox(height: t.space.md),
          Semantics(
            liveRegion: true,
            child: Text(_error!, style: theme.textTheme.bodyMedium?.copyWith(color: t.semantic.danger)),
          ),
        ],
        if (system.isNotEmpty) ...[
          SectionHeader('Built into this phone', padding: EdgeInsets.only(top: t.space.xl, bottom: t.space.sm)),
          for (final s in system)
            _SystemModelTile(option: s, busy: busy, onUse: () => unawaited(_open(s.choice))),
        ],
      ],
    );
  }
}

class _StarterCard extends StatelessWidget {
  const _StarterCard({required this.pick});

  final StarterPick pick;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final row = pick.row;
    final ctx = row.fit?.recommendedMaxContext;
    return Card(
      child: Padding(
        padding: EdgeInsets.all(t.space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: t.space.sm,
              runSpacing: t.space.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(pick.name, style: theme.textTheme.titleMedium),
                FitBadge(kind: row.kind, explanation: row.reason),
                const PrivacyBadge(location: ExecutionLocation.onDevice),
              ],
            ),
            SizedBox(height: t.space.xs),
            Text(
              [
                pick.details.id,
                row.label,
                formatBytes(row.downloadBytes),
                if (ctx != null) 'up to ${formatContext(ctx)} context',
              ].join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            SizedBox(height: t.space.xs),
            Text(row.reason, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _StarterProblem extends StatelessWidget {
  const _StarterProblem({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message, style: theme.textTheme.bodyMedium),
          TextButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh_rounded), label: const Text('Try again')),
        ],
      ),
    );
  }
}

class _JobProgress extends StatelessWidget {
  const _JobProgress({required this.job, required this.onAllowCellular, required this.onRetry});

  final DownloadJobView job;
  final VoidCallback onAllowCellular;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final p = job.phase;
    final notice = job.job.notice;
    final text = switch (p) {
      JobPhase.waitingForWifi => 'Waiting for Wi-Fi to download ${formatBytes(job.totalBytes)}.',
      JobPhase.waitingForNetwork => 'Waiting for a connection…',
      JobPhase.verifying => 'Checking the download…',
      JobPhase.installing || JobPhase.done => 'Opening your first chat…',
      JobPhase.failed => job.error ?? "The download didn't finish.",
      JobPhase.paused => 'Paused.',
      _ => 'Downloading: ${formatBytesOf(job.bytesDone, job.totalBytes)}',
    };
    return LiveAnnouncement(
      message: downloadAnnouncement('The model', p, progress: job.progress),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(
            value: p == JobPhase.downloading || p == JobPhase.resolving ? job.progress : null,
            semanticsLabel: 'Downloading the model',
          ),
          SizedBox(height: t.space.xs),
          Text(text, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
          // What the manager wants the user to know without failing the job
          // (Android hasn't started a Wi-Fi-only download, a file restarted),
          // as Downloads shows it.
          if (notice != null) ...[
            SizedBox(height: t.space.xs),
            Text(
              notice,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
          if (p == JobPhase.waitingForWifi)
            TextButton(onPressed: onAllowCellular, child: const Text('Use mobile data for this download')),
          if (p.canResume) TextButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    );
  }
}

class _SystemModelTile extends ConsumerWidget {
  const _SystemModelTile({required this.option, required this.busy, required this.onUse});

  final SystemModelOption option;
  final bool busy;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final o = option;
    final nano = o.providerId == geminiNanoProviderId;
    final download = nano ? ref.watch(nanoDownloadProvider) : const NanoDownloadState();
    final canDownload = nano && o.availability.state == EngineAvailabilityState.downloadable;
    return Card(
      child: Padding(
        padding: EdgeInsets.all(t.space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: t.space.sm,
              runSpacing: t.space.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(o.name, style: theme.textTheme.titleMedium),
                if (o.foregroundOnly)
                  const InfoPill(
                    label: 'On screen only',
                    icon: Icons.visibility_outlined,
                    tone: PillTone.warning,
                    explanation: kForegroundOnlyExplanation,
                  ),
              ],
            ),
            SizedBox(height: t.space.xs),
            Text(o.availability.reason, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            if (o.foregroundOnly) ...[
              SizedBox(height: t.space.xs),
              Text(kForegroundOnlyExplanation, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
            if (download.running) ...[
              SizedBox(height: t.space.sm),
              LiveAnnouncement(
                message: 'Gemini Nano: downloading, ${progressMilestone(download.fraction)}%',
                child: LinearProgressIndicator(value: download.fraction, semanticsLabel: 'Downloading Gemini Nano'),
              ),
            ],
            SizedBox(height: t.space.sm),
            if (o.selectable)
              FilledButton.tonal(onPressed: busy ? null : onUse, child: Text('Use ${o.name}'))
            else if (canDownload)
              FilledButton.tonal(
                onPressed: download.running ? null : () => unawaited(ref.read(nanoDownloadProvider.notifier).start()),
                child: Text(download.running ? 'Downloading…' : 'Download Gemini Nano'),
              ),
          ],
        ),
      ),
    );
  }
}
