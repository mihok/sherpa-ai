import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../design/motion.dart';
import '../../design/tokens.dart';
import '../../design/typography.dart';
import '../../design/widgets/a11y.dart';
import '../../design/widgets/section_header.dart';
import '../../design/widgets/state_views.dart';
import '../../routing/routes.dart';
import '../../services/downloads/downloads.dart';
import '../../state/ui_preferences.dart';
import 'state/models_providers.dart';
import 'widgets/download_announcement.dart';
import 'widgets/format.dart';
import 'widgets/pills.dart';

/// The download queue: what is moving, what waits (and for what), what
/// failed (and how to fix it), and what is verified and ready.
class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final jobs = ref.watch(downloadJobsProvider);
    final wifiOnly = ref.watch(wifiOnlyProvider);
    final manager = ref.read(downloadManagerProvider);
    final list = jobs.value ?? const <DownloadJobView>[];
    final active = [for (final j in list) if (j.phase.isActive || j.phase.isWaiting) j];
    final paused = [for (final j in list) if (j.phase == JobPhase.paused) j];
    final failed = [for (final j in list) if (j.phase == JobPhase.failed) j];
    final done = [for (final j in list) if (j.phase == JobPhase.done) j];

    return Scaffold(
      appBar: AppBar(
        title: Heading(level: 1, child: const Text('Downloads')),
        actions: [
          if (done.isNotEmpty)
            TextButton(onPressed: () => unawaited(manager.clearFinished()), child: const Text('Clear finished')),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: t.layout.maxContentWidth),
          child: ListView(
            padding: EdgeInsets.only(bottom: t.space.xxxl),
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.wifi_rounded),
                title: const Text('Download over Wi-Fi only'),
                subtitle: const Text('Models are several GB; on mobile data downloads wait until you are back on Wi-Fi.'),
                value: wifiOnly,
                onChanged: (v) {
                  ref.read(hapticsProvider).selection();
                  unawaited(manager.setWifiOnly(v));
                },
              ),
              if (jobs.isLoading && list.isEmpty)
                const Padding(padding: EdgeInsets.only(top: 64), child: LoadingState(label: 'Loading downloads…'))
              else if (list.isEmpty)
                Padding(
                  padding: EdgeInsets.only(top: t.space.xxl),
                  child: EmptyState(
                    icon: Icons.download_for_offline_outlined,
                    title: 'No downloads',
                    message: 'Models you download appear here. They keep going while you use other apps.',
                    primaryAction: FilledButton.tonal(
                      onPressed: () => context.go(Routes.modelBrowse),
                      child: const Text('Browse models'),
                    ),
                  ),
                )
              else ...[
                if (active.isNotEmpty) ...[
                  SectionHeader('In progress', count: _downloads(active.length)),
                  for (final j in active) DownloadTile(view: j),
                ],
                if (paused.isNotEmpty) ...[
                  SectionHeader('Paused', count: _downloads(paused.length)),
                  for (final j in paused) DownloadTile(view: j),
                ],
                if (failed.isNotEmpty) ...[
                  SectionHeader('Needs attention', count: _downloads(failed.length)),
                  for (final j in failed) DownloadTile(view: j),
                ],
                if (done.isNotEmpty) ...[
                  SectionHeader('Verified', count: _downloads(done.length)),
                  for (final j in done) DownloadTile(view: j),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _downloads(int n) => n == 1 ? '1 download' : '$n downloads';

/// One job: name, status in words, progress, numbers with their meaning,
/// and the one or two actions that make sense right now.
class DownloadTile extends ConsumerWidget {
  const DownloadTile({super.key, required this.view});

  final DownloadJobView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final manager = ref.read(downloadManagerProvider);
    final haptics = ref.read(hapticsProvider);
    final v = view;
    final job = v.job;
    final muted = scheme.onSurfaceVariant;
    final status = _status(v);
    final verifying = v.phase == JobPhase.verifying;
    final indeterminate = v.phase == JobPhase.resolving || v.phase == JobPhase.installing || (verifying && v.verifyProgress == null);
    final progressValue = verifying ? v.verifyProgress : v.progress;

    Widget? primary;
    switch (v.phase) {
      case JobPhase.queued || JobPhase.waitingForWifi || JobPhase.waitingForNetwork || JobPhase.resolving || JobPhase.downloading:
        primary = IconButton(
          tooltip: 'Pause',
          icon: const Icon(Icons.pause_rounded),
          onPressed: () {
            haptics.selection();
            unawaited(manager.pause(job.id));
          },
        );
      case JobPhase.paused || JobPhase.failed:
        primary = IconButton(
          tooltip: v.phase == JobPhase.failed ? 'Retry' : 'Resume',
          icon: Icon(v.phase == JobPhase.failed ? Icons.refresh_rounded : Icons.play_arrow_rounded),
          onPressed: () async {
            haptics.selection();
            final problem = await manager.resume(job.id);
            if (problem != null && context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem)));
            }
          },
        );
      case JobPhase.verifying || JobPhase.installing || JobPhase.done:
        primary = null;
    }
    final cancel = v.phase == JobPhase.done
        ? null
        : IconButton(
            tooltip: 'Cancel download',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => unawaited(_confirmCancel(context, ref)),
          );

    final numbers = <Widget>[
      Metric(
        icon: Icons.data_usage_rounded,
        value: v.phase == JobPhase.done ? formatBytes(v.totalBytes) : formatBytesOf(v.bytesDone, v.totalBytes),
        explanation: job.files.length > 1
            ? 'Downloaded so far, of the total for all ${job.files.length} files (model, projector, parts)'
            : 'Downloaded so far, of the total download size',
      ),
      if (v.bytesPerSecond != null)
        Metric(icon: Icons.speed_rounded, value: formatSpeed(v.bytesPerSecond!), explanation: 'Average speed over the last few seconds'),
      if (v.eta != null) Metric(icon: Icons.schedule_rounded, value: formatEta(v.eta!), explanation: 'At the current speed'),
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
                        Row(children: [
                          Flexible(
                            child: Text(job.meta.displayName,
                                style: theme.textTheme.titleSmall,
                                maxLines: scaledMaxLines(context),
                                overflow: TextOverflow.ellipsis),
                          ),
                          SizedBox(width: t.space.sm),
                          InfoPill(label: job.label, dense: true, semanticPrefix: 'Variant', explanation: 'The quantization being downloaded'),
                        ]),
                        SizedBox(height: t.space.xxs),
                        Text(job.repo,
                            style: theme.textTheme.bodySmall?.copyWith(color: muted),
                            maxLines: scaledMaxLines(context),
                            overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  ?primary,
                  ?cancel,
                ],
              ),
              SizedBox(height: t.space.sm),
              Padding(
                padding: EdgeInsetsDirectional.only(end: t.space.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Announced at phase changes and 25 % steps only; the
                    // byte counts below are read on focus.
                    LiveAnnouncement(
                      message: downloadAnnouncement(job.meta.displayName, v.phase, progress: v.progress),
                      child: Row(children: [
                        Icon(status.$2, size: 16, color: v.phase == JobPhase.failed ? t.semantic.danger : muted),
                        SizedBox(width: t.space.xs),
                        Expanded(child: Text(status.$1, style: theme.textTheme.bodyMedium)),
                      ]),
                    ),
                    if (v.phase != JobPhase.done) ...[
                      SizedBox(height: t.space.sm),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(t.radius.pill),
                        child: LinearProgressIndicator(
                          value: indeterminate ? null : progressValue,
                          minHeight: 6,
                          semanticsLabel: verifying ? 'Verification progress' : 'Download progress',
                        ),
                      ),
                    ],
                    SizedBox(height: t.space.sm),
                    Wrap(spacing: t.space.md, runSpacing: t.space.xs, children: numbers),
                    if (v.error != null && v.phase == JobPhase.failed) ...[
                      SizedBox(height: t.space.sm),
                      Text(v.error!, style: theme.textTheme.bodySmall?.copyWith(color: t.semantic.danger)),
                    ],
                    if (job.notice != null) ...[
                      SizedBox(height: t.space.xs),
                      Text(job.notice!, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                    ],
                    if (v.phase == JobPhase.waitingForWifi)
                      Padding(
                        padding: EdgeInsets.only(top: t.space.xs),
                        child: TextButton.icon(
                          onPressed: () => unawaited(manager.allowCellular(job.id)),
                          icon: const Icon(Icons.signal_cellular_alt_rounded),
                          label: Text('Use mobile data for this one (${formatBytes(v.totalBytes - v.bytesDone)})'),
                        ),
                      ),
                    if (v.phase == JobPhase.done)
                      Padding(
                        padding: EdgeInsets.only(top: t.space.xs),
                        child: TextButton.icon(
                          onPressed: () => context.go(Routes.models),
                          icon: const Icon(Icons.folder_open_rounded),
                          label: const Text('Open library'),
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

  (String, IconData) _status(DownloadJobView v) {
    final file = v.job.files.length > 1 && v.currentFile != null ? ' ${v.currentFile!.split('/').last}' : '';
    return switch (v.phase) {
      JobPhase.queued => ('Queued: starts after the current download', Icons.schedule_rounded),
      JobPhase.waitingForWifi => ('Waiting for Wi-Fi', Icons.wifi_off_rounded),
      JobPhase.waitingForNetwork => ('Waiting for a connection', Icons.cloud_off_rounded),
      JobPhase.resolving => ('Connecting to Hugging Face…', Icons.sync_rounded),
      JobPhase.downloading => ('Downloading$file', Icons.downloading_rounded),
      JobPhase.verifying => (
          'Checking the file is intact (SHA-256)$file${v.verifyProgress == null ? '' : ' (${(v.verifyProgress! * 100).round()}%)'}',
          Icons.verified_outlined,
        ),
      JobPhase.installing => ('Adding to your library…', Icons.inventory_2_outlined),
      JobPhase.paused => ('Paused. Progress is kept', Icons.pause_circle_outline_rounded),
      JobPhase.failed => ('Download stopped', Icons.error_outline_rounded),
      JobPhase.done => ('Verified and ready to use', Icons.check_circle_rounded),
    };
  }

  Future<void> _confirmCancel(BuildContext context, WidgetRef ref) async {
    final have = view.bytesDone;
    final ok = await showDialog<bool>(
      context: context,
      animationStyle: motionStyleOf(context),
      builder: (context) => AlertDialog(
        title: const Heading(child: Text('Cancel this download?')),
        content: Text(have > 0
            ? 'The ${formatBytes(have)} downloaded so far will be deleted.'
            : 'It will be removed from the queue.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep downloading')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: SherpaTokens.of(context).semantic.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancel download'),
          ),
        ],
      ),
    );
    if (ok ?? false) {
      ref.read(hapticsProvider).warning();
      await ref.read(downloadManagerProvider).cancel(view.id);
    }
  }
}
