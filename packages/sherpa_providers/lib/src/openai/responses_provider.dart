import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sherpa_core/sherpa_core.dart';

import '../common/endpoint_policy.dart';
import '../common/error_mapping.dart';
import '../common/stream_guard.dart';
import '../common/tool_names.dart';
import '../config.dart';
import 'chat_request.dart';
import 'discovery.dart';
import 'endpoint.dart';
import 'quirks.dart';
import 'responses_request.dart';
import 'responses_stream.dart';

/// OpenAI Responses API, used statelessly (`store: false`), for
/// api.openai.com models that only call tools over Responses (R10 §3.6).
///
/// Reasoning continuity across tool calls comes from replaying this
/// provider's encrypted reasoning items; see [ResponsesInputMapper] for how
/// they are stored on [ReasoningPart]. Optional fields a model rejects
/// (`reasoning.summary` for unverified organisations, sampling params on
/// reasoning models, ...) are stripped once, announced, and remembered per
/// model.
final class OpenAiResponsesProvider implements ModelProvider {
  OpenAiResponsesProvider({
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
      forChat: false,
    );
  }

  /// At most this many optional fields are stripped for one request.
  static const int maxParamFallbacks = 2;

  final OpenAiEndpoint _endpoint;
  late final ModelDiscovery _discovery;
  final Map<String, Set<String>> _rejected = {};

  ProviderConfig get config => _endpoint.config;

  ServerQuirks get _quirks => ServerQuirks.of(ServerProfile.openAi);

  @override
  ProviderInfo get info => _endpoint.info;

  @override
  Future<List<ModelDescriptor>> listModels() => _discovery.listModels(_quirks);

  @override
  Future<ModelCapabilities> capabilities(String modelId) async =>
      config.modelOverrides[modelId] ?? _discovery.capabilities(modelId, _quirks);

  @override
  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel}) =>
      guardModelStream((abort) => _run(request, abort), cancel: cancel);

  Stream<ModelEvent> _run(ModelRequest request, AbortSignal abort) async* {
    final base = await _endpoint.checkedBase();
    final names = ToolNameMapper(visibleTools(request).map((t) => t.name));
    final rejected = _rejected.putIfAbsent(request.modelId, () => <String>{});
    var built = buildResponsesRequest(request: request, names: names, providerId: config.id, rejected: rejected);
    for (final n in built.notices) {
      yield n;
    }
    final url = joinPath(base, '/responses');

    var response = await _endpoint.http.send(
      method: 'POST',
      url: url,
      headers: _endpoint.headers(stream: true),
      body: jsonEncode(built.body),
      abort: abort,
      headersTimeout: config.streamStartTimeout,
      idleTimeout: config.streamIdleTimeout,
    );
    for (var attempt = 0; !response.ok; attempt++) {
      final text = await response.readText(maxBytes: 64 * 1024);
      final param = attempt < maxParamFallbacks
          ? responsesOptionalParams
              .where((p) => hasParam(built.body, p) && rejectsParameter(response.statusCode, text, p))
              .firstOrNull
          : null;
      if (param == null) {
        throw mapHttpError(
            statusCode: response.statusCode,
            headers: response.headers,
            body: text,
            providerId: config.id,
            now: _endpoint.clock.now());
      }
      rejected.add(param);
      yield ProviderNotice('param_dropped', 'The model rejected "$param"; retrying without it.', data: {'param': param});
      built = buildResponsesRequest(request: request, names: names, providerId: config.id, rejected: rejected);
      response = await _endpoint.http.send(
        method: 'POST',
        url: url,
        headers: _endpoint.headers(stream: true),
        body: jsonEncode(built.body),
        abort: abort,
        headersTimeout: config.streamStartTimeout,
        idleTimeout: config.streamIdleTimeout,
      );
    }

    final parser = ResponsesStreamParser(names: names, newCallId: _endpoint.newCallIds(), providerId: config.id);
    await for (final event in response.events()) {
      for (final e in parser.addEvent(event)) {
        yield e;
      }
      if (parser.isDone) break;
    }
    for (final e in parser.finish()) {
      yield e;
    }
  }
}
