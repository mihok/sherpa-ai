import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';
import 'package:sherpa_providers/sherpa_providers.dart';
import 'package:test/test.dart';

void main() {
  ProviderException map(int status, Object body, {Map<String, String> headers = const {}}) => mapHttpError(
        statusCode: status,
        headers: headers,
        body: body is String ? body : jsonEncode(body),
        providerId: 'p',
        now: DateTime.utc(2026, 10, 18),
      );

  Map<String, Object?> openAiError(String message, {String? type, String? code, String? param}) => {
        'error': {'message': message, 'type': type, 'param': param, 'code': code},
      };

  group('HTTP status mapping', () {
    final cases = <(int, Object, ProviderErrorKind)>[
      (401, openAiError('Incorrect API key provided', type: 'invalid_request_error', code: 'invalid_api_key'),
          ProviderErrorKind.auth),
      (403, openAiError('Country, region, or territory not supported', code: 'unsupported_country_region_territory'),
          ProviderErrorKind.auth),
      (404, openAiError('The model `gpt-9` does not exist', type: 'invalid_request_error', code: 'model_not_found'),
          ProviderErrorKind.modelNotFound),
      (400, openAiError('Invalid value for temperature', type: 'invalid_request_error'), ProviderErrorKind.invalidRequest),
      (422, {'detail': 'Unprocessable'}, ProviderErrorKind.invalidRequest),
      (500, openAiError('The server had an error', type: 'server_error'), ProviderErrorKind.server),
      (502, '<html>Bad gateway</html>', ProviderErrorKind.server),
      (503, openAiError('The engine is currently overloaded', type: 'server_error', code: 'server_is_overloaded'),
          ProviderErrorKind.overloaded),
      (529, {'type': 'error', 'error': {'type': 'overloaded_error', 'message': 'Overloaded'}}, ProviderErrorKind.overloaded),
      (504, 'gateway timeout', ProviderErrorKind.timeout),
      (501, {'error': {'code': 501, 'message': 'not supported', 'type': 'not_supported_error'}}, ProviderErrorKind.unsupported),
      (402, {'type': 'error', 'error': {'type': 'billing_error', 'message': 'Your credit balance is too low'}},
          ProviderErrorKind.quotaExceeded),
    ];
    for (final (status, body, kind) in cases) {
      test('$status → ${kind.name}', () {
        final e = map(status, body);
        expect(e.kind, kind);
        expect(e.statusCode, status);
        expect(e.providerId, 'p');
      });
    }
  });

  test('429 rate limit carries Retry-After and is retryable', () {
    final e = map(429, openAiError('Rate limit reached for requests', type: 'requests', code: 'rate_limit_exceeded'),
        headers: {'retry-after': '7'});
    expect(e.kind, ProviderErrorKind.rateLimited);
    expect(e.retryAfter, const Duration(seconds: 7));
    expect(e.isRetryable, isTrue);
  });

  test('429 without Retry-After falls back to vendor reset headers', () {
    final e = map(429, openAiError('slow down', code: 'rate_limit_exceeded'), headers: {'x-ratelimit-reset-requests': '1.5s'});
    expect(e.retryAfter, const Duration(milliseconds: 1500));
  });

  test('quota 429s are not retryable (OpenAI codes and messages)', () {
    for (final body in [
      openAiError('You exceeded your current quota, please check your plan', type: 'insufficient_quota', code: 'insufficient_quota'),
      openAiError('Spend limit reached', type: 'insufficient_quota', code: 'organization_spend_limit_exceeded'),
      openAiError('Project budget used', code: 'project_spend_limit_exceeded'),
      openAiError('Credits exhausted', code: 'credit_balance_exhausted'),
      {'type': 'error', 'error': {'type': 'rate_limit_error', 'message': 'You have reached your specified API usage limits.'}},
    ]) {
      final e = map(429, body, headers: {'retry-after': '1'});
      expect(e.kind, ProviderErrorKind.quotaExceeded, reason: jsonEncode(body));
      expect(e.isRetryable, isFalse);
      expect(e.retryAfter, isNull);
    }
  });

  test('context overflow is recognised from codes and messages', () {
    for (final body in [
      openAiError("This model's maximum context length is 8192 tokens", type: 'invalid_request_error', code: 'context_length_exceeded'),
      {
        'error': {
          'code': 400,
          'message': 'request (9000 tokens) exceeds the available context size (8192 tokens), try increasing it',
          'type': 'exceed_context_size_error',
          'n_prompt_tokens': 9000,
          'n_ctx': 8192,
        },
      },
      {'type': 'error', 'error': {'type': 'invalid_request_error', 'message': 'prompt is too long: 210000 tokens > 200000 maximum'}},
      {'object': 'error', 'message': "This model's maximum context length is 4096 tokens.", 'code': 400},
    ]) {
      final e = map(400, body);
      expect(e.kind, ProviderErrorKind.contextOverflow, reason: jsonEncode(body));
    }
    final llama = map(400, {
      'error': {'code': 400, 'message': 'exceeds', 'type': 'exceed_context_size_error', 'n_prompt_tokens': 9000, 'n_ctx': 8192},
    });
    expect(llama.message, allOf(contains('prompt_tokens=9000'), contains('n_ctx=8192')));
  });

  test('a TPM-limit 429 mentioning tokens stays a rate limit', () {
    final e = map(429, openAiError('Request too large: too many tokens per min (TPM)', code: 'rate_limit_exceeded'));
    expect(e.kind, ProviderErrorKind.rateLimited);
  });

  test('message includes the body, redacted', () {
    final e = map(401, {
      'error': {'message': 'Incorrect API key provided: sk-proj-abcdefghijklmnopqrstuvwx', 'type': 'invalid_request_error'},
    }, headers: {'x-request-id': 'req_123'});
    expect(e.message, contains('HTTP 401'));
    expect(e.message, contains('Incorrect API key provided'));
    expect(e.message, contains('x-request-id=req_123'));
    expect(e.message, isNot(contains('sk-proj-abcdefghijklmnopqrstuvwx')));
    expect(e.message, contains(Redactor.mask));
  });

  test('long bodies are truncated in the message', () {
    final e = map(500, 'x' * 10000);
    expect(e.message.length, lessThan(2600));
  });

  group('mid-stream errors', () {
    test('llama.cpp int code', () {
      final e = mapStreamError({
        'error': {'code': 500, 'message': 'slot crashed', 'type': 'server_error'},
      });
      expect(e.kind, ProviderErrorKind.server);
      expect(e.statusCode, 500);
    });

    test('OpenRouter error chunk with metadata', () {
      final e = mapStreamError({
        'error': {'code': 502, 'message': 'Provider returned error', 'metadata': {'error_type': 'provider_error'}},
      });
      expect(e.kind, ProviderErrorKind.server);
      expect(e.message, contains('Provider returned error'));
    });

    test('Anthropic overloaded and Responses error events', () {
      expect(mapStreamError({'type': 'error', 'error': {'type': 'overloaded_error', 'message': 'Overloaded'}}).kind,
          ProviderErrorKind.overloaded);
      expect(mapStreamError({'type': 'error', 'code': 'rate_limit_exceeded', 'message': 'slow', 'sequence_number': 3}).kind,
          ProviderErrorKind.rateLimited);
      expect(mapStreamError({'type': 'error', 'code': 'context_length_exceeded', 'message': 'too long'}).kind,
          ProviderErrorKind.contextOverflow);
      expect(mapStreamError({'error': 'something odd'}).kind, ProviderErrorKind.server);
    });
  });

  test('ErrorDetails tolerates odd shapes', () {
    expect(ErrorDetails.fromBody('').message, isNull);
    expect(ErrorDetails.fromBody('plain text\nsecond line').message, 'plain text');
    expect(ErrorDetails.fromBody('{"error":"model not found"}').message, 'model not found');
    expect(ErrorDetails.fromBody('{"detail":[{"loc":["body"],"msg":"bad"}]}').message, contains('bad'));
  });
}
