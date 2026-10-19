import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart' show immutable, setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http show ClientException;
import 'package:sherpa_hub/sherpa_hub.dart';

import 'models_providers.dart';

/// Parameter-count buckets. Applied on the client: the Hub's
/// `num_parameters` filter matches the repo-level `gguf` summary, which
/// can describe a 1.9B draft head inside a 27B repo (R08 §2.1).
enum SizeBucket {
  tiny('Under 2B', 0, 2),
  small('2–5B', 2, 5),
  medium('5–10B', 5, 10),
  large('10–35B', 10, 35),
  huge('35B+', 35, double.infinity);

  const SizeBucket(this.label, this.minB, this.maxB);

  final String label;
  final double minB;
  final double maxB;

  bool contains(double billions) => billions >= minB && billions < maxB;
}

/// `pipeline_tag` presets.
enum ModelTask {
  chat('Chat', 'text-generation'),
  vision('Vision', 'image-text-to-text'),
  embeddings('Embeddings', 'feature-extraction');

  const ModelTask(this.label, this.pipelineTag);

  final String label;
  final String pipelineTag;
}

enum DirectorySort {
  trending('Trending', HubSort.trending),
  downloads('Most downloaded', HubSort.downloads),
  likes('Most liked', HubSort.likes),
  newest('Newest', HubSort.createdAt);

  const DirectorySort(this.label, this.hub);

  final String label;
  final HubSort hub;
}

/// License tags (`filter=license:<id>`), the common ones for local models.
const Map<String, String> licenseFilters = {
  'apache-2.0': 'Apache 2.0',
  'mit': 'MIT',
  'gemma': 'Gemma',
  'llama3.2': 'Llama 3.2',
  'other': 'Other',
};

@immutable
final class DirectoryQuery {
  const DirectoryQuery({
    this.text = '',
    this.format = HubFormatFilter.gguf,
    this.size,
    this.license,
    this.task,
    this.toolUse = false,
    this.sort = DirectorySort.trending,
    this.authors = const {},
  });

  final String text;

  /// GGUF by default: it is the format Sherpa runs on both platforms.
  final HubFormatFilter? format;
  final SizeBucket? size;
  final String? license;
  final ModelTask? task;

  /// Client-side: chat template renders tools, or tagged `tool-use` /
  /// `function-calling` (R08 §10). A heuristic, shown as such.
  final bool toolUse;
  final DirectorySort sort;

  /// Selected trusted quantizers; several fan out into one request each.
  final Set<String> authors;

  int get activeFilterCount =>
      (size == null ? 0 : 1) + (license == null ? 0 : 1) + (task == null ? 0 : 1) + (toolUse ? 1 : 0);

  ModelSearchQuery toSearch({int limit = 30}) => ModelSearchQuery(
        text: text.trim().isEmpty ? null : text.trim(),
        format: format,
        pipelineTag: task?.pipelineTag,
        authors: authors.toList()..sort(),
        sort: sort.hub,
        tags: [if (license != null) 'license:$license'],
        limit: limit,
      );

  /// Filters the server can't apply.
  bool matchesClientFilters(CatalogEntry e) {
    if (toolUse && !e.toolUseHint) return false;
    final s = size;
    if (s != null) {
      final b = parameterBillions(e);
      if (b == null || !s.contains(b)) return false;
    }
    return true;
  }

  DirectoryQuery copyWith({
    String? text,
    HubFormatFilter? format,
    bool clearFormat = false,
    SizeBucket? size,
    bool clearSize = false,
    String? license,
    bool clearLicense = false,
    ModelTask? task,
    bool clearTask = false,
    bool? toolUse,
    DirectorySort? sort,
    Set<String>? authors,
  }) =>
      DirectoryQuery(
        text: text ?? this.text,
        format: clearFormat ? null : (format ?? this.format),
        size: clearSize ? null : (size ?? this.size),
        license: clearLicense ? null : (license ?? this.license),
        task: clearTask ? null : (task ?? this.task),
        toolUse: toolUse ?? this.toolUse,
        sort: sort ?? this.sort,
        authors: authors ?? this.authors,
      );

  @override
  bool operator ==(Object other) =>
      other is DirectoryQuery &&
      other.text == text &&
      other.format == format &&
      other.size == size &&
      other.license == license &&
      other.task == task &&
      other.toolUse == toolUse &&
      other.sort == sort &&
      setEquals(other.authors, authors);

  @override
  int get hashCode => Object.hash(text, format, size, license, task, toolUse, sort, Object.hashAllUnordered(authors));
}

/// Parameters in billions: `safetensors.total` when the Hub has it, else
/// the size in the name (`8x7B` counts as 56, an upper bound).
double? parameterBillions(CatalogEntry e) {
  final st = e.summary?.safetensors?.total;
  if (st != null && st > 0) return st / 1e9;
  return e.name.size?.value.billions;
}

/// Why the list could not load.
sealed class DirectoryFailure {
  const DirectoryFailure();
}

final class DirectoryOffline extends DirectoryFailure {
  const DirectoryOffline();
}

final class DirectoryRateLimited extends DirectoryFailure {
  const DirectoryRateLimited(this.retryAfter);

  final Duration? retryAfter;
}

final class DirectoryError extends DirectoryFailure {
  const DirectoryError(this.message);

  final String message;
}

DirectoryFailure failureOf(Object e) => switch (e) {
      HubRateLimitedException(:final retryAfter) => DirectoryRateLimited(retryAfter),
      HubNetworkException() || SocketException() || http.ClientException() || TimeoutException() =>
        const DirectoryOffline(),
      HubServerException() => const DirectoryError('Hugging Face is having trouble right now.'),
      HubBadRequestException(:final message) => DirectoryError('Hugging Face refused the search: $message'),
      HubException(:final message) => DirectoryError(message),
      _ => const DirectoryError('The model list could not be loaded.'),
    };

@immutable
final class DirectoryState {
  const DirectoryState({
    this.query = const DirectoryQuery(),
    this.raw = const [],
    this.nextCursor,
    this.loading = false,
    this.loadingMore = false,
    this.failure,
    this.showUncensored = false,
  });

  final DirectoryQuery query;

  /// Everything the server returned for [query], deduped.
  final List<CatalogEntry> raw;
  final String? nextCursor;
  final bool loading;
  final bool loadingMore;
  final DirectoryFailure? failure;
  final bool showUncensored;

  /// What the list shows.
  List<CatalogEntry> get items => [
        for (final e in raw)
          if ((showUncensored || !e.isUncensored) && query.matchesClientFilters(e)) e,
      ];

  /// Results the default content filter hid (said out loud, never silent).
  int get hiddenUncensored => showUncensored ? 0 : raw.where((e) => e.isUncensored).length;

  bool get hasMore => nextCursor != null;

  DirectoryState copyWith({
    DirectoryQuery? query,
    List<CatalogEntry>? raw,
    String? nextCursor,
    bool clearCursor = false,
    bool? loading,
    bool? loadingMore,
    DirectoryFailure? failure,
    bool clearFailure = false,
    bool? showUncensored,
  }) =>
      DirectoryState(
        query: query ?? this.query,
        raw: raw ?? this.raw,
        nextCursor: clearCursor ? null : (nextCursor ?? this.nextCursor),
        loading: loading ?? this.loading,
        loadingMore: loadingMore ?? this.loadingMore,
        failure: clearFailure ? null : (failure ?? this.failure),
        showUncensored: showUncensored ?? this.showUncensored,
      );
}

final directoryControllerProvider = NotifierProvider.autoDispose<DirectoryController, DirectoryState>(
  DirectoryController.new,
);

/// Search, filters and paging for the model browser.
///
/// One `GET /api/models` per page with `expand[]` (R08 §15.1), pages
/// deduped by `_id` (cursors can repeat items when sort values move,
/// R08 §2.3), typing debounced so a word costs one request, and stale
/// responses dropped by generation.
final class DirectoryController extends Notifier<DirectoryState> {
  static const Duration debounce = Duration(milliseconds: 350);

  Timer? _debounce;
  int _generation = 0;

  @override
  DirectoryState build() {
    ref.onDispose(() => _debounce?.cancel());
    ref.listen(modelBrowserPrefsProvider.select((p) => p.showUncensored), (_, show) {
      state = state.copyWith(showUncensored: show);
    });
    final show = ref.read(modelBrowserPrefsProvider).showUncensored;
    Future.microtask(_load);
    return DirectoryState(loading: true, showUncensored: show);
  }

  void setText(String text) {
    if (text == state.query.text) return;
    state = state.copyWith(query: state.query.copyWith(text: text));
    _debounce?.cancel();
    _debounce = Timer(debounce, _load);
  }

  void update(DirectoryQuery Function(DirectoryQuery q) change) {
    final next = change(state.query);
    if (next == state.query) return;
    _debounce?.cancel();
    state = state.copyWith(query: next);
    unawaited(_load());
  }

  void toggleAuthor(String author) => update((q) {
        final a = {...q.authors};
        if (!a.remove(author)) a.add(author);
        return q.copyWith(authors: a);
      });

  void clearFilters() => update((q) => DirectoryQuery(text: q.text, format: q.format, sort: q.sort, authors: q.authors));

  Future<void> refresh() => _load();

  Future<void> _load() async {
    final gen = ++_generation;
    state = state.copyWith(loading: true, clearFailure: true, raw: const [], clearCursor: true);
    try {
      final page = await ref.read(modelCatalogProvider).search(state.query.toSearch());
      if (gen != _generation || !ref.mounted) return;
      state = state.copyWith(raw: _dedupe(const [], page.items), nextCursor: page.nextCursor, clearCursor: page.nextCursor == null, loading: false);
    } on Object catch (e) {
      if (gen != _generation || !ref.mounted) return;
      state = state.copyWith(loading: false, failure: failureOf(e));
    }
  }

  Future<void> loadMore() async {
    final cursor = state.nextCursor;
    if (cursor == null || state.loadingMore || state.loading) return;
    final gen = _generation;
    state = state.copyWith(loadingMore: true);
    try {
      final page = await ref.read(modelCatalogProvider).search(state.query.toSearch(), cursor: cursor);
      if (gen != _generation || !ref.mounted) return;
      state = state.copyWith(
        raw: _dedupe(state.raw, page.items),
        nextCursor: page.nextCursor,
        clearCursor: page.nextCursor == null,
        loadingMore: false,
      );
    } on Object catch (e) {
      if (gen != _generation || !ref.mounted) return;
      state = state.copyWith(loadingMore: false, failure: failureOf(e));
    }
  }

  static List<CatalogEntry> _dedupe(List<CatalogEntry> have, List<CatalogEntry> more) {
    final seen = {for (final e in have) e.summary?.dedupeKey ?? e.id};
    return [...have, for (final e in more) if (seen.add(e.summary?.dedupeKey ?? e.id)) e];
  }
}
