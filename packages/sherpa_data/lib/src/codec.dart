import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';

/// Timestamps are stored as microseconds since the epoch: the full precision
/// of a Dart `DateTime` on native platforms, and an INTEGER that orders
/// correctly (see `tables.dart`).
int toMicros(DateTime t) => t.microsecondsSinceEpoch;

/// Times come back in UTC, as they do from the core types' `fromJson`.
DateTime fromMicros(int micros) => DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);

String encodeJson(JsonMap value) => jsonEncode(value);

/// Decodes a stored JSON object. `jsonDecode` yields `Map<String, dynamic>`
/// all the way down, which already satisfies [JsonMap] and the core
/// `fromJson` readers, so no deep copy is needed.
JsonMap decodeJsonObject(String source) {
  final value = jsonDecode(source);
  if (value is Map<String, Object?>) return value;
  throw FormatError('expected a stored JSON object, got ${value.runtimeType}');
}
