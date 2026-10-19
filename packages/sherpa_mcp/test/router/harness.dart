import 'dart:async';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:sherpa_net/sherpa_net.dart' show Backoff;

/// A tool for test servers.
DartMcpTool tool(
  String name, {
  String? description,
  JsonMap? schema,
  ToolAnnotations annotations = const ToolAnnotations(),
  JsonMap? meta,
  DartToolHandler? handler,
  String? title,
}) =>
    DartMcpTool(
      name: name,
      title: title,
      description: description ?? 'Does $name things.',
      inputSchema: schema ?? const {'type': 'object', 'properties': <String, Object?>{}},
      annotations: annotations,
      meta: meta,
      handler: handler ?? (args, ctx) async => DartToolResult.text('$name ok ${canonicalJson(args)}'),
    );

const ToolAnnotations readOnly = ToolAnnotations(readOnlyHint: true, idempotentHint: true, openWorldHint: false);

const McpClientOptions fastOptions = McpClientOptions(
  timeouts: McpTimeouts(request: Duration(seconds: 5), inProcessProbe: Duration(milliseconds: 500)),
);

/// Servers hosted in-process, a manager with fast backoff, hygiene and a
/// router — the whole MCP tool layer without a network.
final class Harness {
  Harness({
    ToolBudget budget = ToolBudget.remote,
    this.autoApproveChanges = false,
    Set<String> alwaysOn = const {},
    ToolEmbedder? embedder,
    Duration maxCatalogAge = const Duration(minutes: 1),
    int maxReconnectAttempts = 8,
    Backoff? backoff,
    McpClientOptions options = fastOptions,
    int logCapacity = 200,
    Clock clock = const SystemClock(),
  }) {
    manager = McpServerManager(
      options: options,
      transportFactory: _transport,
      connector: _connect,
      logCapacity: logCapacity,
      backoff: backoff ?? Backoff(base: const Duration(milliseconds: 2), max: const Duration(milliseconds: 10)),
      connectTimeout: const Duration(seconds: 5),
      reconnectWait: const Duration(seconds: 2),
      maxReconnectAttempts: maxReconnectAttempts,
      onTrustChanged: (id, t) => trustChanges.add('$id=$t'),
      onConfigChanged: configChanges.add,
      onAuthRequired: (id, _) => authRequired.add(id),
    );
    hygiene = ToolHygiene(store: pins, clock: clock, autoApproveChanges: (_) => autoApproveChanges);
    router = McpToolRouter(
      manager: manager,
      clock: clock,
      hygiene: hygiene,
      enablement: enablement,
      defaultBudget: budget,
      alwaysOn: alwaysOn,
      embedder: embedder,
      maxCatalogAge: maxCatalogAge,
      onGrantsInvalidated: invalidated.add,
    );
  }

  final bool autoApproveChanges;
  late final McpServerManager manager;
  late final ToolHygiene hygiene;
  late final McpToolRouter router;
  final InMemoryToolPinStore pins = InMemoryToolPinStore();
  final InMemoryToolEnablement enablement = InMemoryToolEnablement();
  final Map<String, DartMcpServer> servers = {};
  final List<String> trustChanges = [];
  final List<McpServerConfig> configChanges = [];
  final List<String> authRequired = [];
  final List<String> invalidated = [];

  /// Servers whose connect attempts fail with a transport error.
  final Set<String> down = {};

  /// Servers whose connect attempts demand OAuth.
  final Set<String> needAuth = {};

  /// Servers whose connect attempts take this long first.
  final Map<String, Duration> slow = {};
  int connects = 0;

  McpTransport? _transport(McpServerConfig c) {
    final s = servers[c.id];
    if (s == null) return null;
    final (client, channel) = InProcessTransport.pair();
    s.serve(channel);
    return client;
  }

  Future<McpConnection> _connect(McpServerConfig c, McpClientOptions o, McpTransport? t) async {
    connects++;
    final delay = slow[c.id];
    if (delay != null) await Future<void>.delayed(delay);
    if (down.contains(c.id)) {
      await t?.close();
      throw McpTransportException('connection refused');
    }
    if (needAuth.contains(c.id)) {
      await t?.close();
      throw McpAuthRequiredException(statusCode: 401, needsUserConsent: true);
    }
    return McpConnection.connect(c, options: o, transport: t);
  }

  McpServerConfig add(String id, List<DartMcpTool> tools, {bool trusted = true, String? name, bool enabled = true}) {
    final server = DartMcpServer(info: McpImplementation(name: id, version: '1'), tools: tools);
    servers[id] = server;
    final config = McpServerConfig(
      id: id,
      name: name ?? id,
      url: Uri.parse('sherpa-inprocess://$id'),
      transport: McpTransportPreference.inProcess,
      trusted: trusted,
      enabled: enabled,
    );
    manager.addServer(config);
    return config;
  }

  /// Drops every live session of [id] (the client sees McpConnectionLost).
  Future<void> dropConnections(String id) => servers[id]!.close();

  ToolExecutionContext ctx(String sessionId, {CancellationToken? cancel, Duration timeout = const Duration(seconds: 5)}) =>
      ToolExecutionContext(sessionId: sessionId, cancel: cancel ?? CancellationToken(), timeout: timeout);

  Future<ToolResult> call(String sessionId, String name, [JsonMap args = const {}, String id = 'c1']) =>
      router.execute(ToolCall(id: id, name: name, arguments: args), ctx(sessionId));

  Future<List<String>> names(String sessionId, {String? query, int? budget}) async => [
        for (final t in await router.toolsForTurn(sessionId: sessionId, query: query, schemaTokenBudget: budget)) t.name,
      ];

  Future<void> close() async {
    await router.dispose();
    await manager.dispose();
    for (final s in servers.values) {
      await s.close();
    }
  }
}

String textOf(ToolResult r) => [for (final p in r.content) if (p is TextPart) p.text].join('\n');

/// Waits until [test] holds (polling), failing after [timeout].
Future<void> until(bool Function() test, {Duration timeout = const Duration(seconds: 5)}) async {
  final sw = Stopwatch()..start();
  while (!test()) {
    if (sw.elapsed > timeout) throw TimeoutException('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
