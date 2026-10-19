/// Owns the connections to a set of MCP servers.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart' show CancellationToken, CancelledException, Clock, JsonMap, ToolProgress;
import 'package:sherpa_net/sherpa_net.dart' show Backoff, Redactor;

import '../client/changes.dart';
import '../client/connection.dart';
import '../config.dart';
import '../era/era.dart';
import '../errors.dart';
import '../protocol/primitives.dart';
import '../transport/transport.dart';

/// Where a server's connection stands.
enum McpServerStatus {
  /// Turned off by the user (`McpServerConfig.enabled == false`).
  disabled,

  /// Enabled but not connected yet: servers connect lazily, on first use.
  idle,

  /// A connect attempt is running.
  connecting,

  connected,

  /// The server wants (re-)authorization: run OAuth, then [McpServerManager.reconnect].
  needsAuth,

  /// Unreachable; reconnecting with backoff (or waiting for the network /
  /// the next use once attempts are exhausted).
  offline,

  /// A non-transient failure (no common protocol era, invalid responses,
  /// missing in-process server). Retried only on the next use.
  error,
}

/// A snapshot of one server's health, for the server list and the debug
/// console. [lastError] is redacted.
@immutable
final class McpServerHealth {
  const McpServerHealth({
    required this.serverId,
    required this.status,
    this.lastError,
    this.lastErrorAt,
    this.latency,
    this.connectedAt,
    this.reconnectAttempts = 0,
    this.nextRetryAt,
    this.era,
    this.protocolVersion,
    this.serverName,
  });

  final String serverId;
  final McpServerStatus status;
  final String? lastError;
  final DateTime? lastErrorAt;

  /// Round-trip time of the last connect or [McpServerManager.checkHealth].
  final Duration? latency;
  final DateTime? connectedAt;
  final int reconnectAttempts;
  final DateTime? nextRetryAt;
  final McpEra? era;
  final String? protocolVersion;

  /// Self-reported `serverInfo` name (display only, never an identity).
  final String? serverName;

  bool get isConnected => status == McpServerStatus.connected;

  @override
  String toString() => 'McpServerHealth($serverId, ${status.name}${lastError == null ? '' : ', $lastError'})';
}

enum McpLogSource {
  /// `notifications/message` from the server (untrusted; never shown to the model).
  server,

  /// What the client did or saw: connects, losses, diagnostics, probe steps.
  client,
}

/// One debug-console line. [message] is redacted and length-capped.
@immutable
final class McpLogEntry {
  const McpLogEntry({required this.at, required this.source, required this.level, required this.message});

  final DateTime at;
  final McpLogSource source;

  /// An `McpLogLevel` name for server entries; `info` / `warning` / `error`
  /// for client entries.
  final String level;
  final String message;

  @override
  String toString() => '${at.toIso8601String()} [${source.name}/$level] $message';
}

/// Something the router or the UI should react to.
@immutable
sealed class McpServerEvent {
  const McpServerEvent(this.serverId);

  final String serverId;
}

final class McpServerStatusChanged extends McpServerEvent {
  const McpServerStatusChanged(super.serverId, this.health);

  final McpServerHealth health;
}

/// The server's tool list may have changed (`list_changed`, a resync after
/// a listen stream reconnected, a reconnect, or the app came back to the
/// foreground): re-list and re-review.
final class McpServerToolsChanged extends McpServerEvent {
  const McpServerToolsChanged(super.serverId, {this.reason = 'list_changed'});

  final String reason;
}

/// The config changed (enabled, trusted, verdict, URL…).
final class McpServerConfigUpdated extends McpServerEvent {
  McpServerConfigUpdated(this.config) : super(config.id);

  final McpServerConfig config;
}

final class McpServerRemoved extends McpServerEvent {
  const McpServerRemoved(super.serverId);
}

/// A call or connect was refused without contacting the server: it is
/// disabled, needs sign-in, or is offline (fail fast: R11 §9.8 says never
/// leave the model hanging on a dead server). [modelMessage] is safe to
/// show the model.
final class McpServerUnavailableException implements Exception {
  const McpServerUnavailableException({
    required this.serverId,
    required this.serverName,
    required this.status,
    this.reason,
    this.retryAt,
  });

  final String serverId;
  final String serverName;
  final McpServerStatus status;

  /// Redacted detail for logs.
  final String? reason;
  final DateTime? retryAt;

  String get modelMessage => switch (status) {
        McpServerStatus.disabled => 'The "$serverName" tool server is turned off by the user.',
        McpServerStatus.needsAuth =>
          'The "$serverName" tool server needs the user to sign in again. Ask the user to reconnect it in the '
              'tool settings; do not retry until they have.',
        McpServerStatus.error =>
          'The "$serverName" tool server is not working right now (it failed to connect). Continue without it '
              'or ask the user to check it.',
        _ => 'The "$serverName" tool server is offline right now. Continue without it or try again later.',
      };

  @override
  String toString() => 'McpServerUnavailableException($serverId: ${status.name}${reason == null ? '' : ', $reason'})';
}

/// The connection dropped while a non-idempotent call was in flight, so its
/// outcome is unknown and it was not re-sent (R11 §9.8).
final class McpCallInterruptedException implements Exception {
  const McpCallInterruptedException({required this.serverId, required this.serverName, required this.toolName, this.reason});

  final String serverId;
  final String serverName;
  final String toolName;
  final String? reason;

  String get modelMessage => 'The connection to "$serverName" dropped while "$toolName" was running, so it is unknown '
      'whether it took effect. It was not retried because it may not be safe to repeat; check its effect or ask the '
      'user before trying again.';

  @override
  String toString() => 'McpCallInterruptedException($serverId/$toolName${reason == null ? '' : ': $reason'})';
}

/// Opens a connection; the default is [McpConnection.connect].
typedef McpConnector = Future<McpConnection> Function(
    McpServerConfig config, McpClientOptions options, McpTransport? transport);

/// Supplies a fresh transport for an in-process server (see
/// `OnDeviceServers.transportFor`); null when there is none.
typedef McpTransportFactory = McpTransport? Function(McpServerConfig config);

final class _Server {
  _Server(this.config, int logCapacity) : logs = ListQueue(logCapacity);

  McpServerConfig config;
  McpConnection? connection;
  StreamSubscription<McpChange>? changesSub;
  Future<McpConnection>? connecting;
  bool reconnecting = false;
  McpServerStatus status = McpServerStatus.idle;
  String? lastError;
  DateTime? lastErrorAt;
  Duration? latency;
  DateTime? connectedAt;
  int attempts = 0;
  Timer? retryTimer;
  DateTime? nextRetryAt;
  int generation = 0;
  final ListQueue<McpLogEntry> logs;

  bool get inProcess => config.transport == McpTransportPreference.inProcess;
}

/// Owns [McpConnection]s for a set of [McpServerConfig]s.
///
/// * **Lazy:** nothing connects until a server is first used (listing its
///   tools or calling one), so a long server list costs nothing at start-up.
/// * **Self-healing:** on `McpConnectionLost` or a transport failure the
///   server goes [McpServerStatus.offline] and reconnects with jittered
///   exponential [Backoff] (sherpa_net), up to [maxReconnectAttempts]; after
///   that, the next use tries once more. Auth failures stop and wait for
///   [reconnect] (after OAuth); other failures become
///   [McpServerStatus.error].
/// * **Offline-aware:** while a server is disconnected, calls fail at once
///   with [McpServerUnavailableException] (whose `modelMessage` the router
///   hands to the model) instead of waiting out timeouts. A call that loses
///   its connection mid-flight is retried once after an immediate reconnect
///   only when [callTool]'s `retryOnReconnect` says the tool is read-only or
///   idempotent; anything else reports an unknown outcome (R11 §9.8:
///   "never auto-re-run a non-idempotent call whose outcome is unknown").
/// * **Observable:** [health], [checkHealth], a redacted per-server log
///   ring ([logs]) for the debug console and an [events] stream.
/// * **Lifecycle:** [listen] / [stopListening] follow app foreground /
///   background (R01 rec. 7–8: hold change feeds only in the foreground);
///   [setNetworkAvailable] pauses and resumes reconnects; [dispose] closes
///   everything.
///
/// Trust and enablement changes are persisted through callbacks:
/// [onTrustChanged] (wire to `ApprovalPolicy.trustServer` /
/// `untrustServer`), [onVerdictChanged] (persist the era verdict) and
/// [onConfigChanged] (persist the whole config).
final class McpServerManager {
  McpServerManager({
    Iterable<McpServerConfig> servers = const [],
    this.options = const McpClientOptions(),
    McpConnector? connector,
    this.transportFactory,
    Backoff? backoff,
    Clock? clock,
    this.connectTimeout = const Duration(seconds: 20),
    this.reconnectWait = const Duration(seconds: 10),
    this.maxReconnectAttempts = 8,
    this.logCapacity = 200,
    this.onTrustChanged,
    this.onVerdictChanged,
    this.onConfigChanged,
    this.onAuthRequired,
  })  : _connector = connector ?? _defaultConnector,
        _backoff = backoff ?? Backoff(base: const Duration(seconds: 1), max: const Duration(seconds: 60)),
        _clock = clock ?? options.clock {
    for (final c in servers) {
      _add(c);
    }
  }

  static Future<McpConnection> _defaultConnector(
          McpServerConfig config, McpClientOptions options, McpTransport? transport) =>
      McpConnection.connect(config, options: options, transport: transport);

  final McpClientOptions options;
  final McpTransportFactory? transportFactory;
  final McpConnector _connector;
  final Backoff _backoff;
  final Clock _clock;

  /// One connect attempt (era probe + handshake) may take this long.
  final Duration connectTimeout;

  /// How long a retry-on-reconnect waits for the reconnect.
  final Duration reconnectWait;
  final int maxReconnectAttempts;

  /// Log lines kept per server.
  final int logCapacity;

  final void Function(String serverId, bool trusted)? onTrustChanged;
  final void Function(String serverId, EraVerdict verdict)? onVerdictChanged;
  final void Function(McpServerConfig config)? onConfigChanged;
  final void Function(String serverId, McpAuthRequiredException error)? onAuthRequired;

  final Map<String, _Server> _servers = {};
  final StreamController<McpServerEvent> _events = StreamController.broadcast();
  bool _listening = false;
  bool _networkAvailable = true;
  bool _disposed = false;

  Stream<McpServerEvent> get events => _events.stream;

  /// Configs in insertion order (also the router's tool order).
  List<McpServerConfig> get servers => [for (final s in _servers.values) s.config];

  McpServerConfig? config(String id) => _servers[id]?.config;

  /// Ids of servers the user trusts (seed `ApprovalPolicy(trustedServers:)`).
  Set<String> get trustedServerIds => {for (final s in _servers.values) if (s.config.trusted) s.config.id};

  bool get isListening => _listening;

  bool get networkAvailable => _networkAvailable;

  _Server _require(String id) {
    final s = _servers[id];
    if (s == null) throw ArgumentError.value(id, 'serverId', 'unknown MCP server');
    return s;
  }

  void _add(McpServerConfig c) {
    if (_servers.containsKey(c.id)) throw ArgumentError.value(c.id, 'config', 'duplicate server id');
    final s = _Server(c, logCapacity);
    s.status = c.enabled ? McpServerStatus.idle : McpServerStatus.disabled;
    _servers[c.id] = s;
  }

  void _emit(McpServerEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  // ---------------------------------------------------------------- config

  void addServer(McpServerConfig config) {
    _checkAlive();
    _add(config);
    _emit(McpServerConfigUpdated(config));
    _emitStatus(_servers[config.id]!);
  }

  /// Replaces a server's config. A changed endpoint (URL, transport,
  /// headers, network scope) drops the connection; it reconnects lazily.
  Future<void> updateServer(McpServerConfig config) async {
    _checkAlive();
    final s = _require(config.id);
    final old = s.config;
    s.config = config;
    final endpointChanged = old.url != config.url ||
        old.transport != config.transport ||
        old.allowLocalNetwork != config.allowLocalNetwork ||
        !_sameHeaders(old.headers, config.headers);
    if (old.trusted != config.trusted) onTrustChanged?.call(config.id, config.trusted);
    if (!config.enabled) {
      await _drop(s, McpServerStatus.disabled, 'disabled');
    } else if (endpointChanged || !old.enabled) {
      await _drop(s, McpServerStatus.idle, endpointChanged ? 'endpoint changed' : 'enabled');
    }
    _emit(McpServerConfigUpdated(config));
  }

  static bool _sameHeaders(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  Future<void> removeServer(String id) async {
    final s = _servers[id];
    if (s == null) return;
    await _drop(s, McpServerStatus.disabled, 'removed');
    _servers.remove(id);
    _emit(McpServerRemoved(id));
  }

  /// Turns a server on or off. Off closes its connection at once.
  Future<void> setEnabled(String id, bool enabled) async {
    final s = _require(id);
    if (s.config.enabled == enabled) return;
    s.config = s.config.copyWith(enabled: enabled);
    onConfigChanged?.call(s.config);
    await _drop(s, enabled ? McpServerStatus.idle : McpServerStatus.disabled, enabled ? 'enabled' : 'disabled');
    _emit(McpServerConfigUpdated(s.config));
  }

  /// Trusting a server makes its annotations count (R01 §6.2) and pins its
  /// new tools at first sight. Persist via the callbacks.
  void setTrusted(String id, bool trusted) {
    final s = _require(id);
    if (s.config.trusted == trusted) return;
    s.config = s.config.copyWith(trusted: trusted);
    _log(s, McpLogSource.client, 'info', trusted ? 'marked trusted' : 'no longer trusted');
    onTrustChanged?.call(id, trusted);
    onConfigChanged?.call(s.config);
    _emit(McpServerConfigUpdated(s.config));
  }

  // ---------------------------------------------------------------- health & logs

  McpServerHealth health(String id) {
    final s = _require(id);
    final c = s.connection;
    return McpServerHealth(
      serverId: id,
      status: s.status,
      lastError: s.lastError,
      lastErrorAt: s.lastErrorAt,
      latency: s.latency,
      connectedAt: s.connectedAt,
      reconnectAttempts: s.attempts,
      nextRetryAt: s.nextRetryAt,
      era: c?.era,
      protocolVersion: c?.protocolVersion,
      serverName: c?.serverInfo?.displayName,
    );
  }

  Map<String, McpServerHealth> get healthAll => {for (final id in _servers.keys) id: health(id)};

  /// Connects if needed and measures a cheap round trip: `server/discover`
  /// (2026-07-28; side-effect free) or `tools/list` (legacy; `ping` was
  /// removed from the protocol). Never throws.
  Future<McpServerHealth> checkHealth(String id) async {
    final s = _require(id);
    try {
      final c = await connection(id);
      final sw = Stopwatch()..start();
      if (c.era == McpEra.modern) {
        await c.discover(refresh: true);
      } else {
        await c.listTools(refresh: true);
      }
      s.latency = sw.elapsed;
      _log(s, McpLogSource.client, 'info', 'health check ok in ${sw.elapsedMilliseconds} ms');
    } on Object catch (e) {
      _recordError(s, e);
      if (_isConnectionLoss(e)) _lost(s, s.generation, 'health check failed: ${_describe(e)}');
    }
    return health(id);
  }

  /// The redacted log ring of a server, oldest first.
  List<McpLogEntry> logs(String id) => List.unmodifiable(_require(id).logs);

  void clearLogs(String id) => _require(id).logs.clear();

  // ---------------------------------------------------------------- connections

  /// The live connection, connecting lazily. Fails fast with
  /// [McpServerUnavailableException] while the server is disabled, needs
  /// auth, or is reconnecting after a loss.
  Future<McpConnection> connection(String id) {
    _checkAlive();
    final s = _require(id);
    final c = s.connection;
    if (c != null && !c.isClosed) return Future.value(c);
    final unavailable = _unavailable(s);
    if (unavailable != null) return Future.error(unavailable);
    return _connect(s, isReconnect: false);
  }

  /// The live connection if there is one (never connects).
  McpConnection? connectedOrNull(String id) {
    final c = _servers[id]?.connection;
    return c != null && !c.isClosed ? c : null;
  }

  McpServerUnavailableException? _unavailable(_Server s) {
    McpServerUnavailableException make(McpServerStatus status, [String? why]) => McpServerUnavailableException(
          serverId: s.config.id,
          serverName: s.config.name,
          status: status,
          reason: why ?? s.lastError,
          retryAt: s.nextRetryAt,
        );
    if (!s.config.enabled) return make(McpServerStatus.disabled);
    if (s.status == McpServerStatus.needsAuth) return make(McpServerStatus.needsAuth);
    if (!s.inProcess && !_networkAvailable) return make(McpServerStatus.offline, 'the device is offline');
    // A reconnect is scheduled or running after a loss: fail fast.
    if (s.retryTimer != null || (s.connecting != null && s.reconnecting)) return make(McpServerStatus.offline);
    return null;
  }

  Future<McpConnection> _connect(_Server s, {required bool isReconnect}) {
    final pending = s.connecting;
    if (pending != null) return pending;
    s.retryTimer?.cancel();
    s.retryTimer = null;
    s.nextRetryAt = null;
    s.reconnecting = isReconnect;
    final gen = ++s.generation;
    _setStatus(s, McpServerStatus.connecting);
    final future = _attempt(s, gen, isReconnect);
    s.connecting = future;
    return future.whenComplete(() {
      if (identical(s.connecting, future)) {
        s.connecting = null;
        s.reconnecting = false;
      }
    });
  }

  Future<McpConnection> _attempt(_Server s, int gen, bool isReconnect) async {
    final config = s.config;
    final sw = Stopwatch()..start();
    _log(s, McpLogSource.client, 'info', isReconnect ? 'reconnecting (attempt ${s.attempts})' : 'connecting');
    McpConnection c;
    McpTransport? transport;
    try {
      if (s.inProcess) {
        transport = transportFactory?.call(config);
        if (transport == null) {
          throw McpProtocolException('no on-device server is registered for "${config.id}"');
        }
      }
      final attempt = _connector(config, options, transport);
      try {
        c = await attempt.timeout(connectTimeout);
      } on TimeoutException {
        // The attempt keeps running; close whatever it produces late.
        unawaited(attempt.then((late) => late.close(), onError: (Object _) {}));
        throw McpTimeoutException('connecting took longer than ${connectTimeout.inSeconds} s');
      }
    } on Object catch (e) {
      // A failed connect does not own its transport: close it, or the
      // on-device server keeps a dead session.
      unawaited(transport?.close().catchError((Object _) {}));
      if (gen == s.generation && !_disposed) _connectFailed(s, e);
      if (e is McpServerUnavailableException) rethrow;
      throw _unavailableAfter(s, e);
    }
    if (_disposed || gen != s.generation || !s.config.enabled || !_servers.containsKey(config.id)) {
      // Disabled, removed or superseded while connecting.
      unawaited(c.close());
      throw McpServerUnavailableException(
        serverId: config.id,
        serverName: config.name,
        status: s.config.enabled ? McpServerStatus.offline : McpServerStatus.disabled,
        reason: 'connection superseded',
      );
    }
    s
      ..connection = c
      ..connectedAt = _clock.now()
      ..latency = sw.elapsed
      ..attempts = 0;
    for (final line in c.probeLog) {
      _log(s, McpLogSource.client, 'debug', 'probe: $line');
    }
    _log(s, McpLogSource.client, 'info',
        'connected (${c.era.name}, ${c.protocolVersion}, ${c.transportKind.name}) in ${sw.elapsedMilliseconds} ms');
    // Cancelled in _drop / _lost / dispose.
    // ignore: cancel_subscriptions
    final sub = c.changes.listen((change) => _onChange(s, gen, change));
    s.changesSub = sub;
    final v = c.verdict;
    if (v != null && c.verdictChanged) {
      s.config = s.config.copyWith(cachedVerdict: v);
      onVerdictChanged?.call(config.id, v);
      onConfigChanged?.call(s.config);
    }
    _setStatus(s, McpServerStatus.connected);
    if (_listening) unawaited(_listenOn(s, c));
    if (isReconnect) _emit(McpServerToolsChanged(config.id, reason: 'reconnected'));
    return c;
  }

  void _connectFailed(_Server s, Object e) {
    _recordError(s, e);
    if (e is McpAuthRequiredException) {
      _setStatus(s, McpServerStatus.needsAuth);
      onAuthRequired?.call(s.config.id, e);
      return;
    }
    if (_isTransient(e)) {
      _setStatus(s, McpServerStatus.offline);
      _scheduleReconnect(s);
    } else {
      _setStatus(s, McpServerStatus.error);
    }
  }

  McpServerUnavailableException _unavailableAfter(_Server s, Object e) => McpServerUnavailableException(
        serverId: s.config.id,
        serverName: s.config.name,
        status: s.status == McpServerStatus.connecting ? McpServerStatus.offline : s.status,
        reason: _describe(e),
        retryAt: s.nextRetryAt,
      );

  void _scheduleReconnect(_Server s) {
    if (_disposed || !s.config.enabled || s.status == McpServerStatus.needsAuth) return;
    if (!s.inProcess && !_networkAvailable) {
      _log(s, McpLogSource.client, 'info', 'waiting for the network');
      return;
    }
    if (s.attempts >= maxReconnectAttempts) {
      _log(s, McpLogSource.client, 'warning', 'giving up after $maxReconnectAttempts reconnect attempts; '
          'will try again on next use');
      s.nextRetryAt = null;
      _emitStatus(s);
      return;
    }
    final delay = _backoff.delay(s.attempts++);
    s.nextRetryAt = _clock.now().add(delay);
    s.retryTimer?.cancel();
    s.retryTimer = Timer(delay, () {
      s.retryTimer = null;
      if (_disposed || !s.config.enabled) return;
      _connect(s, isReconnect: true).then((_) {}, onError: (Object _) {});
    });
    _emitStatus(s);
  }

  /// Reconnects at once (after OAuth, or from the UI's retry button),
  /// resetting the backoff.
  Future<McpConnection> reconnect(String id) async {
    _checkAlive();
    final s = _require(id);
    if (!s.config.enabled) throw _unavailable(s)!;
    s.attempts = 0;
    final old = s.connection;
    await _detach(s);
    if (old != null) await old.close();
    return _connect(s, isReconnect: false);
  }

  void _onChange(_Server s, int gen, McpChange change) {
    if (gen != s.generation) return;
    switch (change) {
      case McpLogMessage(:final level, :final data, :final logger):
        _log(s, McpLogSource.server, level.name, '${logger == null ? '' : '[$logger] '}${_redactData(data)}');
      case McpDiagnostic(:final message):
        _log(s, McpLogSource.client, 'debug', message);
      case McpListenStateChanged(:final active, :final error):
        _log(s, McpLogSource.client, error == null ? 'info' : 'warning',
            'change feed ${active ? 'up' : 'down'}${error == null ? '' : ': ${_describe(error)}'}');
      case McpToolsListChanged(:final resync):
        _emit(McpServerToolsChanged(s.config.id, reason: resync ? 'resync' : 'list_changed'));
      case McpConnectionLost(:final reason):
        _lost(s, gen, reason);
      default:
        break;
    }
  }

  /// The connection is gone: go offline and schedule a reconnect.
  void _lost(_Server s, int gen, String reason) {
    if (gen != s.generation || _disposed) return;
    final old = s.connection;
    if (old == null && s.status != McpServerStatus.connected) return;
    s.generation++;
    s.connection = null;
    unawaited(s.changesSub?.cancel());
    s.changesSub = null;
    if (old != null) unawaited(old.close());
    s
      ..lastError = Redactor.text(reason)
      ..lastErrorAt = _clock.now();
    _log(s, McpLogSource.client, 'warning', 'connection lost: ${Redactor.text(reason)}');
    if (!s.config.enabled) {
      _setStatus(s, McpServerStatus.disabled);
      return;
    }
    _setStatus(s, McpServerStatus.offline);
    _scheduleReconnect(s);
  }

  Future<void> _detach(_Server s) async {
    s.generation++;
    s.retryTimer?.cancel();
    s.retryTimer = null;
    s.nextRetryAt = null;
    s.connection = null;
    final sub = s.changesSub;
    s.changesSub = null;
    await sub?.cancel();
  }

  Future<void> _drop(_Server s, McpServerStatus status, String why) async {
    final old = s.connection;
    await _detach(s);
    s.attempts = 0;
    if (old != null) await old.close();
    _log(s, McpLogSource.client, 'info', why);
    _setStatus(s, status);
  }

  // ---------------------------------------------------------------- tools

  /// `tools/list` (cached by the connection per `ttlMs`). Read-only, so one
  /// lost connection is retried after an immediate reconnect.
  Future<List<McpTool>> listTools(String id, {bool refresh = false, CancellationToken? cancel}) async {
    final s = _require(id);
    for (var attempt = 0;; attempt++) {
      final c = await _cancellable(connection(id), cancel);
      final gen = s.generation;
      try {
        return await c.listTools(refresh: refresh, cancel: cancel);
      } on CancelledException {
        rethrow;
      } on Object catch (e) {
        _recordError(s, e);
        if (!_isConnectionLoss(e)) rethrow;
        _lost(s, gen, 'tools/list failed: ${_describe(e)}');
        if (attempt > 0) rethrow;
        await _reconnectNow(s);
      }
    }
  }

  /// Calls a tool by its wire name.
  ///
  /// [retryOnReconnect]: the tool is read-only or idempotent (by TRUSTED
  /// annotations), so a call whose connection dropped mid-flight may be
  /// re-sent once after an immediate reconnect. Otherwise such a call throws
  /// [McpCallInterruptedException]. [idempotencyKey] goes to `_meta` so a
  /// cooperating server can dedupe the re-send.
  Future<McpCallToolResult> callTool(
    String id,
    String name, {
    JsonMap? arguments,
    CancellationToken? cancel,
    Duration? timeout,
    Duration? maxTimeout,
    void Function(ToolProgress progress)? onProgress,
    String? idempotencyKey,
    bool retryOnReconnect = false,
  }) async {
    final s = _require(id);
    for (var attempt = 0;; attempt++) {
      final c = await _cancellable(attempt == 0 ? connection(id) : _reconnectNow(s), cancel);
      final gen = s.generation;
      try {
        return await c.callTool(
          name,
          arguments: arguments,
          cancel: cancel,
          timeout: timeout,
          maxTimeout: maxTimeout,
          onProgress: onProgress,
          idempotencyKey: idempotencyKey,
        );
      } on CancelledException {
        rethrow;
      } on Object catch (e) {
        if (!_isConnectionLoss(e)) {
          if (e is McpAuthRequiredException) {
            _recordError(s, e);
            _setStatus(s, McpServerStatus.needsAuth);
            onAuthRequired?.call(id, e);
          }
          rethrow;
        }
        _recordError(s, e);
        _lost(s, gen, 'tools/call $name failed: ${_describe(e)}');
        if (!retryOnReconnect || attempt > 0) {
          throw McpCallInterruptedException(
            serverId: id,
            serverName: s.config.name,
            toolName: name,
            reason: _describe(e),
          );
        }
        _log(s, McpLogSource.client, 'info', 'retrying read-only/idempotent $name after reconnect');
      }
    }
  }

  /// Reconnects now (skipping the backoff wait), bounded by [reconnectWait].
  Future<McpConnection> _reconnectNow(_Server s) async {
    final c = s.connection;
    if (c != null && !c.isClosed) return c;
    if (!s.config.enabled) throw _unavailable(s)!;
    if (!s.inProcess && !_networkAvailable) throw _unavailable(s)!;
    s.retryTimer?.cancel();
    s.retryTimer = null;
    try {
      return await _connect(s, isReconnect: true).timeout(reconnectWait);
    } on TimeoutException {
      throw McpServerUnavailableException(
        serverId: s.config.id,
        serverName: s.config.name,
        status: McpServerStatus.offline,
        reason: 'reconnect took longer than ${reconnectWait.inSeconds} s',
      );
    }
  }

  /// Waits for [f] unless [token] fires first (then throws
  /// [CancelledException]); a slow connect must not outlive a stopped run.
  static Future<T> _cancellable<T>(Future<T> f, CancellationToken? token) async {
    if (token == null || identical(token, CancellationToken.none)) return f;
    token.throwIfCancelled();
    final child = token.child();
    try {
      return await Future.any([f, child.whenCancelled.then<T>((reason) => throw CancelledException(reason))]);
    } finally {
      child.detach();
    }
  }

  // ---------------------------------------------------------------- lifecycle

  /// App came to the foreground: open change feeds on connected servers
  /// (and on servers that connect later) and ask the router to re-validate
  /// tool lists (they may have changed while the feed was down).
  Future<void> listen() async {
    _checkAlive();
    _listening = true;
    for (final s in _servers.values) {
      final c = s.connection;
      if (c == null || c.isClosed) continue;
      await _listenOn(s, c);
      _emit(McpServerToolsChanged(s.config.id, reason: 'resumed'));
    }
  }

  Future<void> _listenOn(_Server s, McpConnection c) async {
    try {
      await c.listen();
    } on Object catch (e) {
      _log(s, McpLogSource.client, 'warning', 'listen failed: ${_describe(e)}');
    }
  }

  /// App went to the background: close change feeds (connections stay).
  Future<void> stopListening() async {
    _listening = false;
    for (final s in _servers.values) {
      final c = s.connection;
      if (c == null || c.isClosed) continue;
      try {
        await c.stopListening();
      } on Object catch (e) {
        _log(s, McpLogSource.client, 'warning', 'stopListening failed: ${_describe(e)}');
      }
    }
  }

  /// OS connectivity. Offline pauses reconnects of remote servers and makes
  /// their calls fail fast; back online reconnects them immediately.
  void setNetworkAvailable(bool available) {
    if (_networkAvailable == available) return;
    _networkAvailable = available;
    for (final s in _servers.values) {
      if (s.inProcess || !s.config.enabled) continue;
      if (!available) {
        s.retryTimer?.cancel();
        s.retryTimer = null;
        s.nextRetryAt = null;
        _log(s, McpLogSource.client, 'info', 'network unavailable');
        _emitStatus(s);
      } else if (s.status == McpServerStatus.offline && s.connecting == null) {
        s.attempts = 0;
        _log(s, McpLogSource.client, 'info', 'network available again');
        _connect(s, isReconnect: true).then((_) {}, onError: (Object _) {});
      }
    }
  }

  /// Closes every connection and stops all timers. The manager is unusable
  /// afterwards.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final s in _servers.values) {
      final old = s.connection;
      await _detach(s);
      if (old != null) await old.close();
    }
    await _events.close();
  }

  void _checkAlive() {
    if (_disposed) throw StateError('McpServerManager was disposed');
  }

  // ---------------------------------------------------------------- helpers

  void _setStatus(_Server s, McpServerStatus status) {
    if (s.status == status && status != McpServerStatus.offline) return;
    s.status = status;
    _emitStatus(s);
  }

  void _emitStatus(_Server s) {
    if (_servers[s.config.id] == s) _emit(McpServerStatusChanged(s.config.id, health(s.config.id)));
  }

  void _recordError(_Server s, Object e) {
    s
      ..lastError = _describe(e)
      ..lastErrorAt = _clock.now();
    _log(s, McpLogSource.client, 'error', s.lastError!);
  }

  void _log(_Server s, McpLogSource source, String level, String message) {
    final text = Redactor.text(message);
    s.logs.add(McpLogEntry(
      at: _clock.now(),
      source: source,
      level: level,
      message: text.length > 2000 ? '${text.substring(0, 1999)}…' : text,
    ));
    while (s.logs.length > logCapacity) {
      s.logs.removeFirst();
    }
  }

  /// A connection-level failure (as opposed to a server's answer).
  static bool _isConnectionLoss(Object e) =>
      e is McpConnectionClosedException ||
      e is McpSessionExpiredException ||
      (e is McpTransportException && e is! McpHttpStatusException);

  static bool _isTransient(Object e) => switch (e) {
        McpTimeoutException() || McpConnectionClosedException() || TimeoutException() => true,
        McpHttpStatusException(:final statusCode) => statusCode >= 500 || statusCode == 429 || statusCode == 408,
        McpTransportException() => true,
        _ => false,
      };

  static String _describe(Object e) {
    final s = switch (e) {
      McpException(:final message) => '${e.runtimeType}: $message',
      McpServerUnavailableException(:final status, :final reason) => '${status.name}${reason == null ? '' : ': $reason'}',
      _ => e.toString(),
    };
    final r = Redactor.text(s);
    return r.length > 500 ? '${r.substring(0, 499)}…' : r;
  }

  static final RegExp _sensitiveKey =
      RegExp(r'(authorization|token|secret|password|passwd|api[-_]?key|cookie|credential|session)', caseSensitive: false);

  /// Server log data, JSON-encoded with sensitive-looking fields masked.
  static String _redactData(Object? data) {
    Object? walk(Object? v, int depth) {
      if (depth > 8) return '…';
      return switch (v) {
        final Map<Object?, Object?> m => {
            for (final e in m.entries)
              '${e.key}': _sensitiveKey.hasMatch('${e.key}') ? Redactor.mask : walk(e.value, depth + 1),
          },
        final List<Object?> l => [for (final x in l.take(50)) walk(x, depth + 1)],
        _ => v,
      };
    }

    final v = walk(data, 0);
    return v is String ? v : jsonEncode(v);
  }
}
