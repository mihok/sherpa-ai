import 'dart:convert';

/// Non-cryptographic fingerprints used for change detection and dedupe keys
/// (prefix keys, side-effect `argsDigest`, elided-payload markers).
///
/// FNV-1a is enough here: nothing relies on collision resistance against an
/// adversary, only on "did this change" and "is this the same call".
abstract final class Digest {
  /// FNV-1a 64 over the UTF-8 bytes of [text], as 16 lowercase hex chars.
  static String fnv64(String text) {
    var h = 0xcbf29ce484222325;
    for (final b in utf8.encode(text)) {
      h ^= b;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return h.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }

  /// JSON with object keys sorted recursively, so two argument maps that
  /// differ only in key order produce the same digest.
  static String canonicalJson(Object? value) => jsonEncode(_canonical(value));

  static Object? _canonical(Object? v) => switch (v) {
        Map<Object?, Object?>() => {
            for (final k in (v.keys.map((k) => k.toString()).toList()..sort())) k: _canonical(v[k]),
          },
        List<Object?>() => [for (final e in v) _canonical(e)],
        _ => v,
      };

  /// Digest of tool-call arguments (R11 §9.1 `argsDigest`).
  static String args(Map<String, Object?> arguments) => fnv64(canonicalJson(arguments));
}
