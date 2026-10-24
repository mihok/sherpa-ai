import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_hub/sherpa_hub.dart';

import '../../design/motion.dart';
import '../../design/tokens.dart';
import '../../design/widgets/a11y.dart';
import '../../design/widgets/state_views.dart';
import '../../routing/routes.dart';
import '../../services/device/device_profile_source.dart';
import '../../services/downloads/downloads.dart' show EnqueueOutcome;
import '../../state/connectivity.dart';
import '../../state/ui_preferences.dart';
import 'hf_account_screen.dart';
import 'model_detail_screen.dart';
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
  const ModelDirectoryScreen({super.key, this.onOpenModel, this.initialQuery = const DirectoryQuery()});

  /// Set when the browser is opened from onboarding (outside the app's
  /// routes): opens a repo there instead of on the Browse route, hides the
  /// Downloads shortcut (onboarding shows the download itself), and opens
  /// the Hugging Face account screen on top of the list.
  final ValueChanged<String>? onOpenModel;

  /// What the list opens on: [DirectoryQuery.versionsOf] from a model page
  /// whose files don't run on this device. Each page is a list of its own
  /// ([DirectoryPage]), even when another page opened on the same query.
  final DirectoryQuery initialQuery;

  @override
  ConsumerState<ModelDirectoryScreen> createState() => _ModelDirectoryScreenState();
}

/// The Hub browser pushed over onboarding (outside the app's routes), on
/// [query], with a repo's page pushed over it in turn. Resolves to what a
/// download started there came to, or null when the user backs out.
Future<EnqueueOutcome?> pushModelBrowser(BuildContext context, {DirectoryQuery query = const DirectoryQuery()}) =>
    Navigator.of(context).push<EnqueueOutcome>(MotionPageRoute(
      builder: (browseContext) => ModelDirectoryScreen(
        initialQuery: query,
        onOpenModel: (id) => unawaited(_pushModel(browseContext, id)),
      ),
    ));

Future<void> _pushModel(BuildContext browseContext, String repoId) async {
  final picked = await Navigator.of(browseContext).push<EnqueueOutcome>(MotionPageRoute(
    builder: (detailContext) => ModelDetailScreen(
      repoId: repoId,
      onDownloadStarted: (o) => Navigator.of(detailContext).pop(o),
    ),
  ));
  if (picked != null && browseContext.mounted) Navigator.of(browseContext).pop(picked);
}

class _ModelDirectoryScreenState extends ConsumerState<ModelDirectoryScreen> {
  late final TextEditingController _search = TextEditingController(text: widget.initialQuery.text);
  final ScrollController _scroll = ScrollController();

  late DirectoryPage _page;

  NotifierProvider<DirectoryController, DirectoryState> get _provider => directoryControllersProvider(_page);

  /// Browse's route on its default list is the one root list; any other
  /// page (a repo's versions, the browser over onboarding) gets its own.
  static DirectoryPage _pageFor(ModelDirectoryScreen w) =>
      w.onOpenModel == null && w.initialQuery == const DirectoryQuery() ? DirectoryPage.root : DirectoryPage(w.initialQuery);

  @override
  void initState() {
    super.initState();
    _page = _pageFor(widget);
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void didUpdateWidget(ModelDirectoryScreen old) {
    super.didUpdateWidget(old);
    // The route opened another list (a repo's versions) on this page.
    if (old.initialQuery != widget.initialQuery) {
      _page = _pageFor(widget);
      _search.text = ref.read(_provider).query.text;
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter < 800) unawaited(ref.read(_provider.notifier).loadMore());
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final s = ref.watch(_provider);
    final controller = ref.read(_provider.notifier);
    final jobs = ref.watch(downloadJobsProvider).value ?? const [];
    final running = jobs.where((j) => j.phase.isActive || j.phase.isWaiting).length;

    return Scaffold(
      appBar: AppBar(
        title: Heading(level: 1, child: const Text('Browse models')),
        actions: [
          if (widget.onOpenModel == null)
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
              semanticChildCount: s.items.isEmpty ? null : s.items.length,
              slivers: [
                SliverToBoxAdapter(child: _SearchField(controller: _search, onChanged: controller.setText)),
                if (s.query.quantizedFrom case final base?)
                  SliverToBoxAdapter(child: _VersionsOfRow(repoId: base, onClear: controller.clearVersionsOf)),
                SliverToBoxAdapter(child: _QuantizerRow(provider: _provider)),
                SliverToBoxAdapter(child: _FilterRow(provider: _provider)),
                if (s.hiddenUncensored > 0 || s.showUncensored)
                  SliverToBoxAdapter(child: _ContentFilterNote(hidden: s.hiddenUncensored, showing: s.showUncensored)),
                if (s.query.repoId case final id? when !s.items.any((e) => e.id.toLowerCase() == id.toLowerCase()))
                  SliverToBoxAdapter(child: _OpenRepoTile(repoId: id, onOpen: () => _open(context, id))),
                ..._results(context, s, controller),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _open(BuildContext context, String repoId) {
    final open = widget.onOpenModel;
    if (open != null) {
      open(repoId);
    } else if (widget.initialQuery.quantizedFrom != null) {
      // A repo's versions open over the page that asked for them; a
      // version's page goes on top in turn, so back retraces the way.
      unawaited(context.push<void>(Routes.modelDetail(repoId)));
    } else {
      context.go(Routes.modelDetail(repoId));
    }
  }

  /// Settings › Hugging Face account. Onboarding's routes send every other
  /// route back to onboarding, so there it opens on top of this list, and
  /// the list reloads on the way back with the token's higher limit.
  Future<void> _signIn(BuildContext context) async {
    if (widget.onOpenModel == null) {
      context.go(Routes.huggingFace);
      return;
    }
    await Navigator.of(context).push<void>(MotionPageRoute(builder: (_) => const HuggingFaceAccountScreen()));
    if (mounted) unawaited(ref.read(_provider.notifier).refresh());
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
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _FailureView(
            failure: offline ? const DirectoryOffline() : failure!,
            onRetry: c.refresh,
            onSignIn: () => unawaited(_signIn(context)),
          ),
        ),
      ];
    }
    final items = s.items;
    if (items.isEmpty) {
      final filtered = s.query.activeFilterCount > 0 || s.query.authors.isNotEmpty;
      final versions = s.query.quantizedFrom != null;
      final searching = s.loadingMore;
      // What widens the list, nearest first: fewer filters, then (for a
      // repo's versions) every model. "Search further" leads while the Hub
      // has more.
      final ways = [
        if (filtered) ('Clear filters', c.clearFilters),
        if (versions) ('Show all models', c.clearVersionsOf),
      ];
      final others = s.hasMore ? ways : ways.skip(1);
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.travel_explore_outlined,
            title: searching
                ? 'Searching more results…'
                : versions
                    ? 'No versions found'
                    : 'No models match',
            message: _emptyMessage(s, filtered: filtered),
            // The filters ran over the pages loaded so far; the Hub has more.
            primaryAction: s.hasMore
                ? FilledButton.tonalIcon(
                    onPressed: searching ? null : () => unawaited(c.loadMore()),
                    icon: searching
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.manage_search_rounded),
                    label: const Text('Search further'),
                  )
                : ways.isEmpty
                    ? null
                    : FilledButton.tonal(onPressed: ways.first.$2, child: Text(ways.first.$1)),
            secondaryAction: others.isEmpty ? null : TextButton(onPressed: others.first.$2, child: Text(others.first.$1)),
          ),
        ),
      ];
    }
    final device = ref.watch(deviceProfileProvider).value;
    return [
      SliverPadding(
        padding: pad,
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              if (i.isOdd) return SizedBox(height: t.space.md);
              final k = i ~/ 2;
              if (k == items.length) return _ListFooter(state: s, onRetry: c.loadMore);
              final e = items[k];
              return ModelCard(
                key: ValueKey(e.id),
                entry: e,
                estimate: device == null ? null : estimateCardFit(e, device),
                onTap: () => _open(context, e.id),
              );
            },
            childCount: items.length * 2 + 1,
            // Only the cards are list items ("12 of 30" in TalkBack), not
            // the gaps or the "Load more" footer.
            semanticIndexCallback: (_, i) => i.isEven && i ~/ 2 < items.length ? i ~/ 2 : null,
          ),
        ),
      ),
    ];
  }
}

/// Why nothing shows: names the filter that hid the results (the size and
/// tool-use filters, the content filter, or both), never the wrong one.
String _emptyMessage(DirectoryState s, {required bool filtered}) {
  final q = s.query;
  final byFilters = s.hiddenByFilters;
  final byContent = s.hiddenUncensored;
  final names = [
    if (q.size != null) 'the ${q.size!.label} size filter',
    if (q.toolUse) 'the Tool use filter',
  ];
  final parts = <String>[
    if (byFilters > 0 && names.isNotEmpty)
      '$byFilters result${byFilters == 1 ? '' : 's'} so far ${byFilters == 1 ? "doesn't" : "don't"} match ${names.join(' or ')}',
    if (byContent > 0) '$byContent ${byContent == 1 ? 'is' : 'are'} hidden by the content filter',
  ];
  final more = s.hasMore ? ' Hugging Face has more results to search.' : '';
  if (parts.isNotEmpty) return '${parts.join(', and ')}.$more';
  if (q.quantizedFrom case final base?) {
    final kind = q.format == null ? '' : '${formatFilterLabel(q.format!)} ';
    final narrowed = filtered || q.text.trim().isNotEmpty ? ' that match this search and these filters' : '';
    return 'Hugging Face lists no ${kind}versions of $base$narrowed yet.$more';
  }
  if (filtered) return 'Try fewer filters, another quantizer, or a broader search.$more';
  return 'Try another search, such as "qwen", "gemma" or "llama", or paste a Hugging Face link.$more';
}

/// "Quantized from Qwen/Qwen3-0.6B": only repos the Hub tags as quantized
/// from that one are listed until "Show all models" clears it. The heading
/// says what the tag says; a fine-tune can carry it too.
class _VersionsOfRow extends StatelessWidget {
  const _VersionsOfRow({required this.repoId, required this.onClear});

  final String repoId;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(t.space.lg, 0, t.space.sm, 0),
      child: Row(
        children: [
          Icon(Icons.account_tree_outlined, size: 18, color: theme.colorScheme.primary),
          SizedBox(width: t.space.sm),
          Expanded(
            child: Tooltip(
              message: 'Hugging Face repos tagged as quantized from $repoId. Some may be fine-tunes of it.',
              child: Text('Quantized from $repoId', style: theme.textTheme.titleSmall),
            ),
          ),
          TextButton(onPressed: onClear, child: const Text('Show all models')),
        ],
      ),
    );
  }
}

/// "Open Qwen/Qwen3-0.6B-GGUF" when the search is a repo id or a pasted
/// link: straight to the repo, whatever its tags.
class _OpenRepoTile extends StatelessWidget {
  const _OpenRepoTile({required this.repoId, required this.onOpen});

  final String repoId;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: t.space.sm),
      child: ListTile(
        leading: const Icon(Icons.open_in_new_rounded),
        title: Text('Open $repoId'),
        subtitle: const Text('Go straight to this repository'),
        onTap: onOpen,
      ),
    );
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
  const _QuantizerRow({required this.provider});

  final NotifierProvider<DirectoryController, DirectoryState> provider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final prefs = ref.watch(modelBrowserPrefsProvider);
    final selected = ref.watch(provider.select((s) => s.query.authors));
    final c = ref.read(provider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(t.space.lg, t.space.xs, t.space.sm, 0),
          child: Row(
            children: [
              Heading(
                level: 2,
                child: Text('Trusted quantizers', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
              ),
              // A real button (48 dp, labelled) rather than a 32 dp tap tooltip.
              IconButton(
                tooltip: 'About trusted quantizers',
                iconSize: 18,
                icon: const Icon(Icons.info_outline_rounded),
                onPressed: () => unawaited(showDialog<void>(
                  context: context,
                  animationStyle: motionStyleOf(context),
                  builder: (context) => AlertDialog(
                    title: const Heading(child: Text('Trusted quantizers')),
                    content: const Text(
                      'Anyone can upload to Hugging Face. These accounts publish carefully converted copies of '
                      'popular models with file names Sherpa decodes reliably. Tap one to see only its uploads.',
                    ),
                    actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
                  ),
                )),
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
                  padding: EdgeInsetsDirectional.only(end: t.space.sm),
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
  const _FilterRow({required this.provider});

  final NotifierProvider<DirectoryController, DirectoryState> provider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final q = ref.watch(provider.select((s) => s.query));
    final c = ref.read(provider.notifier);
    // Only the formats this device runs: an Android phone is never offered
    // MLX, nor an iPhone LiteRT-LM.
    final formats = runnableFormats(ref.watch(deviceProfileProvider.select((d) => d.value?.platform)));
    void pick(DirectoryQuery Function(DirectoryQuery) f) {
      ref.read(hapticsProvider).selection();
      c.update(f);
    }

    Widget format(HubFormatFilter f) => Padding(
          padding: EdgeInsetsDirectional.only(end: t.space.sm),
          child: Tooltip(
            message: switch (f) {
              HubFormatFilter.gguf => 'llama.cpp files: run on Android and iPhone',
              HubFormatFilter.mlx => 'Apple MLX: iPhone and iPad only',
              HubFormatFilter.litert => 'Google LiteRT-LM: Android only, some builds per chip',
              HubFormatFilter.tflite || HubFormatFilter.onnx => formatFilterLabel(f),
            },
            child: ChoiceChip(
              label: Text(formatFilterLabel(f)),
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
          for (final f in formats) format(f),
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
            padding: EdgeInsetsDirectional.only(end: t.space.sm),
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
      padding: EdgeInsetsDirectional.only(end: t.space.sm),
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
      padding: EdgeInsetsDirectional.fromSTEB(t.space.lg, 0, t.space.sm, 0),
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
        child: const Center(
          child: SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5, semanticsLabel: 'Loading more models'),
          ),
        ),
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

class _FailureView extends StatelessWidget {
  const _FailureView({required this.failure, required this.onRetry, required this.onSignIn});

  final DirectoryFailure failure;
  final Future<void> Function() onRetry;
  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) {
    return switch (failure) {
      DirectoryOffline() => OfflineState(
          message: "Browsing needs a connection. Models you've already downloaded work offline.",
          onRetry: () => unawaited(onRetry()),
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
            onPressed: () => unawaited(onRetry()),
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
          secondaryAction: OutlinedButton(onPressed: onSignIn, child: const Text('Sign in')),
        ),
      DirectoryError(:final message) => ErrorState(
          title: "Couldn't load models",
          message: message,
          onRetry: () => unawaited(onRetry()),
        ),
    };
  }
}

/// Add or remove pinned publishers.
Future<void> showEditQuantizersSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: motionStyleOf(context),
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
            Heading(level: 2, child: Text('Trusted quantizers', style: Theme.of(context).textTheme.titleLarge)),
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
                suffixIcon: IconButton(tooltip: 'Add account', icon: const Icon(Icons.add), onPressed: () => unawaited(_submit())),
              ),
            ),
            SizedBox(height: t.space.md),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(onPressed: () => unawaited(notifier.resetQuantizers()), child: const Text('Reset to defaults')),
            ),
          ],
        ),
      ),
    );
  }
}
