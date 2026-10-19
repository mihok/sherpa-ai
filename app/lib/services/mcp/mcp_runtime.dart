import 'dart:async';
import 'dart:io' show InternetAddress;

import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState;
import 'package:http/http.dart' as http;
import 'package:sherpa_auth/sherpa_auth.dart' show AuthLogger, AuthNetworkPolicy, BrowserLauncher;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:sherpa_net/sherpa_net.dart' show Backoff, UrlPolicy;

import '../../app_info.dart';
import 'auth/mcp_oauth.dart';
import 'auth/oauth_platform.dart';
import 'input/host_settings.dart';
import 'input/input_history.dart';
import 'input/input_queue.dart';
import 'input/interactive_handler.dart';
import 'mcp_records.dart';

/// The app's MCP host: built-in and remote servers, tool hygiene, the tool
/// router, approvals and OAuth, wired once for the app's lifetime.
///
/// * **Servers.** Two on-device servers ship with the app ([memoryServerId]
///   over the document store, [deviceServerId] over sherpa_platform) and
///   are trusted; remote servers come from [McpServerConfigStore]. The
///   [McpServerManager] connects lazily and persists every config change.
/// * **Trust.** `onTrustChanged` feeds the [ApprovalPolicy]; untrusted
///   servers' annotations are display material only.
/// * **Hygiene.** Every `tools/list` is pinned and diffed ([ToolHygiene]
///   over [DocumentToolPinStore]); new tools of untrusted servers and every
///   changed tool wait for the user's review.
/// * **Approvals.** Grants are bound to the reviewed definition hash and
///   persisted ([ApprovalGrantStore]); re-approving a changed tool also
///   revokes its old grants.
/// * **OAuth.** [McpOAuthService] supplies bearer tokens and turns 401/403
///   challenges into consent requests for the UI; after the user signs in,
///   the server reconnects.
/// * **Input (M5).** Elicitation, URL consent and sampling go to the
///   [InteractiveInputHandler]: requests wait in [inputQueue] for the UI
///   and end up, redacted, in [inputHistory]. What each server may ask for
///   is declared per server from [hostSettings]: sampling only when the
///   user turned it on (off by default), the MCP Apps extension unless the
///   user turned apps off for that server. Changing either reconnects the
///   server so the new capabilities apply.
/// * **Lifecycle.** [start] lists every server's tools without blocking
///   the app; [ready] completes when that is done (await it before
///   `AgentRunner.resume`, whose first step looks tools up synchronously;
///   the app exposes it as `toolsReadyProvider`).
///   Foreground opens change feeds, background closes them, connectivity
///   pauses reconnects.
final class McpRuntime {
  McpRuntime._({
    required this.records,
    required this.configs,
    required this.enablement,
    required this.grants,
    required this.onDevice,
    required this.clock,
    required this.startupTimeout,
    required this.hostSettings,
    required this.inputQueue,
    required this.inputHistory,
    required this.notes,
  });

  static const String memoryServerId = 'memory';
  static const String deviceServerId = 'device';

  /// Ids a user-added server can never take.
  static const Set<String> reservedIds = {memoryServerId, deviceServerId, McpToolRouter.proxyServerId};

  /// Builds the runtime from storage. Nothing connects until [start].
  static Future<McpRuntime> create({
    required McpRecords records,
    required SecretStore secrets,
    required http.Client httpClient,
    BrowserLauncher browser = const FlutterWebAuthBrowserLauncher(),
    DeviceFactsProvider? deviceFacts,
    NoteStorage? notes,
    Clock clock = const SystemClock(),
    McpConnector? connector,
    InputRequestHandler? inputHandler,
    Future<List<InternetAddress>> Function(String host)? resolver,
    UrlPolicy? urlPolicy,
    AuthNetworkPolicy authPolicy = const AuthNetworkPolicy(),
    bool Function()? canInteract,
    Backoff? backoff,
    Duration startupTimeout = const Duration(seconds: 8),
    AuthLogger? authLogger,
    Duration inputTimeout = const Duration(minutes: 5),
  }) async {
    final configs = McpServerConfigStore(records);
    final enablement = await PersistentToolEnablement.load(records);
    final grants = ApprovalGrantStore(records, clock: clock);
    final stored = await configs.load();
    final onDevice = OnDeviceServers();
    final noteStorage = notes ?? DocumentNoteStorage(records);
    final rt = McpRuntime._(
      records: records,
      configs: configs,
      enablement: enablement,
      grants: grants,
      onDevice: onDevice,
      clock: clock,
      startupTimeout: startupTimeout,
      hostSettings: await McpHostSettingsStore.load(records, clock: clock),
      inputQueue: McpInputQueue(clock: clock, timeout: inputTimeout),
      inputHistory: McpInputHistory(),
      notes: noteStorage,
    );

    bool storedEnabled(String id) => stored.where((s) => s.$1.id == id).firstOrNull?.$1.enabled ?? true;
    final memory = onDevice.register(
      memoryMcpServer(MemoryNotes(store: noteStorage, clock: clock)),
      id: memoryServerId,
      name: 'Memory',
      enabled: storedEnabled(memoryServerId),
    );
    final device = onDevice.register(
      deviceMcpServer(provider: deviceFacts ?? const _UnknownDeviceFacts(), clock: clock),
      id: deviceServerId,
      name: 'Device',
      enabled: storedEnabled(deviceServerId),
    );
    final remote = [
      for (final (c, _) in stored)
        if (!reservedIds.contains(c.id) && c.transport != McpTransportPreference.inProcess) c,
    ];

    rt.oauth = McpOAuthService(
      secrets: secrets,
      httpClient: httpClient,
      browser: browser,
      configForUrl: (url) => rt.manager.servers.where((c) => c.url == url).firstOrNull,
      configForId: (id) => rt.manager.config(id),
      clock: clock,
      canInteract: canInteract,
      resolver: resolver,
      policy: authPolicy,
      logger: authLogger,
    );
    final connect = connector ?? (c, o, t) => McpConnection.connect(c, options: o, transport: t);
    rt.manager = McpServerManager(
      servers: [memory, device, ...remote],
      options: McpClientOptions(
        httpClient: httpClient,
        clientInfo: const McpImplementation(name: 'sherpa', title: 'Sherpa', version: AppInfo.version),
        // Per server in _optionsFor: sampling only when allowed, apps unless off.
        capabilities: const McpClientCapabilities(mcpApps: true),
        inputHandler: inputHandler ??
            InteractiveInputHandler(
              queue: rt.inputQueue,
              settings: rt.hostSettings,
              history: rt.inputHistory,
              isTrusted: (id) => rt.manager.config(id)?.trusted ?? false,
              completions: (id) =>
                  rt.manager.connectedOrNull(id)?.changes.where((c) => c is McpElicitationCompleted).cast<McpElicitationCompleted>() ??
                  const Stream.empty(),
              clock: clock,
            ),
        authHook: rt.oauth,
        clock: clock,
        urlPolicy: urlPolicy,
        logLevel: McpLogLevel.info,
      ),
      connector: (config, options, transport) => connect(config, rt._optionsFor(config.id, options), transport),
      transportFactory: onDevice.transportFor,
      backoff: backoff,
      clock: clock,
      onTrustChanged: (id, trusted) => trusted ? rt.policy.trustServer(id) : rt.policy.untrustServer(id),
      onConfigChanged: (c) => unawaited(rt.configs.save(c)),
      onAuthRequired: (id, _) => rt._emit(),
    );
    rt.policy = ApprovalPolicy(
      clock: clock,
      trustedServers: rt.manager.trustedServerIds,
      grants: await grants.load(),
      onGrantsChanged: (g) {
        unawaited(rt.grants.save(g));
        rt._emit();
      },
    );
    rt._pins = DocumentToolPinStore(records);
    rt.hygiene = ToolHygiene(store: rt._pins, clock: clock);
    rt.router = McpToolRouter(
      manager: rt.manager,
      hygiene: rt.hygiene,
      enablement: enablement,
      clock: clock,
      onGrantsInvalidated: (name) => rt.policy.revoke(name),
    );
    rt.oauth.onAuthorized = (id) async {
      try {
        await rt.manager.reconnect(id);
      } on Object {
        // The server list shows why; tools load on the next use.
      }
      await rt.refresh();
    };
    rt._subs.addAll([
      rt.manager.events.listen((_) => rt._emit()),
      rt.hygiene.changes.listen((_) => rt._emit()),
      enablement.changes.listen((_) => rt._emit()),
      rt.oauth.changes.listen((_) => rt._emit()),
      rt.hostSettings.changes.listen((_) => rt._emit()),
      rt.inputHistory.changes.listen((_) => rt._emit()),
    ]);
    return rt;
  }

  /// What [serverId] may ask for: elicitation always (the only
  /// non-deprecated client feature), sampling only when the user allowed
  /// it, the MCP Apps extension unless apps are off for it.
  McpClientOptions _optionsFor(String serverId, McpClientOptions base) {
    final s = hostSettings.of(serverId);
    return base.copyWith(
      capabilities: base.capabilities.copyWith(sampling: s.samplingDeclared, mcpApps: s.appsEnabled),
    );
  }

  final McpRecords records;
  final McpServerConfigStore configs;
  final PersistentToolEnablement enablement;
  final ApprovalGrantStore grants;
  final OnDeviceServers onDevice;
  final Clock clock;
  final Duration startupTimeout;

  /// Sampling permission and limits, MCP Apps switches and app network
  /// consents, per server.
  final McpHostSettingsStore hostSettings;

  /// Input requests waiting for the user (the UI answers them).
  final McpInputQueue inputQueue;

  /// What servers asked for and how it ended (redacted; the console).
  final McpInputHistory inputHistory;

  /// The built-in memory server's notes (user data).
  final NoteStorage notes;

  late final McpServerManager manager;
  late final DocumentToolPinStore _pins;
  late final ApprovalPolicy policy;
  late final ToolHygiene hygiene;
  late final McpToolRouter router;
  late final McpOAuthService oauth;

  final List<StreamSubscription<Object?>> _subs = [];
  final StreamController<void> _changes = StreamController.broadcast();
  Future<void>? _ready;
  AppLifecycleListener? _lifecycle;
  StreamSubscription<bool>? _network;
  bool _disposed = false;
  bool _emitScheduled = false;

  /// Something about servers, tools, grants or sign-in changed. Coalesced
  /// to one event per microtask.
  Stream<void> get changes => _changes.stream;

  void _emit() {
    if (_disposed || _emitScheduled) return;
    _emitScheduled = true;
    scheduleMicrotask(() {
      _emitScheduled = false;
      if (!_disposed && !_changes.isClosed) _changes.add(null);
    });
  }

  /// What [serverId] asked for (forms, web pages, model use) and how each
  /// request ended, oldest first. Redacted: never the answers.
  List<McpInputRecord> inputRecords(String serverId) => inputHistory.of(serverId);

  // ---------------------------------------------------------------- host settings

  McpServerHostSettings hostSettingsOf(String serverId) => hostSettings.of(serverId);

  /// For "Delete all data": sampling and MCP Apps settings, app network
  /// consents, and the input history; pending requests are declined.
  Future<void> eraseInputData() async {
    for (final c in servers) {
      inputQueue.dropServer(c.id);
      inputHistory.forget(c.id);
    }
    await hostSettings.eraseAll();
  }

  /// "Delete all data" for MCP, as a `dataEraseHooksProvider` hook:
  /// * every user-added server goes: its connection and config, and its
  ///   OAuth state through [McpOAuthService.signOut] (tokens revoked when
  ///   the server answers within [revokeTimeout], deleted either way, plus
  ///   pending sign-ins); the built-in servers stay, back to their defaults
  ///   (on);
  /// * the memory server's notes;
  /// * tool pins (reviewed definitions) and every tool switch (global and
  ///   per chat);
  /// * remembered approvals: the policy's grants and the stored collection;
  /// * the input data ([eraseInputData]): sampling and MCP Apps settings,
  ///   network consents, the input history; pending requests are declined.
  ///
  /// The built-in servers' tools are listed again afterwards. Each part is
  /// best effort, so one failure does not keep the rest.
  Future<void> eraseAll({Duration revokeTimeout = const Duration(seconds: 5)}) async {
    Future<void> step(Future<void> Function() part) async {
      try {
        await part();
      } on Object {
        // Best effort: the other parts still go.
      }
    }

    await step(eraseInputData);
    final removed = [for (final c in servers) if (!isBuiltIn(c.id)) c];
    for (final c in removed) {
      await step(() => manager.removeServer(c.id));
      await step(() async {
        try {
          await oauth.signOut(c).timeout(revokeTimeout);
        } on TimeoutException {
          await oauth.signOut(c, revoke: false);
        }
      });
      oauth.forget(c.id);
    }
    for (final id in const [memoryServerId, deviceServerId]) {
      if (manager.config(id) != null) await step(() => manager.setEnabled(id, true));
    }
    await step(configs.clear);
    await step(() async {
      for (final key in await notes.keys()) {
        await notes.delete(key);
      }
    });
    await step(() async {
      await _pins.clear();
      for (final c in servers) {
        await hygiene.forgetServer(c.id);
      }
      for (final c in removed) {
        await hygiene.forgetServer(c.id);
      }
    });
    await step(enablement.clear);
    policy.revokeWhere((_) => true);
    await step(grants.clear);
    await refresh(force: true);
    _emit();
  }

  /// Saves [next] for [serverId]. When what the server may ask for changes
  /// (sampling declared or not, MCP Apps on or off) the server reconnects,
  /// so the capabilities it sees change (and it may offer other tools).
  Future<void> updateHostSettings(String serverId, McpServerHostSettings next) async {
    final before = hostSettings.of(serverId);
    await hostSettings.update(serverId, next);
    final redeclare = before.samplingDeclared != next.samplingDeclared || before.appsEnabled != next.appsEnabled;
    final status = manager.config(serverId) == null ? null : manager.health(serverId).status;
    // Connected or connecting (a connect in flight still uses the old
    // capabilities): reconnect. Idle servers pick them up on first use.
    if (redeclare && status != null && status != McpServerStatus.idle && status != McpServerStatus.disabled) {
      await reconnect(serverId);
    }
    _emit();
  }

  // ---------------------------------------------------------------- lifecycle

  /// Lists every enabled server's tools (bounded by [startupTimeout]) and
  /// opens change feeds. Idempotent; never throws; never blocks launch.
  Future<void> start() => _ready ??= _startup();

  Future<void> _startup() async {
    try {
      await router.refresh().timeout(startupTimeout);
    } on Object {
      // Slow or broken servers keep loading in the background.
    }
    if (_disposed) return;
    try {
      await manager.listen();
    } on Object {
      // Change feeds are best effort.
    }
    _emit();
  }

  /// Completes once the start-up refresh is done (or timed out). The agent
  /// loop must not resume an interrupted run before this: its first step
  /// resolves tool names synchronously against what has been listed.
  Future<void> get ready => _ready ?? start();

  /// Follows the app lifecycle: change feeds only in the foreground (R01
  /// rec. 7–8), and a re-validation of tool lists on return.
  void attachLifecycle() {
    _lifecycle ??= AppLifecycleListener(onStateChange: (state) {
      if (_disposed) return;
      switch (state) {
        case AppLifecycleState.resumed:
          unawaited(manager.listen().catchError((Object _) {}));
        case AppLifecycleState.hidden || AppLifecycleState.paused:
          unawaited(manager.stopListening().catchError((Object _) {}));
        case AppLifecycleState.inactive || AppLifecycleState.detached:
          break;
      }
    });
  }

  /// Follows connectivity: offline pauses reconnects and makes remote calls
  /// fail fast; back online reconnects at once.
  void attachNetwork(Stream<bool> online) {
    unawaited(_network?.cancel());
    _network = online.listen((up) {
      if (!_disposed) manager.setNetworkAvailable(up);
    });
  }

  /// Call at a user-turn boundary (before sending a new user message): if
  /// the session's frozen tool list no longer matches what a new segment
  /// would offer (servers added, tools approved or switched), the next
  /// turn picks up the new list. Never call it mid tool loop.
  void onUserTurn(String sessionId) {
    if (router.isSegmentStale(sessionId)) router.resetSegment(sessionId);
  }

  /// The app's tool router: today's built-ins first, then every MCP tool.
  ToolRouter toolRouter(SessionStore store) => CompositeToolRouter([
        LocalToolRouter([UpdatePlanTool(store: store, clock: clock)]),
        router,
      ]);

  /// Re-lists every enabled server's tools now.
  Future<void> refresh({bool force = false}) async {
    try {
      await router.refresh(force: force);
    } on Object {
      // Per-server failures are kept by the router (refreshErrorFor).
    }
    _emit();
  }

  // ---------------------------------------------------------------- servers

  List<McpServerConfig> get servers => manager.servers;

  McpServerConfig? server(String id) => manager.config(id);

  bool isBuiltIn(String id) => id == memoryServerId || id == deviceServerId;

  McpServerMeta? metaOf(String id) => isBuiltIn(id) ? const McpServerMeta(source: McpServerSource.builtIn) : configs.metaOf(id);

  /// A configured server with this endpoint, if any.
  McpServerConfig? serverForUrl(Uri url) {
    String norm(Uri u) => u.replace(path: u.path.endsWith('/') && u.path.length > 1 ? u.path.substring(0, u.path.length - 1) : u.path).toString().toLowerCase();
    final key = norm(url);
    return manager.servers.where((c) => c.transport != McpTransportPreference.inProcess && norm(c.url) == key).firstOrNull;
  }

  /// Adds a remote server (after the user confirmed it) and lists its
  /// tools in the background. New tools of an untrusted server wait for
  /// review.
  Future<McpServerConfig> addServer({
    required Uri url,
    required String name,
    bool allowLocalNetwork = false,
    McpServerSource source = McpServerSource.url,
    String? registryName,
    String? description,
    EraVerdict? verdict,
  }) async {
    final label = name.trim().isEmpty ? url.host : name.trim();
    final config = McpServerConfig(
      id: _newId(name.trim(), url),
      name: label.length > 60 ? label.substring(0, 60) : label,
      url: url,
      allowLocalNetwork: allowLocalNetwork,
      cachedVerdict: verdict,
    );
    final meta = McpServerMeta(
      source: source,
      addedAt: clock.now(),
      registryName: registryName,
      description: description,
    );
    await configs.save(config, meta: meta);
    manager.addServer(config);
    unawaited(refresh());
    _emit();
    return config;
  }

  String _newId(String name, Uri url) {
    String slug(String s) => s
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    var base = slug(name);
    if (base.isEmpty) {
      final labels = url.host.split('.').where((p) => p != 'www' && p != 'mcp' && p != 'api').toList();
      base = slug(labels.isEmpty ? url.host : labels.first);
    }
    if (base.isEmpty || RegExp('^[0-9]').hasMatch(base)) base = 'server${base.isEmpty ? '' : '_$base'}';
    if (base.length > 24) base = base.substring(0, 24).replaceAll(RegExp(r'_+$'), '');
    var id = base;
    var n = 2;
    while (manager.config(id) != null || reservedIds.contains(id)) {
      id = '${base}_${n++}';
    }
    return id;
  }

  /// Removes a remote server: its connection, config, tool pins, switches,
  /// approval grants and OAuth tokens.
  Future<void> removeServer(String id) async {
    final config = manager.config(id);
    if (config == null) return;
    if (isBuiltIn(id)) throw ArgumentError.value(id, 'id', 'built-in servers can only be turned off');
    final toolNames = toolsOf(id).map((e) => e.modelName).toSet();
    await manager.removeServer(id);
    await configs.delete(id);
    try {
      await oauth.signOut(config);
    } on Object {
      // Nothing stored, or the store is unavailable: nothing to wipe.
    }
    oauth.forget(id);
    inputHistory.forget(id);
    await hostSettings.forgetServer(id);
    inputQueue.dropServer(id);
    await enablement.forgetServer(id, toolNames);
    policy.revokeWhere((g) => toolNames.contains(g.toolName));
    _emit();
  }

  /// Renames a server (display only; its id and tool names stay).
  Future<void> rename(String id, String name) async {
    final c = manager.config(id);
    final label = name.trim();
    if (c == null || label.isEmpty || isBuiltIn(id)) return;
    final next = c.copyWith(name: label.length > 60 ? label.substring(0, 60) : label);
    await manager.updateServer(next);
    await configs.save(next);
  }

  Future<void> setEnabled(String id, bool enabled) async {
    await manager.setEnabled(id, enabled);
    if (enabled) unawaited(refresh());
  }

  /// Trusting a server makes its declared annotations count (read-only
  /// tools may run without asking) and pins its future new tools without
  /// review. Changed tools are still quarantined.
  void setTrusted(String id, bool trusted) {
    if (isBuiltIn(id)) return;
    manager.setTrusted(id, trusted);
  }

  /// Reconnects now (the retry button), then re-lists tools.
  Future<McpServerHealth> reconnect(String id) async {
    try {
      await manager.reconnect(id);
    } on Object {
      // Recorded in the server's health and log.
    }
    await refresh();
    return manager.health(id);
  }

  /// Signs out of a server: its tokens are revoked (best effort) and
  /// deleted; the next use asks to sign in again.
  Future<void> signOut(String id) async {
    final c = manager.config(id);
    if (c == null) return;
    await oauth.signOut(c);
    try {
      await manager.reconnect(id);
    } on Object {
      // Expected: the server now wants a sign-in.
    }
    _emit();
  }

  // ---------------------------------------------------------------- tools

  /// The tools of one server (quarantined ones included).
  List<McpCatalogEntry> toolsOf(String serverId) => [for (final e in router.catalog) if (e.server.id == serverId) e];

  /// Every tool waiting for the user's review.
  List<ToolReview> get pendingReviews => hygiene.pending;

  /// Approves a tool's CURRENT definition (from the review screen).
  Future<bool> approveTool(McpToolKey key) async {
    final ok = await hygiene.approve(key);
    _emit();
    return ok;
  }

  /// Approves every quarantined tool of a server.
  Future<int> approveAll(String serverId) async {
    final n = await hygiene.approveServer(serverId);
    _emit();
    return n;
  }

  /// The global switch of one tool (by model-facing name).
  Future<void> setToolEnabled(String modelName, bool enabled) =>
      enablement.setToolEnabled(modelName, enabled ? null : false);

  bool isToolEnabled(String modelName) => enablement.isToolEnabledGlobally(modelName);

  /// Resources of a connected (or connectable) server; empty when it has
  /// none or cannot be reached.
  Future<List<McpResource>> resourcesOf(String serverId) async {
    final c = await manager.connection(serverId);
    if (!c.capabilities.resources) return const [];
    return c.listResources();
  }

  Future<List<McpPrompt>> promptsOf(String serverId) async {
    final c = await manager.connection(serverId);
    if (!c.capabilities.prompts) return const [];
    return c.listPrompts();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _lifecycle?.dispose();
    await _network?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    await router.dispose();
    await manager.dispose();
    await onDevice.close();
    await hygiene.dispose();
    await enablement.dispose();
    await oauth.dispose();
    inputQueue.dispose();
    await hostSettings.dispose();
    await inputHistory.dispose();
    await _changes.close();
  }
}

/// Device facts when no platform source was given (tests, desktop).
final class _UnknownDeviceFacts implements DeviceFactsProvider {
  const _UnknownDeviceFacts();

  @override
  Future<DeviceFacts> deviceFacts() async {
    final now = DateTime.now();
    return DeviceFacts(
      appName: AppInfo.name,
      appVersion: AppInfo.version,
      platform: 'unknown',
      locale: 'en',
      timeZone: now.timeZoneName,
      timeZoneOffset: now.timeZoneOffset,
    );
  }
}
