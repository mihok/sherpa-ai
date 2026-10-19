import 'dart:async';
import 'dart:io' show InternetAddress, SocketException;

import 'package:flutter/foundation.dart' show immutable;
import 'package:http/http.dart' as http;
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:sherpa_net/sherpa_net.dart';

import '../../app_info.dart';

/// The outcome of checking a URL the user typed (or a link brought in).
@immutable
final class McpUrlCheck {
  const McpUrlCheck.ok(Uri this.url, {required this.local}) : error = null;

  const McpUrlCheck.invalid(String this.error)
      : url = null,
        local = false;

  final Uri? url;

  /// The server is on the user's own network (http and private addresses
  /// allowed for its host only).
  final bool local;

  /// Plain language, safe to show.
  final String? error;

  bool get isValid => url != null;
}

/// Validates MCP endpoint URLs with sherpa_net's [UrlPolicy]: https on the
/// public internet; a "server on my network" may be plain http, but only
/// to a loopback / private / `.local` address
/// ([UrlPolicy.httpRequiresLocalAddress]), so nothing goes unencrypted
/// across the internet. Link-local and metadata addresses are always out.
final class McpUrlValidator {
  McpUrlValidator({Future<List<InternetAddress>> Function(String host)? resolver}) : _resolver = resolver;

  final Future<List<InternetAddress>> Function(String host)? _resolver;

  UrlPolicy _policy({required bool local}) {
    final r = _resolver;
    if (local) {
      return r == null
          ? const UrlPolicy(scope: NetworkScope.loopback, allowHttp: true, httpRequiresLocalAddress: true)
          : UrlPolicy(scope: NetworkScope.loopback, allowHttp: true, httpRequiresLocalAddress: true, resolver: r);
    }
    return r == null ? const UrlPolicy() : UrlPolicy(resolver: r);
  }

  /// Whether [url] looks like a server on the user's network: plain http,
  /// a private or loopback literal, or a local host name.
  static bool looksLocal(Uri url) {
    if (url.scheme.toLowerCase() == 'http') return true;
    final host = url.host.toLowerCase();
    if (host == 'localhost' || host.endsWith('.localhost') || host.endsWith('.local') || host.endsWith('.lan') || host.endsWith('.internal')) {
      return true;
    }
    final literal = InternetAddress.tryParse(host.startsWith('[') ? host.substring(1, host.length - 1) : host);
    if (literal == null) return false;
    final kind = classify(literal);
    return kind == AddressKind.private || kind == AddressKind.loopback;
  }

  /// [raw] without a scheme gets `https://`. [local] null means "decide
  /// from the URL" ([looksLocal]).
  Future<McpUrlCheck> check(String raw, {bool? local}) async {
    var text = raw.trim();
    if (text.isEmpty) return const McpUrlCheck.invalid('Enter the server address.');
    if (!text.contains('://')) text = 'https://$text';
    final parsed = Uri.tryParse(text);
    if (parsed == null || parsed.host.isEmpty) return const McpUrlCheck.invalid("That doesn't look like a web address.");
    final isLocal = local ?? looksLocal(parsed);
    try {
      final uri = await _policy(local: isLocal).check(text);
      return McpUrlCheck.ok(uri, local: isLocal);
    } on UrlPolicyViolation catch (e) {
      return McpUrlCheck.invalid(_explain(e.reason, local: isLocal));
    }
  }

  static String _explain(String reason, {required bool local}) {
    if (reason.contains('credentials')) return 'Remove the user name or password from the address.';
    if (reason.contains('only https')) return 'Only https addresses (or http on your own network) can be used.';
    if (reason.contains('plain http is only allowed to a server on your own network')) {
      return 'Plain http only works for a server on your own network. This address is on the internet; use https.';
    }
    if (reason.contains('plain http')) return 'Plain http only works for a server on your own network. Use https.';
    if (reason.contains('does not resolve')) return "Couldn't find that server. Check the address and your connection.";
    if (!local && (reason.contains('private') || reason.contains('loopback') || reason.contains('local host'))) {
      return 'This address is on a local network. Turn on "Server on my network" to use it.';
    }
    if (reason.contains('link-local') || reason.contains('metadata') || reason.contains('not allowed')) {
      return "Sherpa doesn't connect to that kind of address.";
    }
    return "That address can't be used: $reason.";
  }
}

/// What probing a server found.
@immutable
final class McpProbeReport {
  const McpProbeReport({
    this.era,
    this.protocolVersion,
    this.transportKind,
    this.serverName,
    this.serverVersion,
    this.needsAuth = false,
    this.error,
    this.verdict,
    this.toolCount,
    this.hasResources = false,
    this.hasPrompts = false,
  });

  final McpEra? era;
  final String? protocolVersion;
  final McpTransportKind? transportKind;

  /// Self-reported, untrusted.
  final String? serverName;
  final String? serverVersion;

  /// The server answered 401/403: it can be added, then signed in to.
  final bool needsAuth;

  /// Plain language, when the server could not be used.
  final String? error;

  /// Persist with the config so the next connect skips the probe.
  final EraVerdict? verdict;
  final int? toolCount;
  final bool hasResources;
  final bool hasPrompts;

  bool get reachable => error == null;

  /// "MCP 2026-07-28 (stateless)", "MCP 2025-11-25 (Streamable HTTP, sessions)"…
  String? get eraLabel => describeEra(era, protocolVersion, transportKind);
}

/// The protocol era in words.
String? describeEra(McpEra? era, String? version, McpTransportKind? kind) {
  if (era == null) return null;
  final v = version ?? '';
  return switch (kind) {
    McpTransportKind.legacySse => 'MCP $v over HTTP+SSE (old, deprecated transport)',
    McpTransportKind.legacyStreamableHttp => 'MCP $v (Streamable HTTP with sessions)',
    McpTransportKind.modernHttp => 'MCP $v (stateless, the current revision)',
    McpTransportKind.inProcess => 'MCP $v (built in)',
    null => era == McpEra.modern ? 'MCP $v (stateless)' : 'MCP $v',
  };
}

/// Connects to a server once to see what it speaks. A seam for tests.
abstract interface class McpServerProber {
  Future<McpProbeReport> probe(McpServerConfig config);
}

/// [McpServerProber] that opens a real connection (no credentials), reads
/// the era, the server info and the tool count, and closes it again.
final class ConnectingMcpProber implements McpServerProber {
  ConnectingMcpProber({required http.Client client, this.connector, this.timeout = const Duration(seconds: 25), this.urlPolicy})
      : _client = client;

  final http.Client _client;
  final McpConnector? connector;
  final Duration timeout;
  final UrlPolicy? urlPolicy;

  @override
  Future<McpProbeReport> probe(McpServerConfig config) async {
    final options = McpClientOptions(
      httpClient: _client,
      clientInfo: const McpImplementation(name: 'sherpa', title: 'Sherpa', version: AppInfo.version),
      urlPolicy: urlPolicy,
    );
    McpConnection? c;
    try {
      final connect = connector ?? (cfg, o, t) => McpConnection.connect(cfg, options: o, transport: t);
      c = await connect(config, options, null).timeout(timeout);
      int? tools;
      if (c.capabilities.tools) {
        try {
          tools = (await c.listTools().timeout(const Duration(seconds: 10))).length;
        } on Object {
          tools = null;
        }
      }
      return McpProbeReport(
        era: c.era,
        protocolVersion: c.protocolVersion,
        transportKind: c.transportKind,
        serverName: c.serverInfo?.displayName,
        serverVersion: c.serverInfo?.version,
        verdict: c.verdict,
        toolCount: tools,
        hasResources: c.capabilities.resources,
        hasPrompts: c.capabilities.prompts,
      );
    } on McpAuthRequiredException {
      return const McpProbeReport(needsAuth: true);
    } on TimeoutException {
      return const McpProbeReport(error: 'The server did not answer in time.');
    } on Object catch (e) {
      return McpProbeReport(error: describeConnectError(e));
    } finally {
      await c?.close();
    }
  }
}

/// A connection failure in words.
String describeConnectError(Object e) => switch (e) {
      McpEraNegotiationException() || McpUnsupportedVersionException() =>
        "This doesn't look like an MCP server Sherpa can talk to (no common protocol version).",
      McpHttpStatusException(:final statusCode) when statusCode == 404 =>
        'Nothing answered at that address (404). Check the path, often /mcp or /sse.',
      McpHttpStatusException(:final statusCode) when statusCode >= 500 => 'The server had an error ($statusCode). Try again later.',
      McpHttpStatusException(:final statusCode) => 'The server refused the connection (HTTP $statusCode).',
      McpTimeoutException() => 'The server did not answer in time.',
      McpTransportException(:final message) when message.contains('policy') || message.contains('not allowed') =>
        "Sherpa doesn't connect to that address.",
      McpTransportException() || SocketException() || http.ClientException() =>
        "Couldn't reach the server. Check the address and your connection.",
      McpProtocolException() => 'The server sent something Sherpa could not understand.',
      McpServerUnavailableException(:final reason) => reason ?? 'The server is unavailable.',
      _ => 'Connecting failed (${e.runtimeType}).',
    };

/// The last error of a server in plain language, from the manager's
/// redacted text ("McpTransportException: …").
String describeLastError(String? raw) {
  if (raw == null || raw.isEmpty) return '';
  final r = raw.toLowerCase();
  if (r.startsWith('mcpauthrequiredexception')) return 'The server needs you to sign in.';
  if (r.contains('connection refused') || r.contains('failed host lookup') || r.contains('socketexception')) {
    return "Couldn't reach the server.";
  }
  if (r.contains('timeout') || r.contains('timed out') || r.contains('took longer')) return 'The server did not answer in time.';
  if (r.contains('the device is offline') || r.contains('network unavailable')) return 'Your device is offline.';
  if (r.startsWith('mcperanegotiationexception') || r.startsWith('mcpunsupportedversionexception')) {
    return 'No protocol version in common with this server.';
  }
  if (r.contains('http 404') || r.contains(' 404')) return 'Nothing answered at that address (404).';
  if (r.contains('http 5') || RegExp(r'\b5\d\d\b').hasMatch(r)) return 'The server had an internal error.';
  if (r.startsWith('mcpprotocolexception')) return 'The server sent an invalid response.';
  if (r.contains('no on-device server')) return 'This built-in server is not available in this build.';
  final colon = raw.indexOf(': ');
  final text = colon > 0 && colon < 40 ? raw.substring(colon + 2) : raw;
  return text.length > 160 ? '${text.substring(0, 159)}…' : text;
}
