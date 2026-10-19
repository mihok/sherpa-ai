// The performance lab on the real engine: one tiny benchmark, a tiny A/B
// (1 thread vs N threads) and a speculative (n-gram) comparison, through
// the lab's own service code and the production engine host (FFI here).
//
// Runs only when both are set (skips cleanly otherwise):
//   SHERPA_ENGINE_LIB=/opt/vendor-src/sherpa-engine-build/host-shared/libsherpa_engine.so
//   SHERPA_TEST_MODEL=/opt/models/Qwen3-0.6B-Q4_K_M.gguf
//   cd app && flutter test --no-pub test/features/perf/perf_lab_engine_test.dart
// SHERPA_TEST_THREADS (default 2) sets the larger thread count.
@Tags(['engine'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/features/perf/state/perf_lab.dart';
import 'package:sherpa/features/perf/state/perf_models.dart';
import 'package:sherpa/services/inference/local_engine_host.dart';
import 'package:sherpa/services/inference/local_inference.dart';
import 'package:sherpa_inference/sherpa_inference.dart';

import 'support/perf_rig.dart';

String? _env(String name) {
  final v = Platform.environment[name];
  return v == null || v.isEmpty ? null : v;
}

String? _skipReason() {
  final lib = _env('SHERPA_ENGINE_LIB');
  final model = _env('SHERPA_TEST_MODEL');
  if (lib == null || model == null) return 'set SHERPA_ENGINE_LIB and SHERPA_TEST_MODEL to run the real engine';
  if (!File(lib).existsSync()) return 'SHERPA_ENGINE_LIB does not exist: $lib';
  if (!File(model).existsSync()) return 'SHERPA_TEST_MODEL does not exist: $model';
  return null;
}

int get _threads => int.tryParse(Platform.environment['SHERPA_TEST_THREADS'] ?? '') ?? 2;

String _f(double v) => v.toStringAsFixed(1);

void main() {
  test('benchmarks the real engine through the performance lab', () async {
    final rig = await PerfRig.create(
      hostFactory: createLocalEngineHost,
      sessionDefaults: SessionConfig(nThreads: _threads, nThreadsBatch: _threads, seed: 42),
      maxContext: 4096,
    );
    addTearDown(rig.dispose);

    // The GGUF, linked into the library as an import would place it.
    final model = File(_env('SHERPA_TEST_MODEL')!);
    final link = Link(rig.layout.libraryPath('imported/qwen/model.gguf'));
    await link.parent.create(recursive: true);
    await link.create(model.absolute.path);
    await rig.library.add(libraryModel('qwen', name: 'Qwen3 0.6B', sha: null, sizeBytes: model.lengthSync()));

    final status = await rig.local.start();
    expect(status.state, LocalEngineState.ready, reason: status.reason);
    expect(rig.local.host!.kind, EngineHostKind.inProcessFfi);

    // Real memory readings (/proc/self/status) and the platform's device facts.
    final lab = PerfLab(local: rig.local, memory: rig.memory, device: captureDeviceSnapshot);

    final o = await lab.overview('qwen');
    // ignore: avoid_print
    print('engine ${o.engine.version} · ${o.engine.backendLabel} · ${o.engine.hostLabel} · '
        'perf cores ${o.engine.system?.performanceCores} of ${o.engine.system?.logicalCores} · '
        'features ${(o.engine.system?.cpuFeatures.toList() ?? [])..sort()}');
    // ignore: avoid_print
    print('plan: ${o.current.contextTokens}-token context, ${o.current.config.summary}, '
        'estimate ${(o.current.estimate!.totalBytes / (1 << 20)).round()} MiB');

    final run = await lab.bench('qwen', const BenchSpec(promptTokens: 64, genTokens: 16, reps: 2));
    final s = run.sample;
    // ignore: avoid_print
    print('bench pp64/tg16 ×2 (${run.config.summary}): prefill ${_f(s.prefillTps)} tok/s, '
        'decode ${_f(s.decodeTps)} tok/s, TTFT ${s.ttftMs.round()} ms, '
        'peak RSS ${((s.peakMemoryBytes ?? 0) / (1 << 20)).round()} MiB '
        '(+${(((s.peakMemoryBytes ?? 0) - (s.baselineMemoryBytes ?? 0)) / (1 << 20)).round()} MiB)');
    expect(s.prefillTps, greaterThan(0));
    expect(s.decodeTps, greaterThan(0));
    expect(s.ttftMs, greaterThan(0));
    expect(s.peakMemoryBytes, isNotNull);
    expect(await lab.history.list('qwen'), hasLength(1));

    final ab = await lab.compare(
      'qwen',
      const LabConfig(nThreads: 1, nBatch: 64, nUbatch: 64),
      LabConfig(nThreads: _threads, nBatch: 64, nUbatch: 64),
      spec: const BenchSpec.comparison(promptTokens: 64, genTokens: 16, reps: 3),
    );
    for (final m in AbMetric.values) {
      final c = ab.metrics[m]!;
      // ignore: avoid_print
      print('A/B ${m.label}: A(t1) ${_f(c.a.median)} [${_f(c.a.q1)}–${_f(c.a.q3)}] vs '
          'B(t$_threads) ${_f(c.b.median)} [${_f(c.b.q1)}–${_f(c.b.q3)}] ${m.unit} → ${c.winner.name}');
    }
    expect(ab.aSamples, hasLength(3));
    expect(ab.bSamples, hasLength(3));

    final spec = await lab.compare(
      'qwen',
      LabConfig(nThreads: _threads),
      LabConfig(nThreads: _threads, speculative: SpeculativeChoice.ngram),
      spec: const BenchSpec.comparison(promptTokens: 128, genTokens: 48, reps: 3),
    );
    expect(spec.method, BenchMethod.generation);
    final acc = [for (final r in spec.bSamples) ?r.draftAcceptRate];
    // ignore: avoid_print
    print('speculative (generation, pp~128/tg48 ×3): off decode ${_f(spec.metrics[AbMetric.decode]!.a.median)} tok/s, '
        'n-gram decode ${_f(spec.metrics[AbMetric.decode]!.b.median)} tok/s, accepted '
        '${acc.isEmpty ? 'n/a' : acc.map((a) => '${(a * 100).round()}%').join('/')}, '
        'prompt ${spec.aSamples.first.promptTokens} tokens → ${spec.winner.name}');
    expect(spec.aSamples.every((r) => r.decodeTps > 0), isTrue);
  }, skip: _skipReason(), timeout: const Timeout(Duration(minutes: 8)));
}
