/// Small helpers for hand-written, codegen-free JSON (de)serialization.
///
/// The core avoids build_runner so it stays trivially portable; every type
/// that crosses persistence or a handoff bundle has explicit toJson/fromJson.
library;

typedef JsonMap = Map<String, Object?>;

/// Thrown when persisted or imported JSON does not match the expected shape.
final class FormatError implements Exception {
  const FormatError(this.message);

  final String message;

  @override
  String toString() => 'FormatError: $message';
}

extension JsonMapRead on JsonMap {
  T req<T>(String key) {
    final v = this[key];
    if (v is T) return v;
    throw FormatError('expected "$key" to be $T, got ${v.runtimeType}');
  }

  T? opt<T>(String key) {
    final v = this[key];
    if (v == null || v is T) return v as T?;
    throw FormatError('expected "$key" to be $T?, got ${v.runtimeType}');
  }

  JsonMap obj(String key) => (req<Map<Object?, Object?>>(key)).cast<String, Object?>();

  JsonMap? optObj(String key) => opt<Map<Object?, Object?>>(key)?.cast<String, Object?>();

  List<JsonMap> mapList(String key) => (opt<List<Object?>>(key) ?? const [])
      .map((e) => (e as Map<Object?, Object?>).cast<String, Object?>())
      .toList();

  int? optInt(String key) => (opt<num>(key))?.toInt();

  double? optDouble(String key) => (opt<num>(key))?.toDouble();

  DateTime? optDate(String key) {
    final s = opt<String>(key);
    return s == null ? null : DateTime.parse(s);
  }
}

/// Drops null values so serialized objects stay compact and diff-friendly.
JsonMap compact(JsonMap m) => {
      for (final e in m.entries)
        if (e.value != null) e.key: e.value,
    };

/// Deep-converts decoded JSON (`Map<dynamic,dynamic>`) into [JsonMap]s.
Object? normalizeJson(Object? v) => switch (v) {
      Map<Object?, Object?>() => {
          for (final e in v.entries) e.key.toString(): normalizeJson(e.value),
        },
      List<Object?>() => [for (final e in v) normalizeJson(e)],
      _ => v,
    };
