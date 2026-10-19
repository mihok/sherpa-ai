import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:test/test.dart';

/// The era-probe classification table (R01 §3.3: TS v2 classifyProbeOutcome).
void main() {
  ProbeVerdict classify(ProbeOutcome o, {bool fallback = true, bool stdio = false}) => classifyProbeOutcome(
        o,
        clientModernVersions: const ['2026-07-28'],
        requestedVersion: '2026-07-28',
        fallbackAvailable: fallback,
        stdioLike: stdio,
      );

  JsonRpcError rpc(int code, [Object? data]) => JsonRpcError(code, 'm', data: data);

  const discover = {
    'resultType': 'complete',
    'supportedVersions': ['2026-07-28'],
    'capabilities': {'tools': <String, Object?>{}},
    'ttlMs': 1000,
    'cacheScope': 'public',
  };

  test('valid DiscoverResult with a mutual version → modern', () {
    final v = classify(const ProbeResult(discover));
    expect(v, isA<ModernVerdict>());
    expect((v as ModernVerdict).version, '2026-07-28');
    expect(v.discover.ttlMs, 1000);
  });

  test('DiscoverResult missing caching hints still validates (0 / private)', () {
    final v = classify(const ProbeResult({
      'supportedVersions': ['2026-07-28'],
      'capabilities': <String, Object?>{},
    })) as ModernVerdict;
    expect(v.discover.ttlMs, 0);
    expect(v.discover.cacheScope, 'private');
  });

  test('valid DiscoverResult without overlap → legacy (fallback) or error', () {
    const other = {
      'supportedVersions': ['2027-01-01'],
      'capabilities': <String, Object?>{},
    };
    expect(classify(const ProbeResult(other)), isA<LegacyVerdict>());
    final e = classify(const ProbeResult(other), fallback: false) as ErrorVerdict;
    expect(e.error, isA<McpUnsupportedVersionException>());
  });

  test('a 200 result that is not a DiscoverResult → legacy', () {
    expect(classify(const ProbeResult({})), isA<LegacyVerdict>());
    expect(classify(const ProbeResult({'supportedVersions': 'x', 'capabilities': <String, Object?>{}})),
        isA<LegacyVerdict>());
    expect(
        classify(const ProbeResult({
          'resultType': 'input_required',
          'supportedVersions': ['2026-07-28'],
          'capabilities': <String, Object?>{},
        })),
        isA<LegacyVerdict>());
  });

  group('JSON-RPC errors keyed on code only', () {
    for (final code in [-32000, -32001, -32020, -32021, -32601, -32602, -32603]) {
      test('$code → legacy (in-band 200)', () => expect(classify(ProbeRpcError(rpc(code))), isA<LegacyVerdict>()));
    }

    test('TS v1 stateless 400 -32000 "Unsupported protocol version" → legacy', () {
      final o = ProbeHttpError(400,
          rpcError: const JsonRpcError(-32000,
              'Bad Request: Unsupported protocol version: 2026-07-28 (supported versions: 2025-11-25, 2025-06-18)'));
      expect(classify(o), isA<LegacyVerdict>());
    });

    test('TS v1 stateful 400 -32000 "Server not initialized" → legacy', () {
      expect(classify(const ProbeHttpError(400, rpcError: JsonRpcError(-32000, 'Bad Request: Server not initialized'))),
          isA<LegacyVerdict>());
    });

    test('-32022 with a mutual modern version → corrective', () {
      final v = classify(ProbeHttpError(400, rpcError: rpc(-32022, {
        'supported': ['2026-07-28', '2025-11-25'],
        'requested': '2026-09-01',
      })));
      expect(v, isA<CorrectiveVerdict>());
      expect((v as CorrectiveVerdict).version, '2026-07-28');
    });

    test('-32022 listing only other modern versions → hard error', () {
      final v = classify(ProbeHttpError(400, rpcError: rpc(-32022, {
        'supported': ['2027-03-01'],
      })));
      expect((v as ErrorVerdict).error, isA<McpUnsupportedVersionException>());
    });

    test('-32022 listing only legacy versions → legacy (or error without fallback)', () {
      final o = ProbeHttpError(400, rpcError: rpc(-32022, {
        'supported': ['2025-11-25'],
      }));
      expect(classify(o), isA<LegacyVerdict>());
      expect(classify(o, fallback: false), isA<ErrorVerdict>());
    });

    test('-32022 without usable data.supported → legacy', () {
      for (final data in [null, <String, Object?>{}, {'supported': <Object?>[]}, {'supported': [1]}]) {
        expect(classify(ProbeHttpError(400, rpcError: rpc(-32022, data))), isA<LegacyVerdict>(), reason: '$data');
      }
    });
  });

  group('HTTP statuses', () {
    test('4xx without a JSON-RPC body → legacy', () {
      for (final s in [400, 404, 405, 406, 415]) {
        expect(classify(ProbeHttpError(s)), isA<LegacyVerdict>(), reason: '$s');
      }
    });

    test('404 + -32601 body → legacy', () {
      expect(classify(ProbeHttpError(404, rpcError: rpc(-32601))), isA<LegacyVerdict>());
    });

    test('5xx → error, no verdict', () {
      expect(classify(const ProbeHttpError(503)), isA<ErrorVerdict>());
      expect(classify(ProbeHttpError(500, rpcError: rpc(-32603))), isA<ErrorVerdict>());
    });

    test('401/403 → auth error, not an era verdict', () {
      final o = ProbeAuthRequired(McpAuthRequiredException(statusCode: 401, needsUserConsent: true));
      expect((classify(o) as ErrorVerdict).error, isA<McpAuthRequiredException>());
    });
  });

  test('network error and unusable 2xx reply → error', () {
    expect(classify(ProbeNetworkError(McpTransportException('refused'))), isA<ErrorVerdict>());
    expect(classify(ProbeUnusableReply(McpProtocolException('text/html'))), isA<ErrorVerdict>());
  });

  test('timeout / close: legacy on stdio-like channels, error on HTTP', () {
    const t = ProbeTimeout(Duration(seconds: 1));
    expect(classify(t, stdio: true), isA<LegacyVerdict>());
    expect((classify(t) as ErrorVerdict).error, isA<McpTimeoutException>());
    expect(classify(const ProbeClosed(), stdio: true), isA<LegacyVerdict>());
    expect(classify(const ProbeClosed()), isA<ErrorVerdict>());
  });
}
