import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart' show ExecutionLocation;
import 'package:sherpa_hub/sherpa_hub.dart';

import '../../design/motion.dart';
import '../../design/tokens.dart';
import '../../design/typography.dart';
import '../../design/widgets/a11y.dart';
import '../../design/widgets/privacy_badge.dart';
import '../../design/widgets/section_header.dart';
import '../../design/widgets/skeleton.dart';
import '../../design/widgets/state_views.dart';
import '../../routing/routes.dart';
import '../../services/device/device_profile_source.dart';
import '../../services/downloads/downloads.dart';
import '../../state/ui_preferences.dart';
import '../diagnostics/app_error_ring.dart';
import 'state/directory_controller.dart' show DirectoryError, DirectoryOffline, DirectoryRateLimited, failureOf;
import 'state/download_errors.dart';
import 'state/model_fit.dart';
import 'state/models_providers.dart';
import 'state/variant_download.dart';
import 'widgets/fit_explain.dart';
import 'widgets/format.dart';
import 'widgets/pills.dart';

/// One Hub repo, pinned to the commit its details came from.
///
/// Shows what the name means (every chip explains itself), whether the
/// author gates it, what the Hub's scanners say, and every variant with its
/// real download size, bits per weight and a Fits / Tight / Won't fit
/// verdict from one GGUF header peek + this device's memory. Download is
/// never offered for Won't fit or unsafe files; Tight asks first.
class ModelDetailScreen extends ConsumerStatefulWidget {
  const ModelDetailScreen({super.key, required this.repoId, this.onDownloadStarted});

  final String repoId;

  /// Set when the page is opened from onboarding (outside the app's
  /// routes): called with the outcome once a download is queued, or with
  /// [AlreadyPresent] for a variant that is downloading or installed, so
  /// onboarding can follow it and open the first chat on it. Without it,
  /// the page links to Downloads and the library as usual.
  final ValueChanged<EnqueueOutcome>? onDownloadStarted;

  @override
  ConsumerState<ModelDetailScreen> createState() => _ModelDetailScreenState();
}

class _ModelDetailScreenState extends ConsumerState<ModelDetailScreen> {
  String? _selected;
  bool _starting = false;

  // Memo: assessing ~25 variants (each with a max-context search) on every
  // rebuild would be wasteful; inputs change rarely.
  Object? _memoKey;
  ModelAssessment? _memo;

  ModelAssessment _assess(CatalogModelDetails d, DeviceProfile device, ModelShape? shape) {
    final key = (d, device.toJson().toString(), shape);
    if (_memoKey == key && _memo != null) return _memo!;
    _memoKey = key;
    return _memo = assessVariants(d, device, shape: shape);
  }

  @override
  Widget build(BuildContext context) {
    final details = ref.watch(modelDetailsProvider(widget.repoId));
    final title = parseModelName(widget.repoId).displayName;
    return Scaffold(
      appBar: AppBar(title: Heading(level: 1, child: Text(title))),
      body: switch (details) {
        AsyncData(:final value) => _body(context, value),
        AsyncError(:final error) => _DetailFailure(
            error: error,
            onRetry: () => ref.invalidate(modelDetailsProvider(widget.repoId)),
            onBrowse: widget.onDownloadStarted == null ? null : () => Navigator.of(context).maybePop(),
          ),
        _ => const _DetailSkeleton(),
      },
    );
  }

  Widget _body(BuildContext context, CatalogModelDetails d) {
    final t = SherpaTokens.of(context);
    final device = ref.watch(deviceProfileProvider).value;
    final target = peekTarget(d);
    final shapeAsync = target == null ? null : ref.watch(modelShapeProvider((d.id, d.commit, target.path)));
    final shape = shapeAsync?.value;
    final assessment = device == null ? null : _assess(d, device, shape);
    final rows = assessment?.rows ?? const <VariantRow>[];
    final selected = rows.where((r) => r.variant.id == _selected).firstOrNull ??
        assessment?.recommended ??
        rows.where((r) => r.canDownload).firstOrNull ??
        rows.firstOrNull;

    return Column(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: t.layout.maxContentWidth),
              child: ListView(
                padding: EdgeInsets.only(bottom: t.space.xl),
                children: [
                  _Header(details: d),
                  if (d.gating.isGated) _GatedCard(details: d),
                  _FitSummary(
                    assessment: assessment,
                    device: device,
                    shapeLoading: shapeAsync?.isLoading ?? false,
                    shapeError: shapeAsync?.error,
                    noPeek: target == null,
                    onRetry: target == null ? null : () => ref.invalidate(modelShapeProvider((d.id, d.commit, target.path))),
                  ),
                  SectionHeader('Files', trailing: Text('${rows.length} variant${rows.length == 1 ? '' : 's'}')),
                  Padding(
                    padding: EdgeInsets.fromLTRB(t.space.lg, 0, t.space.lg, t.space.sm),
                    child: Text(
                      'Grouped by quantization: fewer bits are smaller and faster, more bits are closer to the '
                      'original. Sizes are the real download sizes.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ),
                  if (assessment == null)
                    const _RowsSkeleton()
                  else
                    for (final r in rows)
                      _VariantTile(
                        row: r,
                        selected: identical(r, selected),
                        trained: shape?.architecture.trainContextLength,
                        shapeLoading: shapeAsync?.isLoading ?? false,
                        onTap: r.kind == FitBadgeKind.blocked ? null : () => setState(() => _selected = r.variant.id),
                      ),
                  if (assessment != null && assessment.otherFiles.isNotEmpty) _OtherFiles(files: assessment.otherFiles),
                ],
              ),
            ),
          ),
        ),
        if (selected != null)
          _DownloadBar(
            details: d,
            row: selected,
            shape: shape,
            starting: _starting,
            onDownload: () => _download(d, selected, shape),
            onFollow: widget.onDownloadStarted,
          ),
      ],
    );
  }

  Future<void> _download(CatalogModelDetails d, VariantRow row, ModelShape? shape) async {
    if (!row.canDownload || _starting) return;
    final haptics = ref.read(hapticsProvider);
    if (row.needsConfirm) {
      haptics.warning();
      if (!await confirmRiskyDownload(context, row)) return;
    }
    final plan = planDownload(
      repo: d.id,
      commit: d.commit,
      files: [for (final f in d.files) f.file],
      quant: row.variant.id,
      repoSecurity: d.security,
    );
    if (!mounted) return;
    if (plan is PlanRefused) {
      await _showRefusal(plan.reasons);
      return;
    }
    setState(() => _starting = true);
    try {
      final DownloadManager manager;
      try {
        manager = ref.read(downloadManagerProvider);
      } on Object catch (e) {
        // The manager could not be built (recorded by the provider
        // observer); rebuild it on the next try.
        recordDownloadError(ref.read(appErrorRingProvider), e, source: 'models', step: 'download_manager');
        ref
          ..invalidate(networkMonitorProvider)
          ..invalidate(downloadManagerProvider);
        haptics.error();
        await _showRefusal([downloadStartMessage(e)]);
        return;
      }
      final EnqueueOutcome o;
      try {
        o = await manager.enqueue(plan as DownloadPlan, meta: downloadMetaFor(d, row, shape));
      } on Object catch (e) {
        recordDownloadError(ref.read(appErrorRingProvider), e, source: 'models', step: 'enqueue');
        if (!mounted) return;
        haptics.error();
        await _showRefusal([downloadStartMessage(e)]);
        return;
      }
      if (!mounted) return;
      final follow = widget.onDownloadStarted;
      if (follow != null && o is! EnqueueRefused) {
        haptics.light();
        follow(o);
        return;
      }
      switch (o) {
        case Enqueued(:final warnings):
          haptics.light();
          final waitingForWifi = manager.job(o.jobId)?.phase == JobPhase.waitingForWifi;
          _snack(
            waitingForWifi
                ? 'Queued. It starts on Wi-Fi; you can allow mobile data in Downloads.'
                : warnings.isEmpty
                    ? 'Downloading ${row.label}'
                    : 'Downloading ${row.label}. ${warnings.first}',
            action: SnackBarAction(label: 'View', onPressed: () => context.go(Routes.downloads)),
          );
        case EnqueueRefused(:final reasons):
          haptics.error();
          await _showRefusal(reasons.isEmpty ? const [refusedWithoutReason] : reasons);
        case AlreadyPresent(:final libraryModelId):
          context.go(libraryModelId != null ? Routes.models : Routes.downloads);
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _snack(String message, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  Future<void> _showRefusal(List<String> reasons) => showDialog<void>(
        context: context,
        animationStyle: motionStyleOf(context),
        builder: (context) => AlertDialog(
          title: const Heading(child: Text("Can't download this")),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final r in reasons) Text('• $r')],
          ),
          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
        ),
      );
}

class _Header extends StatelessWidget {
  const _Header({required this.details});

  final CatalogModelDetails details;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final d = details;
    final info = d.info;
    final license = d.cardData?.licenseName ?? d.license;
    return Padding(
      padding: EdgeInsets.fromLTRB(t.space.lg, t.space.sm, t.space.lg, t.space.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(d.id, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          SizedBox(height: t.space.sm),
          Wrap(
            spacing: t.space.lg,
            runSpacing: t.space.xs,
            children: [
              Metric(icon: Icons.person_outline_rounded, value: d.name.owner, explanation: 'Who uploaded this repository'),
              if (info?.downloads != null)
                Metric(icon: Icons.download_rounded, value: formatCount(info!.downloads!), explanation: 'Downloads in the last 30 days'),
              if (info?.likes != null)
                Metric(icon: Icons.favorite_border_rounded, value: formatCount(info!.likes!), explanation: 'Likes on Hugging Face'),
              Metric(
                icon: Icons.commit_rounded,
                value: d.commit.substring(0, 7),
                explanation: 'Downloads are pinned to this commit, so every file comes from the same version '
                    'even if the author updates the repository meanwhile.',
              ),
            ],
          ),
          SizedBox(height: t.space.md),
          Wrap(
            spacing: t.space.xs,
            runSpacing: t.space.xs,
            children: [
              const PrivacyBadge(location: ExecutionLocation.onDevice),
              if (license != null)
                InfoPill(
                  label: license,
                  icon: Icons.gavel_rounded,
                  semanticPrefix: 'License',
                  explanation: d.cardData?.licenseLink != null
                      ? 'License declared by the author. Full text: ${d.cardData!.licenseLink}'
                      : 'License declared by the author on Hugging Face. Some (Llama, Gemma) restrict how you may use the model.',
                ),
              if (d.gating.isGated)
                InfoPill(
                  label: d.gating == HubGating.manual ? 'Gated · manual approval' : 'Gated',
                  icon: Icons.lock_outline_rounded,
                  tone: PillTone.warning,
                  explanation: 'The author requires accepting their terms on huggingface.co before downloading.',
                ),
              _ScanPill(security: d.security),
              if (d.toolUseHint)
                const InfoPill(
                  label: 'Tool use',
                  icon: Icons.build_outlined,
                  explanation: 'The chat template mentions tools, so the model can likely call functions. '
                      "Sherpa re-checks the downloaded file's own template.",
                ),
              if (d.reasoningHint)
                const InfoPill(
                  label: 'Reasoning',
                  icon: Icons.psychology_alt_outlined,
                  explanation: 'The chat template supports a thinking phase before the answer.',
                ),
            ],
          ),
          SizedBox(height: t.space.md),
          ModelNameChips(name: d.name),
        ],
      ),
    );
  }
}

class _ScanPill extends StatelessWidget {
  const _ScanPill({required this.security});

  final HubRepoSecurity? security;

  @override
  Widget build(BuildContext context) {
    const about = 'Hugging Face scans uploads for malware and unsafe pickle code (ClamAV, Protect AI, JFrog and '
        'others). Sherpa also never downloads pickle files, whatever the scan says.';
    final s = security;
    if (s == null) return const InfoPill(label: 'Scan status unknown', icon: Icons.shield_outlined, explanation: about);
    if (s.filesWithIssues.isNotEmpty) {
      final list = s.filesWithIssues.entries.map((e) => '${e.key}: ${e.value.name}').join('\n');
      return InfoPill(
        label: '${s.filesWithIssues.length} file${s.filesWithIssues.length == 1 ? '' : 's'} flagged',
        icon: Icons.gpp_maybe_outlined,
        tone: PillTone.danger,
        explanation: '$about\n\nFlagged:\n$list',
      );
    }
    if (!s.scansDone) return const InfoPill(label: 'Scan pending', icon: Icons.shield_outlined, explanation: about);
    return const InfoPill(label: 'Scanned: no issues', icon: Icons.verified_user_outlined, tone: PillTone.success, explanation: about);
  }
}

/// Gated repos: what to do, in order, without leaving the user guessing.
class _GatedCard extends ConsumerWidget {
  const _GatedCard({required this.details});

  final CatalogModelDetails details;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final profile = ref.watch(hubProfileProvider).value;
    final url = 'https://huggingface.co/${details.id}';
    final manual = details.gating == HubGating.manual;
    return Padding(
      padding: EdgeInsets.fromLTRB(t.space.lg, t.space.sm, t.space.lg, t.space.sm),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(t.radius.lg),
        ),
        child: Padding(
          padding: EdgeInsets.all(t.space.lg),
          child: HeadingGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.lock_outline_rounded, color: theme.colorScheme.onTertiaryContainer),
                  SizedBox(width: t.space.sm),
                  Expanded(
                    child: Heading(
                      level: 2,
                      child: Text('Accept the terms on huggingface.co',
                          style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onTertiaryContainer)),
                    ),
                  ),
                ]),
                SizedBox(height: t.space.sm),
                Text(
                  '1. Open the link below in your browser and sign in.\n'
                  '2. Accept the author\'s license form.${manual ? ' This author approves requests by hand, which can take days.' : ' Access is granted at once.'}\n'
                  '3. ${profile == null ? 'Add a Hugging Face token here so Sherpa can download for you.' : 'Come back and download. Sherpa uses your token (${profile.name}).'}',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onTertiaryContainer),
                ),
                SizedBox(height: t.space.sm),
                // Plain text: "Copy link" below copies it (a selectable field
                // would be one more, 16 dp tall, tap target).
                Text(url, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onTertiaryContainer)),
                SizedBox(height: t.space.sm),
                Wrap(
                  spacing: t.space.sm,
                  runSpacing: t.space.sm,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: url));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
                        }
                      },
                      icon: const Icon(Icons.link_rounded),
                      label: const Text('Copy link'),
                    ),
                    if (profile == null)
                      FilledButton.tonalIcon(
                        onPressed: () => context.go(Routes.huggingFace),
                        icon: const Icon(Icons.key_outlined),
                        label: const Text('Add token'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FitSummary extends StatelessWidget {
  const _FitSummary({
    required this.assessment,
    required this.device,
    required this.shapeLoading,
    required this.shapeError,
    required this.noPeek,
    required this.onRetry,
  });

  final ModelAssessment? assessment;
  final DeviceProfile? device;
  final bool shapeLoading;
  final Object? shapeError;
  final bool noPeek;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final d = device;
    final ram = d == null ? null : formatBytes(d.totalRamBytes);
    final String text;
    if (shapeLoading) {
      text = "Reading the model's shape (a few MB) to check what fits…";
    } else if (shapeError != null) {
      text = shapeError is HubGatedRepoException
          ? "Fit can't be checked until you have access: the header is behind the gate."
          : "Couldn't read the model's header to check fit. Sizes below are still real.";
    } else if (noPeek && (assessment?.rows.every((r) => r.fit == null) ?? true)) {
      text = 'Fit is checked for GGUF, MLX and LiteRT files only; sizes below are real.';
    } else {
      text = assessment?.summary ?? 'Checking this device…';
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(t.space.lg, t.space.sm, t.space.lg, 0),
      child: DecoratedBox(
        decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerLow, borderRadius: BorderRadius.circular(t.radius.lg)),
        child: Padding(
          padding: EdgeInsets.all(t.space.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.memory_rounded, color: theme.colorScheme.primary),
              SizedBox(width: t.space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Tooltip(
                      message: d?.availableRamBytes == null
                          ? 'Memory available to apps is estimated from total RAM until Sherpa can measure it.'
                          : 'Measured memory available to Sherpa right now.',
                      child: Text(
                        ram == null ? 'This device' : 'This device: $ram RAM',
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    SizedBox(height: t.space.xxs),
                    Semantics(
                      liveRegion: true,
                      child: Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    ),
                    if (shapeError != null && onRetry != null)
                      Padding(
                        padding: EdgeInsets.only(top: t.space.xs),
                        child: TextButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Try again')),
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

class _VariantTile extends StatelessWidget {
  const _VariantTile({
    required this.row,
    required this.selected,
    required this.onTap,
    required this.trained,
    required this.shapeLoading,
  });

  final VariantRow row;
  final bool selected;
  final VoidCallback? onTap;
  final int? trained;
  final bool shapeLoading;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final blocked = row.kind == FitBadgeKind.blocked;
    final fit = row.fit;
    final bpw = row.bitsPerWeight;
    final mm = row.mmproj;
    final muted = scheme.onSurfaceVariant;
    final quant = row.variant.quant;
    final ctx = fit?.recommendedMaxContext;

    final content = Padding(
      padding: EdgeInsets.all(t.space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (!blocked)
                Padding(
                  padding: EdgeInsetsDirectional.only(end: t.space.sm),
                  child: Icon(
                    selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                    size: 20,
                    color: selected ? scheme.primary : muted,
                  ),
                ),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Tooltip(
                        message: quant?.explanation ?? row.variant.format.explanation,
                        triggerMode: TooltipTriggerMode.longPress,
                        child: Text(row.label, style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    if (row.recommended) ...[
                      SizedBox(width: t.space.sm),
                      const InfoPill(
                        label: 'Recommended',
                        icon: Icons.star_rounded,
                        tone: PillTone.accent,
                        explanation: 'The highest-quality variant that fits this device with headroom.',
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(width: t.space.sm),
              Tooltip(
                message: mm == null
                    ? 'Download size (all parts)'
                    : 'Download size including the vision projector (${formatBytes(mm.size ?? mm.lfsSize ?? 0)})',
                child: Text(formatBytes(row.downloadBytes), style: theme.textTheme.metric),
              ),
            ],
          ),
          SizedBox(height: t.space.sm),
          Wrap(
            spacing: t.space.sm,
            runSpacing: t.space.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (shapeLoading && !blocked)
                const Skeleton(width: 64, height: 20, radius: 999)
              else
                FitBadge(
                  kind: row.kind,
                  explanation: fit == null ? row.reason : '${row.reason}\n\n${fitBreakdown(fit, runtime: row.variant.runtime)}',
                ),
              if (bpw != null)
                Metric(
                  icon: Icons.grain_rounded,
                  value: formatBpwShort(bpw),
                  explanation: row.bpwMeasured
                      ? 'Measured: file bytes × 8 ÷ parameters. Embeddings and output layers count too, so small models '
                          'spend more than the label suggests.'
                      : 'Nominal for this quant type; the real figure depends on the model.',
                ),
              if (ctx != null && fit != null)
                Metric(
                  icon: Icons.notes_rounded,
                  value: 'Up to ${formatContext(ctx)} context',
                  explanation: contextExplanation(fit, trained: trained),
                ),
              if (row.variant.weights.length > 1)
                Metric(
                  icon: Icons.layers_outlined,
                  value: '${row.variant.weights.length} parts',
                  explanation: row.variant.isByteSplit
                      ? 'Byte-split parts: Sherpa joins them in order after verifying each one.'
                      : 'Split GGUF: all parts are downloaded into one folder and loaded together.',
                ),
            ],
          ),
          if (!blocked && fit != null && row.kind != FitBadgeKind.fits) ...[
            SizedBox(height: t.space.xs),
            Text(row.reason, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
          ],
          if (blocked) ...[
            SizedBox(height: t.space.xs),
            for (final r in row.blockedReasons)
              Text(r, style: theme.textTheme.bodySmall?.copyWith(color: SherpaTokens.of(context).semantic.danger)),
          ],
          if (row.runtimeCacheBytes > 0 && !blocked) ...[
            SizedBox(height: t.space.xs),
            Tooltip(
              message: 'On its first load LiteRT-LM writes packed weights for the CPU into Sherpa\'s cache, about '
                  'the size of the model, so later loads are faster. The storage check counts it.',
              child: Row(children: [
                Icon(Icons.sd_storage_outlined, size: 14, color: muted),
                SizedBox(width: t.space.xs),
                Flexible(
                  child: Text('+ about ${formatBytes(row.runtimeCacheBytes)} weight cache on first load',
                      style: theme.textTheme.bodySmall?.copyWith(color: muted), overflow: TextOverflow.ellipsis),
                ),
              ]),
            ),
          ],
          if (mm != null && !blocked) ...[
            SizedBox(height: t.space.xs),
            Tooltip(
              message: 'Vision projector: lets the model see images. Paired with this variant the way llama.cpp '
                  'pairs it (same folder, closest precision).',
              child: Row(children: [
                Icon(Icons.image_outlined, size: 14, color: muted),
                SizedBox(width: t.space.xs),
                Flexible(
                  child: Text('+ ${mm.name} (${formatBytes(mm.size ?? mm.lfsSize ?? 0)})',
                      style: theme.textTheme.bodySmall?.copyWith(color: muted), overflow: TextOverflow.ellipsis),
                ),
              ]),
            ),
          ],
          for (final w in row.warnings)
            Padding(
              padding: EdgeInsets.only(top: t.space.xxs),
              child: Text(w, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            ),
        ],
      ),
    );

    final semantics = [
      row.label,
      if (row.recommended) 'Recommended',
      formatBytes(row.downloadBytes),
      switch (row.kind) {
        FitBadgeKind.fits => 'Fits',
        FitBadgeKind.tight => 'Tight',
        FitBadgeKind.wontFit => "Won't fit",
        FitBadgeKind.unknown => 'Fit unknown',
        FitBadgeKind.blocked => 'Unavailable',
      },
      row.reason,
      if (ctx != null) 'Up to $ctx tokens of context',
    ].join('. ');

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: t.space.lg, vertical: t.space.xs),
      child: Semantics(
        container: true,
        label: semantics,
        selected: selected,
        button: !blocked,
        enabled: !blocked,
        excludeSemantics: true,
        onTap: onTap,
        child: Opacity(
          opacity: blocked ? 0.6 : 1,
          child: Material(
            color: selected ? scheme.secondaryContainer.withValues(alpha: 0.5) : scheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(t.radius.md),
              side: BorderSide(color: selected ? scheme.primary : Colors.transparent, width: 1.5),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(onTap: onTap, child: content),
          ),
        ),
      ),
    );
  }
}

class _OtherFiles extends StatelessWidget {
  const _OtherFiles({required this.files});

  final List<(HubRepoFile, String)> files;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: t.space.sm),
      child: ExpansionTile(
        expansionAnimationStyle: motionStyleOf(context),
        title: Text('Other files (${files.length})', style: theme.textTheme.titleSmall),
        subtitle: const Text('Not offered: companions, configs or unsafe formats'),
        children: [
          for (final (f, why) in files)
            ListTile(
              dense: true,
              title: Text(f.path, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(why),
              trailing: f.size == null ? null : Text(formatBytes(f.size!), style: theme.textTheme.metricSmall),
            ),
        ],
      ),
    );
  }
}

class _DownloadBar extends ConsumerWidget {
  const _DownloadBar({
    required this.details,
    required this.row,
    required this.shape,
    required this.starting,
    required this.onDownload,
    this.onFollow,
  });

  final CatalogModelDetails details;
  final VariantRow row;
  final ModelShape? shape;
  final bool starting;
  final VoidCallback onDownload;

  /// Onboarding: follow this variant's job or installed model there.
  final ValueChanged<EnqueueOutcome>? onFollow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    ref.watch(downloadJobsProvider);
    ref.watch(libraryModelsProvider);
    final DownloadManager manager;
    try {
      manager = ref.watch(downloadManagerProvider);
    } on Object catch (e) {
      // Never an error box where the Download button belongs: say what
      // failed and offer to try again (the provider observer recorded it).
      return _BarFrame(
        children: [
          Text(downloadStartMessage(e), style: theme.textTheme.bodySmall?.copyWith(color: t.semantic.danger)),
          SizedBox(height: t.space.sm),
          FilledButton.tonalIcon(
            onPressed: () => ref
              ..invalidate(networkMonitorProvider)
              ..invalidate(downloadManagerProvider),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
          ),
        ],
      );
    }
    final installed = manager.library.find(repo: details.id, revision: details.commit, variantId: row.variant.id);
    final job = manager.jobFor(repo: details.id, commit: details.commit, variantId: row.variant.id);
    final follow = onFollow;

    final Widget button;
    String? note;
    if (installed != null) {
      button = follow != null
          ? FilledButton.icon(
              onPressed: () => follow(AlreadyPresent(libraryModelId: installed.id)),
              icon: const Icon(Icons.check_rounded),
              label: const Text('Installed · Use this model'),
            )
          : FilledButton.tonalIcon(
              onPressed: () => context.go(Routes.models),
              icon: const Icon(Icons.check_rounded),
              label: const Text('Installed · Open library'),
            );
    } else if (job != null && job.phase != JobPhase.done) {
      button = FilledButton.tonalIcon(
        onPressed: follow != null ? () => follow(AlreadyPresent(jobId: job.id)) : () => context.go(Routes.downloads),
        icon: const Icon(Icons.downloading_rounded),
        label: Text(job.phase == JobPhase.failed ? 'Download failed · View' : 'Downloading ${(job.progress * 100).round()}% · View'),
      );
    } else {
      final can = row.canDownload && !starting;
      if (row.kind == FitBadgeKind.wontFit) note = "Won't fit on this device: ${row.reason}";
      if (row.kind == FitBadgeKind.blocked) note = row.reason;
      button = FilledButton.icon(
        onPressed: can ? onDownload : null,
        icon: starting
            ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.download_rounded),
        label: Text('Download ${row.label} · ${formatBytes(row.downloadBytes)}'),
      );
    }
    return _BarFrame(
      children: [
        if (note != null) ...[
          Text(note, style: theme.textTheme.bodySmall?.copyWith(color: SherpaTokens.of(context).semantic.danger)),
          SizedBox(height: t.space.sm),
        ],
        ConstrainedBox(constraints: BoxConstraints(minHeight: t.space.minTouchTarget), child: button),
      ],
    );
  }
}

/// Full-width bar, but the content keeps to the reading column on tablets.
class _BarFrame extends StatelessWidget {
  const _BarFrame({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: t.layout.maxContentWidth),
            child: Padding(
              padding: EdgeInsets.fromLTRB(t.space.lg, t.space.md, t.space.lg, t.space.md),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton();

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    return Semantics(
      label: 'Loading model',
      excludeSemantics: true,
      child: ListView(
        padding: EdgeInsets.all(t.space.lg),
        children: [
          const Skeleton(width: 220, height: 14),
          SizedBox(height: t.space.md),
          const Skeleton(width: 160, height: 12),
          SizedBox(height: t.space.xl),
          const Skeleton(height: 72, radius: 16),
          SizedBox(height: t.space.xl),
          const _RowsSkeleton(),
        ],
      ),
    );
  }
}

class _RowsSkeleton extends StatelessWidget {
  const _RowsSkeleton();

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: t.space.lg),
      child: Column(children: [
        for (var i = 0; i < 3; i++) ...[const Skeleton(height: 76, radius: 12), SizedBox(height: t.space.sm)],
      ]),
    );
  }
}

class _DetailFailure extends StatelessWidget {
  const _DetailFailure({required this.error, required this.onRetry, this.onBrowse});

  final Object error;
  final VoidCallback onRetry;

  /// Back to the list this page was opened from (onboarding); default:
  /// the Browse route.
  final VoidCallback? onBrowse;

  @override
  Widget build(BuildContext context) {
    if (error is HubRepoNotFoundException) {
      return EmptyState(
        icon: Icons.search_off_rounded,
        title: 'Model not found',
        message: 'It was removed, renamed or made private.',
        primaryAction: FilledButton.tonal(
          onPressed: onBrowse ?? () => context.go(Routes.modelBrowse),
          child: const Text('Browse models'),
        ),
      );
    }
    return switch (failureOf(error)) {
      DirectoryOffline() => OfflineState(message: 'Model details need a connection.', onRetry: onRetry),
      DirectoryRateLimited() => StateView(
          icon: Icons.hourglass_top_rounded,
          tone: StateTone.warning,
          liveRegion: true,
          title: 'Hugging Face needs a breather',
          message: 'Too many requests from this network. Try again shortly; signing in raises the limit.',
          primaryAction: FilledButton.tonal(onPressed: onRetry, child: const Text('Try again')),
        ),
      DirectoryError(:final message) => ErrorState(title: "Couldn't load this model", message: message, onRetry: onRetry),
    };
  }
}
