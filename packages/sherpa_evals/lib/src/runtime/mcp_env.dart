/// In-process MCP servers behind the real client stack: era probe,
/// `McpServerManager`, `ToolHygiene` (pins, scanner, quarantine) and
/// `McpToolRouter` (namespacing, budgets, `tool_search`/`call_tool`,
/// argument validation, idempotency keys). Nothing is faked above the
/// transport.
library;

import 'dart:async';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:sherpa_net/sherpa_net.dart' show Backoff;

const McpClientOptions _fastOptions = McpClientOptions(
  timeouts: McpTimeouts(request: Duration(seconds: 20), inProcessProbe: Duration(seconds: 2)),
);

/// A set of [DartMcpServer]s served in-process to one router.
///
/// [autoApproveChanges] is false by default, unlike the app's on-device
/// servers: eval servers stand in for third-party servers, whose changed
/// definitions must be quarantined.
final class McpEnv {
  McpEnv({
    ToolBudget? budget,
    bool autoApproveChanges = false,
    Clock clock = const SystemClock(),
    Duration maxCatalogAge = Duration.zero,
    InMemoryToolPinStore? pins,
  }) : pins = pins ?? InMemoryToolPinStore() {
    manager = McpServerManager(
      options: _fastOptions,
      transportFactory: _transport,
      backoff: Backoff(base: const Duration(milliseconds: 2), max: const Duration(milliseconds: 10)),
      connectTimeout: const Duration(seconds: 10),
      reconnectWait: const Duration(seconds: 2),
    );
    hygiene = ToolHygiene(store: pins, clock: clock, autoApproveChanges: (_) => autoApproveChanges);
    router = McpToolRouter(
      manager: manager,
      clock: clock,
      hygiene: hygiene,
      defaultBudget: budget,
      maxCatalogAge: maxCatalogAge,
      refreshTimeout: const Duration(seconds: 10),
      onGrantsInvalidated: invalidated.add,
    );
  }

  late final McpServerManager manager;
  late final ToolHygiene hygiene;
  late final McpToolRouter router;
  /// Approved definitions; share it between two envs to model the pins a
  /// restarted app reads back from disk.
  final InMemoryToolPinStore pins;
  final Map<String, DartMcpServer> servers = {};

  /// Servers whose `notifications/tools/list_changed` never reach the
  /// client (a server that changes its tools silently).
  final Set<String> muteListChanged = {};
  final List<String> invalidated = [];

  McpTransport? _transport(McpServerConfig c) {
    final s = servers[c.id];
    if (s == null) return null;
    final (client, channel) = InProcessTransport.pair();
    s.serve(_MutingChannel(channel, () => muteListChanged.contains(c.id)));
    return client;
  }

  /// Adds [server] under [id] (its tool namespace: `<id>__<tool>`).
  McpServerConfig add(String id, DartMcpServer server, {bool trusted = true, String? name}) {
    servers[id] = server;
    final config = McpServerConfig(
      id: id,
      name: name ?? id,
      url: Uri.parse('sherpa-inprocess://$id'),
      transport: McpTransportPreference.inProcess,
      trusted: trusted,
    );
    manager.addServer(config);
    return config;
  }

  /// Lists every server and approves every quarantined tool, as a user who
  /// reviewed them would. Returns the approved model names.
  Future<List<String>> reviewAll() async {
    // The app opens change feeds when it comes to the foreground.
    if (!manager.isListening) await manager.listen();
    await router.refresh(force: true);
    final approved = <String>[];
    for (final e in router.catalog) {
      if (e.quarantined && await router.approve(e.modelName)) approved.add(e.modelName);
    }
    return approved;
  }

  /// The trusted server ids, for `ApprovalPolicy.trustedServers`.
  Set<String> get trustedServerIds => {for (final c in manager.servers) if (c.trusted) c.id};

  Future<void> close() async {
    await router.dispose();
    await manager.dispose();
    for (final s in servers.values) {
      await s.close();
    }
  }
}

/// Drops `notifications/tools/list_changed` on the way to the client while
/// [_muted] says so.
final class _MutingChannel implements McpMessageChannel {
  _MutingChannel(this._inner, this._muted);

  final McpMessageChannel _inner;
  final bool Function() _muted;

  @override
  Stream<String> get messages => _inner.messages;

  @override
  void send(String message) {
    if (_muted() && message.contains('notifications/tools/list_changed')) return;
    _inner.send(message);
  }

  @override
  Future<void> close() => _inner.close();
}

/// A [DartMcpTool] from a compact spec.
DartMcpTool mcpTool(
  String name, {
  required String description,
  required DartToolHandler handler,
  Map<String, Object?> properties = const {},
  List<String> required = const [],
  ToolAnnotations annotations = const ToolAnnotations(),
  String? title,
}) =>
    DartMcpTool(
      name: name,
      title: title,
      description: description,
      inputSchema: {
        'type': 'object',
        'properties': properties,
        if (required.isNotEmpty) 'required': required,
      },
      annotations: annotations,
      handler: handler,
    );

/// Annotation presets for eval tools (honest hints; the policy trusts them
/// only for trusted servers).
abstract final class Hints {
  static const ToolAnnotations read = ToolAnnotations(readOnlyHint: true, idempotentHint: true, openWorldHint: false);
  static const ToolAnnotations readOpen = ToolAnnotations(readOnlyHint: true, idempotentHint: true, openWorldHint: true);
  static const ToolAnnotations idempotentWrite =
      ToolAnnotations(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false);
  static const ToolAnnotations write =
      ToolAnnotations(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false);
  static const ToolAnnotations send =
      ToolAnnotations(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true);
  static const ToolAnnotations destructive =
      ToolAnnotations(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false);
  static const ToolAnnotations destructiveOpen =
      ToolAnnotations(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true);

  static ToolAnnotations byName(String kind) => switch (kind) {
        'read' || 'read_closed' => read,
        'read_open' => readOpen,
        'idempotent_write' => idempotentWrite,
        'write' => write,
        'send' => send,
        'destructive' => destructive,
        'destructive_open' => destructiveOpen,
        _ => throw ArgumentError.value(kind, 'kind', 'unknown tool kind'),
      };
}

/// Waits until [test] holds, polling; false on timeout.
Future<bool> waitUntil(bool Function() test, {Duration timeout = const Duration(seconds: 5)}) async {
  final sw = Stopwatch()..start();
  while (!test()) {
    if (sw.elapsed > timeout) return false;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return true;
}
