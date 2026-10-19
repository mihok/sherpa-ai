import 'dart:async';
import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_data/sherpa_data.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';

/// The slice of `JsonDocumentStore` the MCP feature uses.
///
/// An interface so tests run without SQLite, while production writes into
/// the encrypted database ([DocumentMcpRecords]). Nothing stored through it
/// is a secret: OAuth tokens live in the `SecretStore` only.
abstract interface class McpRecords {
  Future<JsonMap?> get(String collection, String id);

  Future<void> put(String collection, String id, JsonMap doc);

  Future<void> delete(String collection, String id);

  Future<List<JsonMap>> list(String collection);
}

/// [McpRecords] over the app's encrypted `JsonDocumentStore`.
final class DocumentMcpRecords implements McpRecords {
  DocumentMcpRecords(this._docs);

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

/// Volatile [McpRecords] for tests, previews and `bootstrap(inMemory: true)`.
final class InMemoryMcpRecords implements McpRecords {
  final Map<String, Map<String, String>> _data = {};

  @override
  Future<JsonMap?> get(String collection, String id) async {
    final raw = _data[collection]?[id];
    return raw == null ? null : (jsonDecode(raw) as Map).cast<String, Object?>();
  }

  @override
  Future<void> put(String collection, String id, JsonMap doc) async => (_data[collection] ??= {})[id] = jsonEncode(doc);

  @override
  Future<void> delete(String collection, String id) async => _data[collection]?.remove(id);

  @override
  Future<List<JsonMap>> list(String collection) async {
    final c = _data[collection];
    if (c == null) return const [];
    final ids = c.keys.toList()..sort();
    return [for (final id in ids) (jsonDecode(c[id]!) as Map).cast<String, Object?>()];
  }

  /// Ids stored in [collection] (tests).
  List<String> ids(String collection) => (_data[collection]?.keys.toList() ?? <String>[])..sort();
}

/// Runs writes one after another, so a later write of the same document
/// can never land before an earlier one.
final class _Serial {
  Future<void> _tail = Future.value();

  Future<void> run(Future<void> Function() job) {
    final next = _tail.then((_) => job());
    _tail = next.catchError((Object _) {});
    return next;
  }
}

// ---------------------------------------------------------------------------
// Server configs
// ---------------------------------------------------------------------------

/// How a server was added, for the server list and the debug console.
enum McpServerSource { url, registry, link, qr, builtIn }

/// What the app knows about a server besides its [McpServerConfig].
final class McpServerMeta {
  const McpServerMeta({required this.source, this.addedAt, this.registryName, this.description});

  factory McpServerMeta.fromJson(JsonMap j) => McpServerMeta(
        source: McpServerSource.values.where((s) => s.name == j['source']).firstOrNull ?? McpServerSource.url,
        addedAt: j.optDate('addedAt'),
        registryName: j.opt<String>('registryName'),
        description: j.opt<String>('description'),
      );

  final McpServerSource source;
  final DateTime? addedAt;

  /// The MCP Registry name (`io.github.owner/server`) when added from it.
  final String? registryName;

  /// Untrusted, display only (from the registry).
  final String? description;

  JsonMap toJson() => compact({
        'source': source.name,
        'addedAt': addedAt?.toUtc().toIso8601String(),
        'registryName': registryName,
        'description': description,
      });
}

/// Server configs, one document per server in [DocumentCollections.mcpServers]
/// (`config.toJson()` plus a `meta` object). Built-in servers are stored too,
/// so the user's on/off choice survives a restart.
final class McpServerConfigStore {
  McpServerConfigStore(this._records);

  final McpRecords _records;
  final _Serial _serial = _Serial();
  final Map<String, McpServerMeta> _meta = {};

  static const String _collection = DocumentCollections.mcpServers;

  /// Every stored config with its meta. Corrupt entries are skipped.
  Future<List<(McpServerConfig, McpServerMeta)>> load() async {
    final out = <(McpServerConfig, McpServerMeta)>[];
    for (final doc in await _records.list(_collection)) {
      try {
        final c = McpServerConfig.fromJson(doc);
        final m = doc['meta'] is Map ? McpServerMeta.fromJson((doc['meta']! as Map).cast()) : const McpServerMeta(source: McpServerSource.url);
        _meta[c.id] = m;
        out.add((c, m));
      } on Object {
        // A config written by a newer version, or damaged: ignore it.
      }
    }
    return out;
  }

  McpServerMeta? metaOf(String id) => _meta[id];

  Future<void> save(McpServerConfig config, {McpServerMeta? meta}) {
    if (meta != null) _meta[config.id] = meta;
    final m = _meta[config.id];
    return _serial.run(() => _records.put(_collection, config.id, {...config.toJson(), 'meta': ?m?.toJson()}));
  }

  Future<void> delete(String id) {
    _meta.remove(id);
    return _serial.run(() => _records.delete(_collection, id));
  }
}

// ---------------------------------------------------------------------------
// Tool pins
// ---------------------------------------------------------------------------

/// [ToolPinStore] over [DocumentCollections.mcpToolPins], one document per
/// pin keyed by `McpToolKey.encoded`, with an in-memory copy (hygiene reads
/// a server's pins on every `tools/list`).
final class DocumentToolPinStore implements ToolPinStore {
  DocumentToolPinStore(this._records);

  final McpRecords _records;
  final _Serial _serial = _Serial();
  Map<McpToolKey, ToolPin>? _cache;
  Future<Map<McpToolKey, ToolPin>>? _loading;

  static const String _collection = DocumentCollections.mcpToolPins;

  Future<Map<McpToolKey, ToolPin>> _all() {
    final c = _cache;
    if (c != null) return Future.value(c);
    return _loading ??= () async {
      final m = <McpToolKey, ToolPin>{};
      for (final doc in await _records.list(_collection)) {
        try {
          final p = ToolPin.fromJson(doc);
          m[p.key] = p;
        } on Object {
          // A damaged pin only costs a re-review of that tool.
        }
      }
      return _cache = m;
    }();
  }

  @override
  Future<ToolPin?> get(McpToolKey key) async => (await _all())[key];

  @override
  Future<List<ToolPin>> forServer(String serverId) async => [
        for (final p in (await _all()).values)
          if (p.key.serverId == serverId) p,
      ];

  @override
  Future<void> put(ToolPin pin) async {
    (await _all())[pin.key] = pin;
    await _serial.run(() => _records.put(_collection, pin.key.encoded, pin.toJson()));
  }

  @override
  Future<void> remove(McpToolKey key) async {
    (await _all()).remove(key);
    await _serial.run(() => _records.delete(_collection, key.encoded));
  }

  @override
  Future<void> removeServer(String serverId) async {
    final all = await _all();
    final keys = [for (final k in all.keys) if (k.serverId == serverId) k];
    for (final k in keys) {
      all.remove(k);
      await _serial.run(() => _records.delete(_collection, k.encoded));
    }
  }
}

// ---------------------------------------------------------------------------
// Tool switches
// ---------------------------------------------------------------------------

/// [ToolEnablement] whose switches (global and per session) are kept in
/// [DocumentCollections.mcpToolSettings] and announced on [changes].
///
/// Reads are synchronous (tool selection runs before every model step), so
/// the state lives in an [InMemoryToolEnablement] loaded once at start-up;
/// every change is written through.
final class PersistentToolEnablement implements ToolEnablement {
  PersistentToolEnablement._(this._records, this._state);

  static const String _collection = DocumentCollections.mcpToolSettings;
  static const String _doc = 'enablement';

  static Future<PersistentToolEnablement> load(McpRecords records) async {
    InMemoryToolEnablement state;
    try {
      final j = await records.get(_collection, _doc);
      state = j == null ? InMemoryToolEnablement() : InMemoryToolEnablement.fromJson(j);
    } on Object {
      state = InMemoryToolEnablement();
    }
    return PersistentToolEnablement._(records, state);
  }

  final McpRecords _records;
  final InMemoryToolEnablement _state;
  final _Serial _serial = _Serial();
  final StreamController<void> _changes = StreamController.broadcast(sync: true);

  Stream<void> get changes => _changes.stream;

  int get revision => _state.revision;

  @override
  bool isServerEnabled(String sessionId, String serverId) => _state.isServerEnabled(sessionId, serverId);

  @override
  bool isToolEnabled(String sessionId, String toolName) => _state.isToolEnabled(sessionId, toolName);

  @override
  bool isPinned(String sessionId, String toolName) => _state.isPinned(sessionId, toolName);

  /// The global default for [toolName] (no session override).
  bool isToolEnabledGlobally(String toolName) => _state.isToolEnabled('*', toolName);

  /// [enabled] null clears the override; [sessionId] null sets the default.
  Future<void> setServerEnabled(String serverId, bool? enabled, {String? sessionId}) =>
      _apply(() => _state.setServerEnabled(serverId, enabled, sessionId: sessionId));

  Future<void> setToolEnabled(String toolName, bool? enabled, {String? sessionId}) =>
      _apply(() => _state.setToolEnabled(toolName, enabled, sessionId: sessionId));

  Future<void> setPinned(String toolName, bool? pinned, {String? sessionId}) =>
      _apply(() => _state.setPinned(toolName, pinned, sessionId: sessionId));

  /// Drops every switch that names [serverId] or one of [toolNames] (a
  /// removed server), in every scope.
  Future<void> forgetServer(String serverId, Iterable<String> toolNames) {
    final j = _state.toJson();
    final names = toolNames.toSet();
    String? scope(Object? s) => s == '*' ? null : '$s';
    return _apply(() {
      for (final s in (j['servers'] as Map? ?? const {}).keys) {
        _state.setServerEnabled(serverId, null, sessionId: scope(s));
      }
      for (final s in (j['tools'] as Map? ?? const {}).keys) {
        for (final n in names) {
          _state.setToolEnabled(n, null, sessionId: scope(s));
        }
      }
      for (final s in (j['pinned'] as Map? ?? const {}).keys) {
        for (final n in names) {
          _state.setPinned(n, null, sessionId: scope(s));
        }
      }
    });
  }

  /// Drops a session's overrides (the session was deleted).
  Future<void> forgetSession(String sessionId) => _apply(() => _state.forgetSession(sessionId));

  Future<void> _apply(void Function() change) {
    change();
    _changes.add(null);
    final snapshot = _state.toJson();
    return _serial.run(() => _records.put(_collection, _doc, snapshot));
  }

  Future<void> dispose() => _changes.close();
}

// ---------------------------------------------------------------------------
// Approval grants
// ---------------------------------------------------------------------------

/// "Allow" grants of the app's `ApprovalPolicy`, as one document in
/// [DocumentCollections.approvalGrants]. Expired grants are dropped on load.
final class ApprovalGrantStore {
  ApprovalGrantStore(this._records, {Clock clock = const SystemClock()}) : _clock = clock;

  final McpRecords _records;
  final Clock _clock;
  final _Serial _serial = _Serial();

  static const String _collection = DocumentCollections.approvalGrants;
  static const String _doc = 'grants';

  Future<List<ApprovalGrant>> load() async {
    try {
      final j = await _records.get(_collection, _doc);
      final now = _clock.now();
      return [
        for (final g in (j?['grants'] as List?) ?? const [])
          if (g is Map)
            if (_tryGrant(g.cast<String, Object?>()) case final grant? when grant.expiresAt == null || now.isBefore(grant.expiresAt!))
              grant,
      ];
    } on Object {
      return const [];
    }
  }

  static ApprovalGrant? _tryGrant(JsonMap j) {
    try {
      return ApprovalGrant.fromJson(j);
    } on Object {
      return null;
    }
  }

  /// Persists [grants] (wire to `ApprovalPolicy.onGrantsChanged`). Only
  /// lasting grants are worth keeping: "once" grants are never recorded.
  Future<void> save(List<ApprovalGrant> grants) {
    final doc = {
      'grants': [for (final g in grants) g.toJson()],
    };
    return _serial.run(() => _records.put(_collection, _doc, doc));
  }
}

// ---------------------------------------------------------------------------
// Memory notes
// ---------------------------------------------------------------------------

/// The built-in memory server's [NoteStorage] over the document store, one
/// document per key in [DocumentCollections.memoryNotes]. Notes are user
/// data (encrypted at rest with the rest of the database).
final class DocumentNoteStorage implements NoteStorage {
  DocumentNoteStorage(this._records);

  final McpRecords _records;
  final _Serial _serial = _Serial();

  static const String _collection = DocumentCollections.memoryNotes;

  @override
  Future<String?> read(String key) async => (await _records.get(_collection, key))?['value'] as String?;

  @override
  Future<void> write(String key, String value) => _serial.run(() => _records.put(_collection, key, {'key': key, 'value': value}));

  @override
  Future<void> delete(String key) => _serial.run(() => _records.delete(_collection, key));

  @override
  Future<List<String>> keys({String prefix = ''}) async => [
        for (final d in await _records.list(_collection))
          if (d['key'] case final String k when k.startsWith(prefix)) k,
      ];
}
