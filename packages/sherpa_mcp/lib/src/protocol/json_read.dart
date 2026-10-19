/// Lenient readers for untrusted server JSON (internal).
///
/// Servers are untrusted: a wrong-typed optional field is dropped rather
/// than failing the whole result, while a missing or wrong-typed REQUIRED
/// field throws [FormatError] so the caller can drop that one item.
library;

import 'package:sherpa_core/sherpa_core.dart' show FormatError, JsonMap;

JsonMap? asMap(Object? v) => v is Map ? v.cast<String, Object?>() : null;

String? asString(Object? v) => v is String ? v : null;

bool? asBool(Object? v) => v is bool ? v : null;

int? asInt(Object? v) => v is int ? v : (v is double && v.isFinite && v == v.truncateToDouble() ? v.toInt() : null);

double? asDouble(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

List<Object?> asList(Object? v) => v is List ? v : const [];

List<JsonMap> mapList(Object? v) => [
      for (final e in asList(v))
        if (e is Map) e.cast<String, Object?>(),
    ];

List<String> stringList(Object? v) => [
      for (final e in asList(v))
        if (e is String) e,
    ];

String reqString(JsonMap j, String key, String what) {
  final v = j[key];
  if (v is String) return v;
  throw FormatError('$what: "$key" must be a string');
}

JsonMap reqMap(JsonMap j, String key, String what) {
  final v = j[key];
  if (v is Map) return v.cast<String, Object?>();
  throw FormatError('$what: "$key" must be an object');
}
