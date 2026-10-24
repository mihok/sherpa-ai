import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/bootstrap.dart' show noRetry;
import 'package:sherpa/features/models/model_detail_screen.dart';
import 'package:sherpa/features/models/state/directory_controller.dart';
import 'package:sherpa/features/models/state/models_providers.dart';
import 'package:sherpa/routing/routes.dart';
import 'package:sherpa/services/downloads/downloads.dart';
import 'package:sherpa_hub/sherpa_hub.dart';
import 'package:sherpa_hub/testing.dart';

import 'support/models_rig.dart';

/// Trending GGUF pages as they look live: the first pages are mostly
/// 20–30B models, so "Under 2B" matches nothing on page one.
List<CatalogEntry> trendingLike({int big = 30, int tiny = 15, int uncensored = 0}) => [
      for (var i = 0; i < big; i++) entry('acme/Big-27B-v$i-GGUF', toolUse: true),
      for (var i = 0; i < uncensored; i++) entry('acme/Big-27B-abliterated-v$i-GGUF'),
      for (var i = 0; i < tiny; i++) entry('acme/Tiny-1B-v$i-GGUF'),
    ];

/// Counts search calls.
final class CountingCatalog implements ModelCatalog {
  CountingCatalog(List<CatalogEntry> entries) : _inner = FixtureModelCatalog(entries: entries);

  final FixtureModelCatalog _inner;
  int searches = 0;

  @override
  String get id => _inner.id;

  @override
  Future<HubPage<CatalogEntry>> search(ModelSearchQuery query, {String? cursor}) {
    searches++;
    return _inner.search(query, cursor: cursor);
  }

  @override
  Future<CatalogModelDetails> details(String modelId, {String? revision}) => _inner.details(modelId, revision: revision);

  @override
  Future<List<CatalogFile>> files(String modelId, {required String revision}) => _inner.files(modelId, revision: revision);
}

ProviderContainer _container(ModelCatalog catalog) {
  final c = ProviderContainer(overrides: [
    modelCatalogProvider.overrideWithValue(catalog),
    modelRecordStoreProvider.overrideWithValue(InMemoryRecordStore()),
  ], retry: noRetry);
  addTearDown(c.dispose);
  c.listen(directoryControllerProvider, (_, _) {});
  return c;
}

Future<void> _settle(ProviderContainer c) async {
  for (var i = 0; i < 50; i++) {
    await pumpEventQueue();
    final s = c.read(directoryControllerProvider);
    if (!s.loading && !s.loadingMore) return;
  }
}

void main() {
  group('client-side filters page on', () {
    test('a size filter that matches nothing on the first page loads further pages until results show', () async {
      final catalog = CountingCatalog(trendingLike());
      final c = _container(catalog);
      await _settle(c);
      c.read(directoryControllerProvider.notifier).update((q) => q.copyWith(size: SizeBucket.tiny));
      await _settle(c);
      final s = c.read(directoryControllerProvider);
      expect(s.items, hasLength(15), reason: 'page one has no model under 2B; page two has 15');
      expect(s.items.every((e) => e.id.contains('Tiny')), isTrue);
    });

    test('paging stops after a bounded number of pages and says the Hub has more', () async {
      final catalog = CountingCatalog(trendingLike(big: 400, tiny: 0));
      final c = _container(catalog);
      await _settle(c);
      final before = catalog.searches;
      c.read(directoryControllerProvider.notifier).update((q) => q.copyWith(size: SizeBucket.tiny));
      await _settle(c);
      final s = c.read(directoryControllerProvider);
      expect(catalog.searches - before, 1 + DirectoryController.maxAutoPages);
      expect(s.items, isEmpty);
      expect(s.hasMore, isTrue);
      expect(s.hiddenByFilters, 30 * (1 + DirectoryController.maxAutoPages));
      expect(s.hiddenUncensored, 0);

      await c.read(directoryControllerProvider.notifier).loadMore();
      await _settle(c);
      expect(catalog.searches - before, 2 * (1 + DirectoryController.maxAutoPages) - 1);
    });
  });

  group('pasted Hugging Face links', () {
    test('search for the repo id, not the URL', () {
      for (final text in [
        'https://huggingface.co/Qwen/Qwen3-0.6B-GGUF',
        '  https://www.huggingface.co/Qwen/Qwen3-0.6B-GGUF/tree/main  ',
        'huggingface.co/Qwen/Qwen3-0.6B-GGUF?library=gguf',
        'https://hf.co/Qwen/Qwen3-0.6B-GGUF/blob/main/Qwen3-0.6B-Q8_0.gguf',
        'https://huggingface.co/models/Qwen/Qwen3-0.6B-GGUF',
        // The Hub's "Use this model" snippets (Ollama, llama.cpp -hf).
        'hf.co/Qwen/Qwen3-0.6B-GGUF:Q8_0',
        'Qwen/Qwen3-0.6B-GGUF:Q8_0',
      ]) {
        expect(DirectoryQuery(text: text).toSearch().text, 'Qwen/Qwen3-0.6B-GGUF', reason: text);
        expect(repoIdOf(text), 'Qwen/Qwen3-0.6B-GGUF', reason: text);
      }
      expect(DirectoryQuery(text: ' qwen 0.6b ').toSearch().text, 'qwen 0.6b');
      expect(repoIdOf('qwen 0.6b'), isNull);
      expect(repoIdOf('https://huggingface.co/Qwen'), isNull);
      expect(DirectoryQuery(text: 'https://huggingface.co/Qwen').toSearch().text, 'Qwen');
    });

    test('file links reduce to the repo, even with a download query', () {
      for (final text in [
        'https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/blob/main/Qwen3-0.6B-Q8_0.gguf',
        'https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q8_0.gguf?download=true',
        'huggingface.co/models/Qwen/Qwen3-0.6B-GGUF/resolve/main/sub/dir/model.gguf',
        'https://huggingface.co/Qwen/Qwen3-0.6B-GGUF#files',
      ]) {
        expect(DirectoryQuery(text: text).toSearch().text, 'Qwen/Qwen3-0.6B-GGUF', reason: text);
        expect(repoIdOf(text), 'Qwen/Qwen3-0.6B-GGUF', reason: text);
      }
      // A legacy id without an owner is not "gpt2/blob".
      expect(searchTextOf('https://huggingface.co/gpt2/blob/main/config.json'), 'gpt2');
      expect(repoIdOf('https://huggingface.co/gpt2/resolve/main/model.safetensors'), isNull);
    });

    test("the Hub's search page searches for its query", () {
      expect(searchTextOf('https://huggingface.co/models?search=qwen'), 'qwen');
      expect(searchTextOf('huggingface.co/models?library=gguf&search=qwen%203&sort=trending'), 'qwen 3');
      expect(repoIdOf('https://huggingface.co/models?search=qwen'), isNull);
      expect(searchTextOf('https://huggingface.co/models?search=Qwen/Qwen3-0.6B-GGUF'), 'Qwen/Qwen3-0.6B-GGUF');
      expect(searchTextOf('https://huggingface.co/models'), isNull, reason: 'no query: the default list');
      expect(searchTextOf('https://huggingface.co/models?library=gguf'), isNull);
    });

    test('Spaces and datasets are not models: their name is searched and never offered to open', () {
      for (final (text, name) in [
        ('https://huggingface.co/spaces/Qwen/Qwen3-Demo', 'Qwen3-Demo'),
        ('https://huggingface.co/spaces/ggml-org/gguf-my-repo/blob/main/app.py', 'gguf-my-repo'),
        ('huggingface.co/datasets/bartowski/calibration_datav3', 'calibration_datav3'),
        ('https://hf.co/datasets/acme/chat-logs/tree/main', 'chat-logs'),
      ]) {
        expect(DirectoryQuery(text: text).toSearch().text, name, reason: text);
        expect(repoIdOf(text), isNull, reason: 'no "Open spaces/…" row for $text');
      }
      expect(searchTextOf('https://huggingface.co/spaces?search=llama'), 'llama');
      expect(searchTextOf('https://huggingface.co/spaces'), isNull);
    });

    test("the Hub's own sections and pages are never repos: a name is searched, or nothing", () {
      for (final (text, search) in [
        ('https://huggingface.co/collections/Qwen/qwen3-67dd247413f0e2e4f8b75e43', 'qwen3'),
        ('https://huggingface.co/papers/2505.09388', '2505.09388'),
        ('https://huggingface.co/docs/hub/gguf', 'gguf'),
        ('https://huggingface.co/blog/gemma3', 'gemma3'),
        ('https://huggingface.co/organizations/Qwen/share/abc', 'Qwen'),
        ('https://huggingface.co/blog', null),
        // What the account screen's "Copy token page link" copies.
        ('https://huggingface.co/settings/tokens', null),
        ('huggingface.co/join', null),
      ]) {
        expect(searchTextOf(text), search, reason: text);
        expect(repoIdOf(text), isNull, reason: 'no "Open …" row for $text');
      }
      expect(repoIdOf('https://huggingface.co/api/models/Qwen/Qwen3-0.6B-GGUF'), 'Qwen/Qwen3-0.6B-GGUF');
    });

    test('a repo named like a path marker stays a repo; the marker counts only with a path after it', () {
      expect(repoIdOf('https://huggingface.co/someone/tree'), 'someone/tree');
      expect(repoIdOf('https://huggingface.co/someone/raw'), 'someone/raw');
      expect(repoIdOf('https://huggingface.co/someone/edit/blob/main/README.md'), 'someone/edit');
      expect(searchTextOf('https://huggingface.co/gpt2/tree/main'), 'gpt2');
    });
  });

  group('browse screen', () {
    testWidgets('a filter that hides a whole page offers "Search further" and names the filter that hid them',
        (tester) async {
      final rig = await ModelsRig.create(tester, entries: trendingLike(big: 400, tiny: 0, uncensored: 3));
      await rig.pump(tester, location: Routes.modelBrowse);
      await tester.tap(find.widgetWithText(FilterChip, 'Size'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Under 2B').last);
      await tester.pumpAndSettle();

      expect(find.text('No models match'), findsOneWidget);
      expect(find.textContaining("don't match the Under 2B size filter"), findsOneWidget);
      expect(find.textContaining('hidden by the content filter'), findsNothing,
          reason: 'the 3 uncensored ones are further down; nothing loaded so far was hidden by it');
      expect(find.text('Search further'), findsOneWidget);
      expect(find.text('Clear filters'), findsOneWidget);
      await tester.tap(find.text('Search further'));
      await tester.pumpAndSettle();
      expect(find.text('Search further'), findsOneWidget, reason: 'still nothing; still more on the Hub');
    });

    testWidgets('a pasted link finds the repo, and a repo id not in the results can be opened directly',
        (tester) async {
      final rig = await ModelsRig.create(tester);
      await rig.pump(tester, location: Routes.modelBrowse);
      await tester.enterText(find.byType(TextField).first, 'https://huggingface.co/$llama1b');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.byWidgetPredicate((w) => w is Text && (w.data ?? '').startsWith('Open ')), findsNothing,
          reason: 'the repo is in the results already');
      expect(find.textContaining('Llama 3.2'), findsWidgets);

      await tester.enterText(find.byType(TextField).first, 'https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/tree/main');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open Qwen/Qwen3-0.6B-GGUF'));
      await tester.pumpAndSettle();
      expect(find.byWidgetPredicate((w) => w is ModelDetailScreen && w.repoId == 'Qwen/Qwen3-0.6B-GGUF'), findsOneWidget,
          reason: "the repo's page");
    });

    testWidgets('a pasted search page searches its query; a Space link offers no repo to open', (tester) async {
      final rig = await ModelsRig.create(tester);
      await rig.pump(tester, location: Routes.modelBrowse);
      final openRow = find.byWidgetPredicate((w) => w is Text && (w.data ?? '').startsWith('Open '));

      await tester.enterText(find.byType(TextField).first, 'https://huggingface.co/models?search=gemma&library=gguf');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.textContaining('Gemma'), findsWidgets);
      expect(find.textContaining('Llama 3.2'), findsNothing, reason: 'the search, not the default list');
      expect(openRow, findsNothing);

      await tester.enterText(find.byType(TextField).first, 'https://huggingface.co/spaces/ggml-org/gemma-3-270m-it-GGUF');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(openRow, findsNothing, reason: 'a Space is not a model');
      expect(find.textContaining('Gemma'), findsWidgets, reason: 'models named like the Space');
    });
  });
}
