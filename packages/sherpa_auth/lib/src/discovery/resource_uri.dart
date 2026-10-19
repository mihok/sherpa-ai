/// RFC 8707 resource indicators and the RFC 9728 §3.3 resource check.
library;

/// The canonical URI of an MCP server, used as the RFC 8707 `resource`
/// when no Protected Resource Metadata supplies one, and as Sherpa's
/// per-server storage key.
///
/// A26 L215-252: absolute, no fragment, lower-case scheme and host, and
/// "SHOULD consistently use the form without the trailing slash" — so a
/// bare `/` path is dropped, any other path is kept as written (a trailing
/// slash after a real path may be significant). Default ports are omitted.
/// The query is kept (RFC 8707 discourages but allows it).
String canonicalResourceUri(Uri serverUrl) {
  final scheme = serverUrl.scheme.toLowerCase();
  if ((scheme != 'https' && scheme != 'http') || serverUrl.host.isEmpty) {
    throw ArgumentError.value(serverUrl.toString(), 'serverUrl', 'not an http(s) URL');
  }
  if (serverUrl.userInfo.isNotEmpty) {
    throw ArgumentError.value(serverUrl.toString(), 'serverUrl', 'credentials in URLs are not allowed');
  }
  final host = serverUrl.host.toLowerCase();
  final hostPart = host.contains(':') ? '[$host]' : host;
  final defaultPort = scheme == 'https' ? 443 : 80;
  final port = serverUrl.hasPort && serverUrl.port != defaultPort ? ':${serverUrl.port}' : '';
  final path = serverUrl.path == '/' ? '' : serverUrl.path;
  final query = serverUrl.hasQuery ? '?${serverUrl.query}' : '';
  return '$scheme://$hostPart$port$path$query';
}

/// How strictly a PRM `resource` must match the server URL.
enum ResourceMatchPolicy {
  /// RFC 9728 §3.3 literally: `resource` is identical to the URL the
  /// well-known suffix was inserted into (or, with a header-supplied PRM
  /// URL, the URL the client requested).
  exact,

  /// [exact], or same origin with a path that is a segment-boundary prefix
  /// of the server path (`https://h` and `https://h/mcp` both cover
  /// `https://h/mcp`; `/api` does not cover `/api123`). This is what both
  /// TS SDKs implement (`checkResourceAllowed`) and what deployed servers
  /// expect, e.g. a PRM at the root naming the origin for every endpoint.
  /// A cross-origin `resource` is always rejected. Default.
  sameOriginPathPrefix,
}

/// How a PRM `resource` matched, so relaxations can be logged.
enum ResourceMatch { exact, pathPrefix }

/// Checks [resource] (verbatim from the PRM) against the server URL.
/// Returns null when it must not be used (RFC 9728 §3.3, §7.3).
ResourceMatch? matchResource(String resource, Uri serverUrl, ResourceMatchPolicy policy) {
  final requested = serverUrl.removeFragment();
  if (resource == requested.toString() || resource == canonicalResourceUri(requested)) return ResourceMatch.exact;
  if (policy == ResourceMatchPolicy.exact) return null;
  final r = Uri.tryParse(resource);
  if (r == null || !r.isAbsolute || r.hasFragment || r.hasQuery || r.userInfo.isNotEmpty) return null;
  if (!_sameOrigin(r, requested)) return null;
  final rp = r.path.endsWith('/') ? r.path : '${r.path}/';
  final sp = requested.path.endsWith('/') ? requested.path : '${requested.path}/';
  return sp.startsWith(rp) ? ResourceMatch.pathPrefix : null;
}

bool _sameOrigin(Uri a, Uri b) =>
    a.scheme.toLowerCase() == b.scheme.toLowerCase() && a.host.toLowerCase() == b.host.toLowerCase() && a.port == b.port;
