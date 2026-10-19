import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart' show immutable;
import 'package:http/http.dart' as http;
import 'package:sherpa_core/sherpa_core.dart';

/// One remote endpoint of a registry server (`remotes[]`).
@immutable
final class McpRegistryRemote {
  const McpRegistryRemote({
    required this.type,
    required this.url,
    this.requiredHeaders = const [],
    this.hasUrlVariables = false,
  });

  /// `streamable-http` or `sse`.
  final String type;
  final String url;

  /// Headers the server needs (e.g. an API key). Sherpa keeps secrets out
  /// of server configs, so such servers cannot be added from here yet.
  final List<String> requiredHeaders;

  /// The URL has `{placeholders}` the user would have to fill in.
  final bool hasUrlVariables;

  bool get isStreamableHttp => type == 'streamable-http';
}

/// A server from the official MCP Registry. Everything here is
/// publisher-supplied, untrusted text: display only.
@immutable
final class McpRegistryEntry {
  const McpRegistryEntry({
    required this.name,
    required this.description,
    required this.version,
    this.title,
    this.websiteUrl,
    this.repositoryUrl,
    this.remotes = const [],
    this.packageOnly = false,
  });

  /// Reverse-DNS registry name, e.g. `io.github.owner/server`.
  final String name;
  final String? title;
  final String description;
  final String version;
  final String? websiteUrl;
  final String? repositoryUrl;

  /// Remote endpoints Sherpa can speak (streamable-http and sse only).
  final List<McpRegistryRemote> remotes;

  /// Only local packages (npm, PyPI, OCI…): a phone cannot run them.
  final bool packageOnly;

  String get displayName => title ?? name.split('/').last;

  /// The endpoint to add: streamable HTTP first, then SSE, skipping ones
  /// that need a header or URL variables.
  McpRegistryRemote? get preferredRemote {
    final usable = [for (final r in remotes) if (r.requiredHeaders.isEmpty && !r.hasUrlVariables && r.url.startsWith('https://')) r];
    return usable.where((r) => r.isStreamableHttp).firstOrNull ?? usable.firstOrNull;
  }

  /// Why this server cannot be added from the registry, or null.
  String? get unsupportedReason {
    if (preferredRemote != null) return null;
    if (remotes.isEmpty) return packageOnly ? 'Runs only on a computer (no remote endpoint).' : 'No remote endpoint listed.';
    if (remotes.any((r) => r.requiredHeaders.isNotEmpty)) {
      return 'Needs an API key header, which Sherpa cannot store for tool servers yet.';
    }
    if (remotes.any((r) => r.hasUrlVariables)) return 'Its address needs values filled in by hand.';
    return 'Its endpoint is not https.';
  }
}

/// One page of results.
@immutable
final class McpRegistryPage {
  const McpRegistryPage({required this.entries, this.nextCursor});

  final List<McpRegistryEntry> entries;
  final String? nextCursor;
}

enum McpRegistryFailure { offline, unavailable, invalidResponse }

final class McpRegistryException implements Exception {
  const McpRegistryException(this.failure, this.message);

  final McpRegistryFailure failure;

  /// Plain language, safe to show.
  final String message;

  @override
  String toString() => 'McpRegistryException(${failure.name}: $message)';
}

/// Client for the official MCP Registry (registry.modelcontextprotocol.io).
///
/// API (checked 2026-10-19 against the live OpenAPI document, registry
/// v1.8.1): `GET /v0.1/servers?search=<substring of name>&version=latest&limit=<1..100>&cursor=<nextCursor>`
/// → `{servers: [{server: ServerJSON, _meta: {"io.modelcontextprotocol.registry/official": {status, isLatest…}}}],
/// metadata: {count, nextCursor?}}`. `/v0` serves the same shape; `v0.1`
/// is the frozen API. Only `remotes` of type `streamable-http` or `sse`
/// are offered: `packages` (npm, PyPI, OCI) run on a computer.
final class McpRegistryClient {
  McpRegistryClient({required http.Client client, Uri? baseUri, this.timeout = const Duration(seconds: 15), this.pageSize = 30})
      : _client = client,
        baseUri = baseUri ?? defaultBase;

  static final Uri defaultBase = Uri.parse('https://registry.modelcontextprotocol.io/v0.1/');

  final http.Client _client;
  final Uri baseUri;
  final Duration timeout;
  final int pageSize;

  static const int _maxBytes = 4 << 20;

  /// Control characters and bidi overrides (publisher text is untrusted).
  static final RegExp _unsafeChars = RegExp(
    '[${String.fromCharCode(0)}-${String.fromCharCode(0x1F)}${String.fromCharCode(0x7F)}'
    '${String.fromCharCode(0x202A)}-${String.fromCharCode(0x202E)}${String.fromCharCode(0x2066)}-${String.fromCharCode(0x2069)}]',
  );

  Future<McpRegistryPage> search(String query, {String? cursor}) async {
    final q = query.trim();
    final url = baseUri.resolve('servers').replace(queryParameters: {
      if (q.isNotEmpty) 'search': q,
      'version': 'latest',
      'limit': '$pageSize',
      'cursor': ?cursor,
    });
    final http.Response r;
    try {
      r = await _client.get(url, headers: const {'accept': 'application/json'}).timeout(timeout);
    } on TimeoutException {
      throw const McpRegistryException(McpRegistryFailure.offline, 'The MCP Registry did not answer in time. Try again.');
    } on SocketException {
      throw const McpRegistryException(McpRegistryFailure.offline, "Couldn't reach the MCP Registry. Check your connection.");
    } on http.ClientException {
      throw const McpRegistryException(McpRegistryFailure.offline, "Couldn't reach the MCP Registry. Check your connection.");
    }
    if (r.statusCode == 429) {
      throw const McpRegistryException(McpRegistryFailure.unavailable, 'The MCP Registry is busy. Try again in a minute.');
    }
    if (r.statusCode != 200) {
      throw McpRegistryException(McpRegistryFailure.unavailable, 'The MCP Registry answered with an error (${r.statusCode}).');
    }
    if (r.bodyBytes.length > _maxBytes) {
      throw const McpRegistryException(McpRegistryFailure.invalidResponse, 'The MCP Registry sent too much data.');
    }
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is! Map) throw const FormatException('not an object');
      return parsePage(j.cast<String, Object?>());
    } on FormatException {
      throw const McpRegistryException(McpRegistryFailure.invalidResponse, 'The MCP Registry sent an unreadable answer.');
    }
  }

  /// Parses a `ServerListResponse`, keeping active latest versions and
  /// dropping entries that do not parse.
  static McpRegistryPage parsePage(JsonMap j) {
    final out = <McpRegistryEntry>[];
    final seen = <String>{};
    for (final item in (j['servers'] as List?) ?? const []) {
      if (item is! Map) continue;
      final meta = item['_meta'];
      final official = meta is Map ? meta['io.modelcontextprotocol.registry/official'] : null;
      if (official is Map) {
        final status = official['status'];
        if (status is String && status != 'active') continue;
        if (official['isLatest'] == false) continue;
      }
      final s = item['server'];
      if (s is! Map) continue;
      final e = _entry(s.cast<String, Object?>());
      if (e != null && seen.add(e.name)) out.add(e);
    }
    final m = j['metadata'];
    final next = m is Map ? m['nextCursor'] : null;
    return McpRegistryPage(entries: out, nextCursor: next is String && next.isNotEmpty ? next : null);
  }

  static McpRegistryEntry? _entry(JsonMap s) {
    final name = s['name'];
    if (name is! String || name.isEmpty) return null;
    String? str(Object? v, [int max = 300]) {
      if (v is! String) return null;
      final t = v.replaceAll(_unsafeChars, ' ').trim();
      if (t.isEmpty) return null;
      return t.length > max ? '${t.substring(0, max - 1)}…' : t;
    }

    final remotes = <McpRegistryRemote>[];
    for (final r in (s['remotes'] as List?) ?? const []) {
      if (r is! Map) continue;
      final type = r['type'];
      final url = r['url'];
      if (type is! String || url is! String) continue;
      if (type != 'streamable-http' && type != 'sse') continue;
      final headers = [
        for (final h in (r['headers'] as List?) ?? const [])
          if (h is Map && h['name'] is String && (h['isRequired'] == true || h['isSecret'] == true)) h['name']! as String,
      ];
      remotes.add(McpRegistryRemote(
        type: type,
        url: url,
        requiredHeaders: headers,
        hasUrlVariables: url.contains('{') || (r['variables'] is Map && (r['variables']! as Map).isNotEmpty),
      ));
    }
    final repo = s['repository'];
    final packages = s['packages'];
    return McpRegistryEntry(
      name: str(name, 200)!,
      title: str(s['title'], 100),
      description: str(s['description']) ?? '',
      version: str(s['version'], 40) ?? '',
      websiteUrl: str(s['websiteUrl'], 500),
      repositoryUrl: repo is Map ? str(repo['url'], 500) : null,
      remotes: remotes,
      packageOnly: remotes.isEmpty && packages is List && packages.isNotEmpty,
    );
  }
}
