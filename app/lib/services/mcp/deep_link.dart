import 'package:flutter/foundation.dart' show immutable;

import 'mcp_records.dart' show McpServerSource;

/// "Add this MCP server" links and QR codes.
///
/// Format: `sherpa://mcp/add?url=<https URL, percent-encoded>&name=<label>`.
/// A QR code may also hold the bare `https://…` endpoint.
///
/// * The scheme is NOT the OAuth redirect scheme (`io.github.mihok.sherpa`):
///   on Android flutter_web_auth_2's callback activity claims every URI of
///   that scheme, and research R09 §7 says to keep the two apart.
/// * A link never adds anything by itself: it opens the add screen with the
///   server filled in, and the user confirms (any app or web page can open
///   a link, and a custom scheme can be claimed by another app).
@immutable
final class McpAddLink {
  const McpAddLink({required this.url, this.name, this.source = McpServerSource.link});

  static const String scheme = 'sherpa';
  static const String host = 'mcp';
  static const String path = '/add';

  /// The server endpoint as given (validated later by the add screen).
  final String url;

  /// Suggested display name (untrusted; the user can change it).
  final String? name;
  final McpServerSource source;

  /// A link for [url] (for sharing and tests).
  static Uri build(String url, {String? name}) => Uri(
        scheme: scheme,
        host: host,
        path: path,
        queryParameters: {'url': url, 'name': ?name},
      );

  /// Parses a deep link or a scanned code. Null for anything else.
  static McpAddLink? parse(String raw, {McpServerSource source = McpServerSource.link}) {
    final text = raw.trim();
    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    if (isAddLink(uri)) {
      final url = uri.queryParameters['url']?.trim();
      if (url == null || url.isEmpty) return null;
      final name = uri.queryParameters['name']?.trim();
      return McpAddLink(url: url, name: name == null || name.isEmpty ? null : _clip(name, 60), source: source);
    }
    final s = uri.scheme.toLowerCase();
    if ((s == 'https' || s == 'http') && uri.host.isNotEmpty) return McpAddLink(url: text, source: source);
    return null;
  }

  static bool isAddLink(Uri uri) =>
      uri.scheme.toLowerCase() == scheme && uri.host.toLowerCase() == host && (uri.path == path || uri.path == '$path/');

  /// Where the router sends an incoming add link: the add screen with the
  /// server filled in and `source=link` (always confirmed there).
  static String? redirectFor(Uri incoming, {required String addRoute}) {
    if (!isAddLink(incoming)) return null;
    final link = parse(incoming.toString());
    if (link == null) return addRoute;
    return Uri(path: addRoute, queryParameters: {'url': link.url, 'name': ?link.name, 'source': 'link'}).toString();
  }

  static String _clip(String s, int max) => s.length > max ? s.substring(0, max) : s;
}
