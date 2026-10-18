/// Reversible, collision-free mapping between Sherpa's model-facing tool
/// names and the names a remote API accepts.
///
/// OpenAI allows `^[a-zA-Z0-9_-]{1,64}$` and Anthropic the same charset up
/// to 128, so 64 is the common denominator (R10 rec. 9). MCP tool names can
/// contain dots, slashes or spaces and can be longer, and two different
/// names can sanitize to the same string (`a.b` and `a/b`), so the mapping
/// is built per request from the full tool list and inverted for streamed
/// calls.
///
/// Stability matters as much as validity: the same tool list must always
/// produce the same wire names, otherwise prompt caches (remote) and KV
/// prefixes (local) are invalidated on every request. Names that are
/// already valid therefore always map to themselves, and suffixes are
/// derived from a hash of the original name rather than from list order.
final class ToolNameMapper {
  ToolNameMapper(Iterable<String> names, {this.maxLength = 64}) {
    final unique = <String>{...names};
    for (final n in unique) {
      if (isValid(n, maxLength: maxLength)) _assign(n, n);
    }
    for (final n in unique) {
      if (_toWire.containsKey(n)) continue;
      final base = sanitize(n, maxLength: maxLength);
      var candidate = base;
      if (_fromWire.containsKey(candidate)) candidate = _withSuffix(base, _hash(n), maxLength);
      for (var i = 2; _fromWire.containsKey(candidate); i++) {
        candidate = _withSuffix(base, '${_hash(n)}$i', maxLength);
      }
      _assign(n, candidate);
    }
  }

  /// A mapper with no known tools: [toWire] still sanitizes.
  ToolNameMapper.empty({this.maxLength = 64});

  final int maxLength;
  final Map<String, String> _toWire = {};
  final Map<String, String> _fromWire = {};

  static final RegExp _invalidChar = RegExp('[^a-zA-Z0-9_-]');

  static bool isValid(String name, {int maxLength = 64}) =>
      name.isNotEmpty && name.length <= maxLength && !_invalidChar.hasMatch(name);

  /// Deterministic, context-free sanitization. Over-long names keep a
  /// readable prefix plus a hash of the full name so they stay distinct.
  static String sanitize(String name, {int maxLength = 64}) {
    var s = name.replaceAll(_invalidChar, '_');
    if (s.isEmpty) s = 'tool';
    if (s.length > maxLength) s = _withSuffix(s, _hash(name), maxLength);
    return s;
  }

  /// Whether any name needed rewriting (useful for diagnostics).
  bool get rewritesAny => _toWire.entries.any((e) => e.key != e.value);

  /// The wire name for [name]. Names outside the tool list (e.g. a call in
  /// history to a tool that has since been removed) are sanitized the same
  /// context-free way, so the request stays valid.
  String toWire(String name) => _toWire[name] ?? sanitize(name, maxLength: maxLength);

  /// The model-facing name for a [wire] name the model produced.
  ///
  /// Small models and some servers mangle names (case, a `functions.`
  /// prefix from the harmony format). A normalized match is accepted only
  /// when exactly one known tool matches, otherwise the name is returned
  /// unchanged and the agent loop reports an unknown tool.
  String fromWire(String wire) {
    final exact = _fromWire[wire];
    if (exact != null) return exact;
    final trimmed = wire.trim();
    final stripped = trimmed.startsWith('functions.') ? trimmed.substring('functions.'.length) : trimmed;
    final direct = _fromWire[stripped] ?? (_toWire.containsKey(stripped) ? stripped : null);
    if (direct != null) return direct;
    final lower = stripped.toLowerCase();
    final candidates = {
      for (final e in _fromWire.entries)
        if (e.key.toLowerCase() == lower || e.value.toLowerCase() == lower) e.value,
    };
    return candidates.length == 1 ? candidates.single : wire;
  }

  void _assign(String name, String wire) {
    _toWire[name] = wire;
    _fromWire[wire] = name;
  }

  static String _withSuffix(String base, String suffix, int maxLength) {
    final keep = maxLength - suffix.length - 1;
    final head = base.length > keep ? base.substring(0, keep < 0 ? 0 : keep) : base;
    return '${head}_$suffix';
  }

  /// FNV-1a 32-bit as 8 hex chars: tiny, dependency-free and stable across
  /// runs and platforms (unlike `String.hashCode`).
  static String _hash(String s) {
    var h = 0x811c9dc5;
    for (final unit in s.codeUnits) {
      h ^= unit;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }
}
