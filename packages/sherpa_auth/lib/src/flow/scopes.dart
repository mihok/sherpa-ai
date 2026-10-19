/// Scope helpers (RFC 6749 §3.3: space-delimited, case-sensitive tokens).
library;

/// Splits a scope string, dropping empties and duplicates (first wins).
List<String> splitScopes(String? scope) {
  if (scope == null) return const [];
  final seen = <String>{};
  return List.unmodifiable([
    for (final s in scope.split(RegExp(r'\s+')))
      if (s.isNotEmpty && seen.add(s)) s,
  ]);
}

/// Joins scopes for the wire; null when empty so the parameter is omitted.
String? joinScopes(Iterable<String> scopes) {
  final list = scopes.where((s) => s.isNotEmpty).toList();
  return list.isEmpty ? null : list.join(' ');
}

/// Union in first-seen order, without hierarchy handling (the AS
/// normalises redundancy; TS2 `computeScopeUnion`).
List<String> unionScopes(Iterable<Iterable<String>> sets) {
  final seen = <String>{};
  return List.unmodifiable([
    for (final set in sets)
      for (final s in set)
        if (s.isNotEmpty && seen.add(s)) s,
  ]);
}

const String offlineAccessScope = 'offline_access';

/// The MCP scope selection strategy (A26 L124-134):
///
/// 1. the `scope` of the challenge that triggered authorization, else
/// 2. **all** of the PRM `scopes_supported`, else
/// 3. no scope parameter at all.
///
/// `offline_access` is appended when [requestOfflineAccess] and the AS lists
/// it (A26 L308), but only to a non-empty selection: asking for
/// `offline_access` alone would replace the server's default scopes with
/// nothing useful (TS2 `determineScope` has the same guard). The challenge
/// scope is not assumed to relate to `scopes_supported` (A26 L105-108).
List<String> selectScopes({
  List<String> challenged = const [],
  List<String>? resourceScopesSupported,
  List<String>? serverScopesSupported,
  bool requestOfflineAccess = true,
}) {
  final base = challenged.isNotEmpty
      ? challenged
      : (resourceScopesSupported != null && resourceScopesSupported.isNotEmpty ? resourceScopesSupported : const <String>[]);
  if (base.isEmpty) return const [];
  final withOffline = requestOfflineAccess &&
      (serverScopesSupported?.contains(offlineAccessScope) ?? false) &&
      !base.contains(offlineAccessScope);
  return unionScopes([base, if (withOffline) const [offlineAccessScope]]);
}

/// Whether [granted] covers every scope in [wanted].
bool scopesCover(Iterable<String> granted, Iterable<String> wanted) {
  final g = granted.toSet();
  return wanted.every(g.contains);
}
