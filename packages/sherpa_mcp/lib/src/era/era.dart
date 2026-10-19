/// Protocol eras and the cached era verdict (basic/versioning.md
/// §Compatibility; R01 §3, §11).
library;

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart' show FormatError, JsonMap;

import '../protocol/json_read.dart';
import '../protocol/versions.dart';

/// The two wire eras: stateless 2026-07-28+, and the `initialize` era.
enum McpEra { modern, legacy }

/// The concrete wire binding a connection uses.
enum McpTransportKind {
  /// 2026-07-28 Streamable HTTP: POST only, per-request `_meta`.
  modernHttp(McpEra.modern),

  /// 2025-03-26 … 2025-11-25 Streamable HTTP with `Mcp-Session-Id`.
  legacyStreamableHttp(McpEra.legacy),

  /// The deprecated 2024-11-05 HTTP+SSE transport.
  legacySse(McpEra.legacy),

  /// A paired in-memory channel with stdio framing (either era).
  inProcess(null);

  const McpTransportKind(this.fixedEra);

  /// The era this binding implies, or null when it carries both.
  final McpEra? fixedEra;

  bool get isHttp => this != inProcess;
}

/// What era detection decided for one endpoint.
///
/// Verdicts are per server, not per request (versioning.md): clients
/// SHOULD cache them per origin and MAY persist them with the server
/// configuration, re-probing when the cached assumption fails. Sherpa keys
/// them by the full endpoint ([endpoint]), which refines per-origin caching
/// for hosts that serve different eras on different paths.
@immutable
final class EraVerdict {
  const EraVerdict({
    required this.transport,
    required this.protocolVersion,
    required this.endpoint,
    required this.decidedAt,
  });

  factory EraVerdict.fromJson(JsonMap j) {
    final t = asString(j['transport']);
    final kind = McpTransportKind.values.where((k) => k.name == t).firstOrNull;
    if (kind == null || kind == McpTransportKind.inProcess) throw FormatError('verdict: bad transport "$t"');
    final version = reqString(j, 'protocolVersion', 'verdict');
    final modern = McpVersions.isModern(version);
    if (modern != (kind.fixedEra == McpEra.modern)) throw FormatError('verdict: $version does not fit $t');
    return EraVerdict(
      transport: kind,
      protocolVersion: version,
      endpoint: reqString(j, 'endpoint', 'verdict'),
      decidedAt: DateTime.parse(reqString(j, 'decidedAt', 'verdict')),
    );
  }

  /// Never [McpTransportKind.inProcess]: in-process servers live and die
  /// with the app, so their era is re-probed (cheaply) on each connect.
  final McpTransportKind transport;
  final String protocolVersion;

  /// [endpointKey] of the URL the verdict was reached for.
  final String endpoint;
  final DateTime decidedAt;

  McpEra get era => transport.fixedEra!;

  /// Whether this verdict was reached for [url].
  bool appliesTo(Uri url) => endpoint == endpointKey(url);

  JsonMap toJson() => {
        'transport': transport.name,
        'protocolVersion': protocolVersion,
        'endpoint': endpoint,
        'decidedAt': decidedAt.toUtc().toIso8601String(),
      };

  @override
  bool operator ==(Object other) =>
      other is EraVerdict &&
      other.transport == transport &&
      other.protocolVersion == protocolVersion &&
      other.endpoint == endpoint;

  @override
  int get hashCode => Object.hash(transport, protocolVersion, endpoint);

  @override
  String toString() => 'EraVerdict(${transport.name} $protocolVersion @ $endpoint)';
}

/// Canonical cache key for an endpoint: lower-case scheme and host,
/// explicit port, path; no query or fragment.
String endpointKey(Uri url) {
  final scheme = url.scheme.toLowerCase();
  final port = url.hasPort ? url.port : (scheme == 'https' ? 443 : 80);
  final path = url.path.isEmpty ? '/' : url.path;
  return '$scheme://${url.host.toLowerCase()}:$port$path';
}

/// Process-lifetime verdict cache shared by connections. The app persists
/// verdicts through [McpServerConfig.cachedVerdict] instead.
final class EraVerdictCache {
  final Map<String, EraVerdict> _byEndpoint = {};

  EraVerdict? lookup(Uri url) => _byEndpoint[endpointKey(url)];

  void store(EraVerdict verdict) => _byEndpoint[verdict.endpoint] = verdict;

  void invalidate(Uri url) => _byEndpoint.remove(endpointKey(url));

  void clear() => _byEndpoint.clear();
}
