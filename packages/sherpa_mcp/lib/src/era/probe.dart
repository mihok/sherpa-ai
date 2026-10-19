/// Era detection (basic/versioning.md, streamable-http.md and stdio.md
/// §Backward Compatibility; R01 §3.3, §11).
///
/// The classifier mirrors the TS v2 client's `classifyProbeOutcome`
/// (`@modelcontextprotocol/client@2.3.1`, used as a behavioural reference
/// only): it keys on `error.code` and never on message text, so a TS v1
/// server's `400 -32000 "Unsupported protocol version"` reads as legacy.
library;

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart' show CancelledException, Clock, JsonMap;

import '../errors.dart';
import '../protocol/json_read.dart';
import '../protocol/jsonrpc.dart';
import '../protocol/types.dart';
import '../protocol/versions.dart';
import '../transport/http.dart';
import '../transport/legacy_sse.dart';
import '../transport/legacy_streamable_http.dart';
import '../transport/modern_http.dart';
import '../transport/transport.dart';
import 'era.dart';
import 'handshake.dart';

/// The raw outcome of one `server/discover` probe exchange.
@immutable
sealed class ProbeOutcome {
  const ProbeOutcome();
}

/// A JSON-RPC result.
final class ProbeResult extends ProbeOutcome {
  const ProbeResult(this.result);

  final JsonMap result;
}

/// A JSON-RPC error in a normal response (HTTP 200, or stdio).
final class ProbeRpcError extends ProbeOutcome {
  const ProbeRpcError(this.error);

  final JsonRpcError error;
}

/// A non-2xx HTTP status (not 401/403, which are [ProbeAuthRequired]);
/// [rpcError] is the JSON-RPC error parsed from the body, if any.
final class ProbeHttpError extends ProbeOutcome {
  const ProbeHttpError(this.status, {this.rpcError});

  final int status;
  final JsonRpcError? rpcError;
}

final class ProbeNetworkError extends ProbeOutcome {
  const ProbeNetworkError(this.error);

  final Object error;
}

/// A 2xx answer without a usable JSON-RPC reply.
final class ProbeUnusableReply extends ProbeOutcome {
  const ProbeUnusableReply(this.error);

  final Object error;
}

final class ProbeAuthRequired extends ProbeOutcome {
  const ProbeAuthRequired(this.error);

  final McpAuthRequiredException error;
}

final class ProbeClosed extends ProbeOutcome {
  const ProbeClosed();
}

final class ProbeTimeout extends ProbeOutcome {
  const ProbeTimeout(this.after);

  final Duration after;
}

/// What a probe outcome means.
@immutable
sealed class ProbeVerdict {
  const ProbeVerdict();
}

final class ModernVerdict extends ProbeVerdict {
  const ModernVerdict(this.version, this.discover);

  final String version;
  final McpDiscoverResult discover;
}

/// `-32022` naming a mutual modern version: retry the probe with it once.
final class CorrectiveVerdict extends ProbeVerdict {
  const CorrectiveVerdict(this.version);

  final String version;
}

final class LegacyVerdict extends ProbeVerdict {
  const LegacyVerdict(this.reason);

  final String reason;
}

/// No verdict: surface [error] (auth, 5xx, network, HTTP timeout, …).
final class ErrorVerdict extends ProbeVerdict {
  const ErrorVerdict(this.error);

  final Exception error;
}

/// Classifies one probe outcome (pure; TS v2 `classifyProbeOutcome`).
///
/// * Result: a valid `DiscoverResult` whose `supportedVersions` overlaps
///   [clientModernVersions] → modern; valid but no overlap → legacy when
///   [fallbackAvailable], else an unsupported-version error; invalid →
///   legacy.
/// * JSON-RPC error (in-band, or parsed from a non-2xx body): only `-32022`
///   can mean modern — mutual modern version → corrective; modern versions
///   but none mutual → error; legacy-only or unusable `data.supported` →
///   legacy. Every other code (`-32000`, `-32001`, `-32020`, `-32021`,
///   `-32601`, …) → legacy.
/// * HTTP 401/403 → auth error (not an era verdict); ≥ 500 → error; other
///   statuses with no JSON-RPC body → legacy.
/// * Network error / unusable 2xx reply → error.
/// * Timeout or close → legacy on stdio-like channels ([stdioLike]), error
///   on HTTP.
ProbeVerdict classifyProbeOutcome(
  ProbeOutcome outcome, {
  required List<String> clientModernVersions,
  required String requestedVersion,
  required bool fallbackAvailable,
  required bool stdioLike,
}) {
  ProbeVerdict rpc(JsonRpcError e) {
    if (e.code != JsonRpcError.unsupportedProtocolVersion) {
      return LegacyVerdict('JSON-RPC error ${e.code} is not modern evidence');
    }
    final data = asMap(e.data);
    final raw = data?['supported'];
    if (raw is! List || raw.isEmpty || raw.any((v) => v is! String)) {
      return const LegacyVerdict('-32022 without a usable data.supported');
    }
    final supported = raw.cast<String>();
    final requested = asString(data?['requested']) ?? requestedVersion;
    final modern = supported.where(McpVersions.isModern).toList();
    final mutual = clientModernVersions.where(modern.contains).firstOrNull;
    if (mutual != null) return CorrectiveVerdict(mutual);
    final unsupported = McpUnsupportedVersionException(supported: supported, requested: requested);
    if (modern.isNotEmpty) return ErrorVerdict(unsupported);
    return fallbackAvailable ? const LegacyVerdict('-32022 lists only legacy versions') : ErrorVerdict(unsupported);
  }

  switch (outcome) {
    case ProbeResult(:final result):
      final discover = McpDiscoverResult.tryParse(result);
      if (discover == null) return const LegacyVerdict('result is not a DiscoverResult');
      final overlap = clientModernVersions.where(discover.supportedVersions.contains).firstOrNull;
      if (overlap != null) return ModernVerdict(overlap, discover);
      return fallbackAvailable
          ? const LegacyVerdict('DiscoverResult offers no mutual modern version')
          : ErrorVerdict(McpUnsupportedVersionException(supported: discover.supportedVersions, requested: requestedVersion));
    case ProbeRpcError(:final error):
      return rpc(error);
    case ProbeHttpError(:final status, :final rpcError):
      if (status >= 500) {
        return ErrorVerdict(McpEraNegotiationException('the server answered the probe with HTTP $status'));
      }
      return rpcError == null ? LegacyVerdict('HTTP $status without a JSON-RPC error body') : rpc(rpcError);
    case ProbeAuthRequired(:final error):
      return ErrorVerdict(error);
    case ProbeNetworkError(:final error):
      return ErrorVerdict(error is Exception ? error : McpEraNegotiationException('probe failed: $error'));
    case ProbeUnusableReply(:final error):
      return ErrorVerdict(McpEraNegotiationException('the server answered the probe with an unusable reply: $error'));
    case ProbeClosed():
      return stdioLike
          ? const LegacyVerdict('channel closed during the probe')
          : ErrorVerdict(McpEraNegotiationException('connection closed during the probe'));
    case ProbeTimeout(:final after):
      return stdioLike
          ? LegacyVerdict('no answer within $after')
          : ErrorVerdict(McpTimeoutException('version negotiation probe timed out after $after'));
  }
}

/// Runs one `server/discover` exchange and normalizes what happened.
Future<ProbeOutcome> runDiscoverProbe(McpTransport transport, JsonRpcRequest request, Duration timeout) async {
  try {
    final response = await sendWithTimeout(transport, request, timeout);
    return switch (response) {
      JsonRpcResult(:final result) => ProbeResult(result),
      JsonRpcErrorResponse(:final error) => ProbeRpcError(error),
    };
  } on McpAuthRequiredException catch (e) {
    return ProbeAuthRequired(e);
  } on McpHttpStatusException catch (e) {
    return ProbeHttpError(e.statusCode, rpcError: e.rpcError);
  } on McpTimeoutException {
    return ProbeTimeout(timeout);
  } on McpConnectionClosedException {
    return const ProbeClosed();
  } on McpProtocolException catch (e) {
    return ProbeUnusableReply(e);
  } on McpLimitExceededException catch (e) {
    return ProbeUnusableReply(e);
  } on CancelledException {
    return ProbeTimeout(timeout);
  } on McpTransportException catch (e) {
    return ProbeNetworkError(e);
  }
}

/// A connected, era-established transport.
@immutable
final class McpProbeResult {
  const McpProbeResult({
    required this.transport,
    required this.era,
    required this.protocolVersion,
    required this.attempts,
    this.verdict,
    this.discover,
    this.handshake,
  });

  final McpTransport transport;
  final McpEra era;
  final String protocolVersion;

  /// For HTTP endpoints; persist it (null for in-process channels).
  final EraVerdict? verdict;

  /// Modern: the discover result (no second `server/discover` needed).
  final McpDiscoverResult? discover;

  /// Legacy: `initialize` is done and `notifications/initialized` sent.
  final LegacyHandshake? handshake;

  /// One line per probe step, for the debug console.
  final List<String> attempts;

  /// The same result with [line] prepended to [attempts].
  McpProbeResult withLog(String line) => McpProbeResult(
        transport: transport,
        era: era,
        protocolVersion: protocolVersion,
        verdict: verdict,
        discover: discover,
        handshake: handshake,
        attempts: [line, ...attempts],
      );
}

/// Runs the dual-era detection algorithm for one server (R01 §11):
///
/// 1. POST `server/discover` with the full modern envelope and headers
///    ([probeTimeout]); classify with [classifyProbeOutcome]. Modern →
///    done; corrective → retry once with the server's version; error →
///    throw (401/403 → [McpAuthRequiredException]: authorize, then
///    reconnect — the probe re-runs).
/// 2. Legacy → POST `initialize` offering 2025-11-25 and accepting a
///    counter-offer down to 2025-03-26 (Streamable HTTP).
/// 3. If `initialize` fails with 400/404/405 and the body is not a
///    recognized modern error → GET the URL expecting an `endpoint` event
///    (HTTP+SSE, 2024-11-05) and initialize over it.
///
/// On in-process channels the probe is `server/discover` with a short
/// timeout; any non-modern answer, a timeout or a close means legacy, and
/// `initialize` follows on the same channel (stdio.md: the fallback MUST
/// NOT be keyed to one error code).
final class McpEraProbe {
  McpEraProbe({
    required this.clientInfo,
    required this.modernCapabilities,
    required this.legacyCapabilities,
    required this.probeTimeout,
    required this.requestTimeout,
    required this.clock,
    this.modernVersions = McpVersions.modern,
    this.allowLegacyFallback = true,
    this.onTransport,
  });

  final McpImplementation clientInfo;

  /// `ClientCapabilities` for the modern envelope.
  final JsonMap modernCapabilities;

  /// `ClientCapabilities` for `initialize`.
  final JsonMap legacyCapabilities;
  final Duration probeTimeout;
  final Duration requestTimeout;
  final Clock clock;
  final List<String> modernVersions;
  final bool allowLegacyFallback;

  /// Called for every transport the probe creates, before it sends
  /// anything, so the caller can tap its inbound messages.
  final void Function(McpTransport transport)? onTransport;
  var _probeId = 0;

  T _created<T extends McpTransport>(T t) {
    onTransport?.call(t);
    return t;
  }

  JsonRpcId _nextId() => JsonRpcId.string('sherpa-probe-${++_probeId}');

  JsonRpcRequest _discover(String version) => JsonRpcRequest(_nextId(), 'server/discover', {
        '_meta': modernEnvelope(
          protocolVersion: version,
          clientCapabilities: modernCapabilities,
          clientInfo: clientInfo,
        ),
      });

  /// Step 1 on any transport. Returns the modern verdict, or null for
  /// legacy; throws for errors.
  Future<ModernVerdict?> probeModern(McpTransport transport, List<String> log) async {
    var requested = modernVersions.first;
    var corrected = false;
    final stdioLike = transport.kind == McpTransportKind.inProcess;
    for (;;) {
      final outcome = await runDiscoverProbe(transport, _discover(requested), probeTimeout);
      final verdict = classifyProbeOutcome(
        outcome,
        clientModernVersions: modernVersions,
        requestedVersion: requested,
        fallbackAvailable: allowLegacyFallback,
        stdioLike: stdioLike,
      );
      switch (verdict) {
        case ModernVerdict():
          log.add('server/discover: modern ${verdict.version}');
          return verdict;
        case CorrectiveVerdict(:final version):
          log.add('server/discover: -32022, retrying with $version');
          if (corrected) throw McpEraNegotiationException('server kept rejecting $version', attempts: log);
          corrected = true;
          requested = version;
        case LegacyVerdict(:final reason):
          log.add('server/discover: legacy ($reason)');
          if (!allowLegacyFallback) {
            throw McpEraNegotiationException('server gave no modern evidence and fallback is off', attempts: log);
          }
          return null;
        case ErrorVerdict(:final error):
          log.add('server/discover: error ($error)');
          throw error;
      }
    }
  }

  /// The full HTTP algorithm. [http] is bound to the server URL.
  Future<McpProbeResult> probeHttp(McpHttp http) async {
    final log = <String>[];
    final modern = _created(ModernHttpTransport(http: http));
    final verdict = await probeModern(modern, log);
    if (verdict != null) {
      return McpProbeResult(
        transport: modern,
        era: McpEra.modern,
        protocolVersion: verdict.version,
        verdict: _verdict(McpTransportKind.modernHttp, verdict.version, http.serverUrl),
        discover: verdict.discover,
        attempts: log,
      );
    }
    await modern.close();
    return probeLegacyHttp(http, log: log);
  }

  /// Steps 2–3.
  Future<McpProbeResult> probeLegacyHttp(McpHttp http, {List<String>? log, bool allowSse = true}) async {
    final steps = log ?? <String>[];
    final streamable = _created(LegacyStreamableHttpTransport(http: http));
    try {
      final h = await _initialize(streamable, McpVersions.legacyStreamable);
      steps.add('initialize (Streamable HTTP): ${h.protocolVersion}');
      return McpProbeResult(
        transport: streamable,
        era: McpEra.legacy,
        protocolVersion: h.protocolVersion,
        verdict: _verdict(McpTransportKind.legacyStreamableHttp, h.protocolVersion, http.serverUrl),
        handshake: h,
        attempts: steps,
      );
    } on McpHttpStatusException catch (e) {
      steps.add('initialize (Streamable HTTP): HTTP ${e.statusCode}${e.rpcError == null ? '' : ' ${e.rpcError!.code}'}');
      await streamable.close();
      final modernBody = e.rpcError != null && _modernCodes.contains(e.rpcError!.code);
      if (!allowSse || modernBody || !const {400, 404, 405}.contains(e.statusCode)) {
        throw McpEraNegotiationException('initialize failed: ${e.message}', attempts: steps);
      }
    } on Object {
      await streamable.close();
      rethrow;
    }
    return probeSse(http, log: steps);
  }

  /// HTTP+SSE only.
  Future<McpProbeResult> probeSse(McpHttp http, {List<String>? log}) async {
    final steps = log ?? <String>[];
    final sse = _created(LegacySseTransport(http: http));
    try {
      await sse.start();
      final h = await _initialize(sse, McpVersions.legacySse);
      steps.add('initialize (HTTP+SSE): ${h.protocolVersion}');
      return McpProbeResult(
        transport: sse,
        era: McpEra.legacy,
        protocolVersion: h.protocolVersion,
        verdict: _verdict(McpTransportKind.legacySse, h.protocolVersion, http.serverUrl),
        handshake: h,
        attempts: steps,
      );
    } on McpAuthRequiredException {
      await sse.close();
      rethrow;
    } on McpException catch (e) {
      steps.add('HTTP+SSE: $e');
      await sse.close();
      throw McpEraNegotiationException('no MCP era answered at this URL', attempts: steps);
    }
  }

  /// In-process channel (already started).
  Future<McpProbeResult> probeChannel(McpTransport transport) async {
    final log = <String>[];
    final verdict = await probeModern(transport, log);
    if (verdict != null) {
      return McpProbeResult(
        transport: transport,
        era: McpEra.modern,
        protocolVersion: verdict.version,
        discover: verdict.discover,
        attempts: log,
      );
    }
    final h = await _initialize(transport, McpVersions.legacySse);
    log.add('initialize: ${h.protocolVersion}');
    return McpProbeResult(
      transport: transport,
      era: McpEra.legacy,
      protocolVersion: h.protocolVersion,
      handshake: h,
      attempts: log,
    );
  }

  Future<LegacyHandshake> _initialize(McpTransport t, List<String> accepted) => legacyInitialize(
        t,
        capabilities: legacyCapabilities,
        clientInfo: clientInfo,
        acceptedVersions: accepted,
        nextId: _nextId,
        timeout: requestTimeout,
      );

  EraVerdict _verdict(McpTransportKind kind, String version, Uri url) =>
      EraVerdict(transport: kind, protocolVersion: version, endpoint: endpointKey(url), decidedAt: clock.now());

  static const Set<int> _modernCodes = {
    JsonRpcError.headerMismatch,
    JsonRpcError.missingRequiredClientCapability,
    JsonRpcError.unsupportedProtocolVersion,
  };
}
