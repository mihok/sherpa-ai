import 'dart:async';
import 'dart:convert';
import 'dart:io' show IOException;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';

import '../common/endpoint_policy.dart' show endpointUrlPolicy;
import '../common/http_runner.dart' show withIdleTimeout;
import '../config.dart';
import 'errors.dart';
import 'model_traits.dart';
import 'prefix_guard.dart';
import 'request_builder.dart';
import 'stream_decoder.dart';

/// [ModelProvider] for the Anthropic Messages API (native wire format; R10
/// §7). Works against `api.anthropic.com` or any compatible base URL.
///
/// Every Anthropic model is reported as [HistoryPolicy.appendOnly]:
/// current models bind replayed thinking to the exact request prefix, so
/// the context manager must only append (PLAN finding 4). The provider's
/// half of that contract is that rendering is deterministic and replays
/// stored blocks verbatim (see [AnthropicRequestBuilder]).
final class AnthropicProvider implements ModelProvider {
  AnthropicProvider({
    required ProviderConfig config,
    String? apiKey,
    required http.Client client,
    Clock clock = const SystemClock(),
  })  : _config = config,
        _apiKey = apiKey,
        _client = client,
        _clock = clock,
        // allowLocalNetwork is for the user's own proxy/gateway, which may
        // also run on this device; plain http only to a local address.
        _policy = endpointUrlPolicy(allowLocalNetwork: config.allowLocalNetwork),
        _builder = AnthropicRequestBuilder(
          providerId: config.id,
          // Proxies and older gateways may reject the field (claude-api
          // skill), so it is only sent to the first-party API.
          eagerInputStreaming: config.baseUrl.host == firstPartyHost,
        ),
        info = ProviderInfo(
          id: config.id,
          kind: ProviderKind.anthropic,
          displayName: config.displayName,
          location: ExecutionLocation.remote,
          baseUrl: config.baseUrl,
        );

  /// The only current `anthropic-version` (R10 §7.1).
  static const String apiVersion = '2023-06-01';
  static const String firstPartyHost = 'api.anthropic.com';
  static final Uri defaultBaseUrl = Uri.parse('https://$firstPartyHost');

  /// A stream that delivers no bytes for this long is treated as dead
  /// ([ProviderConfig.streamIdleTimeout], 90 s unless configured). Anthropic
  /// sends `ping` events during long thinking, so this only fires on
  /// half-open connections (e.g. a cellular handoff).
  Duration get idleTimeout => _config.streamIdleTimeout;

  /// Deadline for the small JSON endpoints (models, count_tokens).
  static const Duration requestTimeout = Duration(seconds: 30);

  static const int _maxErrorBodyBytes = 64 * 1024;
  static const Duration _urlCheckTtl = Duration(minutes: 5);
  static const Duration _fallbackCapsTtl = Duration(minutes: 10);

  final ProviderConfig _config;
  final String? _apiKey;
  final http.Client _client;
  final Clock _clock;
  final UrlPolicy _policy;
  final AnthropicRequestBuilder _builder;
  final AnthropicPrefixGuard _guard = AnthropicPrefixGuard();

  final Map<String, _CachedCaps> _caps = {};
  final Map<String, Future<ModelCapabilities>> _capsInFlight = {};
  final Map<String, DateTime> _checkedOrigins = {};

  @override
  final ProviderInfo info;

  ProviderConfig get config => _config;

  // ---------------------------------------------------------------------------
  // Discovery

  /// All models visible to the key (`GET /v1/models`, every page). When the
  /// endpoint is unreachable (network/server trouble) the bundled list of
  /// current ids is returned so the picker still works offline; auth and
  /// quota errors are rethrown so the user sees them.
  @override
  Future<List<ModelDescriptor>> listModels() async {
    final out = <ModelDescriptor>[];
    try {
      String? after;
      for (var page = 0; page < 50; page++) {
        final j = await _getJson(_endpoint('models', {'limit': '100', 'after_id': ?after}));
        for (final m in j.mapList('data')) {
          final id = m.opt<String>('id');
          if (id == null) continue;
          final (caps, traits) = _capabilitiesFromApi(m);
          _caps[id] = _CachedCaps(caps, traits, _clock.now(), fromApi: true);
          out.add(ModelDescriptor(
            id: id,
            providerId: info.id,
            displayName: m.opt<String>('display_name') ?? id,
            capabilities: _withOverride(id, caps),
            description: _lifecycleNote(m),
          ));
        }
        if (j.opt<bool>('has_more') != true) break;
        after = j.opt<String>('last_id');
        if (after == null) break;
      }
      return out;
    } on ProviderException catch (e) {
      if (!_isTransient(e)) rethrow;
      return [
        for (final (id, name) in AnthropicModelTraits.currentModels)
          ModelDescriptor(
            id: id,
            providerId: info.id,
            displayName: name,
            capabilities: _withOverride(id, AnthropicModelTraits.forModel(id).toCapabilities()),
            description: 'Offline list: ${e.kind.name}',
          ),
      ];
    }
  }

  /// User overrides win, then a cached `/v1/models/{id}` answer, then a
  /// fresh lookup; if the lookup fails the family table answers (and is
  /// retried after a while).
  @override
  Future<ModelCapabilities> capabilities(String modelId) async {
    final override = _config.modelOverrides[modelId];
    if (override != null) return _appendOnly(override);
    final cached = _caps[modelId];
    if (cached != null && (cached.fromApi || _clock.now().difference(cached.at) < _fallbackCapsTtl)) {
      return cached.caps;
    }
    // Block body on purpose: `remove` returns this very future, and a
    // whenComplete callback that returns a future is awaited (deadlock).
    return _capsInFlight[modelId] ??= _fetchCapabilities(modelId).whenComplete(() {
      _capsInFlight.remove(modelId);
    });
  }

  Future<ModelCapabilities> _fetchCapabilities(String modelId) async {
    try {
      final m = await _getJson(_endpoint('models/${Uri.encodeComponent(modelId)}'));
      final (caps, traits) = _capabilitiesFromApi({'id': modelId, ...m});
      _caps[modelId] = _CachedCaps(caps, traits, _clock.now(), fromApi: true);
      return caps;
    } on Object {
      final traits = AnthropicModelTraits.forModel(modelId);
      final caps = traits.toCapabilities();
      _caps[modelId] = _CachedCaps(caps, traits, _clock.now(), fromApi: false);
      return caps;
    }
  }

  (ModelCapabilities, AnthropicModelTraits) _capabilitiesFromApi(JsonMap m) {
    final id = m.req<String>('id');
    final tree = m.optObj('capabilities');
    final traits = AnthropicModelTraits.forModel(id).refine(tree);
    bool? supported(JsonMap? node) => node?.opt<bool>('supported');
    ReasoningSupport? reasoning;
    final thinking = tree?.optObj('thinking');
    if (thinking != null) {
      final types = thinking.optObj('types');
      final any = supported(types?.optObj('adaptive')) == true || supported(types?.optObj('enabled')) == true;
      if (supported(thinking) == false || (types != null && !any)) {
        reasoning = ReasoningSupport.none;
      } else if (types != null) {
        reasoning = supported(types.optObj('disabled')) == false ? ReasoningSupport.always : ReasoningSupport.optional;
      }
    }
    final caps = traits.toCapabilities(
      contextLength: m.optInt('max_input_tokens'),
      maxOutputTokens: m.optInt('max_tokens'),
      vision: supported(tree?.optObj('image_input')),
      reasoning: reasoning,
    );
    return (caps, traits);
  }

  static String? _lifecycleNote(JsonMap m) {
    final lifecycle = m.opt<String>('lifecycle');
    if (lifecycle == null || lifecycle == 'active') return null;
    final retires = m.opt<String>('retires_at');
    return retires == null ? 'Lifecycle: $lifecycle' : 'Lifecycle: $lifecycle (retires $retires)';
  }

  ModelCapabilities _withOverride(String id, ModelCapabilities discovered) {
    final o = _config.modelOverrides[id];
    return o == null ? discovered : _appendOnly(o);
  }

  /// Overrides are user data and `ModelCapabilities.fromJson` defaults to
  /// [HistoryPolicy.mutable]; for Anthropic that would let the context
  /// manager rewrite history and earn 400s, so append-only is enforced.
  static ModelCapabilities _appendOnly(ModelCapabilities c) => c.historyPolicy == HistoryPolicy.appendOnly
      ? c
      : ModelCapabilities(
          contextLength: c.contextLength,
          maxOutputTokens: c.maxOutputTokens,
          toolCallFormat: c.toolCallFormat,
          parallelToolCalls: c.parallelToolCalls,
          vision: c.vision,
          audioInput: c.audioInput,
          reasoning: c.reasoning,
          quantization: c.quantization,
          parameterCount: c.parameterCount,
          ramEstimateBytes: c.ramEstimateBytes,
          tokenizerFamily: c.tokenizerFamily ?? 'claude',
          supportsSystemRole: c.supportsSystemRole,
          supportsPromptCache: c.supportsPromptCache,
          historyPolicy: HistoryPolicy.appendOnly,
        );

  // ---------------------------------------------------------------------------
  // Requests

  /// Renders [request] exactly as [stream] would send it. Useful for
  /// diagnostics ("show request") and for prefix-diff tooling.
  AnthropicWireRequest buildRequest(ModelRequest request, {bool stream = true}) {
    final cached = _caps[request.modelId];
    final override = _config.modelOverrides[request.modelId];
    return _builder.build(
      request,
      traits: cached?.traits ?? AnthropicModelTraits.forModel(request.modelId),
      modelMaxOutputTokens: override?.maxOutputTokens ?? cached?.caps.maxOutputTokens,
      stream: stream,
    );
  }

  @override
  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel}) =>
      _StreamCall(this, request, cancel).events;

  /// Exact prompt size from `POST /v1/messages/count_tokens` (free, own rate
  /// limit). Best-effort: returns null on any failure so callers fall back
  /// to their estimator.
  Future<int?> countTokens(ModelRequest request) async {
    try {
      final wire = buildRequest(request, stream: false);
      final uri = _endpoint('messages/count_tokens');
      await _checkUrl(uri);
      final req = http.Request('POST', uri)
        ..followRedirects = false
        ..headers.addAll(_headers())
        ..bodyBytes = utf8.encode(jsonEncode(wire.countTokensBody));
      final resp = await _send(req).timeout(requestTimeout);
      final body = await _readBody(resp.stream).timeout(requestTimeout);
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(body);
      return j is Map ? (j['input_tokens'] as num?)?.toInt() : null;
    } on Object {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // HTTP plumbing

  Uri _endpoint(String path, [Map<String, String>? query]) {
    final base = _config.baseUrl;
    var p = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
    if (!p.endsWith('/v1')) p = '$p/v1';
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '$p/$path',
      queryParameters: query == null || query.isEmpty ? null : query,
    );
  }

  Map<String, String> _headers({bool stream = false}) => {
        'accept': stream ? 'text/event-stream' : 'application/json',
        'anthropic-version': apiVersion,
        for (final e in _config.headers.entries)
          if (!_protectedHeaders.contains(e.key.toLowerCase())) e.key.toLowerCase(): e.value,
        'content-type': 'application/json',
        if (_apiKey case final key? when key.isNotEmpty) 'x-api-key': key,
      };

  /// Config headers are user-editable and must not replace the credential
  /// or the body type.
  static const Set<String> _protectedHeaders = {'x-api-key', 'content-type'};

  /// SSRF policy (sherpa_net): base URLs are user input. Checked results
  /// are cached briefly so DNS is not resolved for every agent step.
  Future<void> _checkUrl(Uri uri) async {
    final origin = '${uri.scheme}://${uri.host}:${uri.port}';
    final now = _clock.now();
    final at = _checkedOrigins[origin];
    if (at != null && now.difference(at) < _urlCheckTtl && !now.isBefore(at)) return;
    try {
      await _policy.check(uri.toString());
    } on UrlPolicyViolation catch (e) {
      throw ProviderException(
        e.reason.contains('resolve') ? ProviderErrorKind.network : ProviderErrorKind.invalidRequest,
        e.toString(),
        providerId: info.id,
        cause: e,
      );
    }
    _checkedOrigins[origin] = now;
  }

  Future<http.StreamedResponse> _send(http.BaseRequest request) async {
    try {
      return await _client.send(request);
    } on http.RequestAbortedException {
      rethrow;
    } on http.ClientException catch (e) {
      throw ProviderException(ProviderErrorKind.network, Redactor.text(e.message), providerId: info.id, cause: e);
    } on IOException catch (e) {
      throw ProviderException(ProviderErrorKind.network, Redactor.text('$e'), providerId: info.id, cause: e);
    } on TimeoutException catch (e) {
      throw ProviderException(ProviderErrorKind.timeout, 'Anthropic did not respond in time', providerId: info.id, cause: e);
    }
  }

  Future<JsonMap> _getJson(Uri uri) async {
    await _checkUrl(uri);
    final req = http.Request('GET', uri)
      ..followRedirects = false
      ..headers.addAll(_headers());
    try {
      final resp = await _send(req).timeout(requestTimeout);
      final body = await _readBody(resp.stream).timeout(requestTimeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw AnthropicErrors.fromHttp(resp.statusCode, resp.headers, body, providerId: info.id, now: _clock.now());
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map) throw const FormatException('expected a JSON object');
      return (normalizeJson(decoded)! as Map).cast<String, Object?>();
    } on TimeoutException catch (e) {
      throw ProviderException(ProviderErrorKind.timeout, 'Anthropic did not respond in time', providerId: info.id, cause: e);
    } on FormatException catch (e) {
      throw ProviderException(ProviderErrorKind.server, 'Anthropic sent invalid JSON (${e.message})', providerId: info.id, cause: e);
    } on http.ClientException catch (e) {
      throw ProviderException(ProviderErrorKind.network, Redactor.text(e.message), providerId: info.id, cause: e);
    }
  }

  /// Reads at most [limit] bytes: error bodies are small, and a misbehaving
  /// proxy must not make us buffer an unbounded stream.
  static Future<String> _readBody(Stream<List<int>> stream, {int limit = 4 * 1024 * 1024}) async {
    final b = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      b.add(chunk);
      if (b.length >= limit) break;
    }
    return utf8.decode(b.takeBytes(), allowMalformed: true);
  }

  static bool _isTransient(ProviderException e) => switch (e.kind) {
        ProviderErrorKind.network ||
        ProviderErrorKind.timeout ||
        ProviderErrorKind.server ||
        ProviderErrorKind.overloaded =>
          true,
        _ => false,
      };
}

final class _CachedCaps {
  const _CachedCaps(this.caps, this.traits, this.at, {required this.fromApi});
  final ModelCapabilities caps;
  final AnthropicModelTraits traits;
  final DateTime at;
  final bool fromApi;
}

/// One streaming request: owns the HTTP exchange and the output stream.
///
/// The output is a plain [StreamController] rather than an `async*`
/// generator so that cancellation reaches the request at every stage: the
/// abort trigger fires while connecting, while waiting for headers and
/// while streaming, and pause/resume reach the socket subscription
/// (backpressure, per the [ModelProvider] contract).
final class _StreamCall {
  _StreamCall(this._p, this._request, this._cancel) {
    _out = StreamController<ModelEvent>(
      onListen: _start,
      onPause: () => _sub?.pause(),
      onResume: () => _sub?.resume(),
      onCancel: _onCancel,
    );
  }

  final AnthropicProvider _p;
  final ModelRequest _request;
  final CancellationToken? _cancel;
  late final StreamController<ModelEvent> _out;
  final Completer<void> _abort = Completer<void>();
  StreamSubscription<SseEvent>? _sub;
  Timer? _drain;
  bool _closed = false;

  Stream<ModelEvent> get events => _out.stream;

  void _start() {
    final token = _cancel;
    if (token != null) {
      if (token.isCancelled) return _finishCancelled();
      unawaited(token.whenCancelled.then((_) => _finishCancelled()));
    }
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      final wire = _p.buildRequest(_request);
      for (final n in wire.notices) {
        _emit(n);
      }
      final session = _request.cache.sessionId;
      assert(() {
        final n = session == null ? null : _p._guard.check(session, wire.body);
        if (n != null) _emit(n);
        return true;
      }());
      final uri = _p._endpoint('messages');
      await _p._checkUrl(uri);
      if (_closed) return;
      final req = http.AbortableRequest('POST', uri, abortTrigger: _abort.future)
        ..followRedirects = false
        ..headers.addAll(_p._headers(stream: true))
        ..bodyBytes = utf8.encode(wire.encode());
      final resp = await _p._send(req).timeout(_p._config.streamStartTimeout, onTimeout: () {
        _abortHttp();
        throw ProviderException(
          ProviderErrorKind.timeout,
          'Anthropic did not start its response within ${_p._config.streamStartTimeout.inSeconds} s; '
          'the connection was closed.',
          providerId: _p.info.id,
        );
      });
      if (_closed) {
        // Cancelled while waiting for headers: release the response.
        unawaited(resp.stream.listen(null, onError: (Object _) {}).cancel());
        return;
      }
      final status = resp.statusCode;
      final contentType = resp.headers['content-type'] ?? '';
      if (status < 200 || status >= 300 || contentType.contains('json')) {
        final body = await AnthropicProvider._readBody(resp.stream, limit: AnthropicProvider._maxErrorBodyBytes);
        if (_closed) return;
        final ok = status >= 200 && status < 300;
        _fail(ok
            ? ProviderException(
                ProviderErrorKind.server,
                'Anthropic answered with JSON instead of an event stream: '
                '${AnthropicErrors.fromHttp(status, resp.headers, body, providerId: _p.info.id, now: _p._clock.now()).message}',
                statusCode: status,
                providerId: _p.info.id,
              )
            : AnthropicErrors.fromHttp(status, resp.headers, body, providerId: _p.info.id, now: _p._clock.now()));
        return;
      }
      final low = [for (final l in parseAnthropicRateLimits(resp.headers)) if (l.low) l];
      if (low.isNotEmpty) {
        _emit(ProviderNotice(
          'anthropic.rate_limit_low',
          'Approaching the Anthropic rate limit (${low.map((l) => '${l.remaining}/${l.limit} ${l.kind}').join(', ')}).',
          data: {'limits': [for (final l in low) l.toJson()]},
        ));
      }
      final decoder = AnthropicStreamDecoder(
        providerId: _p.info.id,
        toolNames: wire.toolNames,
        requestedModel: _request.modelId,
      );
      // Silence fails the stream with a retryable timeout and closes the
      // request; the error then flows through onError to _fail.
      _sub = withIdleTimeout(
        resp.stream,
        idle: _p.idleTimeout,
        start: _p._config.streamStartTimeout,
        onTimeout: _abortHttp,
        providerId: _p.info.id,
      )
          .transform(const SseDecoder())
          .listen(
            (sse) => _guarded(() {
              for (final e in decoder.add(sse)) {
                _emit(e);
              }
              if (decoder.isDone) _complete();
            }),
            onError: (Object e, StackTrace st) => _fail(_streamError(e), st),
            onDone: () {
              _drain?.cancel();
              _guarded(() {
                for (final e in decoder.close()) {
                  _emit(e);
                }
                _complete();
              });
            },
            cancelOnError: true,
          );
      if (_out.isPaused) _sub!.pause();
    } on http.RequestAbortedException {
      // Only reachable through cancellation, which already finished us.
    } on ProviderException catch (e, st) {
      _fail(e, st);
    } on Object catch (e, st) {
      _fail(ProviderException(ProviderErrorKind.unknown, Redactor.text('$e'), providerId: _p.info.id, cause: e), st);
    }
  }

  void _guarded(void Function() body) {
    if (_closed) return;
    try {
      body();
    } on AnthropicStreamFailure catch (f) {
      for (final e in f.before) {
        _emit(e);
      }
      _fail(f.error);
    } on Object catch (e, st) {
      // Never let a decoding bug escape into the zone as an uncaught error.
      _fail(ProviderException(ProviderErrorKind.unknown, Redactor.text('$e'), providerId: _p.info.id, cause: e), st);
    }
  }

  ProviderException _streamError(Object e) => switch (e) {
        ProviderException() => e,
        TimeoutException() => ProviderException(ProviderErrorKind.timeout, e.message ?? 'stream timed out',
            providerId: _p.info.id, cause: e),
        http.ClientException(:final message) =>
          ProviderException(ProviderErrorKind.network, Redactor.text(message), providerId: _p.info.id, cause: e),
        _ => ProviderException(ProviderErrorKind.network, Redactor.text('$e'), providerId: _p.info.id, cause: e),
      };

  void _emit(ModelEvent e) {
    if (!_closed) _out.add(e);
  }

  /// The message ended. The socket is left to drain so the connection can
  /// be reused for the next agent step (cancelling a dart:io response
  /// before it is done destroys the connection); a server that keeps it
  /// open after `message_stop` is cut off shortly.
  void _complete() {
    if (_closed) return;
    _closed = true;
    unawaited(_out.close());
    // Events are already buffered in _out; the socket no longer needs to
    // follow the consumer's pause.
    final sub = _sub;
    if (sub != null && sub.isPaused) sub.resume();
    _drain = Timer(const Duration(seconds: 10), _abortRequest);
  }

  void _fail(ProviderException e, [StackTrace? st]) {
    if (_closed) return;
    _closed = true;
    _abortRequest();
    _out
      ..addError(e, st)
      ..close();
  }

  /// Cancellation through the token ends the stream normally with
  /// `Finish(cancelled)` (contract), after aborting the HTTP request.
  void _finishCancelled() {
    if (_closed) return;
    _closed = true;
    _abortRequest();
    _out
      ..add(Finish(FinishReason.cancelled, rawReason: _cancel?.reason))
      ..close();
  }

  Future<void> _onCancel() async {
    _closed = true;
    _abortRequest();
  }

  /// Closes the HTTP request (`AbortableRequest`) without detaching the
  /// listener, so an error already on its way is still delivered.
  void _abortHttp() {
    if (!_abort.isCompleted) _abort.complete();
  }

  void _abortRequest() {
    _drain?.cancel();
    _abortHttp();
    final sub = _sub;
    _sub = null;
    if (sub != null) unawaited(sub.cancel());
  }
}
