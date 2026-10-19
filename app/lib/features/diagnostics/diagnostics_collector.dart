import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable, kDebugMode, kProfileMode;
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart' show EngineCrashReport, InferencePhase;
import 'package:sherpa_mcp/sherpa_mcp.dart' show McpServerConfig;
import 'package:sherpa_platform/sherpa_platform.dart';
import 'package:sherpa_providers/sherpa_providers.dart' show ProviderConfig;

import '../../app_info.dart';
import '../../services/downloads/model_library.dart' show LibraryModel, LibrarySource;
import '../../services/inference/local_inference.dart' show LocalEngineStatus, LocalInference;
import '../../services/inference/on_device_ids.dart' show isOnDeviceProviderId;
import '../../state/observable_session_store.dart';
import '../../state/provider_location.dart';
import '../../state/providers.dart';
import '../../state/ui_preferences.dart';
import '../chat/state/chat_dependencies.dart' show chatAgentConfigProvider, chatContextManagerProvider;
import '../mcp/state/mcp_providers.dart' show McpServerView, mcpRuntimeProvider, mcpServersProvider;
import '../models/state/local_inference_providers.dart' show localInferenceProvider;
import '../models/state/models_providers.dart' show modelLibraryProvider;
import '../perf/state/perf_providers.dart' show perfDeviceReaderProvider, perfLabProvider;
import 'app_error_ring.dart';
import 'diagnostics_providers.dart' show diagnosticsDatabaseSizeProvider, diagnosticsPrivatePathsProvider;
import 'diagnostics_scrubber.dart';
import 'diagnostics_summary.dart';

/// Reads a provider (`ref.read` or `ProviderContainer.read`).
typedef DiagnosticsReader = T Function<T>(ProviderListenable<T> provider);

/// A finished, redacted diagnostics report: [data] is the JSON that is
/// shared, [summary] the readable text for "Copy summary". Both come from
/// the same scrubbed data, so the summary never holds anything the file
/// doesn't.
@immutable
final class DiagnosticsBundle {
  const DiagnosticsBundle({required this.data, required this.summary, required this.generatedAt});

  static const String format = 'sherpa.diagnostics';
  static const int version = 1;

  final Map<String, Object?> data;
  final String summary;
  final DateTime generatedAt;

  /// Pretty JSON, exactly what is shared.
  String get json => const JsonEncoder.withIndent('  ').convert(data);

  Uint8List get bytes => utf8.encode(json);

  /// `sherpa-diagnostics-2026-10-19-1405.json`.
  String get fileName {
    final d = generatedAt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'sherpa-diagnostics-${d.year}-${two(d.month)}-${two(d.day)}-${two(d.hour)}${two(d.minute)}.json';
  }

  /// The top-level sections, in order (for the preview).
  Iterable<MapEntry<String, Object?>> get sections =>
      data.entries.where((e) => !const {'format', 'version', 'generatedAt', 'notice'}.contains(e.key));
}

/// Builds a [DiagnosticsBundle] from the app's public providers.
///
/// **Allowlist, not denylist.** Every field is copied by name from a typed
/// value: enums, numbers, booleans, versions, hosts and model ids. Nothing
/// is serialized wholesale (no `toJson()` of a config, a message or an
/// engine report), and nothing user-written is read at all: chat content,
/// titles, prompts, tool arguments and results, provider and server
/// display names, headers and registry descriptions stay out. Chats and
/// messages are only counted.
///
/// **Then scrubbed.** The finished tree goes through [DiagnosticsScrubber]
/// with every value in the secret store, so even an allowlisted string
/// that happens to contain a key, a URL with a query or a home path (a
/// llama.cpp server reporting a file path as its model id, an engine
/// abort message) is masked.
///
/// Every section is collected on its own with a timeout: a part of the app
/// that isn't wired, or a platform call that hangs, gives
/// `{"unavailable": "<ErrorType>"}` instead of failing the export. Nothing
/// is started for it: the engine and MCP servers are only asked when they
/// are already running.
final class DiagnosticsCollector {
  DiagnosticsCollector(
    this._read, {
    this.maxErrors = 20,
    this.timeout = const Duration(seconds: 4),
    this.maxMessages = 200000,
    Map<String, String>? environment,
  }) : _env = environment ?? _platformEnvironment();

  final DiagnosticsReader _read;

  /// How many recent app errors are included.
  final int maxErrors;

  /// Per section (and per platform call inside one).
  final Duration timeout;

  /// The message count stops here (a corrupted, cyclic tree).
  final int maxMessages;
  final Map<String, String> _env;

  static Map<String, String> _platformEnvironment() {
    try {
      return Platform.environment;
    } on Object {
      return const {};
    }
  }

  Future<DiagnosticsBundle> collect() async {
    final now = _clock().now();
    final secrets = await _secretValues();
    final scrubber = DiagnosticsScrubber(knownSecrets: secrets, homePaths: await _privatePaths());

    // Shared between sections: provider refs (p1, p2…) stand in for ids.
    final configs = _safe(() => _read(providerRegistryProvider).configs) ?? const <ProviderConfig>[];
    final refs = {for (final (i, c) in configs.indexed) c.id: 'p${i + 1}'};
    final sessions = await _guard(() => _read(sessionStoreProvider).listSessions(includeArchived: true));
    final sessionList = sessions is List<SessionRecord> ? sessions : const <SessionRecord>[];
    final device = await _guard(() async => _read(perfDeviceReaderProvider)());
    final snapshot = device is DeviceSnapshot ? device : null;

    final raw = <String, Object?>{
      'format': DiagnosticsBundle.format,
      'version': DiagnosticsBundle.version,
      'generatedAt': now.toUtc().toIso8601String(),
      'notice': 'Diagnostics from Sherpa. It never contains chats, prompts, tool data, API keys, tokens, '
          'full URLs or file paths; text that looked like one was replaced by ${DiagnosticsScrubber.mask} or ${DiagnosticsScrubber.pathMask}.',
      'app': _app(),
      'os': _os(snapshot),
      'device': device is DeviceSnapshot
          ? _device(device)
          : (device == null ? {'unavailable': 'not reported by the platform'} : _unavailable(device)),
      'lastExit': snapshot?.lastExit == null ? null : _exit(snapshot!.lastExit!),
      'engine': await _section(_engine),
      'localModels': await _section(_localModels),
      'providers': await _section(() => _providers(configs, refs, sessionList)),
      'defaultModel': await _section(() async => _defaultModel(refs)),
      'mcpServers': await _section(_mcpServers),
      'context': await _section(() async => _context()),
      'data': await _section(() => _data(sessions), limit: timeout * 3),
      'errors': await _section(() async => _errors()),
      'perfLab': await _section(_perfLab),
    };
    final data = (scrubber.tree(raw)! as Map).cast<String, Object?>();
    return DiagnosticsBundle(data: data, summary: scrubber.text(diagnosticsSummary(data), limit: null), generatedAt: now);
  }

  // ---------------------------------------------------------------------------
  // Sections

  Map<String, Object?> _app() {
    final v = AppInfo.version;
    final plus = v.indexOf('+');
    return {
      'name': AppInfo.name,
      'version': plus < 0 ? v : v.substring(0, plus),
      'build': plus < 0 ? null : v.substring(plus + 1),
      'buildMode': kDebugMode ? 'debug' : (kProfileMode ? 'profile' : 'release'),
      'flutter': AppInfo.flutterVersion,
      'dart': AppInfo.dartVersion,
      'frameworkRevision': AppInfo.frameworkRevision,
    };
  }

  Map<String, Object?> _os(DeviceSnapshot? d) => {
        'platform': d?.platform.name ?? _safe(() => Platform.operatingSystem),
        'version': d?.osVersion,
        'apiLevel': d?.apiLevel,
        'processors': _safe(() => Platform.numberOfProcessors),
      };

  Map<String, Object?> _device(DeviceSnapshot d) => {
        'manufacturer': d.manufacturer,
        'model': d.model,
        'displayModel': d.displayModel,
        'machine': d.machine,
        'hardware': d.hardware,
        'socManufacturer': d.socManufacturer,
        'socModel': d.socModel,
        'cpuClass': d.cpuClass.name,
        'cpu': {
          'cores': d.cpu.cores,
          'performanceCores': d.cpu.performanceCores,
          'peakFreqKHz': d.cpu.peakFreqKHz,
          'features': d.cpu.features.toList()..sort(),
        },
        'totalRamBytes': d.totalRamBytes,
        'advertisedRamBytes': d.advertisedRamBytes,
        'availableRamBytes': d.availableRamBytes,
        'perProcessLimitHintBytes': d.perProcessLimitHintBytes,
        'appFootprintBytes': d.appFootprintBytes,
        'isLowRamDevice': d.isLowRamDevice,
        'freeStorageBytes': d.freeStorageBytes,
        'totalStorageBytes': d.totalStorageBytes,
        'thermal': d.thermal.name,
        'batterySaver': d.lowPowerMode,
        'batteryLevel': d.batteryLevel,
        'charging': d.charging,
        'capturedAt': d.capturedAt.toUtc().toIso8601String(),
      };

  /// The OS's description of an exit is kept only when it is a short code
  /// ("MemoryLimiter:AnonSwap"), never free text.
  static final RegExp _codeLike = RegExp(r'^[A-Za-z0-9_.:=\- ]{1,80}$');

  static final RegExp _processName = RegExp(r'^[A-Za-z0-9_.:]{1,80}$');

  Map<String, Object?> _exit(ExitForensics e) {
    final s = e.summary;
    return {
      'kind': e.kind.name,
      'reason': e.reason,
      'reasonName': e.reasonName,
      'at': e.timestamp.toUtc().toIso8601String(),
      'description': e.description == null ? null : (_codeLike.hasMatch(e.description!) ? e.description : '«omitted»'),
      'status': e.status,
      'importance': e.importance,
      'pssBytes': e.pssBytes,
      'rssBytes': e.rssBytes,
      'processName': e.processName == null || !_processName.hasMatch(e.processName!) ? null : e.processName,
      'wasMemoryKill': e.wasMemoryKill,
      // What the process was doing: phase, hashed model id, backend, context.
      'processState': s == null
          ? null
          : {
              'phase': s.phase.name,
              'modelHash': s.modelHash,
              'backend': s.backend,
              'contextTokens': s.contextTokens,
              'foreground': s.foreground,
            },
    };
  }

  Future<Map<String, Object?>> _engine() async {
    final LocalInference? local = _read(localInferenceProvider);
    if (local == null) return {'wired': false};
    final LocalEngineStatus s = local.status;
    Map<String, Object?>? system;
    final host = local.host;
    if (s.isReady && host != null) {
      final json = await _guard(host.systemInfoJson);
      system = json is String ? engineSystemInfo(json) : _unavailable(json);
    }
    return {
      'wired': true,
      'state': s.state.name,
      'hostKind': s.hostKind?.name ?? host?.kind.name,
      'engineVersion': s.engineVersion,
      'reason': s.reason,
      'canRetry': s.canRetry,
      'systemInfo': system,
      'lastCrash': s.crashReport == null ? null : _crash(s.crashReport!),
    };
  }

  Map<String, Object?> _crash(EngineCrashReport r) => {
        'phase': r.phase.phase.name,
        'at': r.phase.at.toUtc().toIso8601String(),
        'modelHash': r.phase.modelId == null ? null : ProcessStateSummary.hashModelId(r.phase.modelId!),
        'contextTokens': r.phase.nCtx,
        'kv': r.phase.kvLayout,
        'nativeAbort': r.isNativeAbort,
        // A ggml assert ("GGML_ASSERT(...) failed"); paths in it are masked.
        'engineMessage': r.engineMessage,
        'whileGenerating': r.phase.phase == InferencePhase.generating,
      };

  /// The engine's `se_system_info_json`, field by field. Left out on
  /// purpose: `backend_init` (a free-text report that can name library
  /// paths) and anything a newer engine adds until it is listed here.
  static Map<String, Object?> engineSystemInfo(String json) {
    final j = (jsonDecode(json) as Map).cast<String, Object?>();
    Object? scalar(Object? v) => v is num || v is bool || v is String ? v : null;
    Map<String, Object?> pick(Object? m, List<String> keys) {
      if (m is! Map) return const {};
      return {for (final k in keys) if (m[k] != null) k: scalar(m[k])};
    }

    Map<String, Object?> flags(Object? m) {
      if (m is! Map) return const {};
      return {for (final e in m.entries) '${e.key}': scalar(e.value)};
    }

    final cpu = j['cpu'];
    return {
      ...pick(j, const ['engine', 'abi_version', 'llama_commit', 'ggml_version', 'backend_dl', 'mtmd', 'cpu_variant']),
      'backends': [
        for (final b in (j['backends'] as List?) ?? const <Object?>[]) pick(b, const ['name', 'n_devices']),
      ],
      'cpu_backend_features': flags(j['cpu_backend_features']),
      'devices': [
        for (final d in (j['devices'] as List?) ?? const <Object?>[])
          pick(d, const ['name', 'description', 'type', 'memory_free', 'memory_total']),
      ],
      'cpu': {
        ...pick(cpu, const ['arch', 'logical_cores', 'physical_cores', 'performance_cores', 'default_threads']),
        'features': flags(cpu is Map ? cpu['features'] : null),
      },
      'supports': flags(j['supports']),
    };
  }

  Future<List<Object?>> _localModels() async {
    final library = _read(modelLibraryProvider);
    await library.load().timeout(timeout);
    return [for (final m in library.models) _localModel(m)];
  }

  /// Library ids are hashed like the process state summary does, so a
  /// crash's `modelHash` can be matched. Public Hub repos are named; an
  /// imported file is described by its format only (its name is the
  /// user's).
  Map<String, Object?> _localModel(LibraryModel m) => {
        'id': ProcessStateSummary.hashModelId(m.id),
        'source': m.source.name,
        'repo': m.source == LibrarySource.hub ? m.repo : null,
        'format': m.format.name,
        'quant': m.quant,
        'architecture': m.architecture,
        'parameterCount': m.parameterCount,
        'contextLength': m.contextLength,
        'sizeBytes': m.sizeBytes,
        'issue': m.issue.name,
        'hasDraft': m.draftPath != null,
        'hasVision': m.mmprojPath != null,
      };

  Future<List<Object?>> _providers(List<ProviderConfig> configs, Map<String, String> refs, List<SessionRecord> sessions) async {
    final registry = _read(providerRegistryProvider);
    final out = <Object?>[];
    for (final c in configs) {
      final key = await _guard(() => registry.hasApiKey(c.id));
      final used = <String, int>{};
      for (final s in sessions) {
        if (s.providerId == c.id && s.modelId != null) used[s.modelId!] = (used[s.modelId!] ?? 0) + 1;
      }
      out.add({
        'ref': refs[c.id],
        'flavor': c.flavor.name,
        'profile': c.profile.name,
        'scheme': c.baseUrl.scheme,
        'host': hostLabel(c.baseUrl),
        'location': locationOf(c).name,
        'unverifiedLocal': isUnverifiedLocal(c),
        'allowLocalNetwork': c.allowLocalNetwork,
        'apiKeySet': key is bool ? key : null,
        'customHeaders': c.headers.length,
        'defaultModelId': c.defaultModelId,
        'modelOverrides': c.modelOverrides.keys.toList()..sort(),
        'modelsInChats': used,
      });
    }
    return out;
  }

  Map<String, Object?>? _defaultModel(Map<String, String> refs) {
    final choice = _read(preferencesProvider).defaultModel;
    if (choice == null) return null;
    final onDevice = isOnDeviceProviderId(choice.providerId);
    return {
      'provider': onDevice ? choice.providerId : (refs[choice.providerId] ?? 'removed'),
      'modelId': onDevice ? ProcessStateSummary.hashModelId(choice.modelId) : choice.modelId,
    };
  }

  Future<List<Object?>> _mcpServers() async {
    final views = _read(mcpServersProvider);
    final rt = _safe(() => _read(mcpRuntimeProvider));
    final out = <Object?>[];
    for (final (i, v) in views.indexed) {
      final creds = rt == null || v.builtIn ? null : await _guard(() => rt.oauth.hasCredentials(v.id));
      out.add(_mcpServer(v, 'm${i + 1}', creds is bool ? creds : null));
    }
    return out;
  }

  Map<String, Object?> _mcpServer(McpServerView v, String ref, bool? credentials) {
    final c = v.config;
    final h = v.health;
    return {
      'ref': ref,
      'builtIn': v.builtIn,
      'source': v.meta?.source.name,
      'host': v.builtIn ? 'on-device' : hostLabel(c.url),
      'scheme': v.builtIn ? null : c.url.scheme,
      'transport': c.transport.name,
      'era': h.era?.name ?? _cachedEra(c),
      'protocolVersion': h.protocolVersion,
      'enabled': c.enabled,
      'trusted': c.trusted,
      'allowLocalNetwork': c.allowLocalNetwork,
      'status': v.status.name,
      'lastErrorType': errorTypeOf(h.lastError),
      'lastErrorCode': errorCodeOf(h.lastError),
      'lastErrorAt': h.lastErrorAt?.toUtc().toIso8601String(),
      'reconnectAttempts': h.reconnectAttempts,
      'latencyMs': h.latency?.inMilliseconds,
      'toolCount': v.tools.length,
      'pendingReviews': v.pendingReviews,
      'flaggedTools': v.flaggedTools,
      'needsSignIn': v.auth.needsConsent,
      'signInFailed': v.auth.failure != null,
      'hasCredentials': credentials,
      'customHeaders': c.headers.length,
    };
  }

  String? _cachedEra(McpServerConfig c) {
    try {
      return c.cachedVerdict?.era.name;
    } on Object {
      return null;
    }
  }

  static final RegExp _leadingType = RegExp(r'^([A-Z][A-Za-z0-9_]{2,60})(?=[:(]|$)');

  /// The exception type at the start of a recorded error (`McpTimeoutException: …`).
  static String? errorTypeOf(String? raw) => raw == null ? null : _leadingType.firstMatch(raw.trim())?[1];

  /// A short category for a recorded error string; never its text.
  static String? errorCodeOf(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final r = raw.toLowerCase();
    final http = RegExp(r'\bhttp (\d{3})\b').firstMatch(r);
    if (r.startsWith('mcpauthrequiredexception')) return 'auth_required';
    if (http != null) return 'http_${http[1]}';
    if (r.contains('connection refused')) return 'connection_refused';
    if (r.contains('failed host lookup')) return 'dns';
    if (r.contains('socketexception')) return 'socket';
    if (r.contains('handshakeexception') || r.contains('certificate')) return 'tls';
    if (r.contains('timeout') || r.contains('timed out') || r.contains('took longer')) return 'timeout';
    if (r.contains('the device is offline') || r.contains('network unavailable')) return 'offline';
    if (r.startsWith('mcperanegotiationexception') || r.startsWith('mcpunsupportedversionexception')) {
      return 'version_mismatch';
    }
    if (r.startsWith('mcpsessionexpiredexception')) return 'session_expired';
    if (r.startsWith('mcpprotocolexception') || r.startsWith('jsonrpcformatexception')) return 'protocol';
    final rpc = RegExp(r'\(code (-?\d{1,6})\)').firstMatch(r);
    if (rpc != null) return 'rpc_${rpc[1]}';
    if (r.contains('no on-device server')) return 'builtin_unavailable';
    return 'other';
  }

  Map<String, Object?> _context() {
    final config = _read(chatAgentConfigProvider);
    final c = config.contextSettings;
    final ui = _safe(() => _read(uiSettingsProvider));
    final manager = _safe(() => _read(chatContextManagerProvider));
    return {
      'manager': manager == null ? null : AppErrorRing.typeNameOf(manager),
      'modelWrittenSummaries': ui?.modelSummaries,
      'agent': {
        'maxSteps': config.maxSteps,
        'maxParallelTools': config.maxParallelTools,
        'toolTimeoutS': config.toolTimeout.inSeconds,
        'providerRetries': config.providerRetries,
      },
      'settings': {
        'thresholds': {'prune': c.thresholds.prune, 'compact': c.thresholds.compact, 'handoff': c.thresholds.handoff},
        'windowProfile': c.profile != null,
        'keepRecentTurns': c.keepRecentTurns,
        'keepRecentToolCalls': c.keepRecentToolCalls,
        'outputReserveTokens': c.outputReserveTokens,
        'estimateSafetyFraction': c.estimateSafetyFraction,
        'uncalibratedSafetyFraction': c.uncalibratedSafetyFraction,
        'largeToolResultTokens': c.largeToolResultTokens,
        'largeToolInputTokens': c.largeToolInputTokens,
        'smallErrorResultTokens': c.smallErrorResultTokens,
        'staleAfterTurns': c.staleAfterTurns,
        'elideKeepLines': c.elideKeepLines,
        'excludedTools': c.excludedTools.length,
        'autoCompact': c.autoCompact,
        'autoHandoff': c.autoHandoff,
        'maxSummaryTokens': c.maxSummaryTokens,
        'handoffAfterCompactions': c.handoffAfterCompactions,
        'minCompactionGain': c.minCompactionGain,
        'maxPostCompactionRatio': c.maxPostCompactionRatio,
      },
    };
  }

  /// Counts only: the messages are walked (every branch) but never read.
  Future<Map<String, Object?>> _data(Object? sessions) async {
    final store = _read(sessionStoreProvider);
    final inner = store is ObservableSessionStore ? store.inner : store;
    final list = sessions is List<SessionRecord> ? sessions : null;
    var messages = 0;
    var truncated = false;
    if (list != null) {
      final deadline = DateTime.now().add(timeout * 2);
      outer:
      for (final s in list) {
        final queue = <String?>[null];
        final seen = <String>{};
        while (queue.isNotEmpty) {
          if (messages >= maxMessages || DateTime.now().isAfter(deadline)) {
            truncated = true;
            break outer;
          }
          for (final m in await store.children(s.id, queue.removeAt(0))) {
            if (!seen.add(m.id)) continue;
            messages++;
            queue.add(m.id);
          }
        }
      }
    }
    final size = await _guard(() => _read(diagnosticsDatabaseSizeProvider)());
    return {
      'storage': inner is InMemorySessionStore ? 'memory' : AppErrorRing.typeNameOf(inner),
      'chats': list?.length,
      'archivedChats': list?.where((s) => s.archived).length,
      'messages': list == null ? null : messages,
      'messagesTruncated': truncated,
      'databaseBytes': size is int ? size : null,
    };
  }

  Map<String, Object?> _errors() {
    final ring = _read(appErrorRingProvider);
    return {
      'kept': ring.records.length,
      'dropped': ring.dropped,
      'recent': [for (final r in ring.last(maxErrors)) r.toJson()],
    };
  }

  Future<Map<String, Object?>> _perfLab() async {
    final lab = _read(perfLabProvider);
    if (lab == null) return {'available': false};
    final library = _read(modelLibraryProvider);
    await library.load().timeout(timeout);
    final models = <Object?>[];
    for (final m in library.models) {
      final runs = await lab.history.list(m.id).timeout(timeout);
      if (runs.isEmpty) continue;
      final last = runs.last;
      models.add({
        'id': ProcessStateSummary.hashModelId(m.id),
        'runs': runs.length,
        'lastAt': last.at.toUtc().toIso8601String(),
        'method': last.method.name,
        'backend': last.sample.backend,
        'decodeTps': _round(last.sample.decodeTps),
        'prefillTps': _round(last.sample.prefillTps),
        'ttftMs': _round(last.sample.ttftMs),
        'bestDecodeTps': _round(runs.map((r) => r.sample.decodeTps).reduce((a, b) => a > b ? a : b)),
        'threads': last.config.nThreads,
        'batch': last.config.nBatch,
        'kv': last.config.kv.name,
        'flashAttention': last.config.flashAttention.name,
        'peakMemoryBytes': last.sample.peakMemoryBytes,
        'thermalAfter': last.sample.thermalAfter?.name,
      });
    }
    return {'available': true, 'models': models};
  }

  static double _round(double v) => double.parse(v.toStringAsFixed(2));

  // ---------------------------------------------------------------------------
  // Plumbing

  Clock _clock() => _safe(() => _read(clockProvider)) ?? const SystemClock();

  /// Values from the secret store, for masking by value. Held in memory
  /// only while the bundle is built.
  Future<List<String>> _secretValues() async {
    final out = <String>[];
    try {
      final store = _read(secretStoreProvider);
      for (final key in await store.keys().timeout(timeout)) {
        final v = await store.read(key).timeout(timeout);
        if (v != null && v.isNotEmpty) out.add(v);
      }
    } on Object {
      // No store wired (tests); the patterns still apply.
    }
    return out;
  }

  Future<List<String>> _privatePaths() async {
    final out = <String>[
      for (final k in const ['HOME', 'USERPROFILE', 'TMPDIR'])
        if (_env[k] case final String v when v.isNotEmpty) v,
    ];
    final extra = await _guard(() => _read(diagnosticsPrivatePathsProvider)());
    if (extra is List<String>) out.addAll(extra);
    return out;
  }

  T? _safe<T>(T Function() f) {
    try {
      return f();
    } on Object {
      return null;
    }
  }

  /// The value, or the error it failed with (never thrown).
  Future<Object?> _guard(FutureOr<Object?> Function() f, {Duration? limit}) async {
    try {
      return await Future.sync(f).timeout(limit ?? timeout);
    } on Object catch (e) {
      return _Failure(e);
    }
  }

  Future<Object?> _section(FutureOr<Object?> Function() f, {Duration? limit}) async {
    final v = await _guard(f, limit: limit);
    return v is _Failure ? _unavailable(v) : v;
  }

  Map<String, Object?> _unavailable(Object? v) => {
        'unavailable': v is _Failure ? AppErrorRing.typeNameOf(v.error) : 'none',
      };
}

final class _Failure {
  const _Failure(this.error);

  final Object error;
}
