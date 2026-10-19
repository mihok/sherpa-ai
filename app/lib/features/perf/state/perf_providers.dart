import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show KeepAliveLink;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';

import '../../../services/inference/local_inference.dart';
import '../../../state/providers.dart' show clockProvider, memoryMonitorProvider;
import '../../models/state/local_inference_providers.dart';
import 'perf_lab.dart';
import 'perf_models.dart';

/// Reads the device facts for the lab (a test seam).
final perfDeviceReaderProvider = Provider<DeviceReader>((ref) => captureDeviceSnapshot);

/// How often the live monitor re-samples memory and thermal state while
/// the lab is open. Null = only when the monitor reports a change.
final perfMonitorIntervalProvider = Provider<Duration?>((ref) => const Duration(seconds: 2));

/// The lab over the app's on-device engine (null when local inference is
/// not wired).
final perfLabProvider = Provider<PerfLab?>((ref) {
  final local = ref.watch(localInferenceProvider);
  if (local == null) return null;
  return PerfLab(
    local: local,
    memory: ref.watch(memoryMonitorProvider),
    device: ref.watch(perfDeviceReaderProvider),
    clock: ref.watch(clockProvider),
  );
});

/// Device, engine, tuned profile and memory for one model. Re-reads when
/// the engine changes state or the model loads, unloads or shrinks.
final perfOverviewProvider = FutureProvider.autoDispose.family<PerfOverview, String>((ref, modelId) async {
  final lab = ref.watch(perfLabProvider);
  if (lab == null) {
    throw const PerfLabException('On-device models aren’t set up in this build.', unavailable: true);
  }
  ref.watch(localEngineStatusProvider.select((s) => s.value?.state));
  final overview = await lab.overview(modelId);
  final lifecycle = lab.local.lifecycle;
  if (lifecycle != null && ref.mounted) {
    final sub = lifecycle.events.listen((e) {
      if (e is ModelLoadedEvent || e is ModelUnloadedEvent || e is SessionDowngradedEvent) ref.invalidateSelf();
    });
    ref.onDispose(sub.cancel);
  }
  return overview;
});

/// Whether a config fits memory at the model's context (`se_estimate_memory`).
final perfFitProvider = FutureProvider.autoDispose.family<FitCheck, (String, LabConfig)>((ref, key) async {
  final lab = ref.watch(perfLabProvider);
  if (lab == null) throw const PerfLabException('On-device models aren’t set up in this build.', unavailable: true);
  return lab.checkFit(key.$1, key.$2);
});

/// Memory and thermal state now, re-sampled while watched.
final perfLiveMemoryProvider = StreamProvider.autoDispose<MemoryState>((ref) {
  final monitor = ref.watch(memoryMonitorProvider);
  final interval = ref.watch(perfMonitorIntervalProvider);
  final out = StreamController<MemoryState>();
  out.add(monitor.current);
  final sub = monitor.changes.listen(out.add);
  Future<void> sample() async {
    try {
      final s = await monitor.sample();
      if (!out.isClosed) out.add(s);
    } on Object {
      // Keep the last reading.
    }
  }

  unawaited(sample());
  final timer = interval == null ? null : Timer.periodic(interval, (_) => unawaited(sample()));
  ref.onDispose(() {
    timer?.cancel();
    unawaited(sub.cancel());
    unawaited(out.close());
  });
  return out.stream;
});

/// The most recent on-device generation's report, live.
final perfLastGenerationProvider = StreamProvider.autoDispose<LocalGenerationReport?>((ref) async* {
  final local = ref.watch(localInferenceProvider);
  if (local == null) {
    yield null;
    return;
  }
  yield local.lastGeneration;
  yield* local.generations;
});

// ---------------------------------------------------------------------------
// Controller

enum LabJobKind { bench, compare, autotune }

/// The lab's running job.
@immutable
final class LabJob {
  const LabJob(this.kind, {this.phase = LabJobPhase.waiting, this.progress, this.detail, this.cancelling = false});

  final LabJobKind kind;
  final LabJobPhase phase;

  /// 0..1 when known.
  final double? progress;

  /// What it is doing ("A, run 3 of 5").
  final String? detail;
  final bool cancelling;

  LabJob copyWith({LabJobPhase? phase, double? progress, String? detail, bool? cancelling}) => LabJob(
        kind,
        phase: phase ?? this.phase,
        progress: progress ?? this.progress,
        detail: detail ?? this.detail,
        cancelling: cancelling ?? this.cancelling,
      );
}

enum LabMessageTone { info, success, error }

@immutable
final class LabMessage {
  const LabMessage(this.text, this.tone);

  const LabMessage.info(this.text) : tone = LabMessageTone.info;

  const LabMessage.success(this.text) : tone = LabMessageTone.success;

  const LabMessage.error(this.text) : tone = LabMessageTone.error;

  final String text;
  final LabMessageTone tone;
}

@immutable
final class PerfLabState {
  const PerfLabState({
    this.benchSpec = const BenchSpec(),
    this.abSpec = const BenchSpec.comparison(),
    this.a,
    this.b,
    this.job,
    this.lastRun,
    this.history = const [],
    this.ab,
    this.message,
    this.messageFor,
    this.applying = false,
  });

  final BenchSpec benchSpec;
  final BenchSpec abSpec;

  /// The A/B editors; null = start from the model's current settings.
  final LabConfig? a;
  final LabConfig? b;
  final LabJob? job;
  final BenchRun? lastRun;

  /// Oldest first, at most 10.
  final List<BenchRun> history;
  final AbResult? ab;

  /// The outcome of the last action, and the part of the lab it belongs to.
  final LabMessage? message;
  final LabJobKind? messageFor;
  final bool applying;

  bool get busy => job != null || applying;

  PerfLabState copyWith({
    BenchSpec? benchSpec,
    BenchSpec? abSpec,
    LabConfig? a,
    LabConfig? b,
    LabJob? job,
    bool clearJob = false,
    BenchRun? lastRun,
    List<BenchRun>? history,
    AbResult? ab,
    LabMessage? message,
    LabJobKind? messageFor,
    bool clearMessage = false,
    bool? applying,
  }) =>
      PerfLabState(
        benchSpec: benchSpec ?? this.benchSpec,
        abSpec: abSpec ?? this.abSpec,
        a: a ?? this.a,
        b: b ?? this.b,
        job: clearJob ? null : job ?? this.job,
        lastRun: lastRun ?? this.lastRun,
        history: history ?? this.history,
        ab: ab ?? this.ab,
        message: clearMessage ? null : message ?? this.message,
        messageFor: clearMessage ? null : messageFor ?? this.messageFor,
        applying: applying ?? this.applying,
      );
}

/// The lab's state for one model: editors, the running job, results and
/// history. A running job keeps it alive when the screen is left, so
/// coming back shows (and can cancel) it.
final perfLabControllerProvider = NotifierProvider.autoDispose.family<PerfLabController, PerfLabState, String>(
  PerfLabController.new,
  name: 'perfLabControllerProvider',
);

class PerfLabController extends Notifier<PerfLabState> {
  PerfLabController(this.modelId);

  final String modelId;

  CancellationToken? _cancel;
  KeepAliveLink? _keepAlive;

  PerfLab? get _lab => ref.read(perfLabProvider);

  @override
  PerfLabState build() {
    ref.onDispose(() => _cancel?.cancel('left the performance lab'));
    unawaited(_loadHistory());
    return const PerfLabState();
  }

  Future<void> _loadHistory() async {
    final lab = _lab;
    if (lab == null) return;
    try {
      final runs = await lab.history.list(modelId);
      if (ref.mounted) state = state.copyWith(history: runs);
    } on Object {
      // No history.
    }
  }

  void setBenchSpec(BenchSpec s) => state = state.copyWith(benchSpec: s);

  void setAbSpec(BenchSpec s) => state = state.copyWith(abSpec: s);

  void setA(LabConfig c) => state = state.copyWith(a: c);

  void setB(LabConfig c) => state = state.copyWith(b: c);

  void dismissMessage() => state = state.copyWith(clearMessage: true);

  CancellationToken _begin(LabJob job) {
    final token = _cancel = CancellationToken();
    _keepAlive ??= ref.keepAlive();
    state = state.copyWith(job: job, clearMessage: true);
    return token;
  }

  void _progress(LabJob Function(LabJob job) f) {
    final j = state.job;
    if (j == null || !ref.mounted) return;
    state = state.copyWith(job: f(j));
  }

  void _end(LabJobKind kind, {LabMessage? message, BenchRun? lastRun, List<BenchRun>? history, AbResult? ab}) {
    _cancel = null;
    _keepAlive?.close();
    _keepAlive = null;
    if (!ref.mounted) return;
    state = state.copyWith(
      clearJob: true,
      clearMessage: message == null,
      message: message,
      messageFor: kind,
      lastRun: lastRun,
      history: history,
      ab: ab,
    );
  }

  /// Stops the running job (it leaves the queue, or the engine call stops).
  void cancel() {
    _cancel?.cancel('cancelled by the user');
    _progress((j) => j.copyWith(cancelling: true));
  }

  Future<void> runBench() async {
    final lab = _lab;
    if (lab == null || state.busy) return;
    final token = _begin(const LabJob(LabJobKind.bench));
    try {
      final run = await lab.bench(
        modelId,
        state.benchSpec,
        cancel: token,
        onPhase: (p) => _progress((j) => j.copyWith(phase: p)),
      );
      _end(LabJobKind.bench, lastRun: run, history: await lab.history.list(modelId));
      ref.invalidate(perfOverviewProvider(modelId));
    } on CancelledException {
      _end(LabJobKind.bench, message: const LabMessage.info('Benchmark cancelled.'));
    } on PerfLabException catch (e) {
      _end(LabJobKind.bench, message: LabMessage.error(e.message));
    }
  }

  Future<void> runCompare(LabConfig a, LabConfig b) async {
    final lab = _lab;
    if (lab == null || state.busy) return;
    state = state.copyWith(a: a, b: b);
    final token = _begin(const LabJob(LabJobKind.compare, progress: 0));
    try {
      final r = await lab.compare(
        modelId,
        a,
        b,
        spec: state.abSpec,
        cancel: token,
        onProgress: (p) => _progress((j) => j.copyWith(
              phase: p.phase,
              progress: p.fraction,
              detail: p.side == null
                  ? null
                  : 'Measuring ${p.side!.name.toUpperCase()}, run ${p.done ~/ 2 + 1} of ${p.total ~/ 2}',
            )),
      );
      _end(LabJobKind.compare, ab: r);
    } on CancelledException {
      _end(LabJobKind.compare, message: const LabMessage.info('Comparison cancelled.'));
    } on PerfLabException catch (e) {
      _end(LabJobKind.compare, message: LabMessage.error(e.message));
    }
  }

  Future<void> retune() async {
    final lab = _lab;
    if (lab == null || state.busy) return;
    final token = _begin(const LabJob(LabJobKind.autotune, progress: 0));
    try {
      final p = await lab.retune(
        modelId,
        cancel: token,
        onPhase: (ph) => _progress((j) => j.copyWith(phase: ph)),
        onProgress: (pr) => _progress((j) => j.copyWith(
              progress: pr.fraction,
              detail: autotuneDetail(pr),
            )),
      );
      _end(LabJobKind.autotune,
          message: LabMessage.success('Tuned: ${LabConfig.fromCandidate(p.candidate).summary}.'));
      ref.invalidate(perfOverviewProvider(modelId));
    } on CancelledException {
      _end(LabJobKind.autotune, message: const LabMessage.info('Autotune cancelled. The previous settings stay.'));
    } on PerfLabException catch (e) {
      _end(LabJobKind.autotune, message: LabMessage.error(e.message));
    }
  }

  /// Pins [config] as the override; [kind] says where the result shows.
  Future<void> apply(LabConfig config, {LabJobKind kind = LabJobKind.compare}) async {
    final lab = _lab;
    if (lab == null || state.busy) return;
    state = state.copyWith(applying: true, clearMessage: true);
    LabMessage message;
    try {
      await lab.apply(modelId, config);
      message = LabMessage.success('Applied ${config.summary}. Chats use it from the next message.');
    } on PerfLabException catch (e) {
      message = LabMessage.error(e.message);
    }
    if (!ref.mounted) return;
    state = state.copyWith(applying: false, message: message, messageFor: kind);
    ref.invalidate(perfOverviewProvider(modelId));
  }

  Future<void> resetToAuto({LabJobKind kind = LabJobKind.compare}) async {
    final lab = _lab;
    if (lab == null || state.busy) return;
    state = state.copyWith(applying: true, clearMessage: true);
    LabMessage message;
    try {
      await lab.resetToAuto(modelId);
      message = const LabMessage.success('Back to automatic settings.');
    } on PerfLabException catch (e) {
      message = LabMessage.error(e.message);
    }
    if (!ref.mounted) return;
    state = state.copyWith(applying: false, message: message, messageFor: kind);
    ref.invalidate(perfOverviewProvider(modelId));
  }

  Future<void> clearHistory() async {
    final lab = _lab;
    if (lab == null) return;
    await lab.history.clear(modelId);
    if (ref.mounted) state = PerfLabState(benchSpec: state.benchSpec, abSpec: state.abSpec, a: state.a, b: state.b, ab: state.ab);
  }
}

/// The sweep's progress line: "Checked 3 of 10: 4 threads · … , 16.2 tok/s
/// decode" (or why a candidate was skipped).
String autotuneDetail(AutotuneProgress p) {
  final c = p.candidate;
  if (c == null) return 'Checked ${p.done} of ${p.total}';
  final what = LabConfig.fromCandidate(c).summary;
  final outcome = switch (p.step) {
    AutotuneStep.measured => '${p.result!.genTokensPerSec.toStringAsFixed(1)} tok/s decode',
    AutotuneStep.repeated => 'measured already',
    AutotuneStep.doesNotFit => 'skipped: it doesn’t fit in memory',
    AutotuneStep.unsupported => 'skipped: the engine can’t use it',
    null => '',
  };
  return 'Checked ${p.done} of ${p.total}: $what${outcome.isEmpty ? '' : ', $outcome'}';
}
