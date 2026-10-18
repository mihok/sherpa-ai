import 'dart:async';

import 'package:http/http.dart' as http_pkg;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';

import '../common/endpoint_policy.dart';
import '../common/error_mapping.dart';
import '../common/http_runner.dart';
import '../config.dart';

/// What both OpenAI adapters share: the URL policy check, auth headers,
/// the HTTP runner and tool-call id synthesis.
final class OpenAiEndpoint {
  OpenAiEndpoint({required this.config, String? apiKey, required this.client, required this.clock})
      : apiKey = (apiKey == null || apiKey.isEmpty) ? null : apiKey,
        http = ProviderHttp(client: client, providerId: config.id);

  /// How long a passed URL check is trusted before DNS is consulted again.
  static const Duration recheckAfter = Duration(minutes: 10);

  final ProviderConfig config;
  final String? apiKey;
  final http_pkg.Client client;
  final Clock clock;
  final ProviderHttp http;

  late final UrlPolicy _policy = endpointUrlPolicy(allowLocalNetwork: config.allowLocalNetwork);
  Future<Uri>? _checked;
  DateTime? _checkedAt;
  int _streamSeq = 0;

  String get providerId => config.id;

  ProviderInfo get info => ProviderInfo(
        id: config.id,
        kind: ProviderKind.openAiCompatible,
        displayName: config.displayName,
        location: endpointLocation(config.baseUrl),
        baseUrl: config.baseUrl,
      );

  /// The base URL after the SSRF policy check (DNS included), memoized.
  /// A violation is a configuration error, so it maps to
  /// [ProviderErrorKind.invalidRequest] (not retryable); a name that does
  /// not resolve maps to [ProviderErrorKind.network].
  Future<Uri> checkedBase() {
    final at = _checkedAt;
    final cached = _checked;
    if (cached != null && at != null && clock.now().difference(at) < recheckAfter) return cached;
    _checkedAt = clock.now();
    final pending = () async {
      try {
        return await _policy.check(config.baseUrl.toString());
      } on UrlPolicyViolation catch (e) {
        // An unresolvable host is usually "offline", not a bad URL: keep it
        // retryable. Everything else is a configuration error.
        final offline = e.reason.startsWith('host does not resolve');
        throw ProviderException(
          offline ? ProviderErrorKind.network : ProviderErrorKind.invalidRequest,
          Redactor.text(e.toString()),
          providerId: config.id,
          cause: e,
        );
      }
    }();
    _checked = pending;
    pending.catchError((Object _) {
      if (identical(_checked, pending)) _checked = null;
      return config.baseUrl;
    }).ignore();
    return pending;
  }

  /// Request headers. User headers go first so they cannot replace the
  /// credential or the content negotiation, and keys are lower-cased so a
  /// user-supplied `Authorization` cannot produce a duplicate header.
  Map<String, String> headers({bool stream = false, bool json = true}) => {
        for (final e in config.headers.entries) e.key.toLowerCase(): e.value,
        if (json) 'content-type': 'application/json',
        'accept': stream ? 'text/event-stream' : 'application/json',
        if (apiKey != null) 'authorization': 'Bearer $apiKey',
      };

  /// Headers for discovery GETs (no body).
  Map<String, String> probeHeaders() => {
        for (final e in config.headers.entries) e.key.toLowerCase(): e.value,
        if (apiKey != null) 'authorization': 'Bearer $apiKey',
      };

  /// A synthesizer of tool-call ids for one stream. Ids must be unique
  /// across a conversation and use Anthropic's `^[a-zA-Z0-9_-]+$` charset,
  /// because a transcript can be continued on another provider.
  String Function(int ordinal) newCallIds() {
    final tag = '${clock.now().microsecondsSinceEpoch.toRadixString(36)}${(_streamSeq++).toRadixString(36)}';
    return (ordinal) => 'call_${tag}_$ordinal';
  }
}

/// True when a 400/422 [body] names [param] as the problem: the server
/// does not understand an optional field Sherpa added, and the request can
/// be retried once without it (R10 §5 "conservative" servers).
bool rejectsParameter(int status, String body, String param) {
  if (status != 400 && status != 422) return false;
  final details = ErrorDetails.fromBody(body);
  final p = details.param;
  if (p != null && (p == param || p.startsWith('$param.') || p.startsWith('$param['))) return true;
  final leaf = param.contains('.') ? param.substring(param.lastIndexOf('.') + 1) : param;
  final text = '${details.message ?? ''} ${details.code ?? ''}'.toLowerCase();
  return text.contains(param.toLowerCase()) || (leaf.length > 6 && text.contains(leaf.toLowerCase()));
}
