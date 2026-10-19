import 'dart:async';

import 'package:flutter/services.dart';
import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart' show ModelFormat;

import '../backend.dart';
import '../common/availability.dart';
import '../common/errors.dart';
import '../common/event_router.dart';
import '../common/foreground.dart';
import '../common/native_generation.dart';
import '../messages.pigeon.dart';
import 'conversation_cache.dart';
import 'event_mapper.dart';
import 'model_spec.dart';
import 'request_mapper.dart';

/// `ComponentCallbacks2.TRIM_MEMORY_BACKGROUND`.
const int kTrimMemoryBackground = 40;

/// Policy knobs of [LiteRtLmProvider].
@immutable
final class LiteRtLmOptions {
  const LiteRtLmOptions({
    this.releaseAtTrimLevel = kTrimMemoryBackground,
    this.maxLiveConversations = 1,
    this.benchmark = true,
    this.waitForForegroundAfterRelease = true,
  });

  /// `onTrimMemory` level at or above which Kotlin stops a running turn at
  /// the next token (the reply ends with `Finish(pause)`) and frees the
  /// engine; 0 never does. On API 34+ only UI_HIDDEN (20) and BACKGROUND
  /// (40) are delivered (R07 §2.1); 40 means "the app is in the background
  /// LRU list", the right moment to give back gigabytes.
  final int releaseAtTrimLevel;

  /// Native conversations kept open (each holds a KV cache).
  final int maxLiveConversations;

  /// Per-turn TTFT and prefill/decode counts (`ExperimentalFlags.enableBenchmark`)
  /// for usage and perf events.
  final bool benchmark;

  /// After a memory-pressure release, the next request waits for the app to
  /// come back to the foreground instead of reloading gigabytes in the
  /// background (where it would likely be killed).
  final bool waitForForegroundAfterRelease;
}

/// [ModelProvider] for `.litertlm` models on Android through LiteRT-LM
/// 0.18.0 (CPU/GPU, NPU for SoC-specific files).
///
/// * Models are registered with [register] ([LiteRtModelSpec]: id + path).
/// * One engine at a time (weights are GBs); switching models reloads.
/// * One turn at a time (a FIFO lock); requests queue.
/// * History: the native `Conversation` is a cache of one exact transcript
///   prefix; edits, branches, retries, compaction and interrupted turns
///   rebuild it from the request ([ConversationCache]).
/// * Tools: native function calling when the chat template renders tools
///   ([usesNativeTools], probed at load), else the prompted JSON format
///   parsed in Dart.
/// * Memory: `onTrimMemory` ≥ [LiteRtLmOptions.releaseAtTrimLevel] stops the
///   turn at a token boundary (`Finish(pause)`) and frees the engine.
/// * Background: allowed (Android may keep the process alive with
///   sherpa_platform's foreground service).
///
/// On iOS and desktop it compiles and reports [AvailabilityState.unsupported].
final class LiteRtLmProvider implements ModelProvider {
  LiteRtLmProvider({
    LiteRtBackend? backend,
    AppForeground? foreground,
    Iterable<LiteRtModelSpec> models = const [],
    this.options = const LiteRtLmOptions(),
    this.id = 'litert_lm',
    this.displayName = 'On-device (LiteRT-LM)',
    this.cancelGrace = const Duration(seconds: 2),
  })  : backend = backend ?? SherpaLitert.backend,
        _foreground = foreground,
        _cache = ConversationCache(maxLive: options.maxLiveConversations) {
    for (final m in models) {
      register(m);
    }
  }

  final LiteRtBackend backend;
  final LiteRtLmOptions options;
  final String id;
  final String displayName;
  final Duration cancelGrace;

  AppForeground? _foreground;
  AppForeground get foreground => _foreground ??= WidgetsAppForeground();

  late final LiteRtEventRouter _router = routerFor(backend);
  final ConversationCache _cache;
  final TurnLock _lock = TurnLock();
  final Map<String, LiteRtModelSpec> _models = {};
  final Map<String, LiteRtModelInfo> _infos = {};

  /// Load-time template probe per file path.
  final Map<String, bool?> _toolTemplate = {};
  PlatformInfoMsg? _platform;
  _Loaded? _loaded;
  bool _releasedForMemory = false;
  Future<void>? _attach;
  StreamSubscription<LiteRtEvent>? _globalSub;
  StreamSubscription<bool>? _fgSub;

  /// True for files this provider loads (`.litertlm`).
  static bool supportsFile(String path) => path.toLowerCase().endsWith('.litertlm');

  /// True for library models this provider serves.
  static bool supportsFormat(ModelFormat format) => format == ModelFormat.litert;

  @override
  ProviderInfo get info =>
      ProviderInfo(id: id, kind: ProviderKind.localLiteRt, displayName: displayName, location: ExecutionLocation.onDevice);

  List<LiteRtModelSpec> get models => List.unmodifiable(_models.values);

  /// Adds or replaces a model. Replacing the loaded one takes effect at its
  /// next load.
  void register(LiteRtModelSpec spec) {
    _models[spec.id] = spec;
    if (_loaded?.specId == spec.id) _loaded = null;
  }

  void unregister(String modelId) => _models.remove(modelId);

  /// The backend that loaded the current model (`gpu`, `cpu`, `npu`), if any.
  String? get loadedBackend => _loaded?.backend;

  @override
  Future<List<ModelDescriptor>> listModels() async => [
        for (final s in _models.values)
          ModelDescriptor(
            id: s.id,
            providerId: id,
            displayName: s.label,
            capabilities: _infos[s.path] == null
                ? _guessCapabilities(s)
                : liteRtCapabilities(s, _infos[s.path]!, templateRendersTools: _toolTemplate[s.path]),
          ),
      ];

  ModelCapabilities _guessCapabilities(LiteRtModelSpec s) => ModelCapabilities(
        contextLength: s.contextLength ?? kDefaultLiteRtContext,
        toolCallFormat: s.toolCalling ? ToolCallFormat.prompted : ToolCallFormat.none,
        parallelToolCalls: false,
        tokenizerFamily: s.tokenizerFamily ?? guessTokenizerFamily(s.path),
        parameterCount: s.parameterCount,
        supportsPromptCache: true,
        historyPolicy: HistoryPolicy.appendOnly,
      );

  /// Reads the file's metadata (`ModelInfo.from`, no weights loaded).
  @override
  Future<ModelCapabilities> capabilities(String modelId) async {
    final spec = _spec(modelId);
    return liteRtCapabilities(spec, await inspect(spec.path), templateRendersTools: _toolTemplate[spec.path]);
  }

  /// `ModelInfo.from(path)`, cached per path.
  Future<LiteRtModelInfo> inspect(String path) async {
    final cached = _infos[path];
    if (cached != null) return cached;
    if (!backend.isSupported) {
      throw ProviderException(ProviderErrorKind.unsupported, 'LiteRT-LM runs on Android only.', providerId: id);
    }
    try {
      return _infos[path] = LiteRtModelInfo.fromMsg(await backend.inspectModel(path));
    } on Object catch (e) {
      throw hostError(e, providerId: id);
    }
  }

  /// Whether the `.litertlm` file at [path] can run on this device, and why
  /// not. Never throws. `downloadable` does not apply (the model library
  /// downloads files).
  Future<ProviderAvailability> availability(String path) async {
    if (!backend.isSupported) {
      return const ProviderAvailability.unsupported('not_android', 'LiteRT-LM models run on Android only.');
    }
    if (!supportsFile(path)) {
      return const ProviderAvailability.unsupported(
          'unsupported_format', 'Only .litertlm files run on LiteRT-LM (legacy MediaPipe .task bundles do not).');
    }
    final PlatformInfoMsg platform;
    try {
      platform = await _platformInfo();
    } on MissingPluginException {
      return const ProviderAvailability.unsupported(
          'plugin_missing', 'The sherpa_litert plugin is not registered in this build.');
    } on Object catch (e) {
      return ProviderAvailability.unsupported('runtime_missing', 'LiteRT-LM could not start: $e');
    }
    if (!platform.liteRtAvailable) {
      return ProviderAvailability.unsupported(
        'runtime_missing',
        'LiteRT-LM does not run on this device (its native library ships for 64-bit ARM and x86_64 only).',
        details: {'error': platform.liteRtError, 'abis': platform.supportedAbis},
      );
    }
    _infos.remove(path); // re-read: the file may have changed
    final LiteRtModelInfo info;
    try {
      info = await inspect(path);
    } on ProviderException catch (e) {
      if (e.kind == ProviderErrorKind.modelNotFound) {
        return ProviderAvailability.unsupported('file_missing', 'The model file is missing: $path',
            details: {'path': path});
      }
      return ProviderAvailability.unsupported('inspect_failed', 'LiteRT-LM cannot read this file: ${e.message}',
          details: {'path': path});
    }
    if (!info.isLlm) {
      return ProviderAvailability.unsupported(
          'not_an_llm', 'This .litertlm file is not a language model (${info.modelType}).');
    }
    if (runtimeTooOld(info.minRuntimeVersion)) {
      return ProviderAvailability.unsupported('runtime_too_old',
          'This file needs LiteRT-LM ${info.minRuntimeVersion}; Sherpa bundles $kLiteRtLmVersion.',
          details: {'minRuntimeVersion': info.minRuntimeVersion});
    }
    final device = LiteRtDevice.fromMsg(platform);
    final backends = planBackends(info, device);
    if (backends.isEmpty) {
      return ProviderAvailability.unsupported(
        'wrong_soc',
        'This file is built for the ${info.socName ?? info.npuBrand ?? 'another'} NPU only; '
            'this phone has ${platform.socModel ?? 'an unknown chip'}. Download the CPU/GPU build instead.',
        details: {'socName': info.socName, 'npuBrand': info.npuBrand, 'deviceSoc': platform.socModel},
      );
    }
    return ProviderAvailability.available(
      reason: 'Runs on ${backends.first.toUpperCase()}${backends.length > 1 ? ' (falls back to ${backends.skip(1).map((b) => b.toUpperCase()).join(', ')})' : ''}.',
      details: {
        'backends': backends,
        'maxContextTokens': info.maxContextTokens,
        'functionCalling': info.supportsFunctionCalling,
        'thinking': info.supportsThinking,
        'vision': info.vision,
        if (info.npuBrand != null) 'npuBrand': info.npuBrand,
        if (info.socName != null) 'socName': info.socName,
      },
    );
  }

  /// Frees the engine (and its conversations); a running turn ends with
  /// `Finish(pause)` first.
  Future<void> release({String reason = 'app'}) async {
    if (!backend.isSupported) return;
    try {
      await backend.releaseEngine(reason);
    } on Object catch (e) {
      throw hostError(e, providerId: id);
    }
    _loaded = null;
    _cache.clear();
  }

  Future<void> dispose() async {
    await _globalSub?.cancel();
    await _fgSub?.cancel();
    _globalSub = null;
    _fgSub = null;
  }

  @override
  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel}) =>
      _LiteRtGeneration(this, request, cancel).controller.stream;

  // ---------------------------------------------------------------------------

  LiteRtModelSpec _spec(String modelId) =>
      _models[modelId] ??
      (throw ProviderException(ProviderErrorKind.modelNotFound, 'No LiteRT-LM model "$modelId" is registered.',
          providerId: id));

  Future<PlatformInfoMsg> _platformInfo() async => _platform ??= await backend.platformInfo();

  Future<void> _attached() => _attach ??= () async {
        _globalSub ??= _router.globalEvents.listen(_onGlobal);
        if (options.waitForForegroundAfterRelease) {
          _fgSub ??= foreground.changes.listen((fg) {
            if (fg) _releasedForMemory = false;
          });
        }
        try {
          await backend.setTrimPolicy(options.releaseAtTrimLevel);
          // A hot-restarted isolate cannot know what the plugin still holds.
          await backend.releaseEngine('attach');
        } on Object catch (e) {
          _attach = null; // try again on the next request
          throw hostError(e, providerId: id);
        }
      }();

  void _onGlobal(LiteRtEvent e) {
    if (e.kind != EventKind.engineReleased || e.detail == 'reload') return;
    _forgetEngine(memory: e.detail == LiteRtCancelReason.memoryPressure);
  }

  /// The native engine is gone (or about to be): reload on the next turn.
  void _forgetEngine({bool memory = false}) {
    _loaded = null;
    _cache.clear();
    if (memory && options.waitForForegroundAfterRelease) _releasedForMemory = !foreground.isForeground;
  }

  Future<LoadResultMsg?> _ensureLoaded(LiteRtModelSpec spec, LiteRtModelInfo info) async {
    final platform = await _platformInfo();
    final backends = spec.backends ?? planBackends(info, LiteRtDevice.fromMsg(platform));
    if (backends.isEmpty) {
      throw ProviderException(ProviderErrorKind.unsupported,
          'This model file is built for the ${info.socName ?? info.npuBrand} NPU and cannot run on this phone.',
          providerId: id);
    }
    final request = LoadRequestMsg(
      path: spec.path,
      backends: backends,
      maxNumTokens: effectiveContext(spec, info),
      cpuThreads: spec.cpuThreads,
      cacheDir: platform.cacheDir,
      vision: spec.vision && info.vision,
      audio: false,
      benchmark: options.benchmark,
    );
    final key = '${spec.id}|${spec.path}|$backends|${request.maxNumTokens}|${request.cpuThreads}|'
        '${request.vision}|${request.benchmark}';
    if (_loaded?.key == key) return null;
    final result = await backend.loadEngine(request);
    if (!result.reused) _cache.clear();
    _toolTemplate[spec.path] = result.templateRendersTools;
    _loaded = _Loaded(spec.id, key, result.backend);
    return result;
  }

  Future<void> _waitForeground() {
    if (foreground.isForeground) return Future.value();
    return foreground.changes.firstWhere((fg) => fg).then((_) {});
  }

  /// The router shared by every provider on [backend] (one stream-id space).
  static LiteRtEventRouter routerFor(LiteRtBackend backend) => _routers[backend] ??= LiteRtEventRouter(backend);
  static final Expando<LiteRtEventRouter> _routers = Expando();
}

final class _Loaded {
  const _Loaded(this.specId, this.key, this.backend);

  final String specId;
  final String key;
  final String backend;
}

/// One `stream()` call.
final class _LiteRtGeneration extends NativeGeneration {
  _LiteRtGeneration(this.p, this.request, CancellationToken? cancel)
      : super(backend: p.backend, router: p._router, providerId: p.id, cancel: cancel, cancelGrace: p.cancelGrace);

  final LiteRtLmProvider p;
  final ModelRequest request;
  LiteRtEventMapper? _events;
  bool _done = false;

  @override
  Future<void> body() => p._lock.run(_turn);

  Future<void> _turn() async {
    if (listenerGone) throw const CancelledException();
    cancel?.throwIfCancelled();
    final spec = p._spec(request.modelId);
    if (!p.backend.isSupported) {
      throw ProviderException(ProviderErrorKind.unsupported, 'LiteRT-LM runs on Android only.', providerId: p.id);
    }
    await guard(p._attached());
    if (p._releasedForMemory && !p.foreground.isForeground) {
      emit(const ProviderNotice('waiting_for_foreground',
          'The on-device model was unloaded to free memory; it reloads when Sherpa is back on screen.'));
      await guard(p._waitForeground());
    }
    p._releasedForMemory = false;
    final info = await guard(p.inspect(spec.path));
    final LoadResultMsg? load;
    try {
      load = await guard(p._ensureLoaded(spec, info));
    } on CancelledException {
      rethrow;
    } on ProviderException {
      rethrow;
    } on Object catch (e) {
      throw hostError(e, providerId: p.id);
    }
    if (load != null && !load.reused) {
      emit(ProviderNotice('engine_loaded', 'Loaded ${spec.label} on ${load.backend.toUpperCase()}.',
          data: {'backend': load.backend, 'initMs': load.initMs, 'failures': load.failures}));
      if (load.failures.isNotEmpty) {
        emit(ProviderNotice('backend_fallback', 'Fell back to ${load.backend.toUpperCase()}: ${load.failures.join('; ')}',
            data: {'backend': load.backend, 'failures': load.failures}));
      }
    }

    final mapper = LiteRtRequestMapper(
        providerId: p.id, spec: spec, info: info, templateRendersTools: p._toolTemplate[spec.path]);
    final turn = mapper.map(request);
    for (final n in turn.notices) {
      emit(n);
    }
    final sessionKey = request.cache.sessionId ?? '_default';
    final plan = p._cache.plan(sessionKey: sessionKey, modelId: spec.id, turn: turn);
    if (plan is RebuildConversation) {
      for (final c in plan.close) {
        await p.backend.closeConversation(c).catchError((Object _) {});
      }
      try {
        await guard(p.backend.openConversation(turn.spec(plan.conversationId)));
      } on Object catch (e) {
        p._cache.forget(sessionKey);
        if (e is CancelledException) rethrow;
        // The engine may have been released under us (memory pressure, detach): reload next time.
        p._loaded = null;
        throw hostError(e, providerId: p.id);
      }
      p._cache.opened(sessionKey: sessionKey, conversationId: plan.conversationId, modelId: spec.id, turn: turn);
      if (plan.reason != RebuildReason.fresh) {
        emit(ProviderNotice('conversation_rebuilt', 'Rebuilt the on-device conversation (${plan.reason.name}).',
            data: {'reason': plan.reason.name, 'messages': turn.history.length}));
      }
    }

    final events = _events = LiteRtEventMapper(
      providerId: p.id,
      prompted: turn.promptedTools,
      toolNames: turn.toolNames,
      maxOutputTokens: turn.maxOutputTokens,
    );
    try {
      await pump((streamId) => p.backend.sendMessage(SendRequestMsg(
            streamId: streamId,
            conversationId: plan.conversationId,
            message: turn.tail,
            maxOutputTokens: turn.maxOutputTokens,
            enableThinking: turn.enableThinking,
            thinkingBudget: turn.thinkingBudget,
            responseSchemaJson: turn.responseSchemaJson,
          )));
    } finally {
      if (_done) {
        final reply = mapper.assistantMessage(events.text, events.calls, prompted: turn.promptedTools);
        p._cache.commit(
          sessionKey: sessionKey,
          turn: turn,
          replyKey: reply == null ? null : LiteRtRequestMapper.keyOf(reply),
        );
      } else {
        p._cache.invalidate(sessionKey);
      }
    }
  }

  @override
  void onEvent(LiteRtEvent e) {
    final events = _events!;
    for (final m in events.map(e, userCancelled: userCancelled, stopRequested: stopReason != null)) {
      emit(m);
    }
    if (e.kind == EventKind.done) _done = true;
    // Kotlin frees the engine right after a memory-pressure stop; the global
    // `engineReleased` may arrive after the agent loop's next request.
    if (e.kind == EventKind.cancelled && e.detail == LiteRtCancelReason.memoryPressure) p._forgetEngine(memory: true);
  }
}
