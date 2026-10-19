/// `server/discover` (M) and `initialize` (L) exchanges (internal).
library;

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart' show JsonMap;

import '../errors.dart';
import '../protocol/json_read.dart';
import '../protocol/jsonrpc.dart';
import '../protocol/types.dart';
import '../protocol/versions.dart';
import '../transport/legacy_streamable_http.dart';
import '../transport/transport.dart';

/// `DiscoverResult` (server/discover.md): versions, capabilities,
/// instructions and caching hints.
@immutable
final class McpDiscoverResult {
  const McpDiscoverResult({
    required this.supportedVersions,
    required this.capabilities,
    required this.raw,
    this.instructions,
    this.serverInfo,
    this.ttlMs = 0,
    this.cacheScope = 'private',
  });

  /// Null when [result] is not a valid `DiscoverResult` (then the server is
  /// legacy: TS v2 `classifyResult`). Missing `ttlMs` / `cacheScope` fall
  /// back to `0` / `private` like the TS codec.
  static McpDiscoverResult? tryParse(JsonMap result) {
    final rt = result['resultType'];
    if (rt != null && rt != 'complete') return null;
    final versions = result['supportedVersions'];
    final caps = asMap(result['capabilities']);
    if (versions is! List || versions.any((v) => v is! String) || caps == null) return null;
    final ttl = asInt(result['ttlMs']);
    final scope = asString(result['cacheScope']);
    return McpDiscoverResult(
      supportedVersions: versions.cast<String>(),
      capabilities: McpServerCapabilities(caps),
      instructions: asString(result['instructions']),
      serverInfo: McpImplementation.tryParse(asMap(result['_meta'])?[McpMetaKeys.serverInfo]),
      ttlMs: ttl == null || ttl < 0 ? 0 : ttl,
      cacheScope: scope == 'public' ? 'public' : 'private',
      raw: result,
    );
  }

  final List<String> supportedVersions;
  final McpServerCapabilities capabilities;

  /// Untrusted server text meant for the system prompt.
  final String? instructions;
  final McpImplementation? serverInfo;
  final int ttlMs;
  final String cacheScope;
  final JsonMap raw;
}

/// What a successful `initialize` established.
@immutable
final class LegacyHandshake {
  const LegacyHandshake({
    required this.protocolVersion,
    required this.capabilities,
    required this.raw,
    this.serverInfo,
    this.instructions,
  });

  final String protocolVersion;
  final McpServerCapabilities capabilities;
  final McpImplementation? serverInfo;
  final String? instructions;
  final JsonMap raw;
}

/// The 2026-07-28 per-request envelope (basic/index.md §_meta).
JsonMap modernEnvelope({
  required String protocolVersion,
  required JsonMap clientCapabilities,
  required McpImplementation clientInfo,
  McpLogLevel? logLevel,
}) =>
    {
      McpMetaKeys.protocolVersion: protocolVersion,
      McpMetaKeys.clientCapabilities: clientCapabilities,
      McpMetaKeys.clientInfo: clientInfo.toJson(),
      if (logLevel != null) McpMetaKeys.logLevel: logLevel.name,
    };

/// Sends [request] with a timeout, abandoning it on expiry.
Future<JsonRpcResponse> sendWithTimeout(McpTransport t, JsonRpcRequest request, Duration timeout) {
  final abort = Completer<void>();
  final timer = Timer(timeout, () {
    if (!abort.isCompleted) abort.complete();
  });
  return t.request(request, options: McpSendOptions(abort: abort.future)).then((r) {
    timer.cancel();
    return r;
  }, onError: (Object e, StackTrace st) {
    timer.cancel();
    if (abort.isCompleted) throw McpTimeoutException('${request.method} timed out after $timeout');
    Error.throwWithStackTrace(e, st);
  });
}

/// The legacy handshake (2025-11-25 basic/lifecycle.md): offer
/// [McpVersions.latestLegacy]; accept a counter-offer only if it is in
/// [acceptedVersions] (else "disconnect"); then `notifications/initialized`.
/// A server that instead errors with `data.supported` naming a version we
/// accept is retried once with that version. `initialize` is never
/// cancelled except by timeout.
Future<LegacyHandshake> legacyInitialize(
  McpTransport transport, {
  required JsonMap capabilities,
  required McpImplementation clientInfo,
  required List<String> acceptedVersions,
  required JsonRpcId Function() nextId,
  required Duration timeout,
}) async {
  var offer = McpVersions.latestLegacy;
  for (var attempt = 0;; attempt++) {
    final response = await sendWithTimeout(
      transport,
      JsonRpcRequest(nextId(), 'initialize', {
        'protocolVersion': offer,
        'capabilities': capabilities,
        'clientInfo': clientInfo.toJson(),
      }),
      timeout,
    );
    switch (response) {
      case JsonRpcErrorResponse(:final error):
        final supported = stringList(asMap(error.data)?['supported']);
        final retry = acceptedVersions.where(supported.contains).firstOrNull;
        if (attempt == 0 && retry != null && retry != offer) {
          offer = retry;
          continue;
        }
        throw McpRpcException(error);
      case JsonRpcResult(:final result):
        final version = asString(result['protocolVersion']);
        if (version == null) throw McpProtocolException('initialize result has no protocolVersion');
        if (!acceptedVersions.contains(version)) {
          throw McpUnsupportedVersionException(supported: [version], requested: offer);
        }
        if (transport is LegacyStreamableHttpTransport) transport.protocolVersion = version;
        await transport.notify(const JsonRpcNotification('notifications/initialized'));
        return LegacyHandshake(
          protocolVersion: version,
          capabilities: McpServerCapabilities(asMap(result['capabilities']) ?? const {}),
          serverInfo: McpImplementation.tryParse(result['serverInfo']),
          instructions: asString(result['instructions']),
          raw: result,
        );
    }
  }
}
