import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_data/sherpa_data.dart' show DocumentCollections;
import 'package:sherpa_inference/sherpa_inference.dart' show KeyValueStore;

import '../downloads/record_store.dart';

/// `sherpa_inference`'s [KeyValueStore] (autotune profiles, crash
/// downgrades) over the app's [ModelRecordStore]: the encrypted
/// `JsonDocumentStore` in production, memory in tests and
/// `bootstrap(inMemory: true)`.
///
/// One document per key in [DocumentCollections.inference], shaped
/// `{key, value}` so [clear] can find every key again.
final class RecordKeyValueStore implements KeyValueStore {
  RecordKeyValueStore(this._records, {this.collection = DocumentCollections.inference});

  final ModelRecordStore _records;
  final String collection;

  @override
  Future<JsonMap?> read(String key) async {
    final doc = await _records.get(collection, key);
    final value = doc?['value'];
    return value is Map ? value.cast<String, Object?>() : null;
  }

  @override
  Future<void> write(String key, JsonMap value) => _records.put(collection, key, {'key': key, 'value': value});

  @override
  Future<void> delete(String key) => _records.delete(collection, key);

  /// Removes every key ("Delete all data").
  Future<void> clear() async {
    for (final doc in await _records.list(collection)) {
      final key = doc['key'];
      if (key is String) await _records.delete(collection, key);
    }
  }
}
