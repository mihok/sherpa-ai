import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_data/sherpa_data.dart';

/// The slice of `JsonDocumentStore` the model services use.
///
/// An interface so unit and widget tests can run without SQLite (drift's
/// stream queries keep timers alive that `testWidgets` reports as leaks),
/// while production writes into the encrypted database
/// ([JsonDocumentRecordStore]). Documents never contain secrets: no HF
/// token, no signed CDN URL (see `DownloadJob.toJson`).
abstract interface class ModelRecordStore {
  Future<JsonMap?> get(String collection, String id);

  Future<void> put(String collection, String id, JsonMap doc);

  Future<void> delete(String collection, String id);

  Future<List<JsonMap>> list(String collection);
}

/// [ModelRecordStore] over the app's encrypted `JsonDocumentStore`.
final class JsonDocumentRecordStore implements ModelRecordStore {
  JsonDocumentRecordStore(this._docs);

  final JsonDocumentStore _docs;

  @override
  Future<JsonMap?> get(String collection, String id) => _docs.get(collection, id);

  @override
  Future<void> put(String collection, String id, JsonMap doc) => _docs.put(collection, id, doc);

  @override
  Future<void> delete(String collection, String id) => _docs.delete(collection, id);

  @override
  Future<List<JsonMap>> list(String collection) => _docs.list(collection);
}

/// Volatile store for tests, previews and `bootstrap(inMemory: true)`.
final class InMemoryRecordStore implements ModelRecordStore {
  final Map<String, Map<String, JsonMap>> _data = {};

  /// Every write, for tests that assert what reached "disk".
  final List<(String collection, String id, JsonMap doc)> writes = [];

  @override
  Future<JsonMap?> get(String collection, String id) async => _copy(_data[collection]?[id]);

  @override
  Future<void> put(String collection, String id, JsonMap doc) async {
    final c = _copy(doc)!;
    (_data[collection] ??= {})[id] = c;
    writes.add((collection, id, c));
  }

  @override
  Future<void> delete(String collection, String id) async => _data[collection]?.remove(id);

  @override
  Future<List<JsonMap>> list(String collection) async {
    final c = _data[collection];
    if (c == null) return const [];
    final ids = c.keys.toList()..sort();
    return [for (final id in ids) _copy(c[id])!];
  }

  // Round-trip through JSON-like copies so callers can't mutate stored maps
  // (the real store serializes too).
  static JsonMap? _copy(JsonMap? m) => m == null ? null : _deep(m) as JsonMap;

  static Object? _deep(Object? v) => switch (v) {
        final Map<Object?, Object?> m => <String, Object?>{for (final e in m.entries) '${e.key}': _deep(e.value)},
        final List<Object?> l => [for (final e in l) _deep(e)],
        _ => v,
      };
}

/// Ids of the documents the model feature keeps in
/// [DocumentCollections.preferences].
abstract final class ModelPreferenceIds {
  /// Wi-Fi-only policy, trusted quantizers, content filter.
  static const models = 'models';

  /// Display profile of the signed-in Hugging Face user (never the token).
  static const hubAccount = 'hub_account';
}
