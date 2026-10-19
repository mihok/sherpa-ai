/// The 2026-07-28 era session (internal).
library;

import 'dart:async';

import 'package:sherpa_core/sherpa_core.dart' show CancellationToken, CancelledException, FormatError, JsonMap;
import 'package:sherpa_net/sherpa_net.dart' show Backoff;

import '../era/era.dart';
import '../era/handshake.dart';
import '../errors.dart';
import '../protocol/json_read.dart';
import '../protocol/jsonrpc.dart';
import '../protocol/tasks.dart';
import '../protocol/types.dart';
import '../protocol/versions.dart';
import 'changes.dart';
import 'session.dart';

/// Waits [d] unless [token] fires first (then throws [CancelledException]).
/// A child token is used so a long-lived run token does not collect one
/// listener per wait.
Future<void> cancellableDelay(Duration d, CancellationToken? token) async {
  if (token == null || identical(token, CancellationToken.none)) return Future<void>.delayed(d);
  final child = token.child();
  try {
    await Future.any([Future<void>.delayed(d), child.whenCancelled]);
  } finally {
    child.detach();
  }
  token.throwIfCancelled();
}

/// Stateless: every request carries the `_meta` envelope; server input
/// arrives as `InputRequiredResult`s; changes come over
/// `subscriptions/listen`; the log level is per request.
final class ModernSession extends EraSession {
  ModernSession(super.core, {required String version, required McpDiscoverResult discover})
      : _version = version,
        _discover = discover,
        _logLevel = core.options.logLevel;

  String _version;
  McpDiscoverResult _discover;
  McpLogLevel? _logLevel;
  final Backoff _backoff = Backoff();

  /// MRTR is allowed on these only (patterns/mrtr.md).
  static const Set<String> _inputMethods = {'tools/call', 'prompts/get', 'resources/read'};

  @override
  McpEra get era => McpEra.modern;

  @override
  String get protocolVersion => _version;

  @override
  McpServerCapabilities get capabilities => _discover.capabilities;

  @override
  McpImplementation? get serverInfo => _discover.serverInfo;

  @override
  String? get instructions => _discover.instructions;

  McpDiscoverResult get discoverResult => _discover;

  /// A fresh `server/discover` (cache refresh).
  Future<McpDiscoverResult> rediscover() async {
    final r = await core.roundTrip('server/discover', {'_meta': _envelope(const {}, null)});
    final d = McpDiscoverResult.tryParse(r);
    if (d == null) throw McpProtocolException('server/discover returned an invalid result');
    if (!d.supportedVersions.contains(_version)) {
      final mutual = McpVersions.modern.where(d.supportedVersions.contains).firstOrNull;
      if (mutual == null) throw McpUnsupportedVersionException(supported: d.supportedVersions, requested: _version);
      _version = mutual;
    }
    return _discover = d;
  }

  JsonMap _envelope(JsonMap extra, String? progressToken) => {
        ...extra,
        McpMetaKeys.progressToken: ?progressToken,
        ...modernEnvelope(
          protocolVersion: _version,
          clientCapabilities: core.clientCapabilities(McpEra.modern),
          clientInfo: core.options.clientInfo,
          logLevel: _logLevel,
        ),
      };

  @override
  Future<CallOutcome> call(String method, JsonMap params, CallSpec spec) async {
    final token = spec.onProgress == null ? null : core.newProgressToken();
    final limits = core.options.limits;
    String? requestState;
    JsonMap? inputResponses;
    var rounds = 0;
    var stateOnly = 0;
    for (;;) {
      // A retry is a NEW request (new id, from roundTrip) with the original
      // params plus this round's responses and the echoed state; the two are
      // never shared with any other request.
      final result = await core.roundTrip(
        method,
        {
          ...params,
          'inputResponses': ?inputResponses,
          'requestState': ?requestState,
          '_meta': _envelope(spec.meta, token),
        },
        name: spec.name,
        cancel: spec.cancel,
        timeout: spec.timeout,
        maxTimeout: spec.maxTimeout,
        progressToken: token,
        onProgress: spec.onProgress,
        headers: spec.headers,
      );
      final type = result['resultType'] ?? 'complete';
      switch (type) {
        case 'complete':
          return (result: result, viaInput: rounds > 0, taskId: null);
        case 'input_required':
          if (!_inputMethods.contains(method)) throw McpProtocolException('$method may not return input_required');
          if (++rounds > limits.maxInputRounds) {
            throw McpLimitExceededException('$method needed more than ${limits.maxInputRounds} input rounds');
          }
          final requests = asMap(result['inputRequests']);
          final state = result['requestState'];
          if (requests == null && state == null) {
            throw McpProtocolException('input_required carries neither inputRequests nor requestState');
          }
          if (state != null && state is! String) throw McpProtocolException('requestState must be a string');
          requestState = state as String?; // echoed byte-exact, never parsed
          if (requests == null || requests.isEmpty) {
            // "Retry now" (e.g. load shedding): back off a little.
            inputResponses = null;
            await cancellableDelay(Backoff(base: const Duration(milliseconds: 100), max: const Duration(seconds: 2))
                .delay(stateOnly++), spec.cancel);
          } else {
            inputResponses = await _fulfilAll(requests, method, spec);
          }
        case 'task':
          if (!core.options.capabilities.tasks) {
            throw McpProtocolException('resultType "task" although the tasks extension was not declared');
          }
          final McpTask task;
          try {
            task = McpTask.fromJson(result);
          } on FormatError catch (e) {
            throw McpProtocolException('invalid CreateTaskResult: ${e.message}');
          }
          final handle = McpTaskHandle(
            serverId: core.config.id,
            taskId: task.taskId,
            method: method,
            name: spec.name,
            createdAt: task.createdAt ?? core.options.clock.now(),
            pollIntervalMs: task.pollIntervalMs,
            ttlMs: task.ttlMs,
          );
          await spec.onTaskCreated?.call(handle);
          core.emit(McpTaskStatusChanged(task));
          final r = await _poll(handle, spec, task);
          return (result: r, viaInput: true, taskId: task.taskId);
        default:
          throw McpProtocolException('unknown resultType "$type"');
      }
    }
  }

  /// Fulfils every input request of one round, in key order (one consent
  /// dialog at a time). A declined sampling/roots request ends the call:
  /// the server is not waiting, so there is nothing to retry.
  Future<JsonMap> _fulfilAll(JsonMap requests, String method, CallSpec spec) async {
    final ctx = core.inputContext(originMethod: method, originName: spec.name, cancel: spec.cancel);
    final out = <String, Object?>{};
    for (final e in requests.entries) {
      final r = asMap(e.value);
      final m = asString(r?['method']);
      if (m == null) throw McpProtocolException('input request "${e.key}" has no method');
      try {
        out[e.key] = await core.fulfilInput(m, asMap(r!['params']), ctx);
      } on InputRequestError catch (err) {
        if (err.declined) throw McpInputDeclinedException('${e.key} ($m): ${err.message}');
        throw McpProtocolException('server asked for ${e.key} ($m): ${err.message}');
      }
      spec.cancel?.throwIfCancelled();
    }
    return out;
  }

  Duration _interval(McpTask task, McpTaskHandle h) {
    final ms = task.pollIntervalMs ?? h.pollIntervalMs ?? 1000;
    return Duration(milliseconds: ms.clamp(100, 60000));
  }

  /// Polls `tasks/get` until the task is terminal, answering input with
  /// `tasks/update`. Cancelling sends `tasks/cancel` (best effort).
  Future<JsonMap> _poll(McpTaskHandle h, CallSpec spec, McpTask? initial) async {
    final cancel = spec.cancel;
    var task = initial;
    var last = task?.status;
    var rounds = 0;
    try {
      for (;;) {
        if (task != null) {
          switch (task.status) {
            case McpTaskStatus.completed:
              final r = task.result;
              if (r == null) throw McpProtocolException('completed task ${task.taskId} has no result');
              return r;
            case McpTaskStatus.failed:
              throw McpTaskFailedException(task.taskId, task.error);
            case McpTaskStatus.cancelled:
              throw CancelledException('task ${task.taskId} was cancelled');
            case McpTaskStatus.inputRequired when (task.inputRequests?.isNotEmpty ?? false):
              if (++rounds > core.options.limits.maxInputRounds) {
                throw McpLimitExceededException('task ${task.taskId} needed too many input rounds');
              }
              final responses = await _fulfilAll(task.inputRequests!, h.method, spec);
              await core.roundTrip(
                'tasks/update',
                {'taskId': h.taskId, 'inputResponses': responses, '_meta': _envelope(const {}, null)},
                cancel: cancel,
              );
              task = null; // re-read at once
              continue;
            case McpTaskStatus.working || McpTaskStatus.inputRequired:
              await cancellableDelay(_interval(task, h), cancel);
          }
        }
        task = await getTask(h.taskId, cancel: cancel);
        if (task.status != last) {
          last = task.status;
          core.emit(McpTaskStatusChanged(task));
        }
      }
    } on CancelledException {
      if (cancel != null && cancel.isCancelled) unawaited(cancelTask(h.taskId).catchError((Object _) {}));
      rethrow;
    }
  }

  @override
  Future<JsonMap> pollTask(McpTaskHandle handle, CallSpec spec) => _poll(handle, spec, null);

  @override
  Future<McpTask> getTask(String taskId, {CancellationToken? cancel}) async {
    final r = await core.roundTrip('tasks/get', {'taskId': taskId, '_meta': _envelope(const {}, null)},
        name: taskId, cancel: cancel);
    try {
      return McpTask.fromJson(r);
    } on FormatError catch (e) {
      throw McpProtocolException('invalid tasks/get result: ${e.message}');
    }
  }

  @override
  Future<void> cancelTask(String taskId) async {
    await core.roundTrip('tasks/cancel', {'taskId': taskId, '_meta': _envelope(const {}, null)}, name: taskId);
  }

  @override
  Future<void> handleServerRequest(JsonRpcRequest request, JsonRpcId? related) async {
    // "Servers MUST NOT initiate JSON-RPC requests" (patterns/index.md).
    core.diagnostic('ignored ${request.method} request from a 2026-07-28 server (protocol violation)');
  }

  @override
  Future<void> setLogLevel(McpLogLevel? level) async => _logLevel = level;

  // ---- subscriptions/listen (patterns/subscriptions.md) ----

  bool _wantListen = false;
  Set<String> _uris = {};
  CancellationToken? _listenCancel;
  JsonRpcId? _listenId;
  final Map<JsonRpcId, Completer<McpListenAck>> _acks = {};
  int _failures = 0;

  @override
  bool get isListening => _listenCancel != null;

  @override
  bool get changeFeedActive => isListening;

  @override
  Future<McpListenAck> listen({required Set<String> resourceUris}) {
    _wantListen = true;
    _uris = {...resourceUris};
    return _open(resync: false);
  }

  /// Opens a listen stream with the current filter; on its ack the previous
  /// stream (if any) is closed (make-before-break, so a re-filter loses
  /// nothing).
  Future<McpListenAck> _open({required bool resync}) async {
    final caps = capabilities;
    final cancel = CancellationToken();
    final ack = Completer<McpListenAck>();
    JsonRpcId? id;
    final done = core.roundTrip(
      'subscriptions/listen',
      {
        'notifications': {
          if (caps.tools) 'toolsListChanged': true,
          if (caps.prompts) 'promptsListChanged': true,
          if (caps.resources) 'resourcesListChanged': true,
          if (_uris.isNotEmpty) 'resourceSubscriptions': _uris.toList(),
        },
        '_meta': _envelope(const {}, null),
      },
      cancel: cancel,
      longLived: true,
      onSent: (i) {
        id = i;
        _acks[i] = ack;
      },
    );
    unawaited(done.then((_) => _ended(cancel, id, null), onError: (Object e) => _ended(cancel, id, e)));
    final McpListenAck a;
    try {
      a = await ack.future.timeout(core.options.timeouts.listenAck);
    } on TimeoutException {
      cancel.cancel('not acknowledged');
      throw McpTimeoutException('subscriptions/listen was not acknowledged within ${core.options.timeouts.listenAck}');
    } on Object {
      cancel.cancel('failed');
      rethrow;
    }
    // The ack echoes only what the server honours (subscriptions.md: the
    // client SHOULD diff it against the request).
    final refused = _uris.difference(a.resourceSubscriptions.toSet());
    if (refused.isNotEmpty) core.diagnostic('server did not accept subscriptions to ${refused.join(', ')}');
    final previous = _listenCancel;
    _listenCancel = cancel;
    _listenId = id;
    _failures = 0;
    previous?.cancel('re-filtered');
    if (resync) {
      // Notifications may have been missed while the stream was down.
      core.cache.clear();
      core
        ..emit(const McpToolsListChanged(resync: true))
        ..emit(const McpPromptsListChanged(resync: true))
        ..emit(const McpResourcesListChanged(resync: true));
    }
    core.emit(McpListenStateChanged(active: true, ack: a));
    return a;
  }

  void _ended(CancellationToken cancel, JsonRpcId? id, Object? error) {
    final pending = id == null ? null : _acks.remove(id);
    if (pending != null && !pending.isCompleted) {
      pending.completeError(error ?? McpProtocolException('subscriptions/listen ended before its acknowledgement'));
    }
    if (!identical(cancel, _listenCancel)) return; // superseded, or never active
    _listenCancel = null;
    _listenId = null;
    if (!_wantListen || core.closed) return;
    unawaited(_reconnect(error));
  }

  Future<void> _reconnect(Object? cause) async {
    var error = cause;
    core.emit(McpListenStateChanged(active: false, error: error));
    while (_wantListen && !core.closed) {
      if (++_failures > core.options.limits.maxListenReconnects) {
        _wantListen = false;
        core.emit(McpListenStateChanged(active: false, error: error ?? 'listen stream kept closing'));
        return;
      }
      await Future<void>.delayed(_backoff.delay(_failures - 1));
      if (!_wantListen || core.closed || isListening) return;
      try {
        await _open(resync: true);
        return;
      } on Object catch (e) {
        error = e;
      }
    }
  }

  @override
  Future<void> stopListening() async {
    _wantListen = false;
    final c = _listenCancel;
    _listenCancel = null;
    _listenId = null;
    if (c != null) {
      c.cancel('stopped');
      core.emit(const McpListenStateChanged(active: false));
    }
  }

  @override
  Future<void> subscribeResource(String uri, {required Set<String> allUris}) async {
    _uris = {...allUris};
    _wantListen = true;
    await _open(resync: false);
  }

  @override
  Future<void> unsubscribeResource(String uri, {required Set<String> remainingUris}) async {
    _uris = {...remainingUris};
    if (isListening) await _open(resync: false);
  }

  @override
  bool handleNotification(JsonRpcNotification n, JsonRpcId? related) {
    final p = n.params ?? const <String, Object?>{};
    switch (n.method) {
      case 'notifications/subscriptions/acknowledged':
        final sid = JsonRpcId.tryParse(asMap(p['_meta'])?[McpMetaKeys.subscriptionId]) ?? related;
        final c = sid == null ? null : _acks.remove(sid);
        if (c != null && !c.isCompleted) {
          final f = asMap(p['notifications']) ?? const <String, Object?>{};
          c.complete(McpListenAck(
            toolsListChanged: asBool(f['toolsListChanged']) ?? false,
            promptsListChanged: asBool(f['promptsListChanged']) ?? false,
            resourcesListChanged: asBool(f['resourcesListChanged']) ?? false,
            resourceSubscriptions: stringList(f['resourceSubscriptions']),
          ));
        }
        return true;
      case 'notifications/tasks':
        try {
          core.emit(McpTaskStatusChanged(McpTask.fromJson(p)));
        } on FormatError {
          core.diagnostic('ignored malformed notifications/tasks');
        }
        return true;
      case 'notifications/cancelled':
        // stdio: the server tears down a listen stream this way.
        final id = JsonRpcId.tryParse(p['requestId']);
        if (id != null && id == _listenId) core.abandon(id);
        return true;
    }
    return false;
  }

  @override
  Future<void> close() => stopListening();
}
