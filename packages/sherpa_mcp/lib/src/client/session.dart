/// Machinery shared by both era sessions (internal).
library;

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart'
    show CancellationToken, CancelledException, FormatError, JsonMap, ToolProgress;

import '../config.dart';
import '../era/era.dart';
import '../errors.dart';
import '../protocol/input.dart';
import '../protocol/json_read.dart';
import '../protocol/jsonrpc.dart';
import '../protocol/tasks.dart';
import '../protocol/types.dart';
import '../protocol/versions.dart';
import '../transport/transport.dart';
import 'cache.dart';
import 'changes.dart';

/// Cache keys.
abstract final class CacheKeys {
  static const String tools = 'tools/list';
  static const String prompts = 'prompts/list';
  static const String resources = 'resources/list';
  static const String templates = 'resources/templates/list';
  static const String discover = 'server/discover';

  static String read(String uri) => 'resources/read $uri';
}

/// One logical request as the connection asks for it.
@immutable
final class CallSpec {
  const CallSpec({
    this.name,
    this.cancel,
    this.timeout,
    this.maxTimeout,
    this.onProgress,
    this.meta = const {},
    this.headers = const {},
    this.onTaskCreated,
  });

  /// Tool / prompt name or resource URI, for the input-request context.
  final String? name;
  final CancellationToken? cancel;
  final Duration? timeout;
  final Duration? maxTimeout;
  final void Function(ToolProgress progress)? onProgress;

  /// Extra non-reserved `_meta` entries (already validated).
  final JsonMap meta;

  /// `Mcp-Param-*` headers (modern HTTP).
  final Map<String, String> headers;
  final FutureOr<void> Function(McpTaskHandle handle)? onTaskCreated;
}

/// What a logical request produced.
typedef CallOutcome = ({JsonMap result, bool viaInput, String? taskId});

/// Idle timer (reset by progress) plus a hard cap on running time; both
/// stop while the user is answering an input request.
final class RequestTimer {
  RequestTimer({required this.idle, required this.max, required this.onExpire}) {
    _start();
  }

  final Duration? idle;
  final Duration? max;
  final void Function(String why) onExpire;
  final Stopwatch _running = Stopwatch();
  Timer? _idleTimer;
  Timer? _maxTimer;
  int _paused = 0;
  bool expired = false;
  bool _stopped = false;

  void _start() {
    if (_stopped || expired) return;
    _running.start();
    if (idle != null) _idleTimer = Timer(idle!, () => _expire('no response within $idle'));
    if (max != null) {
      final left = max! - _running.elapsed;
      _maxTimer = Timer(left.isNegative ? Duration.zero : left, () => _expire('exceeded the $max limit'));
    }
  }

  void _cancelTimers() {
    _idleTimer?.cancel();
    _maxTimer?.cancel();
    _running.stop();
  }

  void _expire(String why) {
    if (expired || _stopped) return;
    expired = true;
    _cancelTimers();
    onExpire(why);
  }

  /// Progress arrived: restart the idle window.
  void touch() {
    if (_paused > 0 || _stopped || expired || idle == null) return;
    _idleTimer?.cancel();
    _idleTimer = Timer(idle!, () => _expire('no progress within $idle'));
  }

  void pause() {
    if (_paused++ == 0) _cancelTimers();
  }

  void resume() {
    if (_paused == 0) return;
    if (--_paused == 0) _start();
  }

  void stop() {
    _stopped = true;
    _cancelTimers();
  }
}

/// Raised by input fulfilment; legacy answers it as a JSON-RPC error,
/// modern turns it into a local failure (there is no error slot in
/// `inputResponses`).
final class InputRequestError implements Exception {
  const InputRequestError(this.code, this.message, {this.declined = false});

  final int code;
  final String message;

  /// The user declined (sampling / roots), as opposed to a bad request.
  final bool declined;
}

/// The era-specific half of a connection.
abstract base class EraSession {
  EraSession(this.core);

  final SessionCore core;

  McpEra get era;
  String get protocolVersion;
  McpServerCapabilities get capabilities;
  McpImplementation? get serverInfo;
  String? get instructions;

  /// One logical request, with input rounds resolved.
  Future<CallOutcome> call(String method, JsonMap params, CallSpec spec);

  /// Era-specific notifications; returns true when consumed.
  bool handleNotification(JsonRpcNotification n, JsonRpcId? related);

  /// A server → client request.
  Future<void> handleServerRequest(JsonRpcRequest request, JsonRpcId? related);

  Future<void> setLogLevel(McpLogLevel? level);

  /// Starts (or re-filters) the change feed.
  Future<McpListenAck> listen({required Set<String> resourceUris});

  Future<void> stopListening();

  bool get isListening;

  /// Whether `list_changed` notifications currently reach us, so legacy
  /// lists may be cached until one arrives.
  bool get changeFeedActive;

  Future<void> subscribeResource(String uri, {required Set<String> allUris});

  Future<void> unsubscribeResource(String uri, {required Set<String> remainingUris});

  Future<JsonMap> pollTask(McpTaskHandle handle, CallSpec spec) async =>
      throw McpProtocolException('tasks are a 2026-07-28 extension; this server speaks $protocolVersion');

  Future<McpTask> getTask(String taskId) async =>
      throw McpProtocolException('tasks are a 2026-07-28 extension; this server speaks $protocolVersion');

  Future<void> cancelTask(String taskId) async =>
      throw McpProtocolException('tasks are a 2026-07-28 extension; this server speaks $protocolVersion');

  Future<void> close();
}

final class _InFlight {
  _InFlight(this.method, this.name, this.timer, this.cancel, this.origin);

  final String method;
  final String? name;
  final RequestTimer timer;
  final CancellationToken cancel;

  /// [McpCallOrigin.current] when the request was sent.
  final McpCallOrigin? origin;
}

/// Ids, round trips, progress, timers, input dispatch, inbound routing.
final class SessionCore {
  SessionCore({required this.config, required this.options, required this.transport}) : cache = ResultCache(options.clock);

  final McpServerConfig config;
  final McpClientOptions options;
  final McpTransport transport;
  final ResultCache cache;
  late EraSession session;

  final StreamController<McpChange> _changes = StreamController<McpChange>.broadcast();
  final Map<String, void Function(ToolProgress)> _progress = {};
  final Map<JsonRpcId, _InFlight> _inFlight = {};
  final Map<JsonRpcId, CancellationToken> _serverRequests = {};
  int _id = 0;
  int _progressSeq = 0;
  bool closed = false;

  Stream<McpChange> get changes => _changes.stream;

  void emit(McpChange c) {
    if (!_changes.isClosed) _changes.add(c);
  }

  void diagnostic(String message, [JsonMap? detail]) => emit(McpDiagnostic(message, detail: detail));

  JsonRpcId nextId() => JsonRpcId.int(++_id);

  String newProgressToken() => 'sherpa-progress-${++_progressSeq}';

  /// The capabilities object to declare in [era].
  JsonMap clientCapabilities(McpEra era) =>
      options.capabilities.toJson(era: era, hasHandler: options.inputHandler != null);

  /// Sends one JSON-RPC request and returns its result object.
  ///
  /// Cancellation and timeouts use the transport's mechanism: closing the
  /// stream on 2026-07-28 HTTP, `notifications/cancelled {requestId}`
  /// elsewhere (never for `initialize`). A late response to a cancelled
  /// request is ignored by the transport.
  Future<JsonMap> roundTrip(
    String method,
    JsonMap? params, {
    String? name,
    CancellationToken? cancel,
    Duration? timeout,
    Duration? maxTimeout,
    String? progressToken,
    void Function(ToolProgress)? onProgress,
    Map<String, String> headers = const {},
    bool longLived = false,
    void Function(JsonRpcId id)? onSent,
  }) async {
    if (closed) throw const McpConnectionClosedException();
    final id = nextId();
    final abort = Completer<void>();
    final token = (cancel ?? CancellationToken.none).child();
    String? cancelReason;
    var notifyCancel = true;

    void doCancel(String reason) {
      if (abort.isCompleted) return;
      cancelReason = reason;
      abort.complete();
      if (notifyCancel && !transport.cancelsByClosingStream && method != 'initialize') {
        transport
            .notify(JsonRpcNotification('notifications/cancelled', {'requestId': id.toJson(), 'reason': reason}))
            .ignore();
      }
    }

    final timer = RequestTimer(
      idle: longLived ? null : (timeout ?? options.timeouts.request),
      max: longLived ? null : (maxTimeout ?? options.timeouts.maxRequest),
      onExpire: (why) => doCancel('timeout: $why'),
    );
    if (token.isCancelled) {
      timer.stop();
      throw CancelledException(token.reason ?? 'cancelled');
    }
    unawaited(token.whenCancelled.then(doCancel));
    _inFlight[id] = _InFlight(method, name, timer, token, McpCallOrigin.current);
    if (progressToken != null) {
      _progress[progressToken] = (p) {
        timer.touch();
        onProgress?.call(p);
      };
    }
    try {
      onSent?.call(id);
      final response = await transport.request(
        JsonRpcRequest(id, method, params),
        options: McpSendOptions(abort: abort.future, headers: headers, longLived: longLived),
      );
      return switch (response) {
        JsonRpcResult(:final result) => result,
        JsonRpcErrorResponse(:final error) => throw McpRpcException(error),
      };
    } on CancelledException {
      if (timer.expired) throw McpTimeoutException('$method ${cancelReason ?? 'timed out'}');
      throw CancelledException(token.reason ?? cancelReason ?? 'cancelled');
    } on McpHttpStatusException catch (e) {
      final rpc = e.rpcError;
      if (rpc != null) throw McpRpcException(rpc, httpStatus: e.statusCode);
      rethrow;
    } finally {
      notifyCancel = false;
      timer.stop();
      token.detach();
      _inFlight.remove(id);
      if (progressToken != null) _progress.remove(progressToken);
    }
  }

  /// Ends a long-lived request locally because the server ended it (stdio
  /// `notifications/cancelled` for a listen stream). The cancel notification
  /// this may still send is harmless: receivers ignore unknown ids.
  void abandon(JsonRpcId id) => _inFlight[id]?.cancel.cancel('ended by the server');

  /// Pauses every running request timer while the user answers.
  Future<T> whileUserAnswers<T>(Future<T> Function() run) async {
    final timers = [for (final f in _inFlight.values) f.timer];
    for (final t in timers) {
      t.pause();
    }
    try {
      return await run();
    } finally {
      for (final t in timers) {
        t.resume();
      }
    }
  }

  /// The context handed to the [InputRequestHandler].
  McpInputContext inputContext({JsonRpcId? related, String? originMethod, String? originName, CancellationToken? cancel}) {
    final f = related == null ? null : _inFlight[related];
    return McpInputContext(
      serverId: config.id,
      serverName: config.name,
      era: session.era,
      originMethod: originMethod ?? f?.method,
      originName: originName ?? f?.name,
      cancel: cancel ?? f?.cancel ?? CancellationToken(),
      // Legacy: the related request's origin; modern: this zone's (the
      // input round runs inside the call).
      origin: f?.origin ?? McpCallOrigin.current,
    );
  }

  /// Serves one input request with the host's [InputRequestHandler],
  /// refusing anything this connection did not declare. Returns the bare
  /// result object (`ElicitResult`, `CreateMessageResult`,
  /// `ListRootsResult`).
  Future<JsonMap> fulfilInput(String method, JsonMap? params, McpInputContext context) async {
    final handler = options.inputHandler;
    final caps = options.capabilities;
    final p = params ?? const <String, Object?>{};
    switch (method) {
      case 'elicitation/create':
        if (handler == null || !(caps.elicitationForm || caps.elicitationUrl)) {
          throw const InputRequestError(JsonRpcError.methodNotFound, 'elicitation was not declared');
        }
        final McpElicitRequest request;
        try {
          request = McpElicitRequest.fromJson(p);
        } on FormatError catch (e) {
          throw InputRequestError(JsonRpcError.invalidParams, e.message);
        }
        final declared = request.mode == McpElicitMode.form ? caps.elicitationForm : caps.elicitationUrl;
        if (!declared) {
          throw InputRequestError(JsonRpcError.invalidParams, '${request.mode.name}-mode elicitation was not declared');
        }
        final result = await whileUserAnswers(() => handler.elicit(request, context));
        return result.toJson();
      case 'sampling/createMessage':
        if (handler == null || !caps.sampling) {
          throw const InputRequestError(JsonRpcError.methodNotFound, 'sampling was not declared');
        }
        final McpSamplingRequest request;
        try {
          request = McpSamplingRequest.fromJson(p);
        } on FormatError catch (e) {
          throw InputRequestError(JsonRpcError.invalidParams, e.message);
        }
        if (request.usesTools && !caps.samplingTools) {
          throw const InputRequestError(JsonRpcError.invalidParams, 'tools in sampling were not declared');
        }
        try {
          final result = await whileUserAnswers(() => handler.createMessage(request, context));
          return result.toJson();
        } on InputRequestDeclined catch (e) {
          throw InputRequestError(JsonRpcError.userRejected, e.reason, declined: true);
        }
      case 'roots/list':
        if (handler == null || !caps.roots) {
          throw const InputRequestError(JsonRpcError.methodNotFound, 'roots were not declared');
        }
        try {
          final roots = await whileUserAnswers(() => handler.listRoots(context));
          return {
            'roots': [
              for (final r in roots)
                if (r.uri.scheme == 'file') r.toJson(), // roots MUST be file:// URIs
            ],
          };
        } on InputRequestDeclined catch (e) {
          throw InputRequestError(JsonRpcError.userRejected, e.reason, declined: true);
        }
      default:
        throw InputRequestError(JsonRpcError.methodNotFound, 'unsupported input request $method');
    }
  }

  /// Routes one inbound server message.
  void onInbound(McpInbound inbound) {
    switch (inbound.message) {
      case final JsonRpcNotification n:
        _onNotification(n, inbound.relatedRequestId);
      case final JsonRpcRequest r:
        unawaited(_onServerRequest(r, inbound.relatedRequestId));
      case JsonRpcResponse(:final id):
        diagnostic('ignored a response to $id that nobody waits for (late or cancelled)');
    }
  }

  Future<void> _onServerRequest(JsonRpcRequest r, JsonRpcId? related) async {
    final token = CancellationToken();
    _serverRequests[r.id] = token;
    try {
      await session.handleServerRequest(r, related);
    } on Object catch (e) {
      diagnostic('failed to answer server request ${r.method}: $e');
    } finally {
      _serverRequests.remove(r.id);
    }
  }

  /// The cancellation token of a server → client request (legacy).
  CancellationToken? serverRequestToken(JsonRpcId id) => _serverRequests[id];

  void _onNotification(JsonRpcNotification n, JsonRpcId? related) {
    final p = n.params ?? const <String, Object?>{};
    switch (n.method) {
      case 'notifications/progress':
        final token = p['progressToken'];
        final progress = asDouble(p['progress']);
        final cb = _progress['$token'];
        if (cb != null && progress != null) {
          cb(ToolProgress(progress: progress, total: asDouble(p['total']), message: asString(p['message'])));
        }
        return;
      case 'notifications/message':
        final level = McpLogLevel.tryParse(p['level']);
        if (level == null) return;
        emit(McpLogMessage(level: level, data: p['data'], logger: asString(p['logger']), requestId: related));
        return;
      case 'notifications/tools/list_changed':
        cache.invalidate(CacheKeys.tools);
        emit(const McpToolsListChanged());
        return;
      case 'notifications/prompts/list_changed':
        cache.invalidate(CacheKeys.prompts);
        emit(const McpPromptsListChanged());
        return;
      case 'notifications/resources/list_changed':
        cache
          ..invalidate(CacheKeys.resources)
          ..invalidate(CacheKeys.templates);
        emit(const McpResourcesListChanged());
        return;
      case 'notifications/resources/updated':
        final uri = asString(p['uri']);
        if (uri == null) return;
        cache.invalidateWhere((k) => k.startsWith(CacheKeys.read(uri)));
        emit(McpResourceUpdated(uri));
        return;
      case 'notifications/cancelled':
        // Legacy: the server cancels a request it sent us.
        final id = JsonRpcId.tryParse(p['requestId']);
        final token = id == null ? null : _serverRequests[id];
        if (token != null) {
          token.cancel(asString(p['reason']) ?? 'cancelled by the server');
          return;
        }
    }
    if (session.handleNotification(n, related)) return;
    if (n.method.startsWith('notifications/')) diagnostic('ignored notification ${n.method}');
  }

  /// Keys under `_meta` a caller may not set.
  static bool isReservedMetaKey(String key) =>
      McpMetaKeys.isReserved(key) || key == McpMetaKeys.progressToken || key == McpMetaKeys.idempotencyKey;

  Future<void> close() async {
    if (closed) return;
    closed = true;
    for (final f in List.of(_inFlight.values)) {
      f.cancel.cancel('connection closed');
    }
    for (final t in _serverRequests.values) {
      t.cancel('connection closed');
    }
    await _changes.close();
  }
}
