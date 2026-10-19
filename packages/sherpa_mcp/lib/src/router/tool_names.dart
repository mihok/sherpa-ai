/// Model-facing tool names: `<server>__<tool>` (R01 §6.2, R11 §9.5/§9.7).
library;

import 'package:meta/meta.dart';

import 'canonical.dart';

/// Identifies one tool of one server independently of its model-facing
/// name: the key pins, quarantine and approvals are stored under.
@immutable
final class McpToolKey implements Comparable<McpToolKey> {
  const McpToolKey(this.serverId, this.toolName);

  /// Parses [encoded]; throws [FormatException] for anything else.
  factory McpToolKey.parse(String encoded) {
    final slash = encoded.indexOf('/');
    if (slash <= 0) throw FormatException('not a tool key', encoded);
    return McpToolKey(
      Uri.decodeComponent(encoded.substring(0, slash)),
      Uri.decodeComponent(encoded.substring(slash + 1)),
    );
  }

  /// `McpServerConfig.id` (stable, unlike the self-reported server name).
  final String serverId;

  /// The tool's wire name, exactly as the server lists it.
  final String toolName;

  /// `<serverId>/<toolName>`, each part percent-encoded so either may
  /// contain `/`: a stable string for document stores and UI routes.
  String get encoded => '${Uri.encodeComponent(serverId)}/${Uri.encodeComponent(toolName)}';

  @override
  int compareTo(McpToolKey other) {
    final s = serverId.compareTo(other.serverId);
    return s != 0 ? s : toolName.compareTo(other.toolName);
  }

  @override
  bool operator ==(Object other) => other is McpToolKey && other.serverId == serverId && other.toolName == toolName;

  @override
  int get hashCode => Object.hash(serverId, toolName);

  @override
  String toString() => encoded;
}

/// Builds collision-free, stable, provider-safe model-facing tool names.
///
/// Every name matches `^[a-zA-Z0-9_-]{1,64}$`, the common denominator of
/// OpenAI and Anthropic (R10 rec. 9), so the providers' own wire mapper
/// (`ToolNameMapper`) is the identity for MCP tools and the name the user
/// approves is the name the model sees.
///
/// Stability is the design constraint, because a renamed tool changes the
/// prompt prefix (PLAN "Context segments") and orphans approval grants
/// keyed by name. A name is therefore a pure function of `(namespace,
/// tool name)` and never of the other tools in the list:
///
/// * The namespace comes from the server's stable config id (or an alias
///   the app persisted), never from the self-reported `serverInfo.name`,
///   which "is not unique and must not be used" for disambiguation (R01
///   §6.2). A namespace never contains `__`, so the first `__` in a
///   model name unambiguously ends the server part and tools of different
///   servers cannot collide.
/// * A clean tool name (`[a-zA-Z0-9_-]` and short enough) is kept as is.
///   Anything else is sanitized and always gets an 8-hex hash of the
///   original name, even when nothing else collides with it today, so
///   adding `a_b` later cannot rename an existing `a.b`.
/// * Over-long names keep a readable prefix plus that hash.
///
/// The only list-dependent step is [assign]'s fallback for a hash
/// collision with a literally clean name, which is astronomically unlikely
/// and resolved deterministically.
abstract final class McpToolNamer {
  static const int maxLength = 64;
  static const int maxNamespaceLength = 24;
  static const String separator = '__';

  static final RegExp _invalid = RegExp('[^a-zA-Z0-9_-]');
  static final RegExp _underscores = RegExp('_{2,}');

  /// Whether [name] is a valid model-facing tool name.
  static bool isValid(String name) => name.isNotEmpty && name.length <= maxLength && !_invalid.hasMatch(name);

  /// The namespace for a server id or alias.
  static String namespace(String serverId) {
    final clean = serverId.isNotEmpty &&
        serverId.length <= maxNamespaceLength &&
        !_invalid.hasMatch(serverId) &&
        !serverId.contains(separator) &&
        !serverId.startsWith('_') &&
        !serverId.endsWith('_');
    if (clean) return serverId;
    var s = serverId.replaceAll(_invalid, '_').replaceAll(_underscores, '_');
    s = _trim(s);
    final hash = shortHash('ns:$serverId', length: 6);
    final keep = maxNamespaceLength - hash.length - 1;
    if (s.length > keep) s = _trim(s.substring(0, keep));
    return s.isEmpty ? 'srv_$hash' : '${s}_$hash';
  }

  /// The model-facing name of [toolName] under [namespace] (already a
  /// [McpToolNamer.namespace] result).
  static String modelName(String namespace, String toolName) {
    final prefix = '$namespace$separator';
    final room = maxLength - prefix.length;
    final clean = toolName.isNotEmpty && !_invalid.hasMatch(toolName) && toolName.length <= room;
    if (clean) return '$prefix$toolName';
    final hash = shortHash('tool:$toolName');
    var s = toolName.replaceAll(_invalid, '_');
    final keep = room - hash.length - 1;
    if (s.length > keep) s = s.substring(0, keep < 0 ? 0 : keep);
    s = s.replaceAll(RegExp(r'_+$'), '');
    return s.isEmpty ? '$prefix$hash' : '$prefix${s}_$hash';
  }

  /// Assigns names for a whole catalog: [modelName] for every key, with a
  /// deterministic counter suffix for the (practically impossible) case of
  /// two keys producing the same name. Keys are processed in sorted order
  /// so the outcome does not depend on server listing order.
  static Map<McpToolKey, String> assign(Map<McpToolKey, String> namespaces) {
    final out = <McpToolKey, String>{};
    final taken = <String, McpToolKey>{};
    final keys = namespaces.keys.toList()..sort();
    // Clean names first: they never move.
    final ordered = [
      ...keys.where((k) => modelName(namespaces[k]!, k.toolName) == '${namespaces[k]}$separator${k.toolName}'),
      ...keys.where((k) => modelName(namespaces[k]!, k.toolName) != '${namespaces[k]}$separator${k.toolName}'),
    ];
    for (final k in ordered) {
      final base = modelName(namespaces[k]!, k.toolName);
      var name = base;
      for (var i = 2; taken.containsKey(name); i++) {
        final suffix = '_$i';
        name = base.length + suffix.length > maxLength
            ? '${base.substring(0, maxLength - suffix.length)}$suffix'
            : '$base$suffix';
      }
      taken[name] = k;
      out[k] = name;
    }
    return out;
  }

  static String _trim(String s) => s.replaceAll(RegExp(r'^[_-]+|[_-]+$'), '');
}
