import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sherpa_core/sherpa_core.dart';

import '../common/endpoint_policy.dart';
import '../common/error_mapping.dart';
import '../common/http_runner.dart';
import '../common/json_read.dart';
import '../common/stream_guard.dart';
import '../common/tool_names.dart';
import '../config.dart';
import 'chat_request.dart';
import 'chat_stream.dart';
import 'detect.dart';
import 'discovery.dart';
import 'endpoint.dart';
import 'quirks.dart';

/// OpenAI Chat Completions over any compatible server (OpenAI, llama.cpp,
/// Ollama, LM Studio, vLLM, OpenRouter, DeepSeek, the HF router, others).
///
/// Server differences are table-driven ([ServerQuirks]); with
/// [ServerProfile.auto] the server type is detected once, lazily, with
/// [detectServerProfile]. Streams follow the [ModelProvider] contract:
/// cold, cancellable (the socket is aborted), backpressured, and ending in
/// exactly one [Finish] or a [ProviderException].
final class OpenAiChatProvider implements ModelProvider {
  OpenAiChatProvider({
    required ProviderConfig config,
    String? apiKey,
    required http.Client client,
    Clock clock = const SystemClock(),
  }) : _endpoint = OpenAiEndpoint(config: config, apiKey: apiKey, client: client, clock: clock) {
    _discovery = ModelDiscovery(
      http: _endpoint.http,
      baseUrl: _endpoint.checkedBase,
      headers: _endpoint.probeHeaders,
      clock: clock,
      providerId: config.id,
      overrides: config.modelOverrides,
    );
  }

  final OpenAiEndpoint _endpoint;
  late final ModelDiscovery _discovery;
  Future<ServerProfile>? _detected;

  /// Set once a server rejected `stream_options`; later requests skip it.
  bool _usageOptionRejected = false;

  ProviderConfig get config => _endpoint.config;

  @override
  ProviderInfo get info => _endpoint.info;

  /// The configured profile, or the detected one for [ServerProfile.auto]
  /// (probed once per provider instance; a failed probe is retried later).
  Future<ServerProfile> resolveProfile() {
    if (config.profile != ServerProfile.auto) return Future.value(config.profile);
    final existing = _detected;
    if (existing != null) return existing;
    final pending = () async {
      final base = await _endpoint.checkedBase();
      return detectServerProfile(base, _endpoint.client, headers: _endpoint.probeHeaders());
    }();
    _detected = pending;
    pending.catchError((Object _) {
      if (identical(_detected, pending)) _detected = null;
      return ServerProfile.generic;
    }).ignore();
    return pending;
  }

  Future<ServerQuirks> _quirks() async => ServerQuirks.of(await resolveProfile());

  @override
  Future<List<ModelDescriptor>> listModels() async => _discovery.listModels(await _quirks());

  @override
  Future<ModelCapabilities> capabilities(String modelId) async {
    final override = config.modelOverrides[modelId];
    if (override != null) return override;
    return _discovery.capabilities(modelId, await _quirks());
  }

  /// Drops cached capabilities, e.g. after the user reloaded a model with a
  /// different context size.
  void invalidateCapabilities() => _discovery.invalidate();

  @override
  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel}) =>
      guardModelStream((abort) => _run(request, abort), cancel: cancel);

  Stream<ModelEvent> _run(ModelRequest request, AbortSignal abort) async* {
    final base = await _endpoint.checkedBase();
    final quirks = await _quirks();
    final names = ToolNameMapper(visibleTools(request).map((t) => t.name));
    var built = buildChatRequest(
      request: request,
      quirks: quirks,
      names: names,
      providerId: config.id,
      includeUsage: !_usageOptionRejected,
    );
    for (final n in built.notices) {
      yield n;
    }

    final url = joinPath(base, '/chat/completions');
    Future<OpenedResponse> send(ChatRequestBody b) => _endpoint.http.send(
          method: 'POST',
          url: url,
          headers: _endpoint.headers(stream: true),
          body: jsonEncode(b.body),
          abort: abort,
          headersTimeout: config.streamStartTimeout,
          idleTimeout: config.streamIdleTimeout,
        );

    var response = await send(built);
    if (!response.ok) {
      final body = await response.readText(maxBytes: 64 * 1024);
      if (built.body.containsKey('stream_options') && rejectsParameter(response.statusCode, body, 'stream_options')) {
        // R10 §2: usage chunks exist on every server we know, but a strict
        // proxy may refuse the option. Retry once without it, remember.
        _usageOptionRejected = true;
        yield const ProviderNotice('usage_unavailable',
            'The server rejected stream_options.include_usage; token usage will not be reported.');
        built = buildChatRequest(
            request: request, quirks: quirks, names: names, providerId: config.id, includeUsage: false);
        response = await send(built);
        if (!response.ok) throw await errorFromResponse(response, providerId: config.id, now: _endpoint.clock.now());
      } else {
        throw mapHttpError(
            statusCode: response.statusCode,
            headers: response.headers,
            body: body,
            providerId: config.id,
            now: _endpoint.clock.now());
      }
    }

    final parser = ChatStreamParser(
      names: names,
      quirks: quirks,
      newCallId: _endpoint.newCallIds(),
      providerId: config.id,
    );
    if (response.contentType.contains('application/json')) {
      // `stream` ignored by the server: one JSON completion (or an error
      // object sent with 200).
      final json = tryDecodeObject(await response.readText());
      if (json == null) {
        throw ProviderException(ProviderErrorKind.unknown, 'The server returned an unreadable JSON response.',
            providerId: config.id);
      }
      for (final e in parser.addChunk(json)) {
        yield e;
      }
      parser.markDone();
    } else {
      // Any other content type is parsed as SSE: some proxies label event
      // streams text/plain or omit the header.
      await for (final event in response.events()) {
        for (final e in parser.addEvent(event)) {
          yield e;
        }
        if (parser.isDone) break;
      }
    }
    for (final e in parser.finish()) {
      yield e;
    }
  }
}
