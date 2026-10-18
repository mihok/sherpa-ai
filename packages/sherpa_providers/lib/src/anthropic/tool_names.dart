import 'dart:convert';

/// Reversible mapping between Sherpa's model-facing tool names and the
/// Anthropic tool-name grammar.
///
/// Sherpa namespaces MCP tools (`github.create_issue`, `fs/read`), but the
/// Messages API only accepts `^[a-zA-Z0-9_-]{1,128}$`. We sanitize to the
/// stricter `{1,64}` that OpenAI also enforces (R10 rec. 9), so a session
/// that switches providers keeps the same wire names.
///
/// The mapping is a pure function of the ordered tool list. That matters
/// for preserved thinking: replayed `tool_use` blocks must render with the
/// same name on every request, so the same tool set must always produce the
/// same wire names.
final class AnthropicToolNames {
  AnthropicToolNames._(this._toWire, this._fromWire);

  /// Builds the map for one request's tool list (in request order).
  factory AnthropicToolNames(Iterable<String> names) {
    final toWire = <String, String>{};
    final fromWire = <String, String>{};
    final unique = names.toSet().toList();
    // Names that are already valid claim themselves first, so a sanitized
    // name can never shadow a tool that legitimately owns that spelling.
    for (final n in unique) {
      if (isValid(n)) {
        toWire[n] = n;
        fromWire[n] = n;
      }
    }
    for (final n in unique) {
      if (toWire.containsKey(n)) continue;
      var wire = sanitize(n);
      var salt = 0;
      while (fromWire.containsKey(wire)) {
        wire = _hashed(_base(n), salt == 0 ? n : '$n#$salt');
        salt++;
      }
      toWire[n] = wire;
      fromWire[wire] = n;
    }
    return AnthropicToolNames._(toWire, fromWire);
  }

  static const AnthropicToolNames empty = AnthropicToolNames._({}, {});

  /// Longest wire name we emit (OpenAI's limit; Anthropic allows 128).
  static const int maxLength = 64;

  static final RegExp _validName = RegExp(r'^[a-zA-Z0-9_-]{1,64}$');
  static final RegExp _invalidChar = RegExp(r'[^a-zA-Z0-9_-]');
  static final RegExp _validId = RegExp(r'^[a-zA-Z0-9_-]+$');

  final Map<String, String> _toWire;
  final Map<String, String> _fromWire;

  static bool isValid(String name) => _validName.hasMatch(name);

  /// Context-free sanitization: invalid characters become `_`; names that
  /// are empty, changed or too long get a short hash suffix only when
  /// needed to stay unique or within [maxLength].
  static String sanitize(String name) {
    if (isValid(name)) return name;
    final base = _base(name);
    return base == name.replaceAll(_invalidChar, '_') && base.length <= maxLength ? base : _hashed(base, name);
  }

  static String _base(String name) {
    final replaced = name.replaceAll(_invalidChar, '_');
    return replaced.isEmpty ? 'tool' : replaced;
  }

  /// Wire name for a Sherpa tool name. Names outside this request's tool
  /// list (e.g. a replayed call to a tool that is no longer offered) use the
  /// context-free [sanitize], which is still deterministic.
  String toWire(String name) => _toWire[name] ?? sanitize(name);

  /// Sherpa name for a wire name the model emitted; unknown names pass
  /// through so the tool router can report "unknown tool" to the model.
  String fromWire(String wire) => _fromWire[wire] ?? wire;

  /// Tool-use ids must match `^[a-zA-Z0-9_-]+$`. Ids minted by other
  /// providers (or imported transcripts) may not, so they are rewritten
  /// deterministically; the same function is applied to `tool_use.id` and
  /// `tool_result.tool_use_id`, which keeps every pair matched.
  static String sanitizeId(String id) {
    if (_validId.hasMatch(id)) return id;
    final replaced = id.replaceAll(_invalidChar, '_');
    return '${replaced.isEmpty ? 'toolu' : replaced}_${_fnv32(id)}';
  }

  static String _hashed(String base, String seed) {
    final suffix = _fnv32(seed);
    final room = maxLength - suffix.length - 1;
    final head = base.length > room ? base.substring(0, room) : base;
    return '${head}_$suffix';
  }

  /// FNV-1a 32 as 8 hex chars: stable across runs and platforms.
  static String _fnv32(String s) {
    var h = 0x811c9dc5;
    for (final b in utf8.encode(s)) {
      h ^= b;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }
}
