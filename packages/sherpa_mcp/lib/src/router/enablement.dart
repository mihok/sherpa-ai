/// Per-session tool and server switches.
library;

import 'package:sherpa_core/sherpa_core.dart' show JsonMap;

/// Which tools and servers a session may use, and which tools the user
/// pinned (always offered, even in deferred mode).
///
/// Reads are synchronous because tool selection runs before every model
/// step; the app keeps these switches in memory and persists them itself
/// ([InMemoryToolEnablement.toJson]). Tools are identified by their
/// model-facing name (the same key approval grants use). A server must be
/// enabled both here and in its `McpServerConfig.enabled`.
abstract interface class ToolEnablement {
  bool isServerEnabled(String sessionId, String serverId);

  bool isToolEnabled(String sessionId, String toolName);

  bool isPinned(String sessionId, String toolName);
}

/// Enables everything, pins nothing.
final class AllToolsEnabled implements ToolEnablement {
  const AllToolsEnabled();

  @override
  bool isServerEnabled(String sessionId, String serverId) => true;

  @override
  bool isToolEnabled(String sessionId, String toolName) => true;

  @override
  bool isPinned(String sessionId, String toolName) => false;
}

/// [ToolEnablement] with global defaults and per-session overrides.
///
/// Resolution: session override → global override → enabled (not pinned).
/// [revision] increases on every change so the router can tell a session's
/// segment is stale (enablement changes take effect at the next segment;
/// execution checks the live switches immediately).
final class InMemoryToolEnablement implements ToolEnablement {
  InMemoryToolEnablement();

  factory InMemoryToolEnablement.fromJson(JsonMap j) {
    final e = InMemoryToolEnablement();
    void read(String field, Map<String, Map<String, bool>> into) {
      final m = j[field];
      if (m is! Map) return;
      for (final scope in m.entries) {
        final v = scope.value;
        if (v is! Map) continue;
        into['${scope.key}'] = {
          for (final x in v.entries)
            if (x.value is bool) '${x.key}': x.value! as bool,
        };
      }
    }

    read('servers', e._servers);
    read('tools', e._tools);
    read('pinned', e._pinned);
    return e;
  }

  static const String _global = '*';

  // scope ('*' or session id) → id → value
  final Map<String, Map<String, bool>> _servers = {};
  final Map<String, Map<String, bool>> _tools = {};
  final Map<String, Map<String, bool>> _pinned = {};
  int _revision = 0;

  int get revision => _revision;

  bool _resolve(Map<String, Map<String, bool>> m, String sessionId, String id, bool fallback) =>
      m[sessionId]?[id] ?? m[_global]?[id] ?? fallback;

  void _set(Map<String, Map<String, bool>> m, String id, bool? value, String? sessionId) {
    final scope = m.putIfAbsent(sessionId ?? _global, () => {});
    if (value == null) {
      scope.remove(id);
    } else {
      scope[id] = value;
    }
    _revision++;
  }

  @override
  bool isServerEnabled(String sessionId, String serverId) => _resolve(_servers, sessionId, serverId, true);

  @override
  bool isToolEnabled(String sessionId, String toolName) => _resolve(_tools, sessionId, toolName, true);

  @override
  bool isPinned(String sessionId, String toolName) => _resolve(_pinned, sessionId, toolName, false);

  /// [enabled] null clears the override; [sessionId] null sets the default.
  void setServerEnabled(String serverId, bool? enabled, {String? sessionId}) =>
      _set(_servers, serverId, enabled, sessionId);

  void setToolEnabled(String toolName, bool? enabled, {String? sessionId}) => _set(_tools, toolName, enabled, sessionId);

  void setPinned(String toolName, bool? pinned, {String? sessionId}) => _set(_pinned, toolName, pinned, sessionId);

  /// Drops a session's overrides (session deleted).
  void forgetSession(String sessionId) {
    _servers.remove(sessionId);
    _tools.remove(sessionId);
    _pinned.remove(sessionId);
    _revision++;
  }

  JsonMap toJson() => {
        'servers': {for (final e in _servers.entries) if (e.value.isNotEmpty) e.key: {...e.value}},
        'tools': {for (final e in _tools.entries) if (e.value.isNotEmpty) e.key: {...e.value}},
        'pinned': {for (final e in _pinned.entries) if (e.value.isNotEmpty) e.key: {...e.value}},
      };
}
