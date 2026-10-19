/// The `initialize`-era session, 2024-11-05 … 2025-11-25 (internal).
library;

import 'dart:async';

import 'package:sherpa_core/sherpa_core.dart' show CancellationToken, JsonMap;

import '../era/era.dart';
import '../era/handshake.dart';
import '../errors.dart';
import '../protocol/json_read.dart';
import '../protocol/jsonrpc.dart';
import '../protocol/types.dart';
import '../protocol/versions.dart';
import '../transport/legacy_streamable_http.dart';
import 'changes.dart';
import 'modern_session.dart' show cancellableDelay;
import 'session.dart';

/// Sessionful: capabilities were exchanged once in `initialize`; the
/// server sends `elicitation/create`, `sampling/createMessage`,
/// `roots/list` and `ping` as JSON-RPC requests, answered through the same
/// [InputRequestHandler]; changes arrive as unsolicited notifications
/// (GET stream on Streamable HTTP); logging uses `logging/setLevel`;
/// cancellation is `notifications/cancelled`.
final class LegacySession extends EraSession {
  LegacySession(super.core, {required LegacyHandshake handshake}) : _h = handshake {
    final t = core.transport;
    if (t is LegacyStreamableHttpTransport) {
      t.onListenState = (active, error) {
        if (!active) core.emit(McpListenStateChanged(active: false, error: error));
      };
    }
  }

  LegacyHandshake _h;
  McpLogLevel? _level;
  Future<void>? _reinit;
  bool _wantListen = false;
  final Set<String> _subscribed = {};
  final Map<String, Completer<void>> _elicitationWaiters = {};

  @override
  McpEra get era => McpEra.legacy;

  @override
  String get protocolVersion => _h.protocolVersion;

  @override
  McpServerCapabilities get capabilities => _h.capabilities;

  @override
  McpImplementation? get serverInfo => _h.serverInfo;

  @override
  String? get instructions => _h.instructions;

  @override
  Future<CallOutcome> call(String method, JsonMap params, CallSpec spec) async {
    final token = spec.onProgress == null ? null : core.newProgressToken();
    final meta = {...spec.meta, McpMetaKeys.progressToken: ?token};
    final p = {...params, if (meta.isNotEmpty) '_meta': meta};
    var reinitialized = false;
    var rounds = 0;
    for (;;) {
      try {
        final r = await core.roundTrip(
          method,
          p,
          name: spec.name,
          cancel: spec.cancel,
          timeout: spec.timeout,
          maxTimeout: spec.maxTimeout,
          progressToken: token,
          onProgress: spec.onProgress,
        );
        return (result: r, viaInput: rounds > 0, taskId: null);
      } on McpSessionExpiredException {
        // 404 on a request that carried Mcp-Session-Id: the server did not
        // process it, so re-initialize and resend once (new id).
        if (reinitialized) rethrow;
        reinitialized = true;
        await reinitialize();
      } on McpRpcException catch (e) {
        if (e.code != JsonRpcError.urlElicitationRequired) rethrow;
        if (++rounds > core.options.limits.maxInputRounds) {
          throw McpLimitExceededException('$method needed more than ${core.options.limits.maxInputRounds} URL elicitations');
        }
        await _urlElicitations(e.error.data, method, spec);
      }
    }
  }

  /// 2025-11-25 `-32042`: present each URL elicitation (the handler returns
  /// once the user is back from the browser), give the server a short grace
  /// to announce `notifications/elicitation/complete` (optional for it),
  /// then retry.
  Future<void> _urlElicitations(Object? data, String method, CallSpec spec) async {
    final ctx = core.inputContext(originMethod: method, originName: spec.name, cancel: spec.cancel);
    for (final e in mapList(asMap(data)?['elicitations'])) {
      final id = asString(e['elicitationId']);
      final waiter = id == null ? null : (_elicitationWaiters[id] = Completer<void>());
      final JsonMap result;
      try {
        result = await core.fulfilInput('elicitation/create', {...e, 'mode': 'url'}, ctx);
      } on InputRequestError catch (err) {
        if (id != null) _elicitationWaiters.remove(id);
        throw McpProtocolException('URL elicitation refused: ${err.message}');
      }
      if (result['action'] != 'accept') {
        if (id != null) _elicitationWaiters.remove(id);
        throw McpInputDeclinedException('URL elicitation ${result['action']}');
      }
      if (waiter != null) {
        try {
          await Future.any([waiter.future, cancellableDelay(core.options.timeouts.elicitationCompleteGrace, spec.cancel)]);
        } finally {
          _elicitationWaiters.remove(id);
        }
      }
    }
  }

  /// Fresh `initialize` without the old session id (single-flight).
  Future<void> reinitialize() => _reinit ??= _doReinitialize().whenComplete(() => _reinit = null);

  Future<void> _doReinitialize() async {
    final t = core.transport;
    if (t is! LegacyStreamableHttpTransport) throw const McpConnectionClosedException('session lost');
    final wasListening = t.isListening || _wantListen;
    t
      ..closeListenStream()
      ..resetSession();
    _h = await legacyInitialize(
      t,
      capabilities: core.clientCapabilities(McpEra.legacy),
      clientInfo: core.options.clientInfo,
      acceptedVersions: McpVersions.legacyStreamable,
      nextId: core.nextId,
      timeout: core.options.timeouts.request,
    );
    core.cache.clear();
    core.diagnostic('session expired; re-initialized at ${_h.protocolVersion}');
    if (_level != null) await _sendLevel(_level!);
    for (final uri in Set.of(_subscribed)) {
      await core.roundTrip('resources/subscribe', {'uri': uri});
    }
    if (wasListening) await t.openListenStream();
  }

  @override
  Future<void> handleServerRequest(JsonRpcRequest request, JsonRpcId? related) async {
    final t = core.transport;
    if (request.method == 'ping') {
      await t.respond(JsonRpcResult(request.id, const {}));
      return;
    }
    final token = core.serverRequestToken(request.id) ?? CancellationToken();
    final ctx = core.inputContext(related: related, cancel: token);
    JsonRpcResponse response;
    try {
      response = JsonRpcResult(request.id, await core.fulfilInput(request.method, request.params, ctx));
    } on InputRequestError catch (e) {
      response = JsonRpcErrorResponse(request.id, JsonRpcError(e.code, e.message));
    }
    // A request the server cancelled is not answered (patterns/cancellation.md).
    if (token.isCancelled) return;
    await t.respond(response);
  }

  @override
  bool handleNotification(JsonRpcNotification n, JsonRpcId? related) {
    final p = n.params ?? const <String, Object?>{};
    switch (n.method) {
      case 'notifications/elicitation/complete':
        final id = asString(p['elicitationId']);
        if (id == null) return true;
        final w = _elicitationWaiters.remove(id);
        if (w != null && !w.isCompleted) w.complete();
        core.emit(McpElicitationCompleted(id));
        return true;
      case 'notifications/tasks/status':
        core.diagnostic('ignored 2025-11-25 task status notification (legacy tasks are not used)');
        return true;
    }
    return false;
  }

  Future<void> _sendLevel(McpLogLevel level) =>
      core.roundTrip('logging/setLevel', {'level': level.name});

  /// `logging/setLevel` when the server offers logging. There is no "off"
  /// in L, so null sets `emergency`.
  @override
  Future<void> setLogLevel(McpLogLevel? level) async {
    _level = level ?? McpLogLevel.emergency;
    if (capabilities.logging) await _sendLevel(_level!);
  }

  @override
  bool get isListening {
    final t = core.transport;
    return t is LegacyStreamableHttpTransport ? t.isListening : _wantListen;
  }

  /// HTTP+SSE and in-process channels always carry unsolicited messages.
  @override
  bool get changeFeedActive {
    final t = core.transport;
    return t is LegacyStreamableHttpTransport ? t.isListening : true;
  }

  @override
  Future<McpListenAck> listen({required Set<String> resourceUris}) async {
    _wantListen = true;
    final t = core.transport;
    var feed = true;
    if (t is LegacyStreamableHttpTransport) feed = await t.openListenStream();
    for (final uri in resourceUris.difference(_subscribed)) {
      await subscribeResource(uri, allUris: resourceUris);
    }
    final caps = capabilities;
    final ack = McpListenAck(
      toolsListChanged: feed && caps.toolsListChanged,
      promptsListChanged: feed && caps.promptsListChanged,
      resourcesListChanged: feed && caps.resourcesListChanged,
      resourceSubscriptions: feed ? _subscribed.toList() : const [],
    );
    core.emit(McpListenStateChanged(active: feed, ack: ack));
    return ack;
  }

  @override
  Future<void> stopListening() async {
    _wantListen = false;
    final t = core.transport;
    if (t is LegacyStreamableHttpTransport && t.isListening) {
      t.closeListenStream();
      core.emit(const McpListenStateChanged(active: false));
    }
  }

  @override
  Future<void> subscribeResource(String uri, {required Set<String> allUris}) async {
    if (!capabilities.resourcesSubscribe) {
      throw McpProtocolException('server does not offer resources/subscribe');
    }
    if (!_subscribed.contains(uri)) {
      await core.roundTrip('resources/subscribe', {'uri': uri});
      _subscribed.add(uri);
    }
    final t = core.transport;
    if (t is LegacyStreamableHttpTransport && !t.isListening) {
      _wantListen = true;
      await t.openListenStream();
    }
  }

  @override
  Future<void> unsubscribeResource(String uri, {required Set<String> remainingUris}) async {
    if (!_subscribed.remove(uri)) return;
    try {
      await core.roundTrip('resources/unsubscribe', {'uri': uri});
    } on McpException catch (e) {
      core.diagnostic('resources/unsubscribe failed: $e');
    }
  }

  @override
  Future<void> close() => stopListening();
}
