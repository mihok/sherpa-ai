import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;

import 'package:sherpa_core/sherpa_core.dart';

import '../availability.dart';
import '../backend.dart';
import '../common/errors.dart';
import '../common/event_router.dart';
import '../common/history_planner.dart';
import '../common/serial_queue.dart';
import '../common/think_splitter.dart';
import '../common/wire.dart';
import '../messages.pigeon.dart';
import 'mlx_config.dart';
import 'mlx_mapping.dart';
import 'mlx_model_dir.dart';

/// [ModelProvider] for MLX-format models (mlx-community) on iPhone and iPad,
/// through mlx-swift-lm 3.32.3 in Swift.
///
/// Stream contract (core `ModelProvider`): cold and single-subscription; a
/// cancel (token or subscription) stops decoding at the next token and ends
/// with `Finish(cancelled)`; exactly one [Finish] on success; failures are
/// [ProviderException]s. When the app resigns active Swift stops at a token
/// boundary (Metal refuses background command buffers and MLX's default
/// error handler would exit the process) and the reply ends with
/// `Finish(FinishReason.pause, rawReason: 'app_inactive')`; the agent loop
/// then continues it (a request that ends with the partial assistant
/// message), which waits natively until the app is active again.
///
/// Pausing the subscription stops delivery (credits are withheld, Swift
/// coalesces text) but not decoding: ChatSession streams are unbounded and
/// have no backpressure hook.
///
/// One generation runs at a time (one model, one GPU); others queue. The
/// history policy is [HistoryPlanner] (README "History policy").
final class MlxProvider implements ModelProvider {
  MlxProvider({
    AppleMlBackend? backend,
    this.id = 'mlx',
    this.displayName = 'On-device (MLX)',
    this.config = const MlxProviderConfig(),
    Iterable<MlxModelSpec> models = const [],
    IdGenerator? ids,
  }) : backend = backend ?? AppleMl.backend,
       _ids = ids ?? RandomIdGenerator() {
    for (final m in models) {
      _specs[m.id] = m;
    }
    _router = EventRouter.acquire(this.backend);
    _globalSub = _router.global.listen(_onGlobal);
  }

  final AppleMlBackend backend;
  final String id;
  final String displayName;
  final MlxProviderConfig config;
  final IdGenerator _ids;
  final Map<String, MlxModelSpec> _specs = {};
  final SerialQueue _queue = SerialQueue();
  final HistoryPlanner _planner = HistoryPlanner(appendShape: AppendShape.anyRoles);
  final Map<String, _SavedCache> _savedCaches = {};
  late final EventRouter _router;
  late final StreamSubscription<AmEvent> _globalSub;
  MlxLoadedModel? _loaded;

  /// Can MLX run the model in [directory] (or the file in it the library
  /// points at) on this device now?
  ///
  /// * unsupported: not iOS, iOS < 17, Simulator, no Metal device, a build
  ///   without MLX (CocoaPods), legacy `.npz` weights, a `model_type`
  ///   mlx-swift-lm 3.32.3 does not register, no chat template, or weights
  ///   that cannot fit the memory budget even with the minimum context;
  /// * downloadable: the directory, config.json, a weight shard or
  ///   tokenizer.json is missing;
  /// * available: otherwise (`details` has the planned context and sizes).
  static Future<AppleMlAvailability> availability(
    String directory, {
    AppleMlBackend? backend,
    MlxProviderConfig config = const MlxProviderConfig(),
    MlxModelSpec? spec,
  }) async {
    final b = backend ?? AppleMl.backend;
    if (!b.isSupported) {
      return const AppleMlAvailability(
        AppleMlStatus.unsupported,
        AppleMlReason.notIos,
        'MLX models run on iPhone and iPad only.',
      );
    }
    final platform = await b.platformInfo();
    final p = platformVerdict(platform);
    if (p != null) return p;
    final dir = await MlxModelDirectory.inspect(directory);
    final d = directoryVerdict(dir);
    if (d != null) return d;
    final admission = MlxAdmission.plan(
      dir: dir,
      spec: spec ?? MlxModelSpec(id: directory, directory: directory),
      procAvailableBytes: platform.procAvailableBytes,
      config: config,
    );
    final details = {
      'modelType': dir.modelType,
      'weightsBytes': dir.weightsBytes,
      'procAvailableBytes': platform.procAvailableBytes,
      'estimateBytes': admission.estimateBytes,
      'contextLength': admission.maxKVSize,
    };
    if (!admission.admitted) {
      return AppleMlAvailability(
        AppleMlStatus.unsupported,
        AppleMlReason.insufficientMemory,
        'Not enough memory on this device: ${admission.reason}.',
        details: details,
      );
    }
    return AppleMlAvailability.available(details: details);
  }

  /// Device-level verdict, or null when MLX can run here.
  static AppleMlAvailability? platformVerdict(AmPlatformInfo p) {
    final details = {'osVersion': p.osVersion};
    if (_osMajor(p.osVersion) < 17) {
      return AppleMlAvailability(
        AppleMlStatus.unsupported,
        AppleMlReason.osTooOld,
        'MLX needs iOS 17 or later.',
        details: details,
      );
    }
    if (p.isSimulator) {
      return AppleMlAvailability(
        AppleMlStatus.unsupported,
        AppleMlReason.simulator,
        'MLX cannot run on the iOS Simulator; use a device.',
        details: details,
      );
    }
    if (!p.hasMetalDevice) {
      return AppleMlAvailability(
        AppleMlStatus.unsupported,
        AppleMlReason.noMetalDevice,
        'This device has no Metal GPU.',
        details: details,
      );
    }
    if (!p.mlxCompiled) {
      return AppleMlAvailability(
        AppleMlStatus.unsupported,
        AppleMlReason.notCompiled,
        'This build of Sherpa does not include MLX (it needs the Swift Package Manager build).',
        details: details,
      );
    }
    return null;
  }

  /// Model-directory verdict, or null when the files are complete.
  static AppleMlAvailability? directoryVerdict(MlxModelDirectory dir) {
    if (!dir.exists || !dir.hasConfig) {
      return AppleMlAvailability(
        AppleMlStatus.downloadable,
        AppleMlReason.modelMissing,
        'Download the model first.',
        details: {'directory': dir.directory},
      );
    }
    if (dir.weightFiles.isEmpty && dir.hasNpzWeights) {
      return const AppleMlAvailability(
        AppleMlStatus.unsupported,
        AppleMlReason.legacyFormat,
        'Legacy MLX .npz weights are not supported; use a safetensors conversion.',
      );
    }
    if (!dir.isSupportedArchitecture) {
      return AppleMlAvailability(
        AppleMlStatus.unsupported,
        AppleMlReason.unsupportedArchitecture,
        'MLX on iOS does not support the "${dir.modelType ?? 'unknown'}" architecture.',
        details: {'modelType': dir.modelType},
      );
    }
    if (!dir.isComplete) {
      return AppleMlAvailability(
        AppleMlStatus.downloadable,
        AppleMlReason.modelIncomplete,
        'Some model files are missing; resume the download.',
        details: {
          'missingWeights': dir.missingWeightFiles,
          'hasTokenizer': dir.hasTokenizer,
          'weightFiles': dir.weightFiles.length,
        },
      );
    }
    if (!dir.hasChatTemplate) {
      return const AppleMlAvailability(
        AppleMlStatus.unsupported,
        AppleMlReason.unsupportedArchitecture,
        'The model has no chat template (a base model?), so it cannot chat.',
      );
    }
    return null;
  }

  static int _osMajor(String version) => int.tryParse(version.split('.').first) ?? 0;

  /// Registers (or replaces) a library model.
  void register(MlxModelSpec spec) => _specs[spec.id] = spec;

  void unregister(String modelId) => _specs.remove(modelId);

  List<MlxModelSpec> get models => List.unmodifiable(_specs.values);

  /// The natively loaded model, if any.
  MlxLoadedModel? get loaded => _loaded;

  /// Events not tied to a generation: `memoryWarning` (Swift already cleared
  /// the MLX buffer cache and dropped idle sessions) and `lifecycle`.
  Stream<AmEvent> get nativeEvents => _router.global;

  @override
  ProviderInfo get info =>
      ProviderInfo(id: id, kind: ProviderKind.localMlx, displayName: displayName, location: ExecutionLocation.onDevice);

  @override
  Future<List<ModelDescriptor>> listModels() async => [
    for (final s in _specs.values)
      ModelDescriptor(
        id: s.id,
        providerId: id,
        displayName: s.label,
        capabilities: _loaded?.spec.id == s.id
            ? _loaded!.capabilities
            : ModelCapabilities(
                contextLength: s.kv.maxKVSize ?? s.preferredContext,
                toolCallFormat: s.toolCalling ? ToolCallFormat.prompted : ToolCallFormat.none,
                parallelToolCalls: false,
                supportsPromptCache: true,
                historyPolicy: HistoryPolicy.appendOnly,
              ),
      ),
  ];

  /// Loads the model if needed (queued behind running generations), so the
  /// context length is the admitted one and the tool format is resolved.
  @override
  Future<ModelCapabilities> capabilities(String modelId) async {
    final l = _loaded;
    if (l != null && l.spec.id == modelId) return l.capabilities;
    final model = await _queue.run(() => _ensureLoaded(modelId));
    return model.capabilities;
  }

  Future<MlxLoadedModel> _ensureLoaded(String modelId) async {
    final current = _loaded;
    if (current != null && current.spec.id == modelId) return current;
    final spec = _specs[modelId];
    if (spec == null) {
      throw ProviderException(ProviderErrorKind.modelNotFound, 'No MLX model "$modelId" is installed.', providerId: id);
    }
    if (!backend.isSupported) {
      throw ProviderException(ProviderErrorKind.unsupported, 'MLX models run on iPhone and iPad only.', providerId: id);
    }
    try {
      final platform = await backend.platformInfo();
      final verdict = platformVerdict(platform);
      if (verdict != null) throw ProviderException(ProviderErrorKind.unsupported, verdict.message, providerId: id);
      final dir = await MlxModelDirectory.inspect(spec.directory);
      final d = directoryVerdict(dir);
      if (d != null) {
        throw ProviderException(
          d.status == AppleMlStatus.downloadable ? ProviderErrorKind.modelNotFound : ProviderErrorKind.unsupported,
          '${spec.label}: ${d.message}',
          providerId: id,
        );
      }
      if (current != null) await _unloadNow();
      final admission = MlxAdmission.plan(
        dir: dir,
        spec: spec,
        procAvailableBytes: platform.procAvailableBytes,
        config: config,
      );
      if (!admission.admitted) {
        throw ProviderException(
          ProviderErrorKind.outOfMemory,
          'Cannot load ${spec.label}: ${admission.reason}.',
          providerId: id,
        );
      }
      final info = await backend.mlxLoad(
        AmMlxLoadRequest(
          modelId: spec.id,
          directory: dir.directory,
          cacheLimitBytes: config.cacheLimitBytes,
          memoryLimitFraction: config.memoryLimitFraction,
        ),
      );
      _planner.clear();
      return _loaded = MlxLoadedModel(spec: spec, dir: dir, info: info, maxKVSize: admission.maxKVSize);
    } on ProviderException {
      rethrow;
    } on Object catch (e) {
      throw appleMlErrorFrom(e, providerId: id);
    }
  }

  /// Native lost state: memory warnings drop idle sessions (their keys are
  /// in `text`), an MLX error unloads the model.
  void _onGlobal(AmEvent e) {
    switch (e.kind) {
      case AmEventKind.memoryWarning:
        for (final key in (e.text ?? '').split('\n')) {
          if (key.isNotEmpty) _planner.invalidate(key);
        }
      case AmEventKind.notice when e.code == 'modelUnloaded':
        final modelId = e.text;
        if (modelId != null) _forgetLoaded(modelId);
      default:
        break;
    }
  }

  void _forgetLoaded(String modelId) {
    if (_loaded?.spec.id != modelId) return;
    _loaded = null;
    _planner.clear();
  }

  Future<void> _unloadNow() async {
    final l = _loaded;
    _loaded = null;
    _planner.clear();
    if (l != null) await backend.mlxUnload(l.spec.id);
  }

  /// Unloads the model (after the running generation), freeing its memory.
  Future<void> unload() => _queue.run(_unloadNow);

  /// Forgets a conversation: its native session (KV cache) and any saved
  /// prompt cache.
  Future<void> forgetConversation(String sessionId) async {
    _planner.invalidate(sessionId);
    final saved = _savedCaches.remove(sessionId);
    if (saved != null) {
      try {
        await File(saved.path).delete();
      } on FileSystemException {
        // already gone
      }
    }
    if (backend.isSupported) await backend.dropSession(AmEngine.mlx, sessionId);
  }

  /// Pauses every running MLX generation at a token boundary (`Finish(pause,
  /// rawReason: reason)`), e.g. when the thermal state turns critical.
  Future<void> interrupt(String reason) async {
    if (backend.isSupported) await backend.interruptAll(reason);
  }

  /// Saves [sessionId]'s KV cache (`ChatSession.saveCache`, a .safetensors
  /// file compatible with Python mlx-lm). With
  /// [MlxProviderConfig.restorePromptCaches] a later rebuild of exactly this
  /// prefix may start from it (README "Prompt caches").
  Future<bool> savePromptCache(String sessionId, String path) async {
    final ledger = _planner.ledger(sessionId);
    final model = _loaded;
    if (ledger == null || model == null) return false;
    final ok = await _queue.run(() => backend.mlxSavePromptCache(sessionId, path));
    if (ok) _savedCaches[sessionId] = _SavedCache(path, model.spec.id, List.of(ledger.committed));
    return ok;
  }

  /// Exact token count with the loaded model's tokenizer.
  Future<int> countTokens(String modelId, String text) async {
    await _queue.run(() => _ensureLoaded(modelId));
    return backend.mlxCountTokens(modelId, text);
  }

  @override
  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel}) =>
      _MlxRun(this, request, cancel).controller.stream;

  Future<void> dispose() async {
    await _globalSub.cancel();
    await _router.release();
  }
}

final class _SavedCache {
  _SavedCache(this.path, this.modelId, this.fingerprints);

  final String path;
  final String modelId;
  final List<String> fingerprints;
}

/// One `stream()` call.
final class _MlxRun {
  _MlxRun(this.p, this.request, this.cancel) {
    controller = StreamController<ModelEvent>(
      onListen: () => unawaited(_run()),
      onPause: _pause,
      onResume: _resume,
      onCancel: _onCancel,
    );
  }

  final MlxProvider p;
  final ModelRequest request;
  final CancellationToken? cancel;
  late final StreamController<ModelEvent> controller;

  CreditGate? _gate;
  bool _subscriberPaused = false;
  String? _generationId;
  Completer<void>? _done;
  Timer? _grace;
  bool _listenerGone = false;
  bool _cancelRequested = false;
  bool _finishSent = false;

  bool get _cancelled => cancel?.isCancelled ?? false;

  void _emit(ModelEvent e) {
    if (_listenerGone || controller.isClosed) return;
    if (e is Finish) {
      if (_finishSent) return;
      _finishSent = true;
    }
    controller.add(e);
  }

  void _pause() {
    _subscriberPaused = true;
    _gate?.hold();
  }

  void _resume() {
    _subscriberPaused = false;
    _gate?.release();
  }

  void _onCancel() {
    _listenerGone = true;
    _requestCancel();
  }

  void _requestCancel() {
    final id = _generationId;
    if (_cancelRequested || id == null) return;
    _cancelRequested = true;
    unawaited(p.backend.cancel(id).catchError((Object _) {}));
    // Let the terminal event through even when the subscriber is paused.
    _gate?.release();
    _grace = Timer(p.config.cancelGrace, () {
      final d = _done;
      if (d != null && !d.isCompleted) d.complete();
    });
  }

  Future<void> _run() async {
    try {
      await p._queue.run(_job, cancel: cancel);
    } on CancelledException {
      _emit(const Finish(FinishReason.cancelled));
    } on ProviderException catch (e) {
      _fail(e);
    } on Object catch (e) {
      _fail(appleMlErrorFrom(e, providerId: p.id));
    } finally {
      if (!controller.isClosed) await controller.close();
    }
  }

  void _fail(ProviderException e) {
    if (_listenerGone || controller.isClosed) return;
    if (_cancelled) {
      _emit(const Finish(FinishReason.cancelled));
      return;
    }
    controller.addError(e);
  }

  Future<void> _job() async {
    cancel?.throwIfCancelled();
    final sessionId = request.cache.sessionId;
    final ephemeral = sessionId == null;
    final sessionKey = sessionId ?? 'oneoff:${p._ids.next('mlxsession')}';
    // One retry when the native side lost state Dart still counted on: the
    // session was dropped on a memory warning (`sessionLost`) or the model
    // was unloaded after an MLX error (`modelUnloaded`).
    for (var attempt = 0; ; attempt++) {
      final model = await p._ensureLoaded(request.modelId);
      cancel?.throwIfCancelled();
      if (_listenerGone) return;
      final mapped = mapMlxRequest(request, model);
      if (attempt == 0) mapped.notices.forEach(_emit);
      final retry = await _generate(model, mapped, sessionKey, ephemeral, mayRetry: attempt == 0);
      if (!retry) return;
    }
  }

  /// Runs one native generation; true when it should be retried from a
  /// rebuilt plan.
  Future<bool> _generate(
    MlxLoadedModel model,
    MlxMappedRequest mapped,
    String sessionKey,
    bool ephemeral, {
    required bool mayRetry,
  }) async {
    final generationId = p._ids.next('mlxgen');
    final configKey = model.spec.id;
    var plan = p._planner.plan(sessionKey: sessionKey, configKey: configKey, messages: mapped.messages);
    String? cachePath;
    final saved = p._savedCaches[sessionKey];
    if (plan.mode == AmHistoryMode.rebuild &&
        p.config.restorePromptCaches &&
        saved != null &&
        saved.modelId == model.spec.id &&
        mapped.toolsJson == null &&
        plan.pending.length == 1 &&
        plan.pending.single.role == 'user' &&
        _sameFingerprints(saved.fingerprints, plan.history)) {
      plan = HistoryPlan(AmHistoryMode.restoreCache, const [], plan.pending, reason: 'prompt_cache');
      cachePath = saved.path;
    }
    if (plan.mode == AmHistoryMode.rebuild && plan.reason != 'new_session') {
      _emit(
        ProviderNotice(
          'session_rebuilt',
          'The on-device session was rebuilt (${plan.reason}); the prompt is read again.',
          data: {'reason': plan.reason, 'messages': plan.history.length + plan.pending.length},
        ),
      );
    }

    final info = model.info;
    final splitter = model.hasReasoning
        ? ThinkSplitter(
            start: info.reasoningStart!,
            end: info.reasoningEnd!,
            implicitEnds: [for (final s in info.reasoningImplicitEnds) s],
            primed: mapped.primedReasoning,
          )
        : ThinkSplitter.disabled();
    final mapper = MlxEventMapper(providerId: p.id, generationId: generationId, splitter: splitter);

    final route = p._router.open(generationId);
    final gate = _gate = CreditGate(route);
    if (_subscriberPaused) gate.hold();
    final done = _done = Completer<void>();
    route.listen(
      (batch) {
        for (final e in batch.events) {
          if (mapper.terminal != null) break;
          mapper.map(e).forEach(_emit);
        }
        gate.consumed(batch.seq);
        if (mapper.terminal != null && !done.isCompleted) done.complete();
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(appleMlErrorFrom(e, providerId: p.id));
      },
    );

    try {
      await p.backend.mlxGenerate(
        AmMlxGenerateRequest(
          generationId: generationId,
          modelId: model.spec.id,
          sessionKey: sessionKey,
          ephemeral: ephemeral,
          mode: plan.mode,
          instructions: mapped.instructions,
          history: plan.history,
          pending: plan.pending,
          partialAssistant: plan.partialAssistant,
          toolsJson: mapped.toolsJson,
          sampling: mapped.sampling,
          kv: mapped.kv,
          thinkingKey: mapped.thinkingKey,
          thinkingEnabled: mapped.thinkingEnabled,
          cachePath: cachePath,
        ),
      );
    } on Object catch (e) {
      route.close();
      p._planner.invalidate(sessionKey);
      final code = e is PlatformException ? e.code : null;
      if (mayRetry && (code == AppleMlErrorCode.sessionLost || code == AppleMlErrorCode.modelUnloaded)) {
        if (code == AppleMlErrorCode.modelUnloaded) p._forgetLoaded(model.spec.id);
        return true;
      }
      throw appleMlErrorFrom(e, providerId: p.id);
    }
    _generationId = generationId;
    if (cancel != null) unawaited(cancel!.whenCancelled.then((_) => _requestCancel()));
    if (_listenerGone) _requestCancel();
    try {
      await done.future;
    } finally {
      _grace?.cancel();
      route.close();
    }

    switch (mapper.terminal) {
      case NativeFinished(:final code):
        final reason = finishReasonForCode(code, sawToolCalls: mapper.sawToolCalls);
        final produced = mapper.produced;
        final recorded =
            produced != null &&
            (reason == FinishReason.stop || reason == FinishReason.length || reason == FinishReason.toolCalls);
        // A continued or cache-restored reply is not in a history-backed
        // native session: the next request rebuilds.
        if (!ephemeral &&
            recorded &&
            plan.mode != AmHistoryMode.continueAssistant &&
            plan.mode != AmHistoryMode.restoreCache) {
          p._planner.commit(sessionKey, configKey, mapped.messages, produced);
        } else {
          p._planner.invalidate(sessionKey);
        }
        _emit(Finish(_cancelled ? FinishReason.cancelled : reason, rawReason: code));
      case NativePaused(reason: final why):
        p._planner.invalidate(sessionKey);
        if (_cancelled) {
          _emit(const Finish(FinishReason.cancelled));
        } else if (mapper.sawToolCalls) {
          // The calls are complete: the reply ended with them.
          _emit(Finish(FinishReason.toolCalls, rawReason: why));
        } else {
          _emit(Finish(FinishReason.pause, rawReason: why));
        }
      case NativeFailed(:final error):
        p._planner.invalidate(sessionKey);
        throw error;
      case null:
        // Cancel grace expired without a native terminal.
        p._planner.invalidate(sessionKey);
        _emit(const Finish(FinishReason.cancelled));
    }
    return false;
  }

  static bool _sameFingerprints(List<String> saved, List<AmWireMessage> history) {
    if (saved.length != history.length) return false;
    for (var i = 0; i < saved.length; i++) {
      if (saved[i] != wireFingerprint(history[i])) return false;
    }
    return true;
  }
}
