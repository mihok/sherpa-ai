import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_hub/sherpa_hub.dart';

import '../../design/tokens.dart';
import '../../design/widgets/state_views.dart';
import '../../routing/routes.dart';
import '../../services/device/device_profile_source.dart';
import '../../state/connectivity.dart';
import '../../state/ui_preferences.dart';
import 'state/directory_controller.dart';
import 'state/model_fit.dart';
import 'state/models_providers.dart';
import 'widgets/model_card.dart';

/// Browse the Hugging Face Hub for models that run on this phone.
///
/// One request per page (R08 §15.1), GGUF by default, trusted quantizers
/// pinned, uncensored fine-tunes hidden unless asked for (and the count of
/// hidden results always said out loud), and every card's size and fit
/// labelled as an estimate until the detail page reads real file sizes.
class ModelDirectoryScreen extends ConsumerStatefulWidget {
  const ModelDirectoryScreen({super.key});

  @override
  ConsumerState<ModelDirectoryScreen> createState() => _ModelDirectoryScreenState();
}

class _ModelDirectoryScreenState extends ConsumerState<ModelDirectoryScreen> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter < 800) unawaited(ref.read(directoryControllerProvider.notifier).loadMore());
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final s = ref.watch(directoryControllerProvider);
    final controller = ref.read(directoryControllerProvider.notifier);
    final jobs = ref.watch(downloadJobsProvider).value ?? const [];
    final running = jobs.where((j) => j.phase.isActive || j.phase.isWaiting).length;

    return Scaffold(
      appBar: AppBar(
        title: Semantics(headingLevel: 1, child: const Text('Browse models')),
        actions: [
          IconButton(
            tooltip: running == 0 ? 'Downloads' : 'Downloads, $running in progress',
            onPressed: () => context.go(Routes.downloads),
            icon: Badge(
              isLabelVisible: running > 0,
              label: Text('$running'),
              child: const Icon(Icons.download_outlined),
            ),
          ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: t.layout.maxContentWidth),
          child: RefreshIndicator(
            onRefresh: controller.refresh,
            child: CustomScrollView(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: _SearchField(controller: _search, onChanged: controller.setText)),
                const SliverToBoxAdapter(child: _QuantizerRow()),
                const SliverToBoxAdapter(child: _FilterRow()),
                if (s.hiddenUncensored > 0 || s.showUncensored)
                  SliverToBoxAdapter(child: _ContentFilterNote(hidden: s.hiddenUncensored, showing: s.showUncensored)),
                ..._results(context, s, controller),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _results(BuildContext context, DirectoryState s, DirectoryController c) {
    final t = SherpaTokens.of(context);
    final pad = EdgeInsets.fromLTRB(t.space.lg, t.space.sm, t.space.lg, t.space.xxxl);
    final offline = ref.watch(networkStatusProvider).value == NetworkStatus.offline;
    if (s.raw.isEmpty && s.loading) {
      return [
        SliverPadding(
          padding: pad,
          sliver: SliverToBoxAdapter(
            child: Semantics(
              label: 'Loading models',
              excludeSemantics: true,
              child: Column(children: [
                for (var i = 0; i < 4; i++) ...[const ModelCardSkeleton(), SizedBox(height: t.space.md)],
              ]),
            ),
          ),
        ),
      ];
    }
    final failure = s.failure;
    if (s.raw.isEmpty && (failure != null || offline)) {
      return [SliverFillRemaining(hasScrollBody: false, child: _FailureView(failure: offline ? const DirectoryOffline() : failure!))];
    }
    final items = s.items;
    if (items.isEmpty) {
      final filtered = s.query.activeFilterCount > 0 || s.query.authors.isNotEmpty;
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.travel_explore_outlined,
            title: 'No models match',
            message: s.hiddenUncensored > 0
                ? '${s.hiddenUncensored} result${s.hiddenUncensored == 1 ? ' is' : 's are'} hidden by the content filter.'
                : filtered
                    ? 'Try fewer filters, another quantizer, or a broader search.'
                    : 'Try another search, such as "qwen", "gemma" or "llama".',
            primaryAction: filtered
                ? FilledButton.tonal(onPressed: c.clearFilters, child: const Text('Clear filters'))
                : null,
          ),
        ),
      ];
    }
    final device = ref.watch(deviceProfileProvider).value;
    return [
      SliverPadding(
        padding: pad,
        sliver: SliverList.separated(
          itemCount: items.length + 1,
          separatorBuilder: (_, _) => SizedBox(height: t.space.md),
          itemBuilder: (context, i) {
            if (i == items.length) return _ListFooter(state: s, onRetry: c.loadMore);
            final e = items[i];
            return ModelCard(
              key: ValueKey(e.id),
              entry: e,
              estimate: device == null ? null : estimateCardFit(e, device),
              onTap: () => context.go(Routes.modelDetail(e.id)),
            );
          },
        ),
      ),
    ];
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final pill = OutlineInputBorder(borderRadius: BorderRadius.circular(t.radius.pill), borderSide: BorderSide.none);
    return Padding(
      padding: EdgeInsets.fromLTRB(t.space.lg, t.space.xs, t.space.lg, t.space.sm),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) => TextField(
          controller: controller,
          textInputAction: TextInputAction.search,
          autocorrect: false,
          onChanged: onChanged,
          decoration: InputDecoration(
            hintText: 'Search Hugging Face',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: value.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                  ),
            filled: true,
            fillColor: scheme.surfaceContainerHigh,
            border: pill,
            enabledBorder: pill,
            focusedBorder: pill.copyWith(borderSide: BorderSide(color: scheme.primary, width: 2)),
            contentPadding: EdgeInsets.symmetric(horizontal: t.space.lg, vertical: t.space.md),
          ),
        ),
      ),
    );
  }
}

/// Pinned publishers. Tapping one narrows results to their uploads;
/// several fan out into one request each (R08 §2.1: `author` is exact).
class _QuantizerRow extends ConsumerWidget {
  const _QuantizerRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final prefs = ref.watch(modelBrowserPrefsProvider);
    final selected = ref.watch(directoryControllerProvider.select((s) => s.query.authors));
    final c = ref.read(directoryControllerProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(t.space.lg, t.space.xs, t.space.sm, 0),
          child: Row(
            children: [
              Semantics(
                headingLevel: 2,
                child: Text('Trusted quantizers', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
              ),
              const Tooltip(
                triggerMode: TooltipTriggerMode.tap,
                message: 'Anyone can upload to Hugging Face. These accounts publish carefully converted copies of '
                    'popular models with file names Sherpa decodes reliably. Tap one to see only its uploads.',
                child: Padding(padding: EdgeInsets.all(8), child: Icon(Icons.info_outline_rounded, size: 16)),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: t.space.lg),
            children: [
              for (final q in prefs.trustedQuantizers)
                Padding(
                  padding: EdgeInsets.only(right: t.space.sm),
                  child: FilterChip(
                    label: Text(q),
                    selected: selected.contains(q),
                    onSelected: (_) {
                      ref.read(hapticsProvider).selection();
                      c.toggleAuthor(q);
                    },
                  ),
                ),
              ActionChip(
                avatar: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Edit'),
                tooltip: 'Edit trusted quantizers',
                onPressed: () => unawaited(showEditQuantizersSheet(context)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FilterRow extends ConsumerWidget {
  const _FilterRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final q = ref.watch(directoryControllerProvider.select((s) => s.query));
    final c = ref.read(directoryControllerProvider.notifier);
    void pick(DirectoryQuery Function(DirectoryQuery) f) {
      ref.read(hapticsProvider).selection();
      c.update(f);
    }

    Widget format(HubFormatFilter f, String label, String tip) => Padding(
          padding: EdgeInsets.only(right: t.space.sm),
          child: Tooltip(
            message: tip,
            child: ChoiceChip(
              label: Text(label),
              selected: q.format == f,
              onSelected: (on) => pick((x) => on ? x.copyWith(format: f) : x.copyWith(clearFormat: true)),
            ),
          ),
        );

    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: t.space.lg, vertical: t.space.xs),
        children: [
          format(HubFormatFilter.gguf, 'GGUF', 'llama.cpp files: run on Android and iPhone'),
          format(HubFormatFilter.mlx, 'MLX', 'Apple MLX: iPhone and iPad only'),
          format(HubFormatFilter.litert, 'LiteRT', 'Google LiteRT-LM: Android only, some builds per chip'),
          SizedBox(width: t.space.xs),
          _MenuChip<SizeBucket>(
            label: q.size?.label ?? 'Size',
            selected: q.size != null,
            options: {for (final b in SizeBucket.values) b: b.label},
            onSelected: (b) => pick((x) => b == null ? x.copyWith(clearSize: true) : x.copyWith(size: b)),
            tooltip: 'Parameter count, from the Hub or the model name',
          ),
          _MenuChip<String>(
            label: q.license == null ? 'License' : licenseFilters[q.license] ?? q.license!,
            selected: q.license != null,
            options: licenseFilters,
            onSelected: (l) => pick((x) => l == null ? x.copyWith(clearLicense: true) : x.copyWith(license: l)),
            tooltip: 'The license the repo declares on Hugging Face',
          ),
          _MenuChip<ModelTask>(
            label: q.task?.label ?? 'Task',
            selected: q.task != null,
            options: {for (final m in ModelTask.values) m: m.label},
            onSelected: (m) => pick((x) => m == null ? x.copyWith(clearTask: true) : x.copyWith(task: m)),
            tooltip: 'What the model is for (the Hub pipeline tag)',
          ),
          Padding(
            padding: EdgeInsets.only(right: t.space.sm),
            child: Tooltip(
              message: 'Models whose chat template or tags mention tool calling. A hint; Sherpa checks the '
                  'downloaded file itself.',
              child: FilterChip(
                avatar: const Icon(Icons.build_outlined, size: 18),
                label: const Text('Tool use'),
                selected: q.toolUse,
                onSelected: (on) => pick((x) => x.copyWith(toolUse: on)),
              ),
            ),
          ),
          _MenuChip<DirectorySort>(
            label: q.sort.label,
            icon: Icons.sort_rounded,
            selected: false,
            allowAny: false,
            options: {for (final s in DirectorySort.values) s: s.label},
            onSelected: (s) => pick((x) => x.copyWith(sort: s)),
            tooltip: 'Sort order. Downloads count the last 30 days',
          ),
        ],
      ),
    );
  }
}

/// A chip that opens a menu of options (plus "Any").
class _MenuChip<T> extends StatelessWidget {
  const _MenuChip({
    required this.label,
    required this.selected,
    required this.options,
    required this.onSelected,
    this.tooltip,
    this.icon,
    this.allowAny = true,
  });

  final String label;
  final bool selected;
  final Map<T, String> options;
  final ValueChanged<T?> onSelected;
  final String? tooltip;
  final IconData? icon;
  final bool allowAny;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(right: t.space.sm),
      child: MenuAnchor(
        menuChildren: [
          if (allowAny) MenuItemButton(onPressed: () => onSelected(null), child: const Text('Any')),
          for (final e in options.entries) MenuItemButton(onPressed: () => onSelected(e.key), child: Text(e.value)),
        ],
        builder: (context, menu, _) => Tooltip(
          message: tooltip ?? label,
          child: FilterChip(
            avatar: icon == null ? null : Icon(icon, size: 18),
            label: Row(mainAxisSize: MainAxisSize.min, children: [Text(label), const Icon(Icons.arrow_drop_down, size: 18)]),
            selected: selected,
            showCheckmark: false,
            onSelected: (_) => menu.isOpen ? menu.close() : menu.open(),
          ),
        ),
      ),
    );
  }
}

class _ContentFilterNote extends ConsumerWidget {
  const _ContentFilterNote({required this.hidden, required this.showing});

  final int hidden;
  final bool showing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final prefs = ref.read(modelBrowserPrefsProvider.notifier);
    final text = showing
        ? 'Showing uncensored fine-tunes'
        : '$hidden uncensored fine-tune${hidden == 1 ? '' : 's'} hidden';
    return Padding(
      padding: EdgeInsets.fromLTRB(t.space.lg, 0, t.space.sm, 0),
      child: Row(
        children: [
          Icon(showing ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
          SizedBox(width: t.space.sm),
          Expanded(
            child: Tooltip(
              message: 'Abliterated and uncensored fine-tunes have their refusal training removed. '
                  'Sherpa hides them by default.',
              child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          ),
          TextButton(
            onPressed: () => unawaited(prefs.setShowUncensored(!showing)),
            child: Text(showing ? 'Hide' : 'Show'),
          ),
        ],
      ),
    );
  }
}

class _ListFooter extends StatelessWidget {
  const _ListFooter({required this.state, required this.onRetry});

  final DirectoryState state;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    if (state.loadingMore) {
      return Padding(
        padding: EdgeInsets.all(t.space.lg),
        child: const Center(child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5))),
      );
    }
    if (state.failure != null && state.hasMore) {
      return Center(
        child: TextButton.icon(
          onPressed: () => unawaited(onRetry()),
          icon: const Icon(Icons.refresh),
          label: const Text("Couldn't load more. Try again"),
        ),
      );
    }
    if (state.hasMore) {
      return Center(child: TextButton(onPressed: () => unawaited(onRetry()), child: const Text('Load more')));
    }
    return SizedBox(height: t.space.lg);
  }
}

class _FailureView extends ConsumerWidget {
  const _FailureView({required this.failure});

  final DirectoryFailure failure;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.read(directoryControllerProvider.notifier);
    return switch (failure) {
      DirectoryOffline() => OfflineState(
          message: "Browsing needs a connection. Models you've already downloaded work offline.",
          onRetry: () => unawaited(c.refresh()),
        ),
      DirectoryRateLimited(:final retryAfter) => StateView(
          icon: Icons.hourglass_top_rounded,
          tone: StateTone.warning,
          liveRegion: true,
          title: 'Hugging Face needs a breather',
          message: 'Too many requests from this network'
              '${retryAfter == null ? '' : '; try again in ${retryAfter.inSeconds < 90 ? '${retryAfter.inSeconds} s' : '${(retryAfter.inSeconds / 60).ceil()} min'}'}. '
              'Signing in to Hugging Face raises the limit.',
          primaryAction: FilledButton.tonalIcon(
            onPressed: () => unawaited(c.refresh()),
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
          secondaryAction: OutlinedButton(
            onPressed: () => context.go(Routes.huggingFace),
            child: const Text('Sign in'),
          ),
        ),
      DirectoryError(:final message) => ErrorState(
          title: "Couldn't load models",
          message: message,
          onRetry: () => unawaited(c.refresh()),
        ),
    };
  }
}

/// Add or remove pinned publishers.
Future<void> showEditQuantizersSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => const _EditQuantizersSheet(),
    );

class _EditQuantizersSheet extends ConsumerStatefulWidget {
  const _EditQuantizersSheet();

  @override
  ConsumerState<_EditQuantizersSheet> createState() => _EditQuantizersSheetState();
}

class _EditQuantizersSheetState extends ConsumerState<_EditQuantizersSheet> {
  final TextEditingController _add = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _add.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final ok = await ref.read(modelBrowserPrefsProvider.notifier).addQuantizer(_add.text);
    if (!mounted) return;
    setState(() => _error = ok ? null : 'Use a Hugging Face account name, like "bartowski".');
    if (ok) _add.clear();
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final prefs = ref.watch(modelBrowserPrefsProvider);
    final notifier = ref.read(modelBrowserPrefsProvider.notifier);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.fromLTRB(t.space.lg, 0, t.space.lg, t.space.lg),
          children: [
            Semantics(headingLevel: 2, child: Text('Trusted quantizers', style: Theme.of(context).textTheme.titleLarge)),
            SizedBox(height: t.space.sm),
            Text(
              'Pinned above the results. Pick accounts that publish GGUF or MLX conversions you trust.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            SizedBox(height: t.space.md),
            for (final q in prefs.trustedQuantizers)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(q),
                trailing: IconButton(
                  tooltip: 'Remove $q',
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => unawaited(notifier.removeQuantizer(q)),
                ),
              ),
            SizedBox(height: t.space.sm),
            TextField(
              controller: _add,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => unawaited(_submit()),
              decoration: InputDecoration(
                labelText: 'Add an account',
                hintText: 'e.g. Qwen',
                errorText: _error,
                suffixIcon: IconButton(tooltip: 'Add', icon: const Icon(Icons.add), onPressed: () => unawaited(_submit())),
              ),
            ),
            SizedBox(height: t.space.md),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: () => unawaited(notifier.resetQuantizers()), child: const Text('Reset to defaults')),
            ),
          ],
        ),
      ),
    );
  }
}
