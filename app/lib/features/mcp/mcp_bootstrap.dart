import 'dart:async';
import 'dart:io' show HttpClient, Platform;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:cupertino_http/cupertino_http.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:sherpa_auth/sherpa_auth.dart' show BrowserLauncher;
import 'package:sherpa_core/sherpa_core.dart' show SecretStore;
import 'package:sherpa_data/sherpa_data.dart' show JsonDocumentStore;
import 'package:sherpa_mcp/sherpa_mcp.dart' show DeviceFactsProvider;

import '../../services/mcp/auth/oauth_platform.dart';
import '../../services/mcp/device_facts.dart';
import '../../services/mcp/mcp_records.dart';
import '../../services/mcp/mcp_runtime.dart';
import '../../state/connectivity.dart' show NetworkStatus, statusFor;
import '../../state/providers.dart';
import '../../state/sessions.dart' show sessionDeletedHooksProvider;
import '../apps/state/apps_providers.dart' show mcpAppModelContextsProvider, mcpAppViewPoolProvider;
import 'state/input_providers.dart';
import 'state/mcp_providers.dart';

/// `ProviderScope` overrides that wire MCP: built-in and remote tool
/// servers, the tool router, approvals with persisted grants, and OAuth.
/// Spread into `bootstrap()`'s list:
///
/// ```dart
/// ...await mcpFeatureOverrides(docs: docs, secrets: secrets),
/// ```
///
/// - [docs]: the encrypted document store (server configs, tool pins and
///   switches, approval grants, memory notes; never a token).
/// - [secrets]: the Keychain / Keystore store; OAuth tokens live only here.
/// - [httpClient]: the HTTP stack for MCP servers, OAuth and the MCP
///   Registry; defaults to [mcpHttpClient]. It must not follow redirects on
///   its own (`IOClient` and `CupertinoClient` honour `followRedirects =
///   false`).
/// - [connectivity]: interface changes (defaults to connectivity_plus).
///
/// Overrides `toolRouterProvider` (built-ins + MCP) and
/// `approvalPolicyProvider` (one policy, trusting the user's trusted
/// servers), plus `mcpRuntimeProvider`, `mcpHttpClientProvider`,
/// `toolsReadyProvider`, `toolsUserTurnHookProvider`,
/// `sessionDeletedHooksProvider` (a deleted chat's tool switches,
/// sampling grants and app views are forgotten) and `mcpInputQueueProvider` (requests
/// for elicitation and sampling, answered through `McpInputHost`).
/// Start-up lists
/// every server's tools in the background; launch is not blocked (await
/// `toolsReadyProvider` before resuming a run).
Future<List<Override>> mcpFeatureOverrides({
  required JsonDocumentStore docs,
  required SecretStore secrets,
  http.Client? httpClient,
  Stream<List<ConnectivityResult>>? connectivity,
  BrowserLauncher browser = const FlutterWebAuthBrowserLauncher(),
  DeviceFactsProvider? deviceFacts,
}) async {
  httpClient ??= mcpHttpClient();
  final runtime = await McpRuntime.create(
    records: DocumentMcpRecords(docs),
    secrets: secrets,
    httpClient: httpClient,
    browser: browser,
    deviceFacts: deviceFacts ?? PlatformDeviceFactsProvider(),
  );
  return _start(runtime, httpClient: httpClient, connectivity: connectivity);
}

/// For `bootstrap(inMemory: true)`: the same wiring over volatile records.
Future<List<Override>> inMemoryMcpFeatureOverrides({
  required SecretStore secrets,
  http.Client? httpClient,
  Stream<List<ConnectivityResult>>? connectivity,
}) async {
  httpClient ??= mcpHttpClient();
  final runtime = await McpRuntime.create(records: InMemoryMcpRecords(), secrets: secrets, httpClient: httpClient);
  return _start(runtime, httpClient: httpClient, connectivity: connectivity);
}

List<Override> _start(McpRuntime runtime, {required http.Client httpClient, Stream<List<ConnectivityResult>>? connectivity}) {
  runtime
    ..attachLifecycle()
    ..attachNetwork(onlineStream(connectivity ?? _connectivity()));
  unawaited(runtime.start());
  return mcpRuntimeOverrides(runtime, httpClient: httpClient);
}

/// The overrides for an already built [McpRuntime] (tests use this with
/// fakes; [mcpFeatureOverrides] with the real thing).
List<Override> mcpRuntimeOverrides(McpRuntime runtime, {http.Client? httpClient}) => [
      mcpRuntimeProvider.overrideWithValue(runtime),
      approvalPolicyProvider.overrideWithValue(runtime.policy),
      toolRouterProvider.overrideWith((ref) => runtime.toolRouter(ref.watch(sessionStoreProvider))),
      toolsReadyProvider.overrideWithValue(() => runtime.ready),
      toolsUserTurnHookProvider.overrideWithValue(runtime.onUserTurn),
      // A deleted chat's tool switches, router state, sampling grants and
      // app views go with it.
      sessionDeletedHooksProvider.overrideWith((ref) => [
            (id) async {
              runtime.router.forgetSession(id);
              runtime.hostSettings.forgetSession(id);
              ref.read(mcpAppViewPoolProvider).closeSession(id);
              ref.read(mcpAppModelContextsProvider).take(id);
              await runtime.enablement.forgetSession(id);
            },
          ]),
      mcpInputQueueProvider.overrideWithValue(runtime.inputQueue),
      if (httpClient != null) mcpHttpClientProvider.overrideWithValue(httpClient),
    ];

/// The platform HTTP stack for MCP and OAuth: an EPHEMERAL URLSession on
/// iOS (no `Cache.db`, so token responses never land on disk; R02 §13),
/// dart:io elsewhere.
http.Client mcpHttpClient() {
  if (Platform.isIOS || Platform.isMacOS) {
    return CupertinoClient.fromSessionConfiguration(URLSessionConfiguration.ephemeralSessionConfiguration());
  }
  return IOClient(HttpClient()..connectionTimeout = const Duration(seconds: 20));
}

Stream<List<ConnectivityResult>> _connectivity() async* {
  final c = Connectivity();
  try {
    yield await c.checkConnectivity();
  } on Object {
    // Unknown counts as online (a broken signal must never block the user).
  }
  yield* c.onConnectivityChanged;
}

/// Online / offline as the MCP manager should treat it: only a definite
/// "no network" pauses reconnects.
Stream<bool> onlineStream(Stream<List<ConnectivityResult>> raw) =>
    raw.map((r) => statusFor(r) != NetworkStatus.offline).handleError((Object _) {}).distinct();
