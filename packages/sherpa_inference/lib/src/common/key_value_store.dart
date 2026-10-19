import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sherpa_core/sherpa_core.dart';

/// Small persistent key-value store for profiles and lifecycle notes
/// (autotune results, crash downgrades). The app maps it onto
/// `sherpa_data`'s `JsonDocumentStore`; tests use [InMemoryKeyValueStore].
abstract interface class KeyValueStore {
  Future<JsonMap?> read(String key);

  Future<void> write(String key, JsonMap value);

  Future<void> delete(String key);
}

final class InMemoryKeyValueStore implements KeyValueStore {
  final Map<String, String> _data = {};

  Map<String, String> get raw => Map.unmodifiable(_data);

  @override
  Future<JsonMap?> read(String key) async {
    final v = _data[key];
    return v == null ? null : (jsonDecode(v) as Map).cast<String, Object?>();
  }

  @override
  Future<void> write(String key, JsonMap value) async => _data[key] = jsonEncode(value);

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

/// A JSON-file-backed store (one file, rewritten atomically); handy for host
/// tools and as a fallback when no database is wired.
final class JsonFileKeyValueStore implements KeyValueStore {
  JsonFileKeyValueStore(this.file);

  final File file;
  Map<String, Object?>? _cache;
  Future<void> _tail = Future.value();

  Future<Map<String, Object?>> _load() async {
    final c = _cache;
    if (c != null) return c;
    try {
      final text = await file.readAsString();
      return _cache = (jsonDecode(text) as Map).cast<String, Object?>();
    } on Object {
      return _cache = <String, Object?>{};
    }
  }

  Future<void> _save(Map<String, Object?> data) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(data), flush: true);
    await tmp.rename(file.path);
  }

  Future<T> _serial<T>(Future<T> Function() op) {
    final next = _tail.then((_) => op());
    _tail = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  @override
  Future<JsonMap?> read(String key) => _serial(() async {
        final v = (await _load())[key];
        return v is Map ? v.cast<String, Object?>() : null;
      });

  @override
  Future<void> write(String key, JsonMap value) => _serial(() async {
        final d = await _load();
        d[key] = value;
        await _save(d);
      });

  @override
  Future<void> delete(String key) => _serial(() async {
        final d = await _load();
        if (d.remove(key) != null) await _save(d);
      });
}
