import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';

import 'json_read.dart';

/// The fields Sherpa needs from any provider's error body.
///
/// Shapes handled (R10 §1, §3.5, §4, §7.7):
/// * OpenAI / Ollama / vLLM / llama.cpp: `{"error":{"message","type","param","code"}}`
///   where `code` is a string, null, or the HTTP status as an int;
/// * Anthropic: `{"type":"error","error":{"type","message"},"request_id"}`;
/// * OpenRouter: `{"error":{"code","message","metadata":{"error_type",...}}}`;
/// * OpenAI Responses stream: `{"type":"error","code","message","param"}`;
/// * Ollama native / misc: `{"error":"text"}`, FastAPI `{"detail": ...}`.
final class ErrorDetails {
  const ErrorDetails({this.message, this.type, this.code, this.param, this.numericCode, this.extra = const {}});

  /// Extracts details from a decoded body; [raw] is used when the body is
  /// not JSON at all (HTML error pages, plain text).
  factory ErrorDetails.fromBody(String raw) {
    final json = tryDecodeObject(raw);
    if (json == null) return ErrorDetails(message: _firstLine(raw));
    return ErrorDetails.fromJson(json);
  }

  factory ErrorDetails.fromJson(JsonMap json) {
    final errorField = json['error'];
    if (errorField is String) {
      return ErrorDetails(message: errorField, type: json.str('type') == 'error' ? null : json.str('type'));
    }
    // Responses stream errors and some proxies put the fields at top level.
    final e = asJsonMap(errorField) ?? json;
    final code = e['code'];
    final metadata = e.child('metadata');
    final detail = json['detail'];
    return ErrorDetails(
      message: e.str('message') ??
          (detail is String ? detail : (detail == null ? null : jsonEncode(detail))) ??
          json.str('message'),
      type: e.str('type') == 'error' ? null : (e.str('type') ?? metadata?.str('error_type')),
      code: code is String ? code : null,
      numericCode: code is num ? code.toInt() : null,
      param: e.str('param'),
      extra: {
        if (e['n_prompt_tokens'] != null) 'n_prompt_tokens': e['n_prompt_tokens'],
        if (e['n_ctx'] != null) 'n_ctx': e['n_ctx'],
        if (metadata?.str('error_type') case final t?) 'error_type': t,
      },
    );
  }

  final String? message;
  final String? type;

  /// String error code (OpenAI `insufficient_quota`, `context_length_exceeded`).
  final String? code;

  /// Integer code (vLLM / llama.cpp / OpenRouter send the HTTP status here).
  final int? numericCode;
  final String? param;
  final Map<String, Object?> extra;

  /// Every machine-readable label in lower case, for classification.
  Iterable<String> get labels => [
        if (type != null) type!.toLowerCase(),
        if (code != null) code!.toLowerCase(),
        if (extra['error_type'] case final String t) t.toLowerCase(),
      ];

  static String? _firstLine(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final nl = t.indexOf('\n');
    return nl < 0 ? t : t.substring(0, nl);
  }
}

const int _maxBodyInMessage = 2000;

/// Error codes/types that mean "out of money", which no amount of waiting
/// fixes. OpenAI sends some of these as 429s (R10 §3.5), so they must be
/// told apart from retryable rate limits.
const Set<String> _quotaLabels = {
  'insufficient_quota',
  'credit_balance_exhausted',
  'organization_spend_limit_exceeded',
  'project_spend_limit_exceeded',
  'organization_usage_limit_exceeded',
  'billing_hard_limit_reached',
  'billing_not_active',
  'billing_error',
  'payment_required',
  'quota_exceeded',
};

const Set<String> _contextLabels = {
  'context_length_exceeded',
  'exceed_context_size_error',
  'model_context_window_exceeded',
  'context_window_exceeded',
  'string_above_max_length',
};

/// Exact overflow messages are UNVERIFIED for OpenAI and Anthropic (R10
/// §10), so match the phrasings servers are known to use, loosely.
final RegExp _contextMessage = RegExp(
  r"context[ _-]?(length|window|size)|maximum context|prompt is too long|too many (input |prompt )?tokens"
  r"|exceeds? (the )?(available |maximum |model'?s? )?context|input (is )?too long|reduce the length of the (messages|prompt)",
  caseSensitive: false,
);

final RegExp _quotaMessage = RegExp(
  r'exceeded your (current )?quota|insufficient[ _](quota|credits|funds|balance)|(spend|spending|usage) limit|credit balance|billing',
  caseSensitive: false,
);

ProviderErrorKind? _kindFromLabels(Iterable<String> labels) {
  for (final l in labels) {
    if (_quotaLabels.contains(l)) return ProviderErrorKind.quotaExceeded;
    if (_contextLabels.contains(l)) return ProviderErrorKind.contextOverflow;
  }
  for (final l in labels) {
    final kind = switch (l) {
      'overloaded_error' || 'server_is_overloaded' || 'unavailable_error' || 'service_unavailable_error' ||
      'overloaded' || 'engine_overloaded' => ProviderErrorKind.overloaded,
      'rate_limit_error' || 'rate_limit_exceeded' || 'requests' || 'tokens' || 'slow_down' => ProviderErrorKind.rateLimited,
      'authentication_error' || 'permission_error' || 'invalid_api_key' || 'unauthorized' || 'forbidden' =>
        ProviderErrorKind.auth,
      'not_found_error' || 'model_not_found' => ProviderErrorKind.modelNotFound,
      'server_error' || 'api_error' || 'internal_error' || 'internal_server_error' => ProviderErrorKind.server,
      'timeout_error' || 'timeout' => ProviderErrorKind.timeout,
      'not_supported_error' => ProviderErrorKind.unsupported,
      'invalid_request_error' || 'invalid_request' || 'request_too_large' => ProviderErrorKind.invalidRequest,
      _ => null,
    };
    if (kind != null) return kind;
  }
  return null;
}

ProviderErrorKind _kindFromStatus(int status) => switch (status) {
      401 || 403 => ProviderErrorKind.auth,
      402 => ProviderErrorKind.quotaExceeded,
      404 => ProviderErrorKind.modelNotFound,
      408 => ProviderErrorKind.timeout,
      // Anthropic `conflict_error`; SDKs retry it, so classify as server.
      409 => ProviderErrorKind.server,
      429 => ProviderErrorKind.rateLimited,
      501 => ProviderErrorKind.unsupported,
      503 || 529 => ProviderErrorKind.overloaded,
      504 => ProviderErrorKind.timeout,
      >= 500 => ProviderErrorKind.server,
      >= 400 => ProviderErrorKind.invalidRequest,
      _ => ProviderErrorKind.unknown,
    };

/// Classifies an error from its HTTP [status] (null for mid-stream errors)
/// and body [details].
///
/// Order matters: quota and context overflow are recognised from body
/// labels/messages first because they ride on generic statuses (429, 400)
/// whose default meaning would be wrong — a spend cap is not retryable and
/// an overflow needs compaction, not a retry.
ProviderErrorKind classifyError(int? status, ErrorDetails details) {
  final labels = details.labels.toList();
  final message = details.message ?? '';
  final labelKind = _kindFromLabels(labels);
  if (labelKind == ProviderErrorKind.quotaExceeded) return labelKind!;
  if (labelKind == ProviderErrorKind.contextOverflow) return labelKind!;
  final effectiveStatus = status ?? details.numericCode;
  // Overflow arrives as 400/413/422 (or mid-stream); a TPM-limit 429 can
  // mention "tokens", so statuses with their own meaning are excluded.
  final overflowCandidate = effectiveStatus == null ||
      (effectiveStatus >= 400 && effectiveStatus < 500 && !const {401, 402, 403, 404, 429}.contains(effectiveStatus));
  if (overflowCandidate && _contextMessage.hasMatch(message)) {
    return ProviderErrorKind.contextOverflow;
  }
  if ((effectiveStatus == 429 || effectiveStatus == 402 || effectiveStatus == null) && _quotaMessage.hasMatch(message)) {
    return ProviderErrorKind.quotaExceeded;
  }
  // A status is more trustworthy than a free-form type, except that types
  // refine the generic 400/500 buckets for mid-stream errors.
  if (effectiveStatus != null && effectiveStatus >= 400) {
    final byStatus = _kindFromStatus(effectiveStatus);
    if (labelKind != null && (byStatus == ProviderErrorKind.server || byStatus == ProviderErrorKind.invalidRequest)) {
      return labelKind;
    }
    return byStatus;
  }
  return labelKind ?? ProviderErrorKind.unknown;
}

String _describe(ErrorDetails d) {
  final tags = [
    if (d.type != null) 'type=${d.type}',
    if (d.code != null) 'code=${d.code}',
    if (d.param != null) 'param=${d.param}',
    if (d.extra['n_prompt_tokens'] != null) 'prompt_tokens=${d.extra['n_prompt_tokens']}',
    if (d.extra['n_ctx'] != null) 'n_ctx=${d.extra['n_ctx']}',
  ];
  final msg = d.message?.trim() ?? '';
  return [if (msg.isNotEmpty) msg, if (tags.isNotEmpty) '(${tags.join(', ')})'].join(' ');
}

String _snippet(String body) {
  final t = body.trim();
  return t.length <= _maxBodyInMessage ? t : '${t.substring(0, _maxBodyInMessage)}…';
}

String? _requestId(Map<String, String> headers) {
  for (final k in const ['x-request-id', 'request-id', 'x-generation-id', 'cf-ray']) {
    final v = headers[k];
    if (v != null && v.isNotEmpty) return '$k=$v';
  }
  return null;
}

/// Maps a non-2xx HTTP response to a [ProviderException].
///
/// The message carries the server's own words and the (truncated) body so
/// users can diagnose misconfigured servers, but everything passes through
/// [Redactor.text] first: some servers echo the request, headers or the key
/// back in their error page.
ProviderException mapHttpError({
  required int statusCode,
  required Map<String, String> headers,
  required String body,
  String? providerId,
  DateTime? now,
}) {
  final details = ErrorDetails.fromBody(body);
  final kind = classifyError(statusCode, details);
  final retryAfter = parseRetryAfter(headers, now: now);
  final described = _describe(details);
  final requestId = _requestId(headers);
  final message = [
    'HTTP $statusCode',
    if (described.isNotEmpty) ': $described',
    if (requestId != null) ' [$requestId]',
    if (body.trim().isNotEmpty) ' — body: ${_snippet(body)}',
  ].join();
  return ProviderException(
    kind,
    Redactor.text(message),
    statusCode: statusCode,
    retryAfter: kind == ProviderErrorKind.quotaExceeded ? null : retryAfter,
    providerId: providerId,
  );
}

/// Maps an error delivered inside a 200 stream (llama.cpp
/// `data: {"error":{...}}`, OpenRouter error chunks, Responses `error` /
/// `response.failed`, Anthropic `event: error`).
ProviderException mapStreamError(JsonMap payload, {String? providerId}) {
  final details = ErrorDetails.fromJson(payload);
  final status = details.numericCode != null && details.numericCode! >= 400 ? details.numericCode : null;
  var kind = classifyError(status, details);
  if (kind == ProviderErrorKind.unknown) kind = ProviderErrorKind.server;
  final described = _describe(details);
  return ProviderException(
    kind,
    Redactor.text('Stream error${described.isEmpty ? '' : ': $described'} — payload: ${_snippet(jsonEncode(payload))}'),
    statusCode: status,
    providerId: providerId,
  );
}
