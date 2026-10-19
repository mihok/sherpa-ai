import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sherpa/services/mcp/mcp_records.dart';
import 'package:sherpa/services/mcp/mcp_runtime.dart';
import 'package:sherpa_auth/sherpa_auth.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:sherpa_net/sherpa_net.dart';

/// Every host resolves to a public address, except the ones in [local].
Future<List<InternetAddress>> fakeResolver(String host, {Map<String, String> local = const {}}) async {
  final l = local[host];
  if (l != null) return [InternetAddress(l)];
  if (host.endsWith('.invalid')) throw const SocketException('no such host');
  return [InternetAddress('93.184.216.34')];
}

const fakeDevice = StaticDeviceFactsProvider(DeviceFacts(
  appName: 'Sherpa',
  appVersion: '0.1.0',
  platform: 'android',
  locale: 'en-US',
  timeZone: 'UTC',
  timeZoneOffset: Duration.zero,
));

DartMcpTool fakeTool(
  String name, {
  String? description,
  ToolAnnotations annotations = const ToolAnnotations(),
  JsonMap? schema,
}) =>
    DartMcpTool(
      name: name,
      description: description ?? 'Does $name things.',
      inputSchema: schema ?? const {'type': 'object', 'properties': <String, Object?>{}},
      annotations: annotations,
      handler: (args, ctx) async => DartToolResult.text('$name ok ${jsonEncode(args)}'),
    );

const ToolAnnotations readOnlyHints = ToolAnnotations(readOnlyHint: true, idempotentHint: true, openWorldHint: false);

/// "Remote" servers that are really in-process [DartMcpServer]s, keyed by
/// URL, behind the manager's connector seam. [requireBearer] makes a server
/// demand `Authorization: Bearer <token>` through the real auth hook.
final class FakeRemoteServers {
  final Map<String, DartMcpServer> servers = {};
  /// URL → whether a bearer token is accepted (unset: no auth needed).
  final Map<String, bool Function(String token)> requireBearer = {};
  final Map<String, String> resourceMetadata = {};
  final Set<String> down = {};
  int connects = 0;

  DartMcpServer add(
    String url, {
    List<DartMcpTool> tools = const [],
    List<DartMcpResource> resources = const [],
    List<DartMcpPrompt> prompts = const [],
    String name = 'fake',
  }) =>
      servers[url] = DartMcpServer(
        info: McpImplementation(name: name, title: name, version: '1.2.3'),
        tools: tools,
        resources: resources,
        prompts: prompts,
      );

  Future<McpConnection> connect(McpServerConfig config, McpClientOptions options, McpTransport? transport) async {
    if (config.transport == McpTransportPreference.inProcess) {
      return McpConnection.connect(config, options: options, transport: transport);
    }
    connects++;
    final key = config.url.toString();
    if (down.contains(key)) throw McpTransportException('connection refused');
    final accepts = requireBearer[key];
    if (accepts != null) {
      final hook = options.authHook!;
      bool ok(Map<String, String> h) {
        final a = h['authorization'];
        return a != null && a.startsWith('Bearer ') && accepts(a.substring(7));
      }

      if (!ok(await hook.headersFor(config.url))) {
        final decision = await hook.onAuthChallenge(config.url, 401, {
          'www-authenticate': 'Bearer resource_metadata="${resourceMetadata[key]}"',
        });
        if (decision != AuthRetry.retry || !ok(await hook.headersFor(config.url))) {
          throw McpAuthRequiredException(statusCode: 401, needsUserConsent: decision == AuthRetry.needsUserConsent);
        }
      }
    }
    final server = servers[key];
    if (server == null) throw McpTransportException('no fake server at $key');
    final (client, channel) = InProcessTransport.pair();
    server.serve(channel);
    return McpConnection.connect(config.copyWith(transport: McpTransportPreference.inProcess), options: options, transport: client);
  }
}

/// A browser that "signs in" by asking [approve] for the callback.
final class FakeBrowser implements BrowserLauncher {
  FakeBrowser([this.approve]);

  Uri Function(Uri url)? approve;
  final List<Uri> opened = [];

  @override
  Future<Uri> authorize(Uri url, {required String callbackScheme, bool ephemeral = false, Uri? redirectUri}) async {
    opened.add(url);
    final f = approve;
    if (f == null) throw AuthCancelledException();
    return f(url);
  }
}

/// A minimal OAuth 2.1 authorization server plus RFC 9728 metadata for one
/// MCP resource, behind a [MockClient].
final class FakeAuthWorld {
  FakeAuthWorld({this.resource = 'https://tools.example.com/mcp', this.issuer = 'https://auth.example.com', this.scopes = const ['tools:read']});

  final String resource;
  final String issuer;
  final List<String> scopes;
  final Map<String, String> _codes = {};
  final List<String> issued = [];
  final List<http.Request> requests = [];
  int _n = 0;

  String get prmUrl {
    final u = Uri.parse(resource);
    return '${u.origin}/.well-known/oauth-protected-resource${u.path}';
  }

  http.Response _json(Object body, {int status = 200}) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json', 'cache-control': 'no-store'});

  /// Handles requests for the fake AS / PRM; null for anything else.
  Future<http.Response?> handle(http.Request r) async {
    final url = r.url.toString();
    if (r.method == 'GET' && url == prmUrl) {
      requests.add(r);
      return _json({'resource': resource, 'authorization_servers': [issuer], 'scopes_supported': scopes});
    }
    if (r.method == 'GET' && url == '$issuer/.well-known/oauth-authorization-server') {
      requests.add(r);
      return _json({
        'issuer': issuer,
        'authorization_endpoint': '$issuer/authorize',
        'token_endpoint': '$issuer/token',
        'registration_endpoint': '$issuer/register',
        'response_types_supported': ['code'],
        'grant_types_supported': ['authorization_code', 'refresh_token'],
        'code_challenge_methods_supported': ['S256'],
        'token_endpoint_auth_methods_supported': ['none'],
        'scopes_supported': scopes,
        'authorization_response_iss_parameter_supported': true,
      });
    }
    if (r.method == 'POST' && url == '$issuer/register') {
      requests.add(r);
      final body = (jsonDecode(r.body) as Map).cast<String, Object?>();
      return _json({...body, 'client_id': 'client-${++_n}', 'client_id_issued_at': 1}, status: 201);
    }
    if (r.method == 'POST' && url == '$issuer/token') {
      requests.add(r);
      final form = Uri.splitQueryString(r.body);
      final challenge = _codes.remove(form['code']);
      if (challenge == null) return _json({'error': 'invalid_grant'}, status: 400);
      final verifier = form['code_verifier'] ?? '';
      final computed = base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
      if (computed != challenge || form['resource'] != resource) return _json({'error': 'invalid_grant'}, status: 400);
      final token = 'access-${++_n}';
      issued.add(token);
      return _json({'access_token': token, 'token_type': 'Bearer', 'expires_in': 3600, 'refresh_token': 'refresh-$_n', 'scope': scopes.join(' ')});
    }
    return null;
  }

  /// The user approves on the AS page.
  Uri approve(Uri authorizeUrl) {
    final q = authorizeUrl.queryParameters;
    final code = 'code-${++_n}';
    _codes[code] = q['code_challenge']!;
    return Uri.parse(q['redirect_uri']!).replace(queryParameters: {'code': code, 'state': q['state']!, 'iss': issuer});
  }

  MockClient client({Future<http.Response> Function(http.Request r)? fallback}) => MockClient((r) async {
        final h = await handle(r);
        if (h != null) return h;
        if (fallback != null) return fallback(r);
        return http.Response('not found', 404);
      });
}

/// A runtime over in-memory storage and fake servers.
Future<McpRuntime> fakeRuntime({
  McpRecords? records,
  SecretStore? secrets,
  FakeRemoteServers? remote,
  http.Client? client,
  BrowserLauncher? browser,
  Clock? clock,
  NoteStorage? notes,
}) =>
    McpRuntime.create(
      records: records ?? InMemoryMcpRecords(),
      secrets: secrets ?? InMemorySecretStore(),
      httpClient: client ?? MockClient((r) async => http.Response('no network in tests', 599)),
      browser: browser ?? FakeBrowser(),
      deviceFacts: fakeDevice,
      notes: notes ?? InMemoryNoteStorage(),
      clock: clock ?? FakeClock(DateTime.utc(2026, 10, 19, 12)),
      connector: (remote ?? FakeRemoteServers()).connect,
      resolver: fakeResolver,
      authPolicy: const AuthNetworkPolicy(publicPolicy: UrlPolicy(resolver: fakeResolver)),
      canInteract: () => true,
      startupTimeout: const Duration(seconds: 5),
    );

/// Polls [test] until it holds (real time; use inside `runAsync`).
Future<void> eventually(bool Function() test, {Duration timeout = const Duration(seconds: 5), String? what}) async {
  final deadline = DateTime.now().add(timeout);
  while (!test()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('timed out waiting for ${what ?? 'condition'}');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

ToolExecutionContext toolCtx(String sessionId) =>
    ToolExecutionContext(sessionId: sessionId, cancel: CancellationToken(), timeout: const Duration(seconds: 5));
