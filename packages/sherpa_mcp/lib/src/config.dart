/// Server configuration and client options.
library;

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart' show Clock, FormatError, JsonMap, SystemClock, compact;
import 'package:sherpa_net/sherpa_net.dart' show NetworkScope, Redactor, UrlPolicy;

import 'auth.dart';
import 'era/era.dart';
import 'protocol/headers.dart';
import 'protocol/input.dart';
import 'protocol/json_read.dart';
import 'protocol/types.dart';
import 'protocol/versions.dart';

/// Which binding to use for a server.
enum McpTransportPreference {
  /// Probe: modern first, then legacy Streamable HTTP, then HTTP+SSE.
  auto,

  /// Force 2026-07-28 Streamable HTTP (no fallback).
  modernHttp,

  /// Force 2025-era Streamable HTTP (initialize + session).
  legacyStreamableHttp,

  /// Force the deprecated 2024-11-05 HTTP+SSE transport.
  legacySse,

  /// An on-device server the app hosts in Dart; supply the transport.
  inProcess,
}

/// A configured MCP server, as persisted by the app (sherpa_data).
///
/// Holds no secrets: credentials live in the SecretStore behind
/// [McpAuthHook]. [headers] are for non-secret routing headers only, and
/// header names that look sensitive (authorization, cookies, `*token*`,
/// `*secret*`, `*-key`) or that the transport owns are rejected.
@immutable
final class McpServerConfig {
  McpServerConfig({
    required this.id,
    required this.name,
    required this.url,
    this.transport = McpTransportPreference.auto,
    this.cachedVerdict,
    this.allowLocalNetwork = false,
    this.enabled = true,
    this.trusted = false,
    Map<String, String> headers = const {},
  }) : headers = Map.unmodifiable(headers) {
    for (final name in headers.keys) {
      if (Redactor.isSensitiveHeader(name)) {
        throw ArgumentError.value(name, 'headers', 'secrets belong in the SecretStore, not the server config');
      }
      if (McpHeaders.isReserved(name)) {
        throw ArgumentError.value(name, 'headers', 'header is set by the MCP transport');
      }
    }
  }

  factory McpServerConfig.fromJson(JsonMap j) {
    final verdict = asMap(j['cachedVerdict']);
    final t = asString(j['transport']) ?? 'auto';
    return McpServerConfig(
      id: reqString(j, 'id', 'server config'),
      name: reqString(j, 'name', 'server config'),
      url: Uri.parse(reqString(j, 'url', 'server config')),
      transport: McpTransportPreference.values.where((v) => v.name == t).firstOrNull ??
          (throw FormatError('server config: unknown transport "$t"')),
      cachedVerdict: verdict == null ? null : _tryVerdict(verdict),
      allowLocalNetwork: asBool(j['allowLocalNetwork']) ?? false,
      enabled: asBool(j['enabled']) ?? true,
      trusted: asBool(j['trusted']) ?? false,
      headers: {
        for (final e in (asMap(j['headers']) ?? const <String, Object?>{}).entries)
          if (e.value is String) e.key: e.value! as String,
      },
    );
  }

  static EraVerdict? _tryVerdict(JsonMap j) {
    try {
      return EraVerdict.fromJson(j);
    } on Object {
      return null; // A stale or corrupt verdict only costs a re-probe.
    }
  }

  /// Stable id (namespacing, cache keys, task handles).
  final String id;
  final String name;

  /// The MCP endpoint. Ignored for [McpTransportPreference.inProcess].
  final Uri url;
  final McpTransportPreference transport;

  /// The era verdict from the last successful connect (persist
  /// `McpConnection.verdict` here). Ignored when it does not match [url].
  final EraVerdict? cachedVerdict;

  /// Allows http and private/loopback addresses: a server the user runs on
  /// the LAN or on the phone. Link-local and metadata addresses stay
  /// blocked whatever this says.
  final bool allowLocalNetwork;
  final bool enabled;

  /// The user trusts this server's annotations (approval policy input;
  /// R01 §6.2: annotations are untrusted unless the server is trusted).
  final bool trusted;
  final Map<String, String> headers;

  /// The SSRF policy for this server's URLs (same rule as model endpoints).
  UrlPolicy get urlPolicy =>
      allowLocalNetwork ? const UrlPolicy(scope: NetworkScope.loopback, allowHttp: true) : const UrlPolicy();

  McpServerConfig copyWith({
    String? name,
    Uri? url,
    McpTransportPreference? transport,
    EraVerdict? cachedVerdict,
    bool clearCachedVerdict = false,
    bool? allowLocalNetwork,
    bool? enabled,
    bool? trusted,
    Map<String, String>? headers,
  }) =>
      McpServerConfig(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        transport: transport ?? this.transport,
        cachedVerdict: clearCachedVerdict ? null : (cachedVerdict ?? this.cachedVerdict),
        allowLocalNetwork: allowLocalNetwork ?? this.allowLocalNetwork,
        enabled: enabled ?? this.enabled,
        trusted: trusted ?? this.trusted,
        headers: headers ?? this.headers,
      );

  JsonMap toJson() => compact({
        'id': id,
        'name': name,
        'url': url.toString(),
        'transport': transport.name,
        'cachedVerdict': cachedVerdict?.toJson(),
        'allowLocalNetwork': allowLocalNetwork ? true : null,
        'enabled': enabled ? null : false,
        'trusted': trusted ? true : null,
        'headers': headers.isEmpty ? null : headers,
      });
}

/// Which client capabilities to declare. Declared per request (M) or in
/// `initialize` (L); a server MUST NOT ask for anything undeclared, and
/// this client refuses such requests.
@immutable
final class McpClientCapabilities {
  const McpClientCapabilities({
    this.elicitationForm = true,
    this.elicitationUrl = true,
    this.sampling = false,
    this.samplingTools = false,
    this.roots = false,
    this.mcpApps = false,
    this.tasks = false,
    this.extraExtensions = const {},
  });

  /// Elicitation is the only non-deprecated client feature.
  final bool elicitationForm;

  /// URL mode needs the consent dialog (show full URL, open outside app).
  final bool elicitationUrl;

  /// Off by default (deprecated in M; per-server opt-in, PLAN §7.5).
  final bool sampling;

  /// Only with a real tool loop for sampling (R01 rec. 5).
  final bool samplingTools;

  /// Off by default: deprecated and of little value on mobile.
  final bool roots;

  /// MCP Apps: `extensions["io.modelcontextprotocol/ui"]` (R03 §2).
  final bool mcpApps;

  /// `extensions["io.modelcontextprotocol/tasks"]` (modern era only).
  final bool tasks;
  final Map<String, JsonMap> extraExtensions;

  McpClientCapabilities copyWith({bool? elicitationForm, bool? elicitationUrl, bool? sampling, bool? mcpApps}) =>
      McpClientCapabilities(
        elicitationForm: elicitationForm ?? this.elicitationForm,
        elicitationUrl: elicitationUrl ?? this.elicitationUrl,
        sampling: sampling ?? this.sampling,
        samplingTools: samplingTools,
        roots: roots,
        mcpApps: mcpApps ?? this.mcpApps,
        tasks: tasks,
        extraExtensions: extraExtensions,
      );

  /// The `ClientCapabilities` object. Input capabilities are declared only
  /// when there is a handler to serve them.
  JsonMap toJson({required McpEra era, required bool hasHandler}) {
    final extensions = <String, Object?>{
      ...extraExtensions,
      if (mcpApps) McpExtensionIds.ui: const {'mimeTypes': [McpExtensionIds.uiMimeType]},
      if (tasks && era == McpEra.modern) McpExtensionIds.tasks: const <String, Object?>{},
    };
    return {
      if (hasHandler && (elicitationForm || elicitationUrl))
        'elicitation': {
          if (elicitationForm) 'form': const <String, Object?>{},
          if (elicitationUrl) 'url': const <String, Object?>{},
        },
      if (hasHandler && sampling) 'sampling': {if (samplingTools) 'tools': const <String, Object?>{}},
      if (hasHandler && roots) 'roots': const <String, Object?>{},
      if (extensions.isNotEmpty) 'extensions': extensions,
    };
  }
}

/// Timeouts. Request timeouts are idle timeouts: progress notifications and
/// time spent waiting for the user (elicitation, sampling approval) reset
/// or pause them, while [maxRequest] is a hard cap on server time
/// (patterns/cancellation.md §Timeouts).
@immutable
final class McpTimeouts {
  const McpTimeouts({
    this.request = const Duration(seconds: 60),
    this.maxRequest = const Duration(minutes: 10),
    this.headers = const Duration(seconds: 30),
    this.probe = const Duration(seconds: 10),
    this.inProcessProbe = const Duration(seconds: 2),
    this.sseEndpoint = const Duration(seconds: 10),
    this.listenAck = const Duration(seconds: 15),
    this.streamIdle = const Duration(minutes: 5),
    this.close = const Duration(seconds: 3),
    this.elicitationCompleteGrace = const Duration(seconds: 3),
  });

  final Duration request;
  final Duration maxRequest;

  /// Wait for response headers.
  final Duration headers;

  /// Each HTTP era-probe step. A modern probe timeout is an error, not a
  /// verdict (TS v2 `classifyProbeOutcome`).
  final Duration probe;

  /// `server/discover` on an in-process channel: a timeout means legacy.
  final Duration inProcessProbe;

  /// HTTP+SSE: the `endpoint` event must arrive within this.
  final Duration sseEndpoint;
  final Duration listenAck;

  /// A long-lived stream (listen, GET) with no bytes for this long is
  /// considered dead and reconnected.
  final Duration streamIdle;

  /// Best-effort `DELETE` on close.
  final Duration close;

  /// Legacy `-32042`: after the user finished a URL elicitation, how long to
  /// wait for the (optional) `notifications/elicitation/complete` before
  /// retrying the request anyway.
  final Duration elicitationCompleteGrace;
}

/// Size and loop caps against hostile or buggy servers.
@immutable
final class McpLimits {
  const McpLimits({
    this.maxMessageBytes = 8 << 20,
    this.maxErrorBodyBytes = 64 << 10,
    this.maxListPages = 64,
    this.maxInputRounds = 8,
    this.maxResumeAttempts = 3,
    this.maxListenReconnects = 5,
  });

  /// One JSON body or one SSE event.
  final int maxMessageBytes;
  final int maxErrorBodyBytes;
  final int maxListPages;

  /// MRTR rounds (and legacy -32042 retries) per request.
  final int maxInputRounds;

  /// Legacy SSE resumption attempts (Last-Event-ID) per stream.
  final int maxResumeAttempts;

  /// Consecutive failed reconnects before a listen stream gives up.
  final int maxListenReconnects;
}

/// Everything a connection needs besides the server config.
@immutable
final class McpClientOptions {
  const McpClientOptions({
    this.httpClient,
    this.clientInfo = McpImplementation.sherpa,
    this.capabilities = const McpClientCapabilities(),
    this.inputHandler,
    this.authHook,
    this.clock = const SystemClock(),
    this.timeouts = const McpTimeouts(),
    this.limits = const McpLimits(),
    this.verdictCache,
    this.urlPolicy,
    this.logLevel,
    this.legacyListCacheTtl = Duration.zero,
    this.serveStaleOnError = true,
  });

  /// Required for HTTP servers. Use one whose connections are not shared
  /// with unrelated hosts' credentials; redirects are never followed by it
  /// (the client handles same-origin 307/308 itself).
  final http.Client? httpClient;
  final McpImplementation clientInfo;
  final McpClientCapabilities capabilities;

  /// Without a handler no input capability is declared.
  final InputRequestHandler? inputHandler;
  final McpAuthHook? authHook;
  final Clock clock;
  final McpTimeouts timeouts;
  final McpLimits limits;

  /// Shared process-lifetime verdicts (in addition to the config's).
  final EraVerdictCache? verdictCache;

  /// Overrides [McpServerConfig.urlPolicy] (tests resolve DNS offline).
  final UrlPolicy? urlPolicy;

  /// Initial log level: per request in M, `logging/setLevel` in L.
  /// Null = no server log messages (M servers MUST NOT emit logs then).
  final McpLogLevel? logLevel;

  /// Legacy results carry no `ttlMs`. Lists are then cached for this long,
  /// and until the next `list_changed` when the server advertises
  /// `listChanged` (zero = always re-fetch unless `listChanged`).
  final Duration legacyListCacheTtl;

  /// Serve a stale list when a re-fetch fails at the transport level
  /// (caching.md: clients MAY).
  final bool serveStaleOnError;

  /// These options with other [capabilities] or [inputHandler] (e.g. what
  /// one server may ask for, decided per server by the host).
  McpClientOptions copyWith({McpClientCapabilities? capabilities, InputRequestHandler? inputHandler}) => McpClientOptions(
        httpClient: httpClient,
        clientInfo: clientInfo,
        capabilities: capabilities ?? this.capabilities,
        inputHandler: inputHandler ?? this.inputHandler,
        authHook: authHook,
        clock: clock,
        timeouts: timeouts,
        limits: limits,
        verdictCache: verdictCache,
        urlPolicy: urlPolicy,
        logLevel: logLevel,
        legacyListCacheTtl: legacyListCacheTtl,
        serveStaleOnError: serveStaleOnError,
      );
}
