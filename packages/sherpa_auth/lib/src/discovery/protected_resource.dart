import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../common/redaction.dart';
import '../errors.dart';
import '../http/auth_http.dart';
import 'resource_uri.dart';

/// RFC 9728 OAuth 2.0 Protected Resource Metadata (§2, §3.2).
///
/// Strings that are compared or sent are kept *verbatim*: [resource] is
/// sent as the RFC 8707 `resource` parameter exactly as published (TS
/// issue #1968: re-serialising through a URL type adds a trailing `/`), and
/// [authorizationServers] entries are the issuers the AS metadata must
/// echo character for character. Unknown members are ignored (§3.2).
@immutable
final class ProtectedResourceMetadata {
  const ProtectedResourceMetadata({
    required this.resource,
    required this.authorizationServers,
    required this.metadataUrl,
    this.scopesSupported,
    this.bearerMethodsSupported,
    this.resourceName,
    this.resourceDocumentation,
    this.dpopBoundAccessTokensRequired = false,
    this.match = ResourceMatch.exact,
  });

  /// Parses a document; throws [FormatError] on a schema violation.
  factory ProtectedResourceMetadata.fromJson(JsonMap j, {required Uri metadataUrl, ResourceMatch match = ResourceMatch.exact}) {
    final resource = j.req<String>('resource');
    final r = Uri.tryParse(resource);
    if (r == null || !r.isAbsolute || r.host.isEmpty || !(r.scheme == 'https' || r.scheme == 'http')) {
      throw const FormatError('"resource" must be an absolute http(s) URI without a fragment');
    }
    return ProtectedResourceMetadata(
      resource: resource,
      authorizationServers: _strings(j, 'authorization_servers') ?? const [],
      metadataUrl: metadataUrl,
      scopesSupported: _strings(j, 'scopes_supported'),
      bearerMethodsSupported: _strings(j, 'bearer_methods_supported'),
      resourceName: j['resource_name'] is String ? j['resource_name']! as String : null,
      resourceDocumentation: j['resource_documentation'] is String ? Uri.tryParse(j['resource_documentation']! as String) : null,
      dpopBoundAccessTokensRequired: j['dpop_bound_access_tokens_required'] == true,
      match: match,
    );
  }

  final String resource;
  final List<String> authorizationServers;

  /// The URL the document was requested from.
  final Uri metadataUrl;
  final List<String>? scopesSupported;
  final List<String>? bearerMethodsSupported;

  /// Untrusted display string.
  final String? resourceName;
  final Uri? resourceDocumentation;
  final bool dpopBoundAccessTokensRequired;

  /// Whether [resource] matched exactly or by the relaxed prefix rule.
  final ResourceMatch match;

  JsonMap toJson() => compact({
        'resource': resource,
        'authorization_servers': authorizationServers,
        'scopes_supported': scopesSupported,
        'bearer_methods_supported': bearerMethodsSupported,
        'resource_name': resourceName,
        'resource_documentation': resourceDocumentation?.toString(),
        if (dpopBoundAccessTokensRequired) 'dpop_bound_access_tokens_required': true,
      });

  @override
  String toString() => 'ProtectedResourceMetadata($resource, as: $authorizationServers)';
}

List<String>? _strings(JsonMap j, String key) {
  final v = j[key];
  if (v == null) return null;
  if (v is! List) throw FormatError('"$key" must be an array of strings');
  return List.unmodifiable([
    for (final e in v)
      if (e is String) e else throw FormatError('"$key" must be an array of strings'),
  ]);
}

/// The well-known PRM URLs for [serverUrl], in the order ASD26 L37-47
/// mandates: path-aware first (omitted when the server is at the root),
/// then the root. RFC 9728 §3.1: a terminating `/` is removed and the
/// suffix goes between host and path, with the query kept after the path.
List<Uri> protectedResourceMetadataUrls(Uri serverUrl) {
  final u = serverUrl.removeFragment();
  final path = u.path.endsWith('/') ? u.path.substring(0, u.path.length - 1) : u.path;
  final query = u.hasQuery ? '?${u.query}' : '';
  const suffix = '/.well-known/oauth-protected-resource';
  return [
    if (path.isNotEmpty) Uri.parse('${u.origin}$suffix$path$query'),
    Uri.parse('${u.origin}$suffix'),
  ];
}

/// Fetches and validates the Protected Resource Metadata for [serverUrl].
///
/// Order (ASD26 L37-47): the challenge's [resourceMetadataUrl] when present
/// — falling back to the well-known URLs only if it answers 404 (a stale
/// header should not strand the user; the SDKs never fall back) — else the
/// path-aware and root well-known URLs. A header URL the network policy
/// refuses (cloud metadata, LAN, non-https) is an [AuthPolicyException], not
/// a reason to probe elsewhere: the server is pointing us somewhere unsafe.
///
/// Per candidate:
/// - no response → [AuthNetworkException] (offline is not "not found");
/// - 4xx, 502 or an unfollowed redirect → next candidate;
/// - other 5xx → [AuthServerException];
/// - 200 that is not a valid JSON object (an SPA's `index.html`), is
///   oversized, or whose `resource` fails [matchPolicy] → next candidate,
///   remembering why.
///
/// The returned metadata's `resource` matched [serverUrl] under
/// [matchPolicy]; a relaxed (path-prefix) match is logged. An empty
/// `authorization_servers` is a [DiscoveryFailure.noAuthorizationServers]
/// (MCP requires at least one; the SDKs' "the MCP origin is the AS"
/// fallback is 2025-03-26 behaviour Sherpa does not enable).
Future<ProtectedResourceMetadata> discoverProtectedResource({
  required Uri serverUrl,
  required AuthHttp http,
  Uri? resourceMetadataUrl,
  ResourceMatchPolicy matchPolicy = ResourceMatchPolicy.sameOriginPathPrefix,
  AuthLogger? logger,
}) async {
  final log = AuthLog(logger);
  final wellKnown = protectedResourceMetadataUrls(serverUrl);
  final candidates = resourceMetadataUrl != null ? [resourceMetadataUrl] : wellKnown;
  DiscoveryException? lastProblem;
  for (var i = 0; i < candidates.length; i++) {
    final url = candidates[i];
    final resp = await http.get(url);
    final status = resp.statusCode;
    if (resp.ok) {
      final json = resp.jsonObject();
      if (json == null) {
        lastProblem = DiscoveryException(DiscoveryFailure.resourceMetadataInvalid, 'PRM is not a JSON object', url: url);
        log.info('PRM at ${AuthRedact.uri(url)} is not JSON; trying the next location');
        continue;
      }
      final ProtectedResourceMetadata parsed;
      try {
        // The URL as requested (not after same-origin redirects), so a later
        // challenge naming the same URL is recognised as unchanged.
        parsed = ProtectedResourceMetadata.fromJson(json, metadataUrl: url);
      } on FormatError catch (e) {
        lastProblem = DiscoveryException(DiscoveryFailure.resourceMetadataInvalid, 'invalid PRM: ${e.message}', url: url);
        log.info('invalid PRM at ${AuthRedact.uri(url)}: ${e.message}');
        continue;
      }
      final match = matchResource(parsed.resource, serverUrl, matchPolicy);
      if (match == null) {
        lastProblem = DiscoveryException(
          DiscoveryFailure.resourceMismatch,
          'PRM resource ${AuthRedact.untrusted(parsed.resource, max: 120)} does not identify $serverUrl',
          url: url,
        );
        log.warning(lastProblem.message);
        continue;
      }
      if (match == ResourceMatch.pathPrefix) {
        log.info('PRM resource ${parsed.resource} accepted for $serverUrl by the same-origin path-prefix rule');
      }
      if (parsed.authorizationServers.isEmpty) {
        throw DiscoveryException(DiscoveryFailure.noAuthorizationServers, 'PRM lists no authorization server', url: url);
      }
      return ProtectedResourceMetadata(
        resource: parsed.resource,
        authorizationServers: parsed.authorizationServers,
        metadataUrl: parsed.metadataUrl,
        scopesSupported: parsed.scopesSupported,
        bearerMethodsSupported: parsed.bearerMethodsSupported,
        resourceName: parsed.resourceName,
        resourceDocumentation: parsed.resourceDocumentation,
        dpopBoundAccessTokensRequired: parsed.dpopBoundAccessTokensRequired,
        match: match,
      );
    }
    if (status >= 500 && status != 502) {
      throw AuthServerException('PRM request failed with HTTP $status', statusCode: status, url: url);
    }
    log.debug('no PRM at ${AuthRedact.uri(url)} (HTTP $status)');
    if (resourceMetadataUrl != null && identical(url, resourceMetadataUrl) && status == 404) {
      // A stale header URL: probe the well-known locations instead.
      log.info('resource_metadata URL answered 404; probing well-known locations');
      candidates.addAll(wellKnown.where((w) => w != resourceMetadataUrl));
    }
  }
  throw lastProblem ??
      DiscoveryException(DiscoveryFailure.resourceMetadataNotFound, 'no protected resource metadata for $serverUrl');
}
