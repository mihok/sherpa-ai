import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart' show KeyValueStore;

import 'perf_models.dart';

/// The last [limit] benchmark runs per model, in the engine's notes store
/// (`LocalInference.store`: the `inference` document collection, which
/// "Delete all data" clears). Holds measurements only, no user content.
final class PerfHistory {
  PerfHistory(this._store, {this.limit = 10});

  final KeyValueStore _store;
  final int limit;

  static String key(String modelId) => 'sherpa.perf.history.$modelId';

  /// Oldest first.
  Future<List<BenchRun>> list(String modelId) async {
    final j = await _store.read(key(modelId));
    final runs = <BenchRun>[];
    for (final r in j?.opt<List<Object?>>('runs') ?? const <Object?>[]) {
      if (r is! Map) continue;
      try {
        runs.add(BenchRun.fromJson(r.cast<String, Object?>()));
      } on Object {
        // A record from another app version: skip it.
      }
    }
    return runs;
  }

  /// Appends [run], dropping the oldest beyond [limit]. Returns the list.
  Future<List<BenchRun>> add(String modelId, BenchRun run) async {
    final runs = [...await list(modelId), run];
    final kept = runs.length > limit ? runs.sublist(runs.length - limit) : runs;
    await _store.write(key(modelId), {
      'runs': [for (final r in kept) r.toJson()],
    });
    return kept;
  }

  Future<void> clear(String modelId) => _store.delete(key(modelId));
}
