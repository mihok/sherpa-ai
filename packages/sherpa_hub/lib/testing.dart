/// Test doubles for code that depends on sherpa_hub.
library;

import 'sherpa_hub.dart';

/// In-memory [ModelCatalog] (PLAN §2: "fixture catalog").
final class FixtureModelCatalog implements ModelCatalog {
  FixtureModelCatalog({required this.entries, this.detailsById = const {}, this.filesById = const {}});

  final List<CatalogEntry> entries;
  final Map<String, CatalogModelDetails> detailsById;
  final Map<String, List<CatalogFile>> filesById;

  @override
  String get id => 'fixture';

  @override
  Future<HubPage<CatalogEntry>> search(ModelSearchQuery query, {String? cursor}) async {
    final text = query.text?.toLowerCase();
    final authors = query.authors.map((a) => a.toLowerCase()).toSet();
    final hits = [
      for (final e in entries)
        if ((text == null || e.id.toLowerCase().contains(text)) &&
            (authors.isEmpty || authors.contains(e.name.owner.toLowerCase())) &&
            (query.format == null || e.tags.contains(query.format!.tag)) &&
            (query.quantizedFrom == null || e.tags.contains('base_model:quantized:${query.quantizedFrom}')))
          e,
    ];
    final start = cursor == null ? 0 : int.parse(cursor);
    final end = (start + query.limit).clamp(0, hits.length);
    return HubPage(hits.sublist(start, end), nextCursor: end < hits.length ? '$end' : null);
  }

  @override
  Future<CatalogModelDetails> details(String modelId, {String? revision}) async {
    final d = detailsById[modelId];
    if (d == null) throw StateError('no fixture for $modelId');
    return d;
  }

  @override
  Future<List<CatalogFile>> files(String modelId, {required String revision}) async => filesById[modelId] ?? const [];
}
