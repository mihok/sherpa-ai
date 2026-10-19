import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart' show ExecutionLocation;

import '../../design/tokens.dart';
import '../../design/widgets/privacy_badge.dart';
import '../../design/widgets/section_header.dart';
import '../../services/downloads/downloads.dart';
import '../../services/inference/on_device_ids.dart';
import '../../services/inference/platform_models.dart' show EngineAvailabilityState;
import '../../state/services.dart';
import '../models/state/local_model_choice.dart';
import '../models/state/local_model_fit.dart';
import '../models/state/models_providers.dart';
import '../models/state/platform_models_providers.dart';
import '../models/state/variant_download.dart';
import '../models/widgets/format.dart';
import '../models/widgets/pills.dart';
import 'onboarding_scaffold.dart';
import 'starter_model.dart';

/// "Run a model on this phone": a recommended small model that fits this
/// device (the Hub directory's recommended variant of a starter repo,
/// [starterModelProvider]) is downloaded and opened in the first chat; the
/// phone's own system model (Apple Intelligence, Gemini Nano) is offered
/// too when it is available.
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
      final o = await enqueueVariant(ref.read(downloadManagerProvider), pick.details, pick.row, pick.shape);
      if (!mounted) return;
      switch (o) {
        case Enqueued(:final jobId):
          setState(() => _jobId = jobId);
        case AlreadyPresent(:final libraryModelId?):
          await _openLibraryModel(libraryModelId);
        case AlreadyPresent(:final jobId):
          setState(() => _jobId = jobId);
        case EnqueueRefused(:final reasons):
          setState(() => _error = reasons.isEmpty ? "The download couldn't start." : reasons.first);
      }
    } on Object {
      if (mounted) setState(() => _error = "The download couldn't start. Try again.");
    } finally {
      if (mounted) setState(() => _enqueueing = false);
    }
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
          'leaves the device. Bigger models are a tap away later, in Models & downloads.',
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
    final text = switch (p) {
      JobPhase.waitingForWifi => 'Waiting for Wi-Fi to download ${formatBytes(job.totalBytes)}.',
      JobPhase.waitingForNetwork => 'Waiting for a connection…',
      JobPhase.verifying => 'Checking the download…',
      JobPhase.installing || JobPhase.done => 'Opening your first chat…',
      JobPhase.failed => job.error ?? "The download didn't finish.",
      JobPhase.paused => 'Paused.',
      _ => 'Downloading: ${formatBytesOf(job.bytesDone, job.totalBytes)}',
    };
    return Semantics(
      liveRegion: true,
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(
            value: p == JobPhase.downloading || p == JobPhase.resolving ? job.progress : null,
            semanticsLabel: 'Downloading the model',
          ),
          SizedBox(height: t.space.xs),
          Text(text, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
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
              LinearProgressIndicator(value: download.fraction, semanticsLabel: 'Downloading Gemini Nano'),
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
