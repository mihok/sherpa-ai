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
  });
}
