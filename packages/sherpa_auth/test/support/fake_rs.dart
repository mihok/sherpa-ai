import 'package:shelf/shelf.dart';
import 'package:sherpa_core/sherpa_core.dart';

import 'fake_as.dart';
import 'fake_http.dart';

/// A fake MCP server (OAuth protected resource) at `/mcp`.
///
/// - No/invalid/expired token → 401 with `resource_metadata` and the
///   operation's scope.
/// - Valid token for another resource (audience) → 401.
/// - Valid token lacking a scope → 403 `insufficient_scope` naming only the
///   missing scope (the 2025-11-25 style; the client must take the union).
///
/// The operation comes from the `x-op` request header; [requiredScopes]
/// maps it to scopes.
final class FakeMcpServer {
  FakeMcpServer._(this.http, this.as, this.path);

  static Future<FakeMcpServer> start(FakeAuthServer as, {String path = '/mcp'}) async {
    final fake = FakeMcpServer._(await FakeHttp.start(), as, path);
    fake._install();
    return fake;
  }

  final FakeHttp http;
  final FakeAuthServer as;
  final String path;

  Uri get url => http.root.replace(path: path);

  String get resource => '${http.origin}$path';

  Uri get prmUrl => Uri.parse('${http.origin}/.well-known/oauth-protected-resource$path');

  /// Advertise the PRM URL in `WWW-Authenticate` (else clients probe).
  bool advertiseMetadata = true;

  /// Overrides the PRM URL in the header.
  String? headerMetadataUrl;

  /// Edits the PRM before it is served.
  JsonMap Function(JsonMap prm)? editPrm;

  /// Authorization servers listed in the PRM; defaults to [as].
  List<String>? authorizationServers;

  Map<String, List<String>> requiredScopes = {'read': ['files:read'], 'write': ['files:read', 'files:write']};

  /// Tokens the server refuses even though the AS issued them.
  final Set<String> revoked = {};

  JsonMap get prm {
    final m = <String, Object?>{
      'resource': resource,
      'authorization_servers': authorizationServers ?? [as.issuer],
      'scopes_supported': ['files:read', 'files:write'],
      'bearer_methods_supported': ['header'],
      'resource_name': 'Example Files',
    };
    return editPrm == null ? m : editPrm!(m);
  }

  void _install() {
    http.route('GET /.well-known/oauth-protected-resource$path', (r, _) => json(prm));
    http.route('POST $path', (r, body) {
      final op = r.headers['x-op'] ?? 'read';
      final need = requiredScopes[op] ?? const <String>[];
      final auth = r.headers['authorization'];
      final token = auth != null && auth.startsWith('Bearer ') ? auth.substring(7) : null;
      final grant = token == null || revoked.contains(token) ? null : as.accessTokens[token];
      if (grant == null || grant.revoked || grant.resource != resource) {
        return _challenge(401, scope: need.join(' '));
      }
      final missing = need.where((s) => !grant.scopes.contains(s)).toList();
      if (missing.isNotEmpty) {
        return _challenge(403, scope: missing.join(' '), error: 'insufficient_scope');
      }
      return json({'ok': true, 'op': op});
    });
  }

  Response _challenge(int status, {required String scope, String? error}) {
    final parts = [
      if (error != null) 'error="$error"',
      if (scope.isNotEmpty) 'scope="$scope"',
      if (advertiseMetadata) 'resource_metadata="${headerMetadataUrl ?? prmUrl}"',
      if (error != null) 'error_description="Permission needed for this operation"',
    ];
    return Response(status, headers: {'www-authenticate': 'Bearer ${parts.join(', ')}'});
  }

  Future<void> close() => http.close();
}
