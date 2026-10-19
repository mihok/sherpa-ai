import 'dart:async';
import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart';

import '../autotune/autotune.dart';
import '../cache/prefix_cache_store.dart';
import '../common/key_value_store.dart';
import '../engine/engine_host.dart';
import '../engine/engine_types.dart';
import '../ffi/bindings.dart';
import '../provider/model_info.dart';
import 'admission.dart';
import 'forensics.dart';

/// A model file the app can run, as registered by the model library.
@immutable
final class LocalModelSpec {
  const LocalModelSpec({
    required this.id,
    required this.path,
    this.displayName,
    this.identity,
    this.preferredContext = 8192,
    this.minContext = 2048,
    this.trainContext,
    this.toolCalling = true,
    this.chatTemplateOverride,
    this.mmprojPath,
    this.nGpuLayers = -1,
    this.loras = const [],
    this.sessionDefaults = const SessionConfig(),
  });

  /// The id requests use (`ModelRequest.modelId`).
  final String id;
  final String path;
  final String? displayName;

  /// Content identity for state files (`sha256:<hex>` of the GGUF, known
  /// from the download's verification). Null = the engine's quick
  /// fingerprint.
  final String? identity;

  /// The context to aim for; admission may shrink it.
  final int preferredContext;

  /// Below this the model is not worth loading (admission refuses).
  final int minContext;

  /// `<arch>.context_length` from the GGUF header, if known (caps
  /// [preferredContext] before the load).
  final int? trainContext;

  /// Sessions call tools: KV is never quantized below q8_0 (R11 §9.6.2).
  final bool toolCalling;
  final String? chatTemplateOverride;
  final String? mmprojPath;
  final int nGpuLayers;

  /// LoRA adapters (path, scale) applied to every session of this model.
  final List<(String, double)> loras;

  /// Base session parameters (seed, threads, batches); autotune and
  /// admission fill in the rest.
  final SessionConfig sessionDefaults;

  ModelLoadOptions get loadOptions => ModelLoadOptions(
        path: path,
        modelId: identity,
        nGpuLayers: nGpuLayers,
        chatTemplateOverride: chatTemplateOverride,
        mmprojPath: mmprojPath,
      );

  String get label => displayName ?? id;

  /// Canonical adapter set for cache keys.
  String get loraSet => loras.map((l) => '${l.$1}@${l.$2}').join(',');
}

/// What happens to a loaded model when the app goes to the background.
enum BackgroundPolicy {
  /// iOS: no GPU work in the background (Metal rejects command buffers) and
  /// a backgrounded app with a big footprint is the first jetsam victim.
  /// Generations stop at a token boundary (the reply finishes with
  /// `FinishReason.pause`), the KV prefix is saved, the model unloaded;
  /// [ModelLifecycleManager.acquire] waits for the foreground (R06 §6.1).
  pauseAndPersist,

  /// Android with a foreground service keeping the run alive: keep
  /// generating; save the KV prefix whenever idle as LMK insurance.
  persistOnly,

  /// Do nothing (host tests).
  none,
}

/// Admission refused to load a model.
final class AdmissionRefusedException implements Exception {
  const AdmissionRefusedException(this.plan);

  final AdmissionPlan plan;

  String get message => plan.refusal ?? 'not enough memory';

  @override
  String toString() => 'AdmissionRefusedException: $message';
}

// ---------------------------------------------------------------------------
// Events

@immutable
sealed class LifecycleEvent {
  const LifecycleEvent();
}

final class ModelLoadedEvent extends LifecycleEvent {
  const ModelLoadedEvent(this.spec, this.config, this.estimate, this.notes, this.loadTime);
  final LocalModelSpec spec;
  final SessionConfig config;
  final MemoryEstimate? estimate;
  final List<String> notes;
  final Duration loadTime;
}

final class ModelUnloadedEvent extends LifecycleEvent {
  const ModelUnloadedEvent(this.spec, this.reason);
  final LocalModelSpec spec;
  final String reason;
}

final class SessionDowngradedEvent extends LifecycleEvent {
  const SessionDowngradedEvent(this.spec, this.from, this.to, this.reason);
  final LocalModelSpec spec;
  final SessionConfig from;
  final SessionConfig to;
  final String reason;
}

final class AdmissionRefusedEvent extends LifecycleEvent {
  const AdmissionRefusedEvent(this.spec, this.plan);
  final LocalModelSpec spec;
  final AdmissionPlan plan;
}

final class EngineCrashDetectedEvent extends LifecycleEvent {
  const EngineCrashDetectedEvent(this.report, {this.downgradedContext});
  final EngineCrashReport report;

  /// The context cap now applied to that model, if any.
  final int? downgradedContext;
}

final class PrefixRestoredEvent extends LifecycleEvent {
  const PrefixRestoredEvent(this.conversation, this.outcome, this.tokens);
  final String conversation;
  final PrefixRestoreOutcome outcome;
  final int tokens;
}

final class PrefixSavedEvent extends LifecycleEvent {
  const PrefixSavedEvent(this.conversation, this.bytes);
  final String conversation;
  final int bytes;
}

// ---------------------------------------------------------------------------
// Loaded model + lease

/// The warm model: weights, one session, and what its KV cache holds.
final class LoadedModel {
  LoadedModel._(this.spec, this.model, this.info, this.session, this.sessionInfo, this.estimate);

  final LocalModelSpec spec;
  final EngineModel model;
  final EngineModelInfo info;
  EngineSession session;
  EngineSessionInfo sessionInfo;
  final MemoryEstimate? estimate;

  /// Conversation whose tokens the KV cache holds (core session id).
  String? conversation;

  /// [PrefixFingerprint] of the last request served.
  List<String> fingerprint = const [];

  /// Tokens in the KV after the last generation (prompt + completion).
  int historyTokens = 0;

  /// The KV holds tokens not yet persisted.
  bool dirty = false;
  int _leases = 0;

  SessionConfig get config => session.config;

  int get leases => _leases;

  /// Capabilities with the session's real, padded n_ctx.
  ModelCapabilities get capabilities =>
      info.capabilities(contextLength: sessionInfo.nCtx, ramBytes: sessionInfo.totalBytes == 0 ? null : sessionInfo.totalBytes);

  String get kvLayout => '${sessionInfo.typeK}/${sessionInfo.typeV}${sessionInfo.flashAttention ? '+fa' : ''}';

  PrefixCacheKey keyFor(String conversation) => PrefixCacheKey(
        sessionId: conversation,
        modelId: info.modelId,
        nCtx: sessionInfo.nCtx,
        kvLayout: kvLayout,
        loraSet: spec.loraSet,
      );
}

/// Permission to use the warm model for one job. Always [release] it.
final class ModelLease {
  ModelLease._(this._owner, this.loaded);

  final ModelLifecycleManager _owner;
  final LoadedModel loaded;
  bool _released = false;
  bool _generating = false;

  /// Set when the lifecycle manager stopped the running generation itself
  /// (`app_background`, `memory_pressure`): the provider then ends the reply
  /// with `FinishReason.pause` so the agent loop continues it later.
  String? interruptReason;

  EngineHost get host => _owner.host;
  SessionRef get session => loaded.session.ref;
  ModelRef get model => loaded.model.ref;
  EngineModelInfo get info => loaded.info;
  ModelCapabilities get capabilities => loaded.capabilities;

  /// Prepares the KV cache for [conversation] (saving the previous
  /// conversation's prefix and restoring this one's when they differ) and
  /// records the generating phase for crash forensics.
  Future<PrefixRestoreResult?> beginGeneration({String? conversation, List<String> fingerprint = const []}) async {
    _generating = true;
    final r = await _owner._bind(loaded, conversation, fingerprint);
    await _owner._phase(InferencePhase.generating, loaded);
    return r;
  }

  /// Records what the KV cache now holds.
  Future<void> endGeneration({required List<String> fingerprint, int promptTokens = 0, int completionTokens = 0}) async {
    _generating = false;
    loaded
      ..fingerprint = fingerprint
      ..historyTokens = promptTokens + completionTokens
      ..dirty = true;
    await _owner._phase(InferencePhase.idle, loaded);
  }

  void release() {
    if (_released) return;
    _released = true;
    if (_generating) {
      _generating = false;
      unawaited(_owner._phase(InferencePhase.idle, loaded));
    }
    _owner._release(this);
  }
}

// ---------------------------------------------------------------------------

/// Loads, sizes, keeps warm and unloads on-device models.
///
/// * **Admission control** before every load: `se_estimate_memory` dry runs
///   against a budget from a fresh [MemoryMonitor.sample] (and the
///   [DeviceProfile]) pick the largest context, then the best KV type, that
///   fits — or refuse with a clear reason ([planAdmission]). Weights are
///   mmapped, so the plan is made before loading (a loaded model already
///   shows up as used memory).
/// * **One main model warm.** Acquiring another model unloads the current
///   one when idle (saving its KV prefix first).
/// * **Memory pressure.** `critical`: stop the running generation at a token
///   boundary, persist the prefix, unload. `moderate`: recreate the session
///   smaller — f16 → q8_0 KV first, then half the context, q4_0 KV only for
///   sessions that do not call tools (R11 §9.6.2) — when idle.
/// * **Background** per [BackgroundPolicy] (iOS: pause, persist, unload).
/// * **Crash forensics.** The engine's crash breadcrumb and a phase file
///   ([EngineForensics]) are inspected by [start]; a crash or kill during
///   loading/generation halves that model's context for future loads and
///   is reported as [EngineCrashDetectedEvent].
/// * **Prefix cache.** Binds conversations to the session's KV cache via
///   [PrefixCacheStore] (see [ModelLease.beginGeneration]).
final class ModelLifecycleManager {
  ModelLifecycleManager({
    required this.host,
    MemoryMonitor? memory,
    this.device,
    this.policy = const AdmissionPolicy(),
    this.forensics,
    KeyValueStore? store,
    this.prefixCache,
    this.autotuner,
    this.backgroundPolicy = BackgroundPolicy.pauseAndPersist,
    this.minTokensToPersist = 256,
    this.onPhase,
    Clock clock = const SystemClock(),
  })  : _memory = memory,
        _store = store ?? InMemoryKeyValueStore(),
        _clock = clock;

  final EngineHost host;
  final MemoryMonitor? _memory;
  final DeviceProfile? device;
  final AdmissionPolicy policy;
  final EngineForensics? forensics;
  final KeyValueStore _store;
  final PrefixCacheStore? prefixCache;
  final Autotuner? autotuner;
  final BackgroundPolicy backgroundPolicy;

  /// KV prefixes shorter than this are not worth a state file.
  final int minTokensToPersist;

  /// Called on every phase transition (Android: `setProcessStateSummary`
  /// with [PhaseRecord.compactSummary], R07 §2.4).
  final void Function(PhaseRecord record)? onPhase;
  final Clock _clock;

  final Map<String, LocalModelSpec> _specs = {};
  final StreamController<LifecycleEvent> _events = StreamController.broadcast();
  LoadedModel? _loaded;
  Future<void> _lock = Future.value();
  final List<Completer<void>> _idleWaiters = [];
  Completer<void>? _foreground;
  StreamSubscription<MemoryState>? _memorySub;
  StreamSubscription<EngineHostEvent>? _hostSub;
  final Set<ModelLease> _leases = {};
  String? _pendingUnload;
  String? _pendingDowngrade;
  bool _started = false;

  Stream<LifecycleEvent> get events => _events.stream;

  LoadedModel? get loaded => _loaded;

  bool get isPaused => _foreground != null;

  List<LocalModelSpec> get models => _specs.values.toList();

  LocalModelSpec? spec(String id) => _specs[id];

  void register(LocalModelSpec spec) => _specs[spec.id] = spec;

  void unregister(String id) => _specs.remove(id);

  static String _downgradeKey(String modelId) => 'sherpa.lifecycle.downgrade.$modelId';

  /// Starts the engine, inspects the previous run's forensics and subscribes
  /// to memory and host signals. Returns the crash report, if any.
  Future<EngineCrashReport?> start() async {
    if (_started) return null;
    await host.start();
    _started = true;
    _hostSub = host.events.listen((e) {
      if (e is EngineHostCrashed && e.nativeStateLost) {
        _loaded = null; // handles of that epoch are stale
        for (final l in _leases) {
          l.interruptReason ??= 'engine_crashed';
        }
      }
    });
    _memorySub = _memory?.changes.listen((s) => unawaited(handleMemory(s)));
    await prefixCache?.open();
    final report = await forensics?.collect();
    if (report == null) return null;
    int? cap;
    final modelId = report.phase.modelId;
    final crashedCtx = report.phase.nCtx;
    if (modelId != null && crashedCtx != null &&
        (report.phase.phase == InferencePhase.generating || report.phase.phase == InferencePhase.loading)) {
      final specMin = _specs[modelId]?.minContext ?? 2048;
      cap = math.max(specMin, (crashedCtx ~/ 2) ~/ policy.contextStep * policy.contextStep);
      await _store.write(_downgradeKey(modelId), {
        'maxContext': cap,
        'reason': report.description,
        'at': _clock.now().toUtc().toIso8601String(),
      });
    }
    _events.add(EngineCrashDetectedEvent(report, downgradedContext: cap));
    return report;
  }

  /// The context cap recorded after a crash, if any.
  Future<int?> downgradeFor(String modelId) async => (await _store.read(_downgradeKey(modelId)))?.optInt('maxContext');

  Future<void> clearDowngrade(String modelId) => _store.delete(_downgradeKey(modelId));

  Future<T> _locked<T>(Future<T> Function() op) {
    final next = _lock.then((_) => op());
    _lock = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _phase(InferencePhase phase, LoadedModel? l, {LocalModelSpec? spec, SessionConfig? config}) async {
    final s = l?.spec ?? spec;
    final record = PhaseRecord(
      phase: phase,
      at: _clock.now(),
      modelId: s?.id,
      modelName: s?.displayName,
      nCtx: l?.sessionInfo.nCtx ?? config?.nCtx,
      kvLayout: l?.kvLayout ?? config?.kvLabel,
    );
    try {
      onPhase?.call(record);
    } on Object {
      // Forensics hooks must never break inference.
    }
    await forensics?.enter(record);
  }

  // ---------------------------------------------------------------------------
  // Acquire / release

  /// Returns a lease on [modelId], loading it (with admission control) when
  /// needed. Waits while the app is backgrounded under
  /// [BackgroundPolicy.pauseAndPersist]. Throws [AdmissionRefusedException]
  /// when it cannot fit.
  Future<ModelLease> acquire(String modelId, {CancellationToken? cancel}) async {
    final spec = _specs[modelId];
    if (spec == null) throw ArgumentError.value(modelId, 'modelId', 'not a registered on-device model');
    if (!_started) await start();
    while (_foreground != null) {
      final f = _foreground!.future;
      await (cancel == null ? f : Future.any([f, cancel.whenCancelled]));
      cancel?.throwIfCancelled();
    }
    return _locked(() async {
      cancel?.throwIfCancelled();
      var l = _loaded;
      if (l != null && (l.spec.id != modelId || l.model.ref.epoch != host.epoch)) {
        await _waitIdle();
        await _unloadLocked('switching to ${spec.label}');
        l = null;
      }
      l ??= await _loadLocked(spec, cancel: cancel);
      final lease = ModelLease._(this, l);
      l._leases++;
      _leases.add(lease);
      return lease;
    });
  }

  void _release(ModelLease lease) {
    if (!_leases.remove(lease)) return;
    final l = lease.loaded;
    l._leases--;
    if (l._leases > 0) return;
    for (final w in List.of(_idleWaiters)) {
      if (!w.isCompleted) w.complete();
    }
    _idleWaiters.clear();
    final unload = _pendingUnload;
    final downgrade = _pendingDowngrade;
    _pendingUnload = null;
    _pendingDowngrade = null;
    if (unload != null) {
      unawaited(_locked(() => _unloadLocked(unload)));
    } else if (downgrade != null) {
      unawaited(_locked(() => _downgradeLocked(downgrade)));
    }
  }

  Future<void> _waitIdle({Duration? timeout}) async {
    final l = _loaded;
    if (l == null || l._leases == 0) return;
    final c = Completer<void>();
    _idleWaiters.add(c);
    if (timeout == null) {
      await c.future;
    } else {
      await c.future.timeout(timeout, onTimeout: () {});
    }
  }

  // ---------------------------------------------------------------------------
  // Load / unload

  /// Admission control for [modelId] without loading anything.
  Future<AdmissionPlan> plan(String modelId) async {
    final spec = _specs[modelId];
    if (spec == null) throw ArgumentError.value(modelId, 'modelId', 'not a registered on-device model');
    if (!_started) await start();
    return _plan(spec);
  }

  Future<AdmissionPlan> _plan(LocalModelSpec spec) async {
    final tuned = await autotuner?.cached(spec.id);
    var base = spec.sessionDefaults;
    if (tuned != null) base = tuned.candidate.applyTo(base);
    final cap = await downgradeFor(spec.id);
    final preferred = cap == null ? spec.preferredContext : math.min(cap, spec.preferredContext);
    final preferredKv = tuned?.candidate.typeK;
    final ladder = <KvType>[
      if (preferredKv != null && preferredKv != KvType.f16 && preferredKv != KvType.q8_0) preferredKv,
      if (preferredKv == null || preferredKv == KvType.f16) KvType.f16,
      KvType.q8_0,
      if (!spec.toolCalling) KvType.q4_0,
    ];
    final state = await (_memory?.sample() ?? Future.value(MemoryState.unknown));
    final budget = MemoryBudget.from(state, device: device, policy: policy);
    final req = AdmissionRequest(
      base: base,
      preferredContext: preferred,
      minContext: math.min(spec.minContext, preferred),
      kvLadder: ladder,
      trainContext: spec.trainContext,
    );
    final plan = await planAdmission(req, budget, (c) => host.estimateMemory(spec.loadOptions, c), policy: policy);
    if (cap != null && plan.admitted) {
      return AdmissionPlan(
        config: plan.config,
        estimate: plan.estimate,
        budget: plan.budget,
        notes: ['context capped at $cap tokens after an earlier engine crash', ...plan.notes],
      );
    }
    return plan;
  }

  Future<LoadedModel> _loadLocked(LocalModelSpec spec, {CancellationToken? cancel}) async {
    final sw = Stopwatch()..start();
    final plan = await _plan(spec);
    if (!plan.admitted) {
      _events.add(AdmissionRefusedEvent(spec, plan));
      throw AdmissionRefusedException(plan);
    }
    var config = plan.config!;
    await _phase(InferencePhase.loading, null, spec: spec, config: config);
    EngineModel? model;
    try {
      model = await host.loadModel(spec.loadOptions, cancel: cancel);
      final info = EngineModelInfo.parse(model.infoJson);
      if (info.contextTrain > 0 && config.nCtx > info.contextTrain) config = config.copyWith(nCtx: info.contextTrain);
      EngineSession? session;
      for (var attempt = 0;; attempt++) {
        try {
          session = await host.createSession(model.ref, config);
          break;
        } on EngineException catch (e) {
          final memoryError = e.code == SeStatus.oom || e.code == SeStatus.contextCreate;
          final smaller = math.max(spec.minContext, config.nCtx ~/ 2);
          if (!memoryError || attempt >= 2 || smaller >= config.nCtx) rethrow;
          config = config.copyWith(nCtx: smaller);
        }
      }
      if (spec.loras.isNotEmpty) {
        final refs = <(LoraRef, double)>[];
        for (final (path, scale) in spec.loras) {
          refs.add((await host.loadLora(model.ref, path), scale));
        }
        await host.setLoras(session.ref, refs);
      }
      final l = LoadedModel._(spec, model, info, session, EngineSessionInfo.parse(session.infoJson), plan.estimate);
      _loaded = l;
      await _phase(InferencePhase.idle, l);
      _events.add(ModelLoadedEvent(spec, config, plan.estimate, plan.notes, sw.elapsed));
      return l;
    } on Object {
      if (model != null) await host.freeModel(model.ref).catchError((Object _) {});
      await _phase(InferencePhase.idle, null, spec: spec);
      rethrow;
    }
  }

  /// Unloads the warm model (after its prefix is saved).
  Future<void> unload({String reason = 'requested'}) async {
    await _waitIdle();
    await _locked(() => _unloadLocked(reason));
  }

  Future<void> _unloadLocked(String reason) async {
    final l = _loaded;
    if (l == null) return;
    if (l._leases > 0) {
      _pendingUnload = reason;
      return;
    }
    await _persist(l);
    _loaded = null;
    try {
      await host.freeSession(l.session.ref);
      await host.freeModel(l.model.ref);
    } on StaleHandleException {
      // The engine restarted underneath us; nothing left to free.
    }
    _events.add(ModelUnloadedEvent(l.spec, reason));
  }

  // ---------------------------------------------------------------------------
  // Prefix cache binding

  Future<void> _persist(LoadedModel l) async {
    final cache = prefixCache;
    final conv = l.conversation;
    if (cache == null || conv == null || !l.dirty || l.historyTokens < minTokensToPersist) return;
    await _phase(InferencePhase.savingState, l);
    try {
      final e = await cache.save(host, l.session.ref, l.keyFor(conv), l.fingerprint);
      l.dirty = false;
      if (e != null) _events.add(PrefixSavedEvent(conv, e.bytes));
    } on Object {
      // A failed save only costs a future prefill.
    } finally {
      await _phase(InferencePhase.idle, l);
    }
  }

  /// Saves the current conversation's prefix now (e.g. the app is about to
  /// be suspended).
  Future<void> persistNow() async {
    final l = _loaded;
    if (l == null || l._leases > 0) return;
    await _locked(() => _persist(l));
  }

  Future<PrefixRestoreResult?> _bind(LoadedModel l, String? conversation, List<String> fingerprint) async {
    if (l.conversation == conversation && conversation != null) return null;
    final cache = prefixCache;
    if (cache == null) {
      l.conversation = conversation;
      return null;
    }
    // The KV is about to hold another prompt: keep the current conversation's
    // prefix first. A request without a conversation (e.g. a summary) only
    // detaches the KV from it, so nothing is ever saved under the wrong key.
    await _persist(l);
    if (conversation == null) {
      l
        ..conversation = null
        ..dirty = false
        ..fingerprint = const [];
      return null;
    }
    await _phase(InferencePhase.restoringState, l);
    try {
      final r = await cache.restore(host, l.session.ref, l.keyFor(conversation), fingerprint);
      l
        ..conversation = conversation
        ..dirty = false
        ..fingerprint = r.restored ? r.entry!.fingerprint : const []
        ..historyTokens = r.tokens;
      if (r.outcome != PrefixRestoreOutcome.notFound) {
        _events.add(PrefixRestoredEvent(conversation, r.outcome, r.tokens));
      }
      return r;
    } on Object {
      // A cache failure only costs a prefill.
      l
        ..conversation = conversation
        ..dirty = false
        ..fingerprint = const [];
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Signals

  /// Reacts to a memory sample (subscribed automatically to the monitor).
  Future<void> handleMemory(MemoryState state) async {
    try {
      await _handleMemory(state);
    } on Object {
      // Best effort: the next sample or acquire re-plans anyway.
    }
  }

  Future<void> _handleMemory(MemoryState state) async {
    final l = _loaded;
    if (l == null) return;
    switch (state.pressure) {
      case MemoryPressure.normal:
        return;
      case MemoryPressure.critical:
        await _interrupt('memory_pressure');
        if (l._leases > 0) {
          _pendingUnload = 'critical memory pressure';
        } else {
          await _locked(() => _unloadLocked('critical memory pressure'));
        }
      case MemoryPressure.moderate:
        if (l._leases > 0) {
          _pendingDowngrade = 'moderate memory pressure';
        } else {
          await _locked(() => _downgradeLocked('moderate memory pressure'));
        }
    }
  }

  /// The next smaller session config, or null when already at the floor.
  @visibleForTesting
  static SessionConfig? downgradeOf(SessionConfig c, LocalModelSpec spec) {
    final k = c.typeK == KvType.engineDefault ? KvType.f16 : c.typeK;
    if (k.precisionRank > KvType.q8_0.precisionRank) return c.copyWith(typeK: KvType.q8_0, typeV: KvType.q8_0);
    final half = (c.nCtx ~/ 2) ~/ 256 * 256;
    if (half >= spec.minContext) return c.copyWith(nCtx: half);
    if (!spec.toolCalling && k == KvType.q8_0) return c.copyWith(typeK: KvType.q4_0, typeV: KvType.q4_0);
    return null;
  }

  Future<void> _downgradeLocked(String reason) async {
    final l = _loaded;
    if (l == null) return;
    if (l._leases > 0) {
      _pendingDowngrade = reason;
      return;
    }
    final from = l.config.copyWith(nCtx: l.sessionInfo.nCtx);
    final to = downgradeOf(from, l.spec);
    if (to == null) return;
    await _persist(l);
    await host.freeSession(l.session.ref);
    final s = await host.createSession(l.model.ref, to);
    l
      ..session = s
      ..sessionInfo = EngineSessionInfo.parse(s.infoJson)
      ..conversation = null
      ..dirty = false
      ..fingerprint = const []
      ..historyTokens = 0;
    _events.add(SessionDowngradedEvent(l.spec, from, to, reason));
  }

  Future<void> _interrupt(String reason) async {
    for (final lease in _leases.toList()) {
      if (lease._generating) {
        lease.interruptReason = reason;
        await host.cancelGeneration(lease.session);
      }
    }
  }

  /// The app moved to the background (see [BackgroundPolicy]).
  Future<void> onAppBackground() async {
    switch (backgroundPolicy) {
      case BackgroundPolicy.none:
        return;
      case BackgroundPolicy.persistOnly:
        await persistNow();
      case BackgroundPolicy.pauseAndPersist:
        _foreground ??= Completer<void>();
        await _interrupt('app_background');
        // iOS grants ~5 s after didEnterBackground; the cancel is observed
        // at the next token, so this normally returns in milliseconds.
        await _waitIdle(timeout: const Duration(seconds: 3));
        await _locked(() => _unloadLocked('app in background'));
    }
  }

  /// The app is in the foreground again: queued acquisitions proceed (the
  /// model reloads and restores its prefix on first use).
  void onAppForeground() {
    final f = _foreground;
    _foreground = null;
    if (f != null && !f.isCompleted) f.complete();
  }

  /// Benchmarks the warm model of [modelId] (or uses the stored profile) and
  /// applies the thread count right away; batch sizes and KV type apply at
  /// the next load. Run it as background work.
  Future<AutotuneProfile?> autotune(String modelId, {bool force = false, CancellationToken? cancel}) async {
    final tuner = autotuner;
    if (tuner == null) return null;
    final state = await (_memory?.sample() ?? Future.value(MemoryState.unknown));
    if (state.thermal.index >= ThermalLevel.serious.index && !force) return null;
    final lease = await acquire(modelId, cancel: cancel);
    try {
      await _phase(InferencePhase.benchmarking, lease.loaded);
      final budget = MemoryBudget.from(state, device: device, policy: policy);
      final fitsMemo = <(int, KvType), bool>{};
      final profile = await tuner.profileFor(
        model: lease.model,
        modelKey: modelId,
        force: force,
        cancel: cancel,
        fits: (c) async {
          if (!budget.isKnown) return true;
          return fitsMemo[(c.nUbatch, c.typeK)] ??= budget.admits(await host.estimateMemory(
              lease.loaded.spec.loadOptions, c.applyTo(lease.loaded.config.copyWith(nCtx: lease.loaded.sessionInfo.nCtx))));
        },
      );
      await host.setThreads(lease.session, profile.candidate.nThreads, profile.candidate.nThreads);
      return profile;
    } finally {
      await _phase(InferencePhase.idle, lease.loaded);
      lease.release();
    }
  }

  Future<void> dispose() async {
    await _memorySub?.cancel();
    await _hostSub?.cancel();
    await _waitIdle(timeout: const Duration(seconds: 2));
    await _locked(() => _unloadLocked('disposed'));
    await forensics?.flush();
    await _events.close();
  }
}
