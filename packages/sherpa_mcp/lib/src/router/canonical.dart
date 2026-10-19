/// Canonical JSON and hashing for tool pins (R11 §9.7).
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sherpa_core/sherpa_core.dart' show JsonMap;

/// Encodes [value] as canonical JSON: object keys sorted by code unit,
/// no insignificant whitespace, integral doubles written as integers.
///
/// Two definitions that differ only in key order or `1` vs `1.0` hash the
/// same, so a server that re-serializes its tool list on every request does
/// not trip the rug-pull detector; any semantic change does.
String canonicalJson(Object? value) {
  final out = StringBuffer();
  _write(value, out);
  return out.toString();
}

void _write(Object? v, StringBuffer out) {
  switch (v) {
    case null:
      out.write('null');
    case final bool b:
      out.write(b ? 'true' : 'false');
    case final int i:
      out.write(i);
    case final double d:
      if (d.isFinite && d == d.truncateToDouble() && d.abs() < 1e15) {
        out.write(d.toInt());
      } else {
        out.write(jsonEncode(d));
      }
    case final String s:
      out.write(jsonEncode(s));
    case final List<Object?> l:
      out.write('[');
      for (var i = 0; i < l.length; i++) {
        if (i > 0) out.write(',');
        _write(l[i], out);
      }
      out.write(']');
    case final Map<Object?, Object?> m:
      final keys = [for (final k in m.keys) k.toString()]..sort();
      out.write('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) out.write(',');
        out
          ..write(jsonEncode(keys[i]))
          ..write(':');
        _write(m[keys[i]], out);
      }
      out.write('}');
    default:
      out.write(jsonEncode(v.toString()));
  }
}

/// Lower-case hex SHA-256 of [text] (UTF-8).
String sha256Hex(String text) => sha256.convert(utf8.encode(text)).toString();

/// A short, stable hex digest for derived names (not a security boundary:
/// collisions are detected and resolved by the caller).
String shortHash(String text, {int length = 8}) => sha256Hex(text).substring(0, length);

/// Deep-copies decoded JSON into plain `Map<String, Object?>` / `List`
/// values so a snapshot cannot be mutated through the original.
Object? deepCopyJson(Object? v) => switch (v) {
      final Map<Object?, Object?> m => <String, Object?>{for (final e in m.entries) '${e.key}': deepCopyJson(e.value)},
      final List<Object?> l => [for (final e in l) deepCopyJson(e)],
      _ => v,
    };

/// [deepCopyJson] for an object.
JsonMap deepCopyMap(JsonMap m) => deepCopyJson(m)! as JsonMap;
