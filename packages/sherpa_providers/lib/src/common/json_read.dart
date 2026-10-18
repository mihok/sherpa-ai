import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';

/// Lenient readers for JSON that comes from model servers.
///
/// `sherpa_core`'s `req`/`opt` throw [FormatError] on a type mismatch, which
/// is right for Sherpa's own persisted data. Server payloads are another
/// matter: compat servers send `code` as an int or a string, `null` where a
/// list is documented, or extra wrapper objects. A provider must keep
/// streaming through such noise, so these readers return `null` instead of
/// throwing and leave the decision to the caller.
extension LenientJson on JsonMap {
  String? str(String key) {
    final v = this[key];
    return v is String ? v : null;
  }

  /// A non-empty string, or null.
  String? text(String key) {
    final v = this[key];
    return v is String && v.isNotEmpty ? v : null;
  }

  int? integer(String key) {
    final v = this[key];
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  double? number(String key) {
    final v = this[key];
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim());
    return null;
  }

  bool? flag(String key) {
    final v = this[key];
    return v is bool ? v : null;
  }

  JsonMap? child(String key) => asJsonMap(this[key]);

  List<Object?>? items(String key) {
    final v = this[key];
    return v is List ? v.cast<Object?>() : null;
  }

  /// The map entries of a list field; non-map entries are skipped.
  List<JsonMap> maps(String key) => [
        for (final e in items(key) ?? const <Object?>[])
          if (asJsonMap(e) case final m?) m,
      ];
}

/// [v] as a [JsonMap] when it is any kind of map, else null.
JsonMap? asJsonMap(Object? v) => v is Map ? v.cast<String, Object?>() : null;

/// Decodes [text] as a JSON object; null when it is not valid JSON or not an
/// object. Never throws.
JsonMap? tryDecodeObject(String text) {
  try {
    return asJsonMap(jsonDecode(text));
  } on FormatException {
    return null;
  }
}

/// Decodes [text] as any JSON value; returns [fallback] on invalid input.
Object? tryDecode(String text, {Object? fallback}) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return fallback;
  }
}
