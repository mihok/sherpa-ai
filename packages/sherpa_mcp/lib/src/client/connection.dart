/// The one era-agnostic MCP client API the rest of Sherpa uses.
library;

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart' show CancellationToken, FormatError, JsonMap, ToolProgress;

import '../config.dart';
import '../era/era.dart';
import '../era/handshake.dart';
import '../era/probe.dart';
import '../errors.dart';
import '../protocol/headers.dart';
import '../protocol/json_read.dart';
import '../protocol/jsonrpc.dart';
import '../protocol/primitives.dart';
import '../protocol/tasks.dart';
import '../protocol/types.dart';
import '../protocol/versions.dart';
import '../transport/http.dart';
import '../transport/modern_http.dart';
import '../transport/transport.dart';
import 'changes.dart';
import 'legacy_session.dart';
import 'modern_session.dart';
import 'session.dart';

/// Who the server is, as established by `server/discover` (M) or
/// `initialize` (L). All text is self-reported and untrusted.
@immutable
final class McpServerDescription {
  const McpServerDescription({
    required this.era,
    required this.protocolVersion,
    required this.capabilities,
    this.serverInfo,
    this.instructions,
  });

  final McpEra era;
  final String protocolVersion;
  final McpServerCapabilities capabilities;
  final McpImplementation? serverInfo;

  /// Meant for the system prompt; treat as untrusted server text.
  final String? instructions;
}

/// An active resource subscription; [cancel] ends it.
final class McpResourceSubscription {
  McpResourceSubscription._(this.uri, this._cancel);

  final String uri;
  final Future<void> Function() _cancel;
  bool _cancelled = false;

  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    await _cancel();
  }
}

/// Taps transports' inbound streams from the moment they exist, so a
/// message that arrives during the handshake is replayed, not lost.
final class _InboundTap {
  final Map<McpTransport, StreamSubscription<McpInbound>> _subs = {};
  final Map<McpTransport, List<McpInbound>> _buffers = {};

  void attach(McpTransport t) {
    final buffer = _buffers[t] = <McpInbound>[];
    _subs[t] = t.inbound.listen(buffer.add);
  }

  /// Keeps [chosen]'s subscription, now delivering to [sink], after
  /// replaying what it buffered; drops the rest.
  StreamSubscription<McpInbound> adopt(McpTransport chosen, void Function(McpInbound) sink) {
    for (final e in _subs.entries) {
      if (!identical(e.key, chosen)) e.value.cancel().ignore();
    }
    final sub = _subs[chosen]!..onData(sink);
    for (final m in _buffers[chosen]!) {
      sink(m);
    }
    _subs.clear();
    _buffers.clear();
    return sub;
  }

  Future<void> cancelAll() async {
    for (final s in _subs.values) {
      await s.cancel();
    }
    _subs.clear();
  }
}

/// A connection to one MCP server, in whichever era it speaks.
///
/// Obtain one with [connect]; it runs era detection (or trusts a cached
/// [EraVerdict], re-probing once if the server contradicts it), performs
/// the handshake of the detected era and exposes every primitive through
/// the same calls. Server text (descriptions, instructions, logs, tool
/// output) is untrusted data.
final class McpConnection {
  McpConnection._(this.config, this._core, this._session, this._inboundSub, this.verdict, this.probeLog,
      McpDiscoverResult? discover) {
    if (discover != null) {
      _core.cache.put(CacheKeys.discover, discover,
          ttl: Duration(milliseconds: discover.ttlMs), isPrivate: discover.cacheScope != 'public');
    }
    unawaited(_core.transport.done.then((_) {
      if (!_closing) _core.emit(const McpConnectionLost('transport closed'));
    }));
  }

  /// Connects to [config].
  ///
  /// HTTP servers need [McpClientOptions.httpClient]. In-process servers
  /// ([McpTransportPreference.inProcess]) need [transport] (e.g. from
  /// [InProcessTransport.pair]). Throws [McpAuthRequiredException] when the
  /// server wants (re-)authorization: run OAuth, then call again.
  static Future<McpConnection> connect(
    McpServerConfig config, {
    McpClientOptions options = const McpClientOptions(),
    McpTransport? transport,
  }) async {
    final tap = _InboundTap();
    final hasHandler = options.inputHandler != null;
    final inProcess = config.transport == McpTransportPreference.inProcess;
    final probe = McpEraProbe(
      clientInfo: options.clientInfo,
      modernCapabilities: options.capabilities.toJson(era: McpEra.modern, hasHandler: hasHandler),
      legacyCapabilities: options.capabilities.toJson(era: McpEra.legacy, hasHandler: hasHandler),
      probeTimeout: inProcess ? options.timeouts.inProcessProbe : options.timeouts.probe,
      requestTimeout: options.timeouts.request,
      clock: options.clock,
      allowLegacyFallback: config.transport != McpTransportPreference.modernHttp,
      onTransport: tap.attach,
    );
    final McpProbeResult result;
    McpHttp? http;
    try {
      if (inProcess) {
        if (transport == null) throw ArgumentError.notNull('transport');
        tap.attach(transport);
        await transport.start();
        result = await probe.probeChannel(transport);
      } else {
        final client = options.httpClient;
        if (client == null) throw ArgumentError.notNull('options.httpClient');
        http = McpHttp(
          client: client,
          serverUrl: config.url,
          policy: options.urlPolicy ?? config.urlPolicy,
          timeouts: options.timeouts,
          limits: options.limits,
          auth: options.authHook,
          baseHeaders: config.headers,
        );
        result = await _probeHttp(config, options, probe, http, tap);
      }
    } on Object {
      await tap.cancelAll();
      rethrow;
    }
    final v = result.verdict;
    if (v != null) options.verdictCache?.store(v);
    final core = SessionCore(config: config, options: options, transport: result.transport);
    final EraSession session = result.era == McpEra.modern
        ? ModernSession(core, version: result.protocolVersion, discover: result.discover!)
        : LegacySession(core, handshake: result.handshake!);
    core.session = session;
    final t = result.transport;
    // A new credential is a new authorization context: drop `private` entries.
    http?.onCredentialChanged = core.cache.dropPrivate;
    // Cancelled in close().
    // ignore: cancel_subscriptions
    final sub = tap.adopt(t, core.onInbound);
    final connection = McpConnection._(config, core, session, sub, v, result.attempts, result.discover);
    if (result.era == McpEra.legacy && options.logLevel != null && session.capabilities.logging) {
      try {
        await session.setLogLevel(options.logLevel);
      } on McpException catch (e) {
        core.diagnostic('logging/setLevel failed: $e');
      }
    }
    return connection;
  }

  static Future<McpProbeResult> _probeHttp(
    McpServerConfig config,
    McpClientOptions options,
    McpEraProbe probe,
    McpHttp http,
    _InboundTap tap,
  ) async {
    Future<McpProbeResult> modernOnly() async {
      final t = ModernHttpTransport(http: http);
      tap.attach(t);
      final log = <String>[];
      final ModernVerdict? v;
      try {
        v = await probe.probeModern(t, log);
      } on Object {
        await t.close();
        rethrow;
      }
      if (v == null) {
        await t.close();
        throw McpEraNegotiationException('the server did not answer as a 2026-07-28 server', attempts: log);
      }
      return McpProbeResult(
        transport: t,
        era: McpEra.modern,
        protocolVersion: v.version,
        verdict: EraVerdict(
          transport: McpTransportKind.modernHttp,
          protocolVersion: v.version,
          endpoint: endpointKey(config.url),
          decidedAt: options.clock.now(),
        ),
        discover: v.discover,
        attempts: log,
      );
    }

    switch (config.transport) {
      case McpTransportPreference.modernHttp:
        return modernOnly();
      case McpTransportPreference.legacyStreamableHttp:
        return probe.probeLegacyHttp(http, allowSse: false);
      case McpTransportPreference.legacySse:
        return probe.probeSse(http);
      case McpTransportPreference.inProcess:
        throw StateError('unreachable');
      case McpTransportPreference.auto:
        final fromConfig = config.cachedVerdict;
        final cached = fromConfig != null && fromConfig.appliesTo(config.url)
            ? fromConfig
            : options.verdictCache?.lookup(config.url);
        if (cached != null) {
          try {
            final r = await switch (cached.transport) {
              McpTransportKind.modernHttp => modernOnly(),
              McpTransportKind.legacyStreamableHttp => probe.probeLegacyHttp(http, allowSse: false),
              McpTransportKind.legacySse => probe.probeSse(http),
              McpTransportKind.inProcess => throw StateError('unreachable'),
            };
            return r.withLog('cached verdict: $cached');
          } on Object catch (e) {
            if (!_contradictsVerdict(e)) rethrow;
            options.verdictCache?.invalidate(config.url);
            return (await probe.probeHttp(http)).withLog('cached verdict $cached failed: $e');
          }
        }
        return probe.probeHttp(http);
    }
  }

  /// Whether [e] means "the cached era is wrong" rather than "the server
  /// is unreachable / unauthorized" (which re-probing would not fix).
  static bool _contradictsVerdict(Object e) => switch (e) {
        McpAuthRequiredException() || McpTimeoutException() => false,
        McpEraNegotiationException() || McpUnsupportedVersionException() || McpProtocolException() => true,
        McpRpcException() => true,
        McpHttpStatusException(:final statusCode) => statusCode < 500,
        _ => false,
      };

  final McpServerConfig config;
  final SessionCore _core;
  final EraSession _session;
  final StreamSubscription<McpInbound> _inboundSub;

  /// The era verdict to persist (`config.copyWith(cachedVerdict: …)`);
  /// null for in-process servers.
  final EraVerdict? verdict;

  /// What era detection did, for the debug console.
  final List<String> probeLog;
  final Set<String> _subscriptions = {};
  List<McpToolRejection> _rejected = const [];
  bool _closing = false;

  McpEra get era => _session.era;

  McpTransportKind get transportKind => _core.transport.kind;

  String get protocolVersion => _session.protocolVersion;

  McpImplementation? get serverInfo => _session.serverInfo;

  McpServerCapabilities get capabilities => _session.capabilities;

  /// Untrusted server instructions (system-prompt material).
  String? get instructions => _session.instructions;

  /// Whether [verdict] differs from what the config had cached.
  bool get verdictChanged => verdict != null && verdict != config.cachedVerdict;

  /// List changes, resource updates, logs, task updates, listen state,
  /// diagnostics and connection loss. Broadcast; events are not replayed.
  Stream<McpChange> get changes => _core.changes;

  /// Server log messages only (untrusted; for the debug console).
  Stream<McpLogMessage> get logs => changes.where((c) => c is McpLogMessage).cast<McpLogMessage>();

  bool get isClosed => _closing;

  /// Completes when the underlying transport is gone.
  Future<void> get done => _core.transport.done;

  /// Tool definitions excluded from the last [listTools] (invalid
  /// `x-mcp-header`, malformed schema, duplicate name), with reasons.
  List<McpToolRejection> get rejectedTools => _rejected;

  /// Whether the change feed is up.
  bool get isListening => _session.isListening;

  void _checkOpen() {
    if (_closing) throw const McpConnectionClosedException();
  }

  /// One logical request: retries once with a new id when a SAFE request's
  /// stream broke (2026-07-28 has no resumability), and drops the cached
  /// verdict when a modern server stops accepting our version.
  Future<CallOutcome> _call(String method, JsonMap params, CallSpec spec, {bool safe = false}) async {
    _checkOpen();
    for (var attempt = 0;; attempt++) {
      try {
        return await _session.call(method, params, spec);
      } on McpTransportException catch (e) {
        if (safe && e.streamInterrupted && attempt == 0) continue;
        rethrow;
      } on McpRpcException catch (e) {
        if (e.code == JsonRpcError.unsupportedProtocolVersion) {
          _core.options.verdictCache?.invalidate(config.url);
          _core.diagnostic('server rejected protocol $protocolVersion; reconnect to re-negotiate');
        }
        rethrow;
      }
    }
  }

  // ---------------------------------------------------------------- discover

  /// The server description. Modern: re-runs `server/discover` when
  /// [refresh] is set or the cached result's `ttlMs` expired. Legacy: the
  /// `initialize` result (only re-initialization refreshes it).
  Future<McpServerDescription> discover({bool refresh = false}) async {
    _checkOpen();
    final s = _session;
    if (s is ModernSession && (refresh || _core.cache.fresh<McpDiscoverResult>(CacheKeys.discover) == null)) {
      final d = await s.rediscover();
      _core.cache.put(CacheKeys.discover, d, ttl: Duration(milliseconds: d.ttlMs), isPrivate: d.cacheScope != 'public');
    }
    return McpServerDescription(
      era: s.era,
      protocolVersion: s.protocolVersion,
      capabilities: s.capabilities,
      serverInfo: s.serverInfo,
      instructions: s.instructions,
    );
  }

  // ---------------------------------------------------------------- lists

  Duration _ttlOf(JsonMap result, {required bool listChanged}) {
    if (era == McpEra.modern) {
      final ms = asInt(result['ttlMs']);
      return Duration(milliseconds: ms == null || ms < 0 ? 0 : ms);
    }
    // Legacy results carry no ttlMs: trust list_changed while the feed is up.
    if (listChanged && _session.changeFeedActive) return const Duration(days: 1);
    return _core.options.legacyListCacheTtl;
  }

  Future<List<T>> _list<T extends Object>({
    required String method,
    required String key,
    required String field,
    required bool listChanged,
    required T? Function(JsonMap item) parse,
    required bool refresh,
    CancellationToken? cancel,
    void Function()? onStart,
    void Function()? onFetched,
  }) async {
    _checkOpen();
    if (!refresh) {
      final fresh = _core.cache.fresh<List<T>>(key);
      if (fresh != null) return fresh;
    }
    try {
      final out = <T>[];
      Duration? ttl;
      var isPrivate = false;
      String? cursor;
      var restarted = false;
      onStart?.call();
      for (var page = 0;; page++) {
        if (page >= _core.options.limits.maxListPages) {
          throw McpLimitExceededException('$method returned more than ${_core.options.limits.maxListPages} pages');
        }
        final JsonMap r;
        try {
          r = (await _call(method, {'cursor': ?cursor}, CallSpec(cancel: cancel), safe: true)).result;
        } on McpRpcException catch (e) {
          // An invalid cursor: discard the pages and restart once.
          if (e.isInvalidParams && cursor != null && !restarted) {
            restarted = true;
            out.clear();
            onStart?.call();
            cursor = null;
            ttl = null;
            page = -1;
            continue;
          }
          rethrow;
        }
        for (final item in mapList(r[field])) {
          final v = parse(item);
          if (v != null) out.add(v);
        }
        final pageTtl = _ttlOf(r, listChanged: listChanged);
        ttl = ttl == null || pageTtl < ttl ? pageTtl : ttl;
        isPrivate |= r['cacheScope'] != 'public';
        final next = r['nextCursor'];
        if (next == null) break;
        if (next is! String) throw McpProtocolException('$method: nextCursor must be a string');
        cursor = next; // "" is a valid cursor; only absence ends the list
      }
      final list = List<T>.unmodifiable(out);
      _core.cache.put<List<T>>(key, list, ttl: ttl, isPrivate: isPrivate);
      onFetched?.call();
      return list;
    } on Object catch (e) {
      final stale = _core.cache.entry<List<T>>(key);
      final transient = e is McpTimeoutException || (e is McpTransportException && e is! McpHttpStatusException);
      if (_core.options.serveStaleOnError && stale != null && transient) {
        _core.diagnostic('$method failed ($e); serving the cached list');
        return stale.value;
      }
      rethrow;
    }
  }

  /// All tools (every page), in server order (stable order keeps prompt
  /// caches warm). Cached per `ttlMs` (M) and invalidated by
  /// `list_changed`. On 2026-07-28 HTTP, tools with invalid `x-mcp-header`
  /// declarations are excluded (MUST) and reported in [rejectedTools] and
  /// as [McpDiagnostic]s; so are malformed and duplicate definitions.
  Future<List<McpTool>> listTools({bool refresh = false, CancellationToken? cancel}) {
    final rejected = <McpToolRejection>[];
    final seen = <String>{};
    final checkHeaders = transportKind == McpTransportKind.modernHttp;
    return _list<McpTool>(
      method: 'tools/list',
      key: CacheKeys.tools,
      field: 'tools',
      listChanged: capabilities.toolsListChanged,
      refresh: refresh,
      cancel: cancel,
      onStart: () {
        rejected.clear();
        seen.clear();
      },
      // Only a completed fetch replaces the rejections (not a cache hit or
      // a stale fallback).
      onFetched: () => _rejected = List.unmodifiable(rejected),
      parse: (j) {
        McpToolRejection reject(String reason) {
          final r = McpToolRejection(asString(j['name']) ?? '<unnamed>', reason, j);
          rejected.add(r);
          _core.diagnostic('excluded tool "${r.name}": $reason');
          return r;
        }

        McpTool tool;
        try {
          tool = McpTool.fromJson(j);
        } on FormatError catch (e) {
          reject(e.message);
          return null;
        }
        if (!seen.add(tool.name)) {
          reject('duplicate tool name');
          return null;
        }
        final (withHeaders, reason) = withHeaderScan(tool);
        if (withHeaders == null) {
          if (checkHeaders) {
            reject(reason!);
            return null;
          }
        } else {
          tool = withHeaders;
        }
        return tool;
      },
    );
  }

  Future<List<McpResource>> listResources({bool refresh = false, CancellationToken? cancel}) => _list<McpResource>(
        method: 'resources/list',
        key: CacheKeys.resources,
        field: 'resources',
        listChanged: capabilities.resourcesListChanged,
        refresh: refresh,
        cancel: cancel,
        parse: (j) => _tryParse(() => McpResource.fromJson(j), 'resource'),
      );

  Future<List<McpResourceTemplate>> listResourceTemplates({bool refresh = false, CancellationToken? cancel}) =>
      _list<McpResourceTemplate>(
        method: 'resources/templates/list',
        key: CacheKeys.templates,
        field: 'resourceTemplates',
        listChanged: capabilities.resourcesListChanged,
        refresh: refresh,
        cancel: cancel,
        parse: (j) => _tryParse(() => McpResourceTemplate.fromJson(j), 'resource template'),
      );

  Future<List<McpPrompt>> listPrompts({bool refresh = false, CancellationToken? cancel}) => _list<McpPrompt>(
        method: 'prompts/list',
        key: CacheKeys.prompts,
        field: 'prompts',
        listChanged: capabilities.promptsListChanged,
        refresh: refresh,
        cancel: cancel,
        parse: (j) => _tryParse(() => McpPrompt.fromJson(j), 'prompt'),
      );

  T? _tryParse<T>(T Function() parse, String what) {
    try {
      return parse();
    } on FormatError catch (e) {
      _core.diagnostic('skipped malformed $what: ${e.message}');
      return null;
    }
  }

  // ---------------------------------------------------------------- tools

  static void _checkMeta(JsonMap meta) {
    for (final k in meta.keys) {
      if (SessionCore.isReservedMetaKey(k)) throw ArgumentError.value(k, 'meta', 'reserved _meta key');
    }
  }

  Future<Map<String, String>> _paramHeaders(String name, JsonMap? arguments, {required bool refresh}) async {
    if (transportKind != McpTransportKind.modernHttp) return const {};
    // Stale definitions are fine here: a -32020 mismatch triggers a re-list.
    var tools = refresh ? null : _core.cache.entry<List<McpTool>>(CacheKeys.tools)?.value;
    if (tools == null) {
      try {
        tools = await listTools(refresh: refresh);
      } on McpException catch (e) {
        // Without definitions no Mcp-Param-* can be mirrored; a tool that
        // needs them is rejected by the server with -32020.
        _core.diagnostic('tools/list failed before tools/call ($e); sending no Mcp-Param headers');
        return const {};
      }
    }
    final rejected = _rejected.where((r) => r.name == name).firstOrNull;
    if (rejected != null) throw McpProtocolException('tool "$name" was excluded: ${rejected.reason}');
    final tool = tools.where((t) => t.name == name).firstOrNull;
    return tool == null ? const {} : buildMcpParamHeaders(tool.headerParams, arguments);
  }

  /// Calls a tool by its WIRE name.
  ///
  /// * [onProgress] receives `notifications/progress`; progress also resets
  ///   the idle [timeout] (hard cap [maxTimeout]).
  /// * [cancel]: closes the stream (2026-07-28 HTTP) or sends
  ///   `notifications/cancelled` (legacy / in-process); throws
  ///   `CancelledException`.
  /// * [meta]: extra `_meta` entries under your own prefix (reserved
  ///   `io.modelcontextprotocol/…`, `progressToken` and Sherpa's keys are
  ///   refused). [idempotencyKey] goes to `_meta["ai.sherpa/idempotencyKey"]`:
  ///   advisory, for servers that dedupe a call re-issued after a broken
  ///   stream or a resume.
  /// * Elicitation / sampling the server needs go to the
  ///   [InputRequestHandler] in both eras.
  /// * If the server runs it as a Tasks-extension task, [onTaskCreated]
  ///   gets the durable handle first (persist it), then the call polls
  ///   `tasks/get` until the task completes.
  ///
  /// A broken response stream is NOT retried (the tool may not be
  /// idempotent): it throws [McpTransportException] with
  /// `streamInterrupted`; the router decides.
  Future<McpCallToolResult> callTool(
    String name, {
    JsonMap? arguments,
    CancellationToken? cancel,
    Duration? timeout,
    Duration? maxTimeout,
    void Function(ToolProgress progress)? onProgress,
    JsonMap meta = const {},
    String? idempotencyKey,
    FutureOr<void> Function(McpTaskHandle handle)? onTaskCreated,
  }) async {
    _checkOpen();
    _checkMeta(meta);
    final m = {...meta, McpMetaKeys.idempotencyKey: ?idempotencyKey};
    var refreshed = false;
    for (;;) {
      final headers = await _paramHeaders(name, arguments, refresh: refreshed);
      try {
        final o = await _call(
          'tools/call',
          {'name': name, 'arguments': ?arguments},
          CallSpec(
            name: name,
            cancel: cancel,
            timeout: timeout,
            maxTimeout: maxTimeout,
            onProgress: onProgress,
            meta: m,
            headers: headers,
            onTaskCreated: onTaskCreated,
          ),
        );
        return McpCallToolResult.fromJson(o.result, taskId: o.taskId);
      } on McpRpcException catch (e) {
        // -32020: our Mcp-Param-* headers disagree with the server's view
        // of the tool. Re-fetch tools/list and retry once.
        if (e.code == JsonRpcError.headerMismatch && !refreshed && transportKind == McpTransportKind.modernHttp) {
          refreshed = true;
          continue;
        }
        rethrow;
      }
    }
  }

  // ---------------------------------------------------------------- resources

  /// Reads a resource (may involve input rounds in M). Cached by `ttlMs`
  /// unless input was needed; invalidated by `resources/updated`. Not
  /// found is [McpRpcException.isResourceNotFound] (-32602 M / -32002 L).
  Future<McpReadResourceResult> readResource(
    String uri, {
    bool refresh = false,
    CancellationToken? cancel,
    Duration? timeout,
    void Function(ToolProgress progress)? onProgress,
  }) async {
    _checkOpen();
    final key = CacheKeys.read(uri);
    if (!refresh) {
      final fresh = _core.cache.fresh<McpReadResourceResult>(key);
      if (fresh != null) return fresh;
    }
    final o = await _call('resources/read', {'uri': uri},
        CallSpec(name: uri, cancel: cancel, timeout: timeout, onProgress: onProgress), safe: true);
    final result = McpReadResourceResult.fromJson(o.result);
    if (!o.viaInput && era == McpEra.modern) {
      _core.cache.put(key, result,
          ttl: _ttlOf(o.result, listChanged: false), isPrivate: o.result['cacheScope'] != 'public');
    }
    return result;
  }

  /// Subscribes to `notifications/resources/updated` for [uri] (M: added to
  /// the `subscriptions/listen` filter, which starts the feed; L:
  /// `resources/subscribe`, plus the GET stream on Streamable HTTP).
  Future<McpResourceSubscription> subscribeResource(String uri) async {
    _checkOpen();
    _subscriptions.add(uri);
    try {
      await _session.subscribeResource(uri, allUris: Set.of(_subscriptions));
    } on Object {
      _subscriptions.remove(uri);
      rethrow;
    }
    return McpResourceSubscription._(uri, () async {
      _subscriptions.remove(uri);
      if (!_closing) await _session.unsubscribeResource(uri, remainingUris: Set.of(_subscriptions));
    });
  }

  // ---------------------------------------------------------------- prompts

  Future<McpGetPromptResult> getPrompt(
    String name, {
    Map<String, String> arguments = const {},
    CancellationToken? cancel,
    Duration? timeout,
  }) async {
    final o = await _call('prompts/get', {'name': name, if (arguments.isNotEmpty) 'arguments': arguments},
        CallSpec(name: name, cancel: cancel, timeout: timeout), safe: true);
    return McpGetPromptResult.fromJson(o.result);
  }

  /// `completion/complete`. Returns no values without a round trip when
  /// the server does not offer `completions` (callers should debounce).
  Future<McpCompletion> complete(
    McpCompletionRef ref, {
    required String argument,
    required String value,
    Map<String, String>? context,
    CancellationToken? cancel,
  }) async {
    if (!capabilities.completions) return const McpCompletion(values: []);
    final o = await _call(
      'completion/complete',
      {
        'ref': ref.toJson(),
        'argument': {'name': argument, 'value': value},
        if (context != null && context.isNotEmpty) 'context': {'arguments': context},
      },
      CallSpec(cancel: cancel),
      safe: true,
    );
    return McpCompletion.fromJson(o.result);
  }

  // ---------------------------------------------------------------- logging & changes

  /// Server log verbosity: per request in M (null = no log messages), via
  /// `logging/setLevel` in L (null = `emergency`; L has no "off").
  Future<void> setLogLevel(McpLogLevel? level) {
    _checkOpen();
    return _session.setLogLevel(level);
  }

  /// Starts the change feed: `subscriptions/listen` (M, with reconnect and
  /// resync) or the GET stream (L Streamable HTTP; HTTP+SSE and in-process
  /// always deliver). Returns what the server agreed to send. Open it while
  /// the app is in the foreground; [stopListening] when backgrounded.
  Future<McpListenAck> listen() {
    _checkOpen();
    return _session.listen(resourceUris: Set.of(_subscriptions));
  }

  Future<void> stopListening() => _session.stopListening();

  // ---------------------------------------------------------------- tasks

  /// `tasks/get` (Tasks extension, M only).
  Future<McpTask> getTask(String taskId) {
    _checkOpen();
    return _session.getTask(taskId);
  }

  /// `tasks/cancel` (cooperative, eventually consistent).
  Future<void> cancelTask(String taskId) {
    _checkOpen();
    return _session.cancelTask(taskId);
  }

  /// Resumes waiting for a `tools/call` task created before (e.g. before
  /// the process died), polling until it completes.
  Future<McpCallToolResult> resumeToolTask(McpTaskHandle handle, {CancellationToken? cancel}) async {
    _checkOpen();
    if (handle.serverId != config.id) throw ArgumentError.value(handle.serverId, 'handle', 'task of another server');
    final r = await _session.pollTask(handle, CallSpec(name: handle.name, cancel: cancel));
    return McpCallToolResult.fromJson(r, taskId: handle.taskId);
  }

  // ---------------------------------------------------------------- lifecycle

  /// Closes the connection: stops listening, cancels in-flight requests,
  /// and on legacy Streamable HTTP ends the session with `DELETE`.
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    try {
      await _session.close();
    } on Object {
      // Closing must not throw.
    }
    await _core.close();
    await _core.transport.close();
    await _inboundSub.cancel();
  }
}
