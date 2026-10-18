import 'package:drift/drift.dart';
import 'package:sherpa_core/sherpa_core.dart';

import 'codec.dart';
import 'database/database.dart';

/// Collection names used by the app. One place, so two features cannot
/// pick the same name by accident.
abstract final class DocumentCollections {
  /// Configured model providers (endpoint, kind, quirks; never the API key).
  static const providerConfigs = 'provider_configs';

  /// App preferences (default model, onboarding state, toggles).
  static const preferences = 'preferences';

  /// Local models the user has added or downloaded.
  static const modelLibrary = 'model_library';

  /// Configured MCP servers (never their OAuth tokens).
  static const mcpServers = 'mcp_servers';

  /// Download records (pinned revision, progress, verification state).
  static const downloads = 'downloads';
}

/// A small keyed JSON store over the `documents` table, for app records
/// that are read and written whole and are too few to deserve a table each.
///
/// Documents are stored verbatim (`jsonEncode`), so anything a type's
/// hand-written `toJson()` produces round-trips. They are encrypted at rest
/// with the rest of the database, but secrets (API keys, OAuth tokens)
/// still belong in the `SecretStore`, never here: database contents end up
/// in exports, handoff bundles and debug dumps.
///
/// Callers that need the id back from [list] or [watch] keep it inside the
/// document as well.
final class JsonDocumentStore {
  JsonDocumentStore(this._db, {Clock clock = const SystemClock()}) : _clock = clock;

  final SherpaDatabase _db;
  final Clock _clock;

  Future<JsonMap?> get(String collection, String id) async {
    final row = await (_db.select(_db.documents)
          ..where((t) => t.collection.equals(collection) & t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : decodeJsonObject(row.json);
  }

  /// Inserts or replaces the document. Durable when the future completes.
  Future<void> put(String collection, String id, JsonMap doc) async {
    if (collection.isEmpty || id.isEmpty) {
      throw ArgumentError('collection and id must not be empty');
    }
    await _db.into(_db.documents).insertOnConflictUpdate(DocumentsCompanion.insert(
          collection: collection,
          id: id,
          json: encodeJson(doc),
          updatedAt: toMicros(_clock.now()),
        ));
  }

  Future<void> delete(String collection, String id) async {
    await (_db.delete(_db.documents)
          ..where((t) => t.collection.equals(collection) & t.id.equals(id)))
        .go();
  }

  /// All documents of [collection], ordered by id: stable, so a list in
  /// the UI does not reshuffle when one entry is touched.
  Future<List<JsonMap>> list(String collection) async =>
      _decodeAll(await _jsonOf(collection).get());

  /// [list] now and after every change to [collection].
  ///
  /// Drift re-runs the query on any write to the `documents` table; results
  /// are compared as raw JSON first, so writes to other collections (and
  /// rewrites with identical content) do not re-emit or re-decode.
  Stream<List<JsonMap>> watch(String collection) =>
      _jsonOf(collection).watch().distinct(_sameStrings).map(_decodeAll);

  Selectable<String> _jsonOf(String collection) {
    final t = _db.documents;
    return (_db.selectOnly(t)
          ..addColumns([t.json])
          ..where(t.collection.equals(collection))
          ..orderBy([OrderingTerm.asc(t.id)]))
        .map((row) => row.read(t.json)!);
  }

  static List<JsonMap> _decodeAll(List<String> rows) => [for (final s in rows) decodeJsonObject(s)];

  static bool _sameStrings(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
