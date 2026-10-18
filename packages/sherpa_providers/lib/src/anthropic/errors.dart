import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';

/// One `anthropic-ratelimit-<kind>-{limit,remaining,reset}` triple.
@immutable
final class AnthropicRateLimit {
  const AnthropicRateLimit({required this.kind, this.limit, this.remaining, this.reset});

  /// `requests`, `tokens`, `input-tokens` or `output-tokens`.
  final String kind;
  final int? limit;
  final int? remaining;

  /// When the bucket refills (RFC 3339 on the wire).
  final DateTime? reset;

  bool get exhausted => remaining != null && remaining! <= 0;

  /// Below 10% of the limit: worth telling the user before the 429.
  bool get low => limit != null && remaining != null && limit! > 0 && remaining! * 10 <= limit!;

  JsonMap toJson() => compact({
        'kind': kind,
        'limit': limit,
        'remaining': remaining,
        'reset': reset?.toUtc().toIso8601String(),
      });
}

/// Parses the `anthropic-ratelimit-*` response headers (R10 §7.7).
List<AnthropicRateLimit> parseAnthropicRateLimits(Map<String, String> headers) {
  final lower = {for (final e in headers.entries) e.key.toLowerCase(): e.value};
  return [
    for (final kind in const ['requests', 'tokens', 'input-tokens', 'output-tokens'])
      if (lower.containsKey('anthropic-ratelimit-$kind-limit') ||
          lower.containsKey('anthropic-ratelimit-$kind-remaining'))
        AnthropicRateLimit(
          kind: kind,
          limit: int.tryParse(lower['anthropic-ratelimit-$kind-limit']?.trim() ?? ''),
          remaining: int.tryParse(lower['anthropic-ratelimit-$kind-remaining']?.trim() ?? ''),
          reset: DateTime.tryParse(lower['anthropic-ratelimit-$kind-reset']?.trim() ?? '')?.toUtc(),
        ),
  ];
}

/// Maps Anthropic error responses onto [ProviderException]s.
///
/// Messages are passed through [Redactor.text] because error bodies can
/// echo request fragments, and they end up in logs and diagnostics exports.
abstract final class AnthropicErrors {
  /// Phrases Anthropic uses when the prompt does not fit the window. The
  /// exact text is unverified (R10 §10), so this matches loosely.
  static final RegExp _tooLong = RegExp(
    r'prompt is too long|too many (input )?tokens|context (window|length|limit)|exceeds? (the )?(maximum|context)|input length and `?max_tokens`? exceed',
    caseSensitive: false,
  );

  static final RegExp _signature = RegExp(r'invalid `?signature`? in `?(redacted_)?thinking`? block', caseSensitive: false);

  static final RegExp _spend = RegExp(r'spend(ing)? (limit|cap)|credit balance|billing|quota|usage limit', caseSensitive: false);

  /// Error for a non-2xx HTTP response. [body] is the (bounded) response
  /// text; [now] resolves `retry-after` HTTP dates and rate-limit resets.
  static ProviderException fromHttp(
    int status,
    Map<String, String> headers,
    String body, {
    required String providerId,
    required DateTime now,
  }) {
    final lower = {for (final e in headers.entries) e.key.toLowerCase(): e.value};
    final (type, rawMessage, requestId) = _parseBody(body);
    final rid = lower['request-id'] ?? requestId;
    final message = _describe(status, type, rawMessage, rid);
    var retryAfter = parseRetryAfter(lower, now: now);
    ProviderException ex(ProviderErrorKind kind, [String? override]) => ProviderException(
          kind,
          override == null ? message : _describe(status, type, override, rid),
          statusCode: status,
          retryAfter: retryAfter,
          providerId: providerId,
        );

    switch (status) {
      case 400:
        return _classify400(type, rawMessage, ex);
      case 401 || 403:
        return ex(ProviderErrorKind.auth);
      case 402:
        return ex(ProviderErrorKind.quotaExceeded);
      case 404:
        return ex(ProviderErrorKind.modelNotFound);
      case 408 || 504:
        return ex(ProviderErrorKind.timeout);
      case 409:
        return ex(ProviderErrorKind.server);
      case 413:
        return ex(ProviderErrorKind.contextOverflow);
      case 429:
        if (_spend.hasMatch(rawMessage ?? '')) return ex(ProviderErrorKind.quotaExceeded);
        if (retryAfter == null) {
          // A proxy may strip retry-after; an exhausted bucket with a known
          // reset is still a plain (retryable) rate limit.
          final resets = [
            for (final l in parseAnthropicRateLimits(lower))
              if (l.exhausted && l.reset != null && l.reset!.isAfter(now)) l.reset!,
          ]..sort();
          if (resets.isNotEmpty) retryAfter = resets.last.difference(now);
        }
        // R10 §7.7: a tier spend-cap 429 carries no retry-after and keeps
        // failing, so it must not be retried like a rate limit.
        return retryAfter == null ? ex(ProviderErrorKind.quotaExceeded) : ex(ProviderErrorKind.rateLimited);
      case 503 || 529:
        return ex(ProviderErrorKind.overloaded);
      default:
        if (status >= 500) return ex(ProviderErrorKind.server);
        return ex(ProviderErrorKind.unknown);
    }
  }

  /// Error for an `event: error` frame received after HTTP 200.
  static ProviderException fromStreamError(JsonMap event, {required String providerId}) {
    final err = event.optObj('error') ?? const {};
    final type = err.opt<String>('type');
    final raw = err.opt<String>('message');
    final message = _describe(null, type, raw, event.opt<String>('request_id'));
    ProviderException ex(ProviderErrorKind kind, [String? override]) => ProviderException(
          kind,
          override == null ? message : _describe(null, type, override, event.opt<String>('request_id')),
          providerId: providerId,
        );
    return switch (type) {
      'overloaded_error' => ex(ProviderErrorKind.overloaded),
      'rate_limit_error' => ex(ProviderErrorKind.rateLimited),
      'api_error' => ex(ProviderErrorKind.server),
      'timeout_error' => ex(ProviderErrorKind.timeout),
      'authentication_error' || 'permission_error' => ex(ProviderErrorKind.auth),
      'not_found_error' => ex(ProviderErrorKind.modelNotFound),
      'billing_error' => ex(ProviderErrorKind.quotaExceeded),
      'request_too_large' => ex(ProviderErrorKind.contextOverflow),
      'invalid_request_error' => _classify400(type, raw, ex),
      _ => ex(ProviderErrorKind.unknown),
    };
  }

  static ProviderException _classify400(
    String? type,
    String? raw,
    ProviderException Function(ProviderErrorKind, [String?]) ex,
  ) {
    final text = raw ?? '';
    if (_signature.hasMatch(text)) {
      // Preserved thinking: something before a replayed thinking block was
      // not byte-identical to the request that produced it.
      return ex(
        ProviderErrorKind.invalidRequest,
        'Anthropic rejected a replayed thinking block because the conversation '
        'before it changed (system prompt, tools or an earlier message differ from '
        'when it was generated). Continue in a new segment, or drop reasoning from '
        'earlier turns. Server said: $text',
      );
    }
    if (_tooLong.hasMatch(text)) return ex(ProviderErrorKind.contextOverflow);
    if (_spend.hasMatch(text)) return ex(ProviderErrorKind.quotaExceeded);
    return ex(ProviderErrorKind.invalidRequest);
  }

  static (String?, String?, String?) _parseBody(String body) {
    if (body.trim().isEmpty) return (null, null, null);
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final j = decoded.cast<String, Object?>();
        final err = j['error'];
        if (err is Map) {
          final e = err.cast<String, Object?>();
          return (e['type']?.toString(), e['message']?.toString(), j['request_id']?.toString());
        }
        return (null, j['message']?.toString(), j['request_id']?.toString());
      }
    } on FormatException {
      // Not JSON (proxy HTML page, plain text): fall through.
    }
    final trimmed = body.length > 500 ? '${body.substring(0, 500)}…' : body;
    return (null, trimmed.trim(), null);
  }

  static String _describe(int? status, String? type, String? message, String? requestId) {
    final b = StringBuffer('Anthropic');
    if (status != null) b.write(' HTTP $status');
    if (type != null) b.write(' $type');
    b.write(': ${message == null || message.isEmpty ? 'no details' : message}');
    if (requestId != null) b.write(' (request-id $requestId)');
    return Redactor.text(b.toString());
  }
}
