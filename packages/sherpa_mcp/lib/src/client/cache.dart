/// `ttlMs` / `cacheScope` result caching (server/utilities/caching.md).
library;

import 'package:sherpa_core/sherpa_core.dart' show Clock;

/// One cached value: fresh while `now < fetchedAt + ttl`.
final class CacheEntry<T> {
  CacheEntry(this.value, {required this.fetchedAt, required this.ttl, required this.isPrivate});

  final T value;
  final DateTime fetchedAt;
  final Duration ttl;

  /// `cacheScope: "private"`: valid for one authorization context only.
  final bool isPrivate;

  bool isFresh(DateTime now) => now.isBefore(fetchedAt.add(ttl));
}

/// Per-connection cache keyed by method + result-affecting params.
///
/// Rules applied by the connection: absent or negative `ttlMs` is 0
/// (immediately stale); `input_required` results and MRTR retries are
/// never stored; `list_changed` invalidates at once; `private` entries are
/// dropped when the credential changes ([dropPrivate]). The cache is
/// never shared across connections, so `public` needs no extra handling.
final class ResultCache {
  ResultCache(this._clock);

  final Clock _clock;
  final Map<String, CacheEntry<Object>> _entries = {};

  /// The entry under [key] whether fresh or stale (stale-on-error).
  CacheEntry<T>? entry<T extends Object>(String key) {
    final e = _entries[key];
    return e is CacheEntry<T> ? e : null;
  }

  /// The value under [key] if still fresh.
  T? fresh<T extends Object>(String key) {
    final e = entry<T>(key);
    return e != null && e.isFresh(_clock.now()) ? e.value : null;
  }

  /// A zero [ttl] entry is never fresh but is remembered for stale-on-error.
  void put<T extends Object>(String key, T value, {required Duration ttl, required bool isPrivate}) =>
      _entries[key] = CacheEntry<T>(
        value,
        fetchedAt: _clock.now(),
        ttl: ttl.isNegative ? Duration.zero : ttl,
        isPrivate: isPrivate,
      );

  void invalidate(String key) => _entries.remove(key);

  void invalidateWhere(bool Function(String key) test) => _entries.removeWhere((k, _) => test(k));

  void dropPrivate() => _entries.removeWhere((_, e) => e.isPrivate);

  void clear() => _entries.clear();
}
