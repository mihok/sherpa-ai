import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';
import 'package:sherpa_platform/sherpa_platform.dart' show DeviceSnapshot;

import '../../../services/inference/local_inference.dart';
import '../../../services/inference/local_model_specs.dart' show isRunnableLocally;
import 'peak_memory.dart';
import 'perf_history.dart';
import 'perf_models.dart';
import 'perf_stats.dart';

/// A lab action that could not run, with a sentence ready to show.
final class PerfLabException implements Exception {
  const PerfLabException(this.message, {this.unavailable = false});

  final String message;

  /// The engine itself is not available (not a problem with the request).
  final bool unavailable;

  @override
  String toString() => 'PerfLabException: $message';
}

/// Reads the device facts (SoC, cores, RAM, battery, thermal), or null.
typedef DeviceReader = Future<DeviceSnapshot?> Function();

/// The device as `sherpa_platform` measures it now; null when the plugin
/// can't answer.
Future<DeviceSnapshot?> captureDeviceSnapshot() async {
  try {
    return await DeviceSnapshot.capture();
  } on Object {
    return null;
  }
}

/// The thermal level [s] reports, or null when the platform reports none
/// (no plugin: host tests, desktop).
ThermalLevel? reportedThermal(MemoryState s) =>
    s.source == 'unknown' || s.source.startsWith('other') ? null : s.thermal;

typedef _Engine = ({EngineHost host, ModelLifecycleManager lifecycle, InferenceScheduler scheduler, LocalEngineStatus status});

/// One measurement before memory and thermal are attached.
typedef _Measured = ({
  double prefillTps,
  double decodeTps,
  double ttftMs,
  double? draftAcceptRate,
  int? promptTokens,
  int? genTokens,
  String? backend,
});

/// The performance lab's engine-facing half: what the overview shows, and
/// benchmarks, A/B comparisons, re-tuning and overrides for one local
/// model.
///
/// **Never in the way of a reply.** Every measurement is a job on the
/// provider's [InferenceScheduler] at [InferencePriority.background]: it
/// starts only when no more urgent work is queued (the scheduler runs one
/// job at a time, so it never overlaps a generation), and a chat request
/// preempts it. Preemption cancels the running `se_bench` (or generation)
/// within a token; the scheduler then re-queues the job, which runs again
/// once the engine is free. A/B comparisons are one job per measurement,
/// so a preemption costs one run, not the comparison.
///
/// **Cancellable.** Every action takes a [CancellationToken]: a queued job
/// leaves the queue, a running one stops the engine call; the action then
/// throws [CancelledException].
///
/// **Memory-safe.** A config is checked with `se_estimate_memory` at the
/// model's context against the admission budget ([checkFit]); comparisons
/// and "Apply" refuse configs that don't fit. While a model is loaded its
/// own memory is counted as available, since it is freed (or reused)
/// before another config loads.
///
/// **How speculative configs are measured.** `se_bench` decodes synthetic
/// tokens without sampling, so it cannot speculate. When either side of a
/// comparison uses speculative decoding, both sides are measured with a
/// real greedy generation on a temporary session instead (a prompt that
/// asks the model to copy a list, which is what n-gram drafting is for:
/// the agent case of repeating arguments and file content). A draft model
/// is loaded next to the main one for its runs and freed after each.
final class PerfLab {
  PerfLab({
    required this.local,
    MemoryMonitor? memory,
    DeviceReader? device,
    MemoryReader? memoryReader,
    Clock clock = const SystemClock(),
    this.samplePeriod = const Duration(milliseconds: 250),
  })  : _memory = memory,
        _device = device,
        _memoryReader = memoryReader,
        _clock = clock,
        history = PerfHistory(local.store);

  final LocalInference local;
  final PerfHistory history;
  final MemoryMonitor? _memory;
  final DeviceReader? _device;
  final MemoryReader? _memoryReader;
  final Clock _clock;

  /// How often app memory is read during a run.
  final Duration samplePeriod;

  int _seq = 0;
  String? _systemJson;
  final Map<(String, int), (String, int)> _probeRequests = {};

  // ---------------------------------------------------------------------------
  // Engine access

  Future<_Engine> _engine() async {
    final status = await local.start();
    final host = local.host;
    final lifecycle = local.lifecycle;
    final provider = local.engine;
    if (!status.isReady || host == null || lifecycle == null || provider == null) {
      throw PerfLabException(status.unavailableMessage ?? 'The on-device engine isn’t running.', unavailable: true);
    }
    return (host: host, lifecycle: lifecycle, scheduler: provider.scheduler, status: status);
  }

  LocalModelSpec _specFor(_Engine e, String modelId) =>
      e.lifecycle.spec(modelId) ??
      (throw const PerfLabException('This model can’t run on the on-device engine (it isn’t a usable GGUF file).'));

  Future<MemoryState> _sample() async {
    try {
      return await (_memory?.sample() ?? Future.value(MemoryState.unknown));
    } on Object {
      return MemoryState.unknown;
    }
  }

  Future<DeviceSnapshot?> _readDevice() async {
    try {
      return await _device?.call();
    } on Object {
      return null;
    }
  }

  /// The admission budget now. A loaded model's anonymous memory (KV,
  /// compute, repacked weights) is counted as available: it is freed before
  /// another config of it, or another model, loads.
  Future<({MemoryBudget budget, int addedBack})> _budget(_Engine e) async {
    final state = await _sample();
    var s = state;
    var added = 0;
    final est = e.lifecycle.loaded?.estimate;
    final available = state.availableBytes;
    if (est != null && available != null) {
      added = math.max(0, est.anonymousBytes);
      s = state.copyWith(availableBytes: available + added);
    }
    return (budget: MemoryBudget.from(s, device: e.lifecycle.device, policy: e.lifecycle.policy), addedBack: added);
  }

  bool _isWarm(_Engine e, String modelId) {
    final l = e.lifecycle.loaded;
    return l != null && l.spec.id == modelId && l.model.ref.epoch == e.host.epoch;
  }

  /// The context the model runs (or would load) with.
  Future<int> _contextTokens(_Engine e, LocalModelSpec spec) async {
    if (_isWarm(e, spec.id)) return e.lifecycle.loaded!.sessionInfo.nCtx;
    try {
      return (await e.lifecycle.plan(spec.id)).config?.nCtx ?? spec.preferredContext;
    } on Object {
      return spec.preferredContext;
    }
  }

  // ---------------------------------------------------------------------------
  // Overview

  /// Device, engine, tuned profile and memory for [modelId].
  Future<PerfOverview> overview(String modelId) async {
    final e = await _engine();
    final spec = _specFor(e, modelId);
    final tuner = e.lifecycle.autotuner;
    final memory = await _sample();
    final (:budget, :addedBack) = await _budget(e);
    final device = await _readDevice();
    final engine = await _describeEngine(e);
    AutotuneProfile? profile;
    var overrides = const AutotuneOverrides();
    try {
      profile = await tuner?.cached(modelId);
      overrides = await tuner?.overrides(modelId) ?? const AutotuneOverrides();
    } on Object {
      // Unreadable notes: show "not tuned".
    }
    return PerfOverview(
      modelId: modelId,
      modelName: spec.label,
      device: device,
      memory: memory,
      engine: engine,
      profile: profile,
      defaults: tuner?.defaults ?? const TuningCandidate(nThreads: 0),
      overrides: overrides,
      speculative: local.speculativeFor(modelId),
      current: await _current(e, spec),
      budget: budget,
      addedBackBytes: addedBack,
      toolCalling: spec.toolCalling,
      drafts: drafts(modelId),
    );
  }

  Future<EngineDescription> _describeEngine(_Engine e) async {
    EngineSystemInfo? system;
    var features = const <String, String>{};
    try {
      final json = _systemJson ??= await e.host.systemInfoJson();
      system = EngineSystemInfo.parse(json);
      final raw = system.raw['cpu_backend_features'];
      if (raw is Map) features = {for (final f in raw.entries) '${f.key}': '${f.value}'};
    } on Object {
      // Older engines: no system info.
    }
    return EngineDescription(
      version: e.status.engineVersion ?? 'unknown',
      hostKind: e.status.hostKind ?? e.host.kind,
      system: system,
      cpuBackendFeatures: features,
    );
  }

  Future<CurrentSettings> _current(_Engine e, LocalModelSpec spec) async {
    if (_isWarm(e, spec.id)) {
      final l = e.lifecycle.loaded!;
      final info = l.sessionInfo;
      final c = l.config;
      MemoryEstimate? live;
      try {
        live = await e.host.sessionMemory(l.session.ref);
      } on Object {
        live = null;
      }
      return CurrentSettings(
        config: LabConfig(
          nThreads: c.nThreads > 0 ? c.nThreads : info.nThreads,
          nBatch: c.nBatch > 0 ? c.nBatch : info.nBatch,
          nUbatch: c.nUbatch > 0 ? c.nUbatch : info.nUbatch,
          kv: KvType.byLabel(info.typeK),
          flashAttention: c.flashAttention,
          speculative: SpeculativeChoice.of(c.speculative),
        ),
        contextTokens: info.nCtx,
        loaded: true,
        flashAttentionOn: info.flashAttention,
        estimate: l.estimate,
        liveMemory: live,
      );
    }
    final plan = await e.lifecycle.plan(spec.id);
    final cfg = plan.config ?? spec.sessionDefaults.copyWith(nCtx: spec.preferredContext);
    return CurrentSettings(
      config: LabConfig.fromSession(cfg),
      contextTokens: cfg.nCtx,
      loaded: false,
      flashAttentionOn: plan.estimate?.flashAttention,
      estimate: plan.estimate,
      notes: plan.notes,
      refusal: plan.refusal,
    );
  }

  /// Library models that can draft for [modelId]: its paired draft file,
  /// and smaller runnable GGUFs of the same architecture (at most half its
  /// parameters). The engine checks vocabulary compatibility on load.
  List<DraftOption> drafts(String modelId) {
    final m = local.library.byId(modelId);
    if (m == null) return const [];
    final out = <DraftOption>[];
    final paired = m.draftPath;
    if (paired != null) {
      out.add(DraftOption(
          modelId: pairedDraftId(modelId), label: 'Paired draft', path: local.layout.libraryPath(paired), paired: true));
    }
    final params = m.parameterCount;
    for (final o in local.library.models) {
      if (o.id == modelId || !isRunnableLocally(o) || m.architecture == null || o.architecture != m.architecture) continue;
      final p = o.parameterCount;
      if (params == null || p == null || p * 2 > params) continue;
      out.add(DraftOption(modelId: o.id, label: o.displayName, path: local.layout.libraryPath(o.loadPath)));
    }
    return out;
  }

  /// The [DraftOption.modelId] of a model's own paired draft file.
  static String pairedDraftId(String modelId) => '$modelId#draft';

  String? _draftPath(String modelId, String? draftId) {
    if (draftId == null) return null;
    for (final d in drafts(modelId)) {
      if (d.modelId == draftId) return d.path;
    }
    return null;
  }

  static ModelLoadOptions _withDraft(ModelLoadOptions o, String draftPath) => ModelLoadOptions(
        path: o.path,
        modelId: o.modelId,
        nGpuLayers: o.nGpuLayers,
        loadMode: o.loadMode,
        useExtraBuffers: o.useExtraBuffers,
        loadMtp: o.loadMtp,
        chatTemplateOverride: o.chatTemplateOverride,
        draftModelPath: draftPath,
      );

  // ---------------------------------------------------------------------------
  // Memory check

  /// `se_estimate_memory` for [config] at the model's context, against the
  /// admission budget now.
  Future<FitCheck> checkFit(String modelId, LabConfig config) async {
    final e = await _engine();
    final spec = _specFor(e, modelId);
    final ctx = await _contextTokens(e, spec);
    final invalid = config.invalidReason;
    if (invalid != null) return FitCheck(config: config, contextTokens: ctx, invalidReason: invalid);
    var load = spec.loadOptions;
    if (config.speculative == SpeculativeChoice.draft) {
      final path = _draftPath(modelId, config.draftModelId);
      if (path == null) {
        return FitCheck(config: config, contextTokens: ctx, invalidReason: 'That draft model is no longer in the library.');
      }
      load = _withDraft(load, path);
    }
    final MemoryEstimate estimate;
    try {
      estimate = await e.host.estimateMemory(load, config.applyTo(spec.sessionDefaults.copyWith(nCtx: ctx)));
    } on EngineException catch (x) {
      return FitCheck(config: config, contextTokens: ctx, invalidReason: 'The engine can’t use this combination (${x.message}).');
    }
    final (:budget, :addedBack) = await _budget(e);
    return FitCheck(config: config, contextTokens: ctx, estimate: estimate, budget: budget, addedBackBytes: addedBack);
  }

  // ---------------------------------------------------------------------------
  // Benchmark

  /// Benchmarks the model with its current settings ([spec.reps] measured
  /// runs after a warm-up) and adds the result to the history.
  Future<BenchRun> bench(
    String modelId,
    BenchSpec spec, {
    CancellationToken? cancel,
    void Function(LabJobPhase phase)? onPhase,
  }) async {
    final e = await _engine();
    final s = _specFor(e, modelId);
    final config = (await _current(e, s)).config;
    final token = cancel ?? CancellationToken();
    final method = config.needsGeneration ? BenchMethod.generation : BenchMethod.bench;
    final sample = await _job(e, s, 'benchmark', token, onPhase, (lease, t) async {
      if (method == BenchMethod.bench) return _benchCall(e.host, lease.model, config, spec, t);
      final runs = <_Measured>[];
      for (var i = 0; i < spec.reps; i++) {
        runs.add(await _generate(e, lease, s, config, spec, t));
      }
      return _medianOf(runs);
    });
    final run = BenchRun(at: _clock.now(), config: config, spec: spec, method: method, sample: sample);
    await history.add(modelId, run);
    return run;
  }

  // ---------------------------------------------------------------------------
  // A/B

  /// Measures [a] and [b] alternately, [spec.reps] times each, one
  /// background job per measurement. Refuses configs that don't fit memory
  /// or that the engine would reject.
  Future<AbResult> compare(
    String modelId,
    LabConfig a,
    LabConfig b, {
    BenchSpec spec = const BenchSpec.comparison(),
    CancellationToken? cancel,
    void Function(AbProgress progress)? onProgress,
  }) async {
    final e = await _engine();
    final s = _specFor(e, modelId);
    for (final (name, c) in [('A', a), ('B', b)]) {
      final fit = await checkFit(modelId, c);
      if (!fit.fits) throw PerfLabException('Setting $name: ${fit.problem}');
    }
    final method = a.needsGeneration || b.needsGeneration ? BenchMethod.generation : BenchMethod.bench;
    final one = spec.copyWith(reps: 1);
    final token = cancel ?? CancellationToken();
    final total = spec.reps * 2;
    final as = <RepSample>[];
    final bs = <RepSample>[];
    for (var i = 0; i < spec.reps; i++) {
      for (final side in const [Winner.a, Winner.b]) {
        token.throwIfCancelled();
        final c = side == Winner.a ? a : b;
        final done = as.length + bs.length;
        onProgress?.call(AbProgress(done: done, total: total, side: side, phase: LabJobPhase.waiting));
        final sample = await _job(
          e,
          s,
          'A/B ${side.name.toUpperCase()} ${i + 1}',
          token,
          (phase) => onProgress?.call(AbProgress(done: done, total: total, side: side, phase: phase)),
          (lease, t) => method == BenchMethod.generation
              ? _generate(e, lease, s, c, one, t)
              : _benchCall(e.host, lease.model, c, one, t),
        );
        (side == Winner.a ? as : bs).add(sample);
      }
    }
    onProgress?.call(AbProgress(done: total, total: total));
    return AbResult(a: a, b: b, aSamples: as, bSamples: bs, method: method);
  }

  // ---------------------------------------------------------------------------
  // Overrides

  /// Pins [config] as the user's override for [modelId] (threads, batches,
  /// KV, flash attention via [Autotuner.setOverrides]; speculative decoding
  /// via [LocalInference.setSpeculative]). A warm model is unloaded once
  /// idle, so the next chat loads with it. Returns false when the override
  /// waits for a tuned profile (the lifecycle applies overrides on top of
  /// a measured profile only; speculative decoding applies at once).
  Future<bool> apply(String modelId, LabConfig config) async {
    final e = await _engine();
    if (config.speculative == SpeculativeChoice.draft) {
      throw const PerfLabException('Chats can’t use a draft model yet: this setting can be measured, not applied.');
    }
    final fit = await checkFit(modelId, config);
    if (!fit.fits) throw PerfLabException(fit.problem!);
    final tuner = e.lifecycle.autotuner ?? (throw const PerfLabException('Tuning is turned off in this build.'));
    await tuner.setOverrides(modelId, config.overrides);
    await local.setSpeculative(modelId, config.speculative == SpeculativeChoice.off ? null : config.speculative.mode);
    _reloadWhenIdle(e, modelId);
    return await tuner.cached(modelId) != null;
  }

  /// Back to automatic settings: clears the overrides and the speculative
  /// choice.
  Future<void> resetToAuto(String modelId) async {
    final e = await _engine();
    await e.lifecycle.autotuner?.setOverrides(modelId, const AutotuneOverrides());
    await local.setSpeculative(modelId, null);
    _reloadWhenIdle(e, modelId);
  }

  void _reloadWhenIdle(_Engine e, String modelId) {
    if (e.lifecycle.loaded?.spec.id != modelId) return;
    unawaited(e.lifecycle.unload(reason: 'performance settings changed').catchError((Object _) {}));
  }

  // ---------------------------------------------------------------------------
  // Autotune

  /// Runs the autotune sweep again ([Autotuner.profileFor] with `force`) as
  /// one background job, reporting each measured candidate. A preempted
  /// sweep restarts once the engine is free.
  Future<AutotuneProfile> retune(
    String modelId, {
    CancellationToken? cancel,
    void Function(AutotuneProgress progress)? onProgress,
    void Function(LabJobPhase phase)? onPhase,
  }) async {
    final e = await _engine();
    final spec = _specFor(e, modelId);
    final tuner = e.lifecycle.autotuner ?? (throw const PerfLabException('Tuning is turned off in this build.'));
    // The first-use sweep would only measure the same thing again.
    local.autotune?.cancel('re-tuning in the performance lab');
    final sweep = tuner.sweep;
    final total = sweep.threads.length + sweep.batchSizes.length + sweep.kvVariants.length;
    final token = cancel ?? CancellationToken();
    return _guard(token, (_) => _scheduled(e, 'autotune', token, onPhase, (t) async {
        var done = 0;
        onProgress?.call(AutotuneProgress(done: 0, total: total));
        final lease = await e.lifecycle.acquire(modelId, cancel: t);
        try {
          final (:budget, addedBack: _) = await _budget(e);
          final base = lease.loaded.config.copyWith(nCtx: lease.loaded.sessionInfo.nCtx);
          final memo = <(int, KvType), bool>{};
          final profile = await tuner.profileFor(
            model: lease.model,
            modelKey: modelId,
            force: true,
            cancel: t,
            fits: (c) async {
              if (!budget.isKnown) return true;
              return memo[(c.nUbatch, c.typeK)] ??= budget.admits(await e.host.estimateMemory(spec.loadOptions, c.applyTo(base)));
            },
            onSample: (c, r) => onProgress?.call(AutotuneProgress(done: ++done, total: total, last: c, lastResult: r)),
          );
          await e.host.setThreads(lease.session, profile.candidate.nThreads, profile.candidate.nThreads);
          onProgress?.call(AutotuneProgress(done: total, total: total));
          return profile;
        } finally {
          lease.release();
        }
      }));
  }

  // ---------------------------------------------------------------------------
  // Jobs

  /// Runs [body] as a background scheduler job; [body]'s token is
  /// cancelled by the user's [cancel] and by preemption.
  Future<T> _scheduled<T>(
    _Engine e,
    String what,
    CancellationToken cancel,
    void Function(LabJobPhase phase)? onPhase,
    Future<T> Function(CancellationToken token) body,
  ) async {
    final label = 'perf lab: $what #${++_seq}';
    final watch = e.scheduler.changes.listen((s) {
      final phase = _phaseOf(s, label);
      if (phase != null) onPhase?.call(phase);
    });
    try {
      return await e.scheduler.run<T>(
        InferencePriority.background,
        (ctx) async {
          cancel.throwIfCancelled();
          final token = CancellationToken();
          unawaited(cancel.whenCancelled.then(token.cancel));
          unawaited(ctx.preempt.whenCancelled.then(token.cancel));
          return body(token);
        },
        label: label,
        cancel: cancel,
      );
    } finally {
      await watch.cancel();
    }
  }

  static LabJobPhase? _phaseOf(SchedulerState s, String label) {
    if (s.running.any((j) => j.label == label)) return LabJobPhase.running;
    for (final j in s.queued) {
      if (j.label == label) return j.preemptions > 0 ? LabJobPhase.paused : LabJobPhase.waiting;
    }
    return null;
  }

  /// One measurement on a lease of the model: app memory sampled while it
  /// runs, thermal state before and after.
  Future<RepSample> _job(
    _Engine e,
    LocalModelSpec spec,
    String what,
    CancellationToken cancel,
    void Function(LabJobPhase phase)? onPhase,
    Future<_Measured> Function(ModelLease lease, CancellationToken token) body,
  ) =>
      _guard(cancel, (_) => _scheduled(e, what, cancel, onPhase, (token) async {
            final lease = await e.lifecycle.acquire(spec.id, cancel: token);
            try {
              token.throwIfCancelled();
              final before = await _sample();
              final sampler = PeakMemorySampler(_memoryReaderFor(e.host), period: samplePeriod);
              await sampler.start();
              final _Measured m;
              try {
                m = await body(lease, token);
              } finally {
                await sampler.stop();
              }
              final after = await _sample();
              return RepSample(
                prefillTps: m.prefillTps,
                decodeTps: m.decodeTps,
                ttftMs: m.ttftMs,
                peakMemoryBytes: sampler.peak,
                baselineMemoryBytes: sampler.baseline,
                thermalBefore: reportedThermal(before),
                thermalAfter: reportedThermal(after),
                draftAcceptRate: m.draftAcceptRate,
                promptTokens: m.promptTokens,
                genTokens: m.genTokens,
                backend: m.backend,
              );
            } finally {
              lease.release();
            }
          }));

  /// Maps engine and lifecycle failures to [PerfLabException] (and a
  /// cancelled engine call after the user's cancel to
  /// [CancelledException]).
  Future<T> _guard<T>(CancellationToken cancel, Future<T> Function(CancellationToken cancel) op) async {
    try {
      return await op(cancel);
    } on CancelledException {
      rethrow;
    } on PerfLabException {
      rethrow;
    } on AdmissionRefusedException catch (x) {
      throw PerfLabException(x.message);
    } on EngineException catch (x) {
      if (cancel.isCancelled) throw CancelledException(cancel.reason ?? 'cancelled');
      throw PerfLabException('The engine stopped this run: ${x.message}');
    } on PreemptedException {
      throw const PerfLabException('A chat reply needed the engine; run it again when the chat is idle.');
    } on Object catch (x) {
      if (cancel.isCancelled) throw CancelledException(cancel.reason ?? 'cancelled');
      throw PerfLabException('The run failed (${x.runtimeType}).');
    }
  }

  /// App memory during a run. Only meaningful when the engine lives in the
  /// app process: the `:inference` process's memory is not visible here.
  MemoryReader _memoryReaderFor(EngineHost host) {
    if (host.kind == EngineHostKind.isolatedProcess) return () async => null;
    return _memoryReader ??
        () async {
          final footprint = (await _sample()).appFootprintBytes;
          return footprint ?? await processResidentBytes();
        };
  }

  // ---------------------------------------------------------------------------
  // Measurements

  Future<_Measured> _benchCall(EngineHost host, ModelRef model, LabConfig c, BenchSpec b, CancellationToken token) async {
    final r = await host.bench(
      model,
      c.candidate.bench(nPrompt: b.promptTokens, nGen: b.genTokens, nReps: b.engineReps),
      cancel: token,
    );
    final nPrompt = r.nPrompt > 0 ? r.nPrompt : b.promptTokens;
    final nGen = r.nGen > 0 ? r.nGen : b.genTokens;
    final promptMs = r.promptMs > 0 ? r.promptMs : (r.promptTokensPerSec > 0 ? nPrompt * 1000 / r.promptTokensPerSec : 0.0);
    final stepMs = r.genMs > 0 ? r.genMs / nGen : (r.genTokensPerSec > 0 ? 1000 / r.genTokensPerSec : 0.0);
    return (
      prefillTps: r.promptTokensPerSec,
      decodeTps: r.genTokensPerSec,
      ttftMs: promptMs + stepMs,
      draftAcceptRate: null,
      promptTokens: nPrompt,
      genTokens: nGen,
      backend: null,
    );
  }

  /// One greedy generation on a temporary session with [c] (and, for a
  /// draft model, a temporary model instance that carries the draft).
  Future<_Measured> _generate(_Engine e, ModelLease lease, LocalModelSpec spec, LabConfig c, BenchSpec b, CancellationToken token) async {
    final host = e.host;
    EngineModel? temp;
    EngineSession? session;
    try {
      var model = lease.model;
      if (c.speculative == SpeculativeChoice.draft) {
        final path = _draftPath(spec.id, c.draftModelId) ??
            (throw const PerfLabException('That draft model is no longer in the library.'));
        temp = await host.loadModel(_withDraft(spec.loadOptions, path), cancel: token);
        model = temp.ref;
      }
      final (request, promptTokens) = await _probeRequest(host, model, spec.id, b);
      final ctx = (promptTokens + b.genTokens + 64 + 255) ~/ 256 * 256;
      session = await host.createSession(model, c.applyTo(spec.sessionDefaults.copyWith(nCtx: ctx, seed: 42)));
      token.throwIfCancelled();
      final ref = session.ref;
      EngineEvent? perf;
      EngineEvent? usage;
      EngineEvent? error;
      var cancelled = false;
      unawaited(token.whenCancelled.then((_) => host.cancelGeneration(ref).catchError((Object _) {})));
      await for (final ev in host.generate(ref, request)) {
        switch (ev.type) {
          case EngineEventType.perf:
            perf = ev;
          case EngineEventType.usage:
            usage = ev;
          case EngineEventType.error:
            error = ev;
          case EngineEventType.finish:
            cancelled = ev.name == 'cancelled';
          default:
            break;
        }
      }
      if (token.isCancelled || cancelled) throw CancelledException(token.reason ?? 'cancelled');
      if (error != null) throw EngineException(error.code, error.text);
      final p = perf ?? (throw const PerfLabException('The engine did not report timings for this run.'));
      return (
        prefillTps: p.prefillTps,
        decodeTps: p.decodeTps,
        ttftMs: p.ttftMs,
        draftAcceptRate: p.nDrafted > 0 ? p.draftAcceptRate : null,
        promptTokens: usage?.promptTokens,
        genTokens: usage?.completionTokens,
        backend: p.name.isEmpty ? null : p.name,
      );
    } finally {
      final s = session;
      if (s != null) await host.freeSession(s.ref).catchError((Object _) {});
      final m = temp;
      if (m != null) await host.freeModel(m.ref).catchError((Object _) {});
    }
  }

  /// A chat request of about [BenchSpec.promptTokens] prompt tokens (as
  /// the model's template renders it) asking to copy a list, capped at
  /// [BenchSpec.genTokens]; with its real token count.
  Future<(String, int)> _probeRequest(EngineHost host, ModelRef model, String modelId, BenchSpec b) async {
    final key = (modelId, b.promptTokens * 10000 + b.genTokens);
    final cached = _probeRequests[key];
    if (cached != null) return cached;
    var items = math.max(2, b.promptTokens ~/ 16);
    var json = probeRequestJson(items, b.genTokens);
    var count = await host.countChatTokens(model, json);
    for (var i = 0; i < 3 && count > 0; i++) {
      if ((count - b.promptTokens).abs() <= b.promptTokens ~/ 10) break;
      final next = math.max(1, (items * b.promptTokens / count).round());
      if (next == items) break;
      items = next;
      json = probeRequestJson(items, b.genTokens);
      count = await host.countChatTokens(model, json);
    }
    return _probeRequests[key] = (json, count > 0 ? count : b.promptTokens);
  }

  /// The generation probe's request: copy an [items]-line list, greedy,
  /// no thinking, no prompt cache.
  static String probeRequestJson(int items, int maxTokens) {
    const things = ['parcel', 'invoice', 'crate', 'ticket', 'sample', 'report', 'battery'];
    const places = ['dock', 'bay', 'gate', 'shelf', 'desk', 'room'];
    final lines = [
      for (var i = 1; i <= items; i++)
        '$i. The ${things[i % things.length]} with code ${(i * 7919) % 10000} goes to '
            '${places[(i ~/ things.length) % places.length]} ${i % 13 + 1}.',
    ];
    return jsonEncode({
      'messages': [
        {'role': 'user', 'content': 'Copy this list exactly, one line per item, with no other text:\n${lines.join('\n')}'},
      ],
      'max_tokens': maxTokens,
      'temperature': 0,
      'seed': 42,
      'enable_thinking': false,
      'cache_prompt': false,
    });
  }

  static _Measured _medianOf(List<_Measured> runs) {
    double med(double Function(_Measured m) f) => Summary.of(runs.map(f)).median;
    final accepts = [for (final r in runs) ?r.draftAcceptRate];
    return (
      prefillTps: med((m) => m.prefillTps),
      decodeTps: med((m) => m.decodeTps),
      ttftMs: med((m) => m.ttftMs),
      draftAcceptRate: accepts.isEmpty ? null : Summary.of(accepts).median,
      promptTokens: runs.first.promptTokens,
      genTokens: runs.first.genTokens,
      backend: runs.first.backend,
    );
  }
}
