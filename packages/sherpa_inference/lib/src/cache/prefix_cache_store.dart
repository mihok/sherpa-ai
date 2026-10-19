import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_core/sherpa_core.dart';

import '../engine/engine_host.dart';
import '../engine/engine_types.dart';
import '../ffi/bindings.dart';

const int _mib = 1024 * 1024;

/// Identity of one persisted KV prefix.
///
/// Everything here must match for a state file to be usable: the engine
/// refuses files from another model, LoRA set, KV type or flash-attention
/// layout and files larger than the session's n_ctx (se_state_load,
/// SE_ERR_STATE_MISMATCH); llama.cpp itself validates only layer count,
/// cell count, K/V types and V layout (R04 §13), so the key is strict on
/// purpose and the engine's header check is the second line of defence.
///
/// **The draft model is deliberately not part of the key.** A state file
/// holds the target context's KV (sequence 0) and token history only
/// (`se_state_save`, native/engine/src/se_state.cpp); the draft context's KV
/// is never written, and the identity header the engine checks on load
/// (`state_identity`: model id and fingerprint, shape, KV types, flash
/// attention, SWA, LoRA set, and the projector when one is loaded) has no
/// draft field. The target's KV for a token prefix does not depend on the
/// draft either: drafted tokens are verified by the target, and the history
/// holds only accepted ones. So a prefix saved while drafting restores into
/// a session without a draft model and back (tested against the real engine),
/// and keying on the draft would only turn a toggle of speculative decoding
/// into a cache miss. One cost remains: after a restore the draft context
/// starts empty, and the engine keeps target and draft in lockstep, so a
/// *speculative* reply re-prefills the prompt (the restored KV is reused only
/// by a request with `speculative: false`).
@immutable
final class PrefixCacheKey {
  const PrefixCacheKey({
    required this.sessionId,
    required this.modelId,
    required this.nCtx,
    required this.kvLayout,
    this.loraSet = '',
  });

  factory PrefixCacheKey.fromJson(JsonMap j) => PrefixCacheKey(
        sessionId: j.req<String>('sessionId'),
        modelId: j.req<String>('modelId'),
        nCtx: j.req<num>('nCtx').toInt(),
        kvLayout: j.req<String>('kvLayout'),
        loraSet: j.opt<String>('loraSet') ?? '',
      );

  /// The conversation (core session id).
  final String sessionId;

  /// Model identity (`se_model_params.model_id`, e.g. sha256 of the GGUF).
  final String modelId;

  /// The session's resolved n_ctx.
  final int nCtx;

  /// `type_k/type_v` (+ `fa` when flash attention is on), e.g. `q8_0/q8_0+fa`.
  final String kvLayout;

  /// Canonical adapter set, e.g. `sha256:…@1.0,sha256:…@0.5`; empty = none.
  final String loraSet;

  /// File-name-safe digest of the key.
  String get digest => sha256.convert(utf8.encode(jsonEncode(toJson()))).toString().substring(0, 40);

  JsonMap toJson() => {
        'sessionId': sessionId,
        'modelId': modelId,
        'nCtx': nCtx,
        'kvLayout': kvLayout,
        'loraSet': loraSet,
      };

  @override
  bool operator ==(Object other) => other is PrefixCacheKey && other.digest == digest;

  @override
  int get hashCode => digest.hashCode;
}

/// Fingerprint of the prompt prefix a state file contains: one hash for the
/// tool block, then one per engine message, in order. A state file is valid
/// for a new request only if its fingerprint is a prefix of the request's
/// (the transcript was only appended to); otherwise the cached KV belongs to
/// a conversation that was edited, branched or compacted.
abstract final class PrefixFingerprint {
  static List<String> of({required List<JsonMap> messages, List<Object?> tools = const []}) => [
        _h(jsonEncode(tools)),
        for (final m in messages) _h(jsonEncode(m)),
      ];

  static bool isPrefix(List<String> prefix, List<String> of) {
    if (prefix.length > of.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (prefix[i] != of[i]) return false;
    }
    return true;
  }

  static String _h(String s) => sha256.convert(utf8.encode(s)).toString().substring(0, 24);
}

@immutable
final class PrefixCacheEntry {
  const PrefixCacheEntry({
    required this.key,
    required this.fileName,
    required this.bytes,
    required this.fingerprint,
    required this.savedAt,
    required this.lastUsedAt,
  });

  factory PrefixCacheEntry.fromJson(JsonMap j) => PrefixCacheEntry(
        key: PrefixCacheKey.fromJson(j.obj('key')),
        fileName: j.req<String>('file'),
        bytes: j.req<num>('bytes').toInt(),
        fingerprint: (j.opt<List<Object?>>('fingerprint') ?? const []).cast<String>(),
        savedAt: DateTime.parse(j.req<String>('savedAt')),
        lastUsedAt: DateTime.parse(j.req<String>('lastUsedAt')),
      );

  final PrefixCacheKey key;
  final String fileName;
  final int bytes;
  final List<String> fingerprint;
  final DateTime savedAt;
  final DateTime lastUsedAt;

  PrefixCacheEntry touched(DateTime at) => PrefixCacheEntry(
      key: key, fileName: fileName, bytes: bytes, fingerprint: fingerprint, savedAt: savedAt, lastUsedAt: at);

  JsonMap toJson() => {
        'key': key.toJson(),
        'file': fileName,
        'bytes': bytes,
        'fingerprint': fingerprint,
        'savedAt': savedAt.toUtc().toIso8601String(),
        'lastUsedAt': lastUsedAt.toUtc().toIso8601String(),
      };
}

enum PrefixRestoreOutcome {
  restored,
  notFound,

  /// The transcript changed since the save; the file was deleted.
  invalidated,

  /// The engine refused the file (another model build, KV layout, larger
  /// context); the file was deleted.
  mismatch,
}

@immutable
final class PrefixRestoreResult {
  const PrefixRestoreResult(this.outcome, {this.tokens = 0, this.entry});

  final PrefixRestoreOutcome outcome;
  final int tokens;
  final PrefixCacheEntry? entry;

  bool get restored => outcome == PrefixRestoreOutcome.restored;
}

/// Persists session KV state (`se_state_save` / `se_state_load`) so a
/// conversation resumed after a model switch, an unload under memory
/// pressure, backgrounding or a relaunch skips its prefill.
///
/// Files live in an injected cache directory (the app passes its
/// caches/`Library/Caches` directory: the OS may purge it, which is fine —
/// a missing file is a cache miss). An LRU budget bounds the total size.
///
/// **Default budget: 1 GiB, at most 12 files.** A state file holds the KV
/// of every cached token: Qwen3-0.6B costs 112 KiB/token in f16 and
/// 59.5 KiB/token in q8_0 (R04 §6), so a full 8k context of a 4B model in
/// q8_0 is ~0.6 GB, while typical chats (1–3k tokens of a 1–4B model in
/// q8_0) are 60–300 MB. 1 GiB keeps the last few conversations of the
/// active model without becoming a noticeable share of a phone's storage;
/// a single state larger than half the budget is not kept at all.
final class PrefixCacheStore {
  PrefixCacheStore({
    required this.directory,
    this.budgetBytes = defaultBudgetBytes,
    this.maxEntries = 12,
    Clock clock = const SystemClock(),
  }) : _clock = clock;

  static const int defaultBudgetBytes = 1024 * _mib;

  final Directory directory;
  final int budgetBytes;
  final int maxEntries;
  final Clock _clock;

  final Map<String, PrefixCacheEntry> _entries = {};
  bool _opened = false;
  Future<void> _tail = Future.value();

  File get _indexFile => File(p.join(directory.path, 'index.json'));

  List<PrefixCacheEntry> get entries => _entries.values.toList()..sort((a, b) => a.lastUsedAt.compareTo(b.lastUsedAt));

  int get totalBytes => _entries.values.fold(0, (n, e) => n + e.bytes);

  PrefixCacheEntry? entryFor(PrefixCacheKey key) => _entries[key.digest];

  Future<T> _serial<T>(Future<T> Function() op) {
    final next = _tail.then((_) => op());
    _tail = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  /// Loads the index and removes files it does not know (crashed saves,
  /// temp files).
  Future<void> open() => _serial(_open);

  Future<void> _open() async {
    if (_opened) return;
    await directory.create(recursive: true);
    try {
      final j = (jsonDecode(await _indexFile.readAsString()) as Map).cast<String, Object?>();
      for (final e in j.mapList('entries')) {
        final entry = PrefixCacheEntry.fromJson(e);
        if (await File(p.join(directory.path, entry.fileName)).exists()) _entries[entry.key.digest] = entry;
      }
    } on Object {
      // No or unreadable index: start empty.
    }
    final known = {for (final e in _entries.values) e.fileName, 'index.json'};
    await for (final f in directory.list()) {
      if (f is File && !known.contains(p.basename(f.path))) await f.delete().catchError((Object _) => f);
    }
    _opened = true;
  }

  Future<void> _writeIndex() async {
    final tmp = File('${_indexFile.path}.tmp');
    await tmp.writeAsString(jsonEncode({'entries': [for (final e in _entries.values) e.toJson()]}), flush: true);
    await tmp.rename(_indexFile.path);
  }

  /// Saves [session]'s KV under [key] with the [fingerprint] of what it
  /// contains, then evicts least-recently-used files over the budget.
  /// Returns null when the state is too large to keep.
  Future<PrefixCacheEntry?> save(EngineHost host, SessionRef session, PrefixCacheKey key, List<String> fingerprint) =>
      _serial(() async {
        await _open();
        final name = '${key.digest}.kv';
        final path = p.join(directory.path, name);
        final bytes = await host.saveState(session, path);
        if (bytes > budgetBytes ~/ 2) {
          await _deleteFile(name);
          _entries.remove(key.digest);
          await _writeIndex();
          return null;
        }
        final now = _clock.now();
        final entry = PrefixCacheEntry(
            key: key, fileName: name, bytes: bytes, fingerprint: fingerprint, savedAt: now, lastUsedAt: now);
        _entries[key.digest] = entry;
        await _evict(keep: key.digest);
        await _writeIndex();
        return entry;
      });

  /// Restores the state saved under [key] into [session] if its fingerprint
  /// is a prefix of [requestFingerprint].
  Future<PrefixRestoreResult> restore(
    EngineHost host,
    SessionRef session,
    PrefixCacheKey key,
    List<String> requestFingerprint,
  ) =>
      _serial(() async {
        await _open();
        final e = _entries[key.digest];
        if (e == null) return const PrefixRestoreResult(PrefixRestoreOutcome.notFound);
        if (!PrefixFingerprint.isPrefix(e.fingerprint, requestFingerprint)) {
          await _drop(e);
          return const PrefixRestoreResult(PrefixRestoreOutcome.invalidated);
        }
        try {
          final n = await host.loadState(session, p.join(directory.path, e.fileName));
          final t = e.touched(_clock.now());
          _entries[key.digest] = t;
          await _writeIndex();
          return PrefixRestoreResult(PrefixRestoreOutcome.restored, tokens: n, entry: t);
        } on EngineException catch (err) {
          if (err.code == SeStatus.stateMismatch || err.code == SeStatus.io || err.code == SeStatus.invalidArg) {
            await _drop(e);
            return const PrefixRestoreResult(PrefixRestoreOutcome.mismatch);
          }
          rethrow;
        }
      });

  /// Drops the entry for [key] (e.g. the conversation was edited).
  Future<void> invalidate(PrefixCacheKey key) => _serial(() async {
        await _open();
        final e = _entries[key.digest];
        if (e != null) await _drop(e);
      });

  /// Drops every entry of a conversation (deleted chat, privacy wipe).
  Future<void> invalidateSession(String sessionId) => _serial(() async {
        await _open();
        for (final e in _entries.values.where((e) => e.key.sessionId == sessionId).toList()) {
          await _drop(e);
        }
      });

  Future<void> clear() => _serial(() async {
        await _open();
        for (final e in _entries.values.toList()) {
          await _drop(e);
        }
      });

  Future<void> _drop(PrefixCacheEntry e) async {
    _entries.remove(e.key.digest);
    await _deleteFile(e.fileName);
    await _writeIndex();
  }

  Future<void> _evict({required String keep}) async {
    final lru = entries; // oldest first
    var total = totalBytes;
    var count = _entries.length;
    for (final e in lru) {
      if (total <= budgetBytes && count <= maxEntries) break;
      if (e.key.digest == keep) continue;
      _entries.remove(e.key.digest);
      await _deleteFile(e.fileName);
      total -= e.bytes;
      count--;
    }
  }

  Future<void> _deleteFile(String name) async {
    final f = File(p.join(directory.path, name));
    try {
      if (await f.exists()) await f.delete();
    } on FileSystemException {
      // Already gone or the cache directory was purged: nothing to do.
    }
  }
}
