/// FNV-1a 32-bit of [s] as 8 hex chars.
///
/// Tiny, dependency-free and stable across runs and platforms (unlike
/// `String.hashCode`), which is what wire-visible derived names and cache
/// keys need. Not a security hash.
String fnv1a32Hex(String s) {
  var h = 0x811c9dc5;
  for (final unit in s.codeUnits) {
    h ^= unit;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}
