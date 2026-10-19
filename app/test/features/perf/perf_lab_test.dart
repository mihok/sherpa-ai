import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/features/perf/state/perf_lab.dart';
import 'package:sherpa/features/perf/state/perf_models.dart';
import 'package:sherpa/features/perf/state/perf_stats.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';
import 'package:sherpa_inference/testing.dart';

import 'support/perf_rig.dart';

const _spec = BenchSpec(promptTokens: 128, genTokens: 32, reps: 3);
const _fourThreads = SessionConfig(nThreads: 4, nThreadsBatch: 4);

Map<int, ({double pp, double tg})> get _byThreads => {
      1: (pp: 60, tg: 6),
      2: (pp: 100, tg: 10),
      3: (pp: 140, tg: 14),
      4: (pp: 180, tg: 18),
    };

void main() {
  group('overview', () {
    test('describes the device, the engine, the tuned profile and the memory estimate', () async {
      final rig = await PerfRig.create(memory: FakeMemoryMonitor(memoryState(availableMib: 4096)));
      addTearDown(rig.dispose);
      await rig.addModelAndStart();

      final o = await rig.lab.overview('m1');
      expect(o.modelName, 'Qwen3 0.6B');
      expect(o.device!.socModel, 'Tensor G3');
      expect(o.engine.version, 'fake 1.0');
      expect(o.engine.kleidiAi, isTrue);
      expect(o.engine.backendLabel, 'CPU · KleidiAI');
      expect(o.engine.system!.performanceCores, 4);
      expect(o.profile, isNull, reason: 'not tuned yet');
      expect(o.defaults.nThreads, 4);
      expect(o.current.loaded, isFalse);
      expect(o.current.contextTokens, 8192);
      expect(o.current.estimate!.totalBytes, greaterThan(0));
      expect(o.budget.totalBytes, (4096 * mib * 0.75).round() - 128 * mib);
      expect(o.addedBackBytes, 0);
      expect(o.toolCalling, isTrue);
    });

    test('a warm model shows its live session and counts its own memory as available', () async {
      final rig = await PerfRig.create(
        host: FakeEngineHost(bench: scriptedBench(_byThreads)),
        memory: FakeMemoryMonitor(memoryState(availableMib: 4096)),
        sessionDefaults: _fourThreads,
      );
      addTearDown(rig.dispose);
      await rig.addModelAndStart();
      await rig.lab.bench('m1', _spec);

      final o = await rig.lab.overview('m1');
      expect(o.current.loaded, isTrue);
      expect(o.current.config.nThreads, 4);
      expect(o.current.liveMemory, isNotNull);
      expect(o.current.flashAttentionOn, isFalse);
      expect(o.addedBackBytes, rig.local.lifecycle!.loaded!.estimate!.anonymousBytes);
    });

    test('the engine-unavailable state carries the reason', () async {
      final rig = await PerfRig.create(host: FakeEngineHost()..startError = const EngineUnavailableException('no engine in this build'));
      addTearDown(rig.dispose);
      await rig.library.add(libraryModel('m1'));
      await expectLater(
        rig.lab.overview('m1'),
        throwsA(isA<PerfLabException>()
            .having((e) => e.unavailable, 'unavailable', isTrue)
            .having((e) => e.message, 'message', contains('no engine in this build'))),
      );
    });
  });

  group('benchmark', () {
    test('reports prefill, decode, TTFT, peak memory and thermal, and keeps the last 10 runs', () async {
      final rig = await PerfRig.create(
        host: FakeEngineHost(bench: scriptedBench({4: (pp: 200, tg: 20)})),
        sessionDefaults: _fourThreads,
      );
      addTearDown(rig.dispose);
      rig.memory.emit(memoryState(thermal: ThermalLevel.fair));
      await rig.addModelAndStart();

      final run = await rig.lab.bench('m1', _spec);
      expect(run.method, BenchMethod.bench);
      expect(run.sample.prefillTps, 200);
      expect(run.sample.decodeTps, 20);
      // 128 tokens at 200 tok/s, then one decode step at 20 tok/s.
      expect(run.sample.ttftMs, closeTo(640 + 50, 1e-6));
      expect(run.sample.baselineMemoryBytes, 500 * mib);
      expect(run.sample.peakMemoryBytes, 620 * mib);
      expect(run.sample.thermalBefore, ThermalLevel.fair);
      expect(run.sample.thermalAfter, ThermalLevel.fair);
      expect(run.config.nThreads, 4);
      expect(run.at, rig.clock.now());

      final bench = rig.fake.benches.single;
      expect(bench.nPrompt, 128);
      expect(bench.nGen, 32);
      expect(bench.nReps, 4, reason: '3 measured runs after a warm-up');
      expect(bench.nThreads, 4);

      for (var i = 0; i < 11; i++) {
        await rig.lab.bench('m1', _spec);
      }
      final history = await rig.lab.history.list('m1');
      expect(history, hasLength(10));
      // Persisted in the engine's notes store (cleared by "Delete all data").
      expect(await rig.local.store.read('sherpa.perf.history.m1'), isNotNull);
    });

    test('runs as background work: it waits for a reply and never overlaps it', () async {
      final fake = FakeEngineHost(eventDelay: const Duration(milliseconds: 10), bench: scriptedBench(_byThreads));
      fake.defaultScript = (_) => fakeReply('x' * 60);
      final rig = await PerfRig.create(host: fake, sessionDefaults: _fourThreads);
      addTearDown(rig.dispose);
      await rig.addModelAndStart();

      final reply = replyText(rig.local.provider, 'm1', 'hello');
      await until(() => rig.host.log.contains('generate start'));
      final phases = <LabJobPhase>[];
      final run = rig.lab.bench('m1', _spec, onPhase: phases.add);
      await until(() => phases.isNotEmpty);
      expect(phases.first, LabJobPhase.waiting);
      expect(rig.host.benchesStarted, 0);
      await reply;
      await run;
      expect(rig.host.log, ['generate start', 'generate done', 'bench start', 'bench done']);
      expect(phases, contains(LabJobPhase.running));
    });

    test('is preempted by a foreground request, then runs again once the reply is done', () async {
      final rig = await PerfRig.create(host: FakeEngineHost(bench: scriptedBench(_byThreads)), sessionDefaults: _fourThreads);
      addTearDown(rig.dispose);
      await rig.addModelAndStart();
      rig.host.holdBenches();

      final phases = <LabJobPhase>[];
      final run = rig.lab.bench('m1', _spec, onPhase: phases.add);
      await until(() => rig.host.benchesStarted == 1);
      final reply = replyText(rig.local.provider, 'm1', 'hello');
      await until(() => rig.host.benchesCancelled == 1);
      expect(await reply, 'ok');
      await until(() => rig.host.benchesStarted == 2);
      expect(rig.host.log, ['bench start', 'bench cancelled', 'generate start', 'generate done', 'bench start']);
      expect(phases, contains(LabJobPhase.paused));

      rig.host.releaseBenches();
      final r = await run;
      expect(r.sample.decodeTps, 18);
      expect(await rig.lab.history.list('m1'), hasLength(1));
      // The reply's own numbers reach the live monitor.
      expect(rig.local.lastGeneration!.perf.decodeTokensPerSec, 20);
      expect(rig.local.lastGeneration!.modelId, 'm1');
    });

    test('cancel stops a running bench; nothing is recorded', () async {
      final rig = await PerfRig.create(host: FakeEngineHost(bench: scriptedBench(_byThreads)), sessionDefaults: _fourThreads);
      addTearDown(rig.dispose);
      await rig.addModelAndStart();
      rig.host.holdBenches();

      final token = CancellationToken();
      final run = rig.lab.bench('m1', _spec, cancel: token);
      await until(() => rig.host.benchesStarted == 1);
      token.cancel();
      await expectLater(run, throwsA(isA<CancelledException>()));
      expect(rig.host.benchesCancelled, 1);
      expect(await rig.lab.history.list('m1'), isEmpty);
      expect(rig.local.engine!.scheduler.state.isIdle, isTrue);
    });

    test('cancel takes a queued bench out of the queue before it starts', () async {
      final fake = FakeEngineHost(eventDelay: const Duration(milliseconds: 10), bench: scriptedBench(_byThreads));
      fake.defaultScript = (_) => fakeReply('x' * 60);
      final rig = await PerfRig.create(host: fake, sessionDefaults: _fourThreads);
      addTearDown(rig.dispose);
      await rig.addModelAndStart();

      final reply = replyText(rig.local.provider, 'm1', 'hello');
      await until(() => rig.host.log.contains('generate start'));
      final token = CancellationToken();
      final run = rig.lab.bench('m1', _spec, cancel: token);
      await until(() => rig.local.engine!.scheduler.state.queued.isNotEmpty);
      token.cancel();
      await expectLater(run, throwsA(isA<CancelledException>()));
      await reply;
      expect(rig.host.benchesStarted, 0);
    });
  });

  group('A/B', () {
    const a = LabConfig(nThreads: 2, nBatch: 512, nUbatch: 256);
    final b = a.copyWith(nThreads: 4);

    test('alternates the configs and names a clear winner', () async {
      final rig = await PerfRig.create(host: FakeEngineHost(bench: scriptedBench(_byThreads, noise: [0, 0.02, -0.02, 0.01])));
      addTearDown(rig.dispose);
      await rig.addModelAndStart();

      final progress = <AbProgress>[];
      final r = await rig.lab.compare('m1', a, b, spec: const BenchSpec.comparison(reps: 4), onProgress: progress.add);
      expect(r.method, BenchMethod.bench);
      expect(r.aSamples, hasLength(4));
      expect(r.bSamples, hasLength(4));
      expect([for (final c in rig.fake.benches) c.nThreads], [2, 4, 2, 4, 2, 4, 2, 4]);
      expect(rig.fake.benches.every((c) => c.nReps == 2), isTrue, reason: 'one warm-up, one measured run per call');
      expect(r.winner, Winner.b);
      expect(r.winningConfig, b);
      expect(r.metrics[AbMetric.decode]!.winner, Winner.b);
      expect(r.metrics[AbMetric.ttft]!.winner, Winner.b);
      expect(r.headline.advantage, greaterThan(0.3));
      expect(progress.last.done, 8);
      // Comparing changes nothing until "Apply".
      expect((await rig.local.lifecycle!.autotuner!.overrides('m1')).isEmpty, isTrue);
    });

    test('no winner when the difference is within noise', () async {
      final rig = await PerfRig.create(
        host: FakeEngineHost(bench: scriptedBench({2: (pp: 100, tg: 10), 4: (pp: 100, tg: 10)}, noise: [0, 0.03, -0.03, 0.01, -0.01])),
      );
      addTearDown(rig.dispose);
      await rig.addModelAndStart();

      final r = await rig.lab.compare('m1', a, b, spec: const BenchSpec.comparison(reps: 5));
      expect(r.headline.enoughReps, isTrue);
      expect(r.headline.a.overlaps(r.headline.b), isTrue);
      expect(r.winner, Winner.none);
      expect(r.winningConfig, isNull);
    });

    test('too few runs never call a winner', () async {
      final rig = await PerfRig.create(host: FakeEngineHost(bench: scriptedBench(_byThreads)));
      addTearDown(rig.dispose);
      await rig.addModelAndStart();
      final r = await rig.lab.compare('m1', a, b, spec: const BenchSpec.comparison(reps: 2));
      expect(r.headline.enoughReps, isFalse);
      expect(r.winner, Winner.none);
    });

    test('refuses a config that would not fit memory, and an invalid one', () async {
      // Budget 1600 × 0.75 − 128 = 1072 MB: an f16 KV cache at 8192 tokens
      // (1326 MB in the fake estimator) doesn't fit, q8_0 (906 MB) does.
      final rig = await PerfRig.create(
        host: FakeEngineHost(bench: scriptedBench(_byThreads)),
        memory: FakeMemoryMonitor(memoryState(availableMib: 1600)),
      );
      addTearDown(rig.dispose);
      await rig.addModelAndStart();
      const q8 = LabConfig(nThreads: 2, kv: KvType.q8_0);
      const f16 = LabConfig(nThreads: 4);

      final fit = await rig.lab.checkFit('m1', f16);
      expect(fit.fits, isFalse);
      expect(fit.contextTokens, 8192);
      expect(fit.problem, contains('Won’t fit'));
      expect(fit.problem, contains('8192-token context'));
      expect((await rig.lab.checkFit('m1', q8)).fits, isTrue);

      await expectLater(
        rig.lab.compare('m1', q8, f16),
        throwsA(isA<PerfLabException>().having((e) => e.message, 'message', allOf(contains('Setting B'), contains('Won’t fit')))),
      );
      await expectLater(rig.lab.apply('m1', f16), throwsA(isA<PerfLabException>()));
      expect(rig.fake.benches, isEmpty);
      expect((await rig.local.lifecycle!.autotuner!.overrides('m1')).isEmpty, isTrue);

      const noFlash = LabConfig(kv: KvType.q8_0, flashAttention: FlashAttention.off);
      expect((await rig.lab.checkFit('m1', noFlash)).problem, contains('needs flash attention'));
      await expectLater(rig.lab.compare('m1', q8, noFlash), throwsA(isA<PerfLabException>()));
    });

    test('speculative configs are measured with real generations on both sides', () async {
      final fake = FakeEngineHost();
      fake.defaultScript = (_) {
        final ngram = fake.sessionConfigs.last.speculative == SpeculativeMode.ngram;
        return [
          const EngineEvent.text('1. The parcel'),
          const EngineEvent(type: EngineEventType.usage, promptTokens: 130, completionTokens: 32),
          EngineEvent(
            type: EngineEventType.perf,
            ttftMs: 400,
            prefillTps: 300,
            decodeTps: ngram ? 30 : 20,
            nDrafted: ngram ? 40 : 0,
            nAccepted: ngram ? 32 : 0,
            draftAcceptRate: ngram ? 0.8 : 0,
            name: 'CPU',
          ),
          const EngineEvent(type: EngineEventType.finish, code: 1, name: 'stop'),
        ];
      };
      final rig = await PerfRig.create(host: fake);
      addTearDown(rig.dispose);
      await rig.addModelAndStart();

      const off = LabConfig(nThreads: 4);
      final ngram = off.copyWith(speculative: SpeculativeChoice.ngram);
      final r = await rig.lab.compare('m1', off, ngram, spec: const BenchSpec.comparison(reps: 3));
      expect(r.method, BenchMethod.generation);
      expect(fake.benches, isEmpty);
      expect(r.winner, Winner.b);
      expect(r.bSamples.first.draftAcceptRate, 0.8);
      expect(r.aSamples.first.draftAcceptRate, isNull);
      expect(r.aSamples.first.ttftMs, 400);
      expect(fake.requests.first, contains('Copy this list exactly'));
      final temp = fake.sessionConfigs.skip(1).toList();
      expect([for (final c in temp) c.speculative],
          [for (var i = 0; i < 3; i++) ...[SpeculativeMode.none, SpeculativeMode.ngram]]);
      expect(temp.every((c) => c.nThreads == 4 && c.nCtx <= 512), isTrue);
      // Every temporary session was freed; only the warm model's remains.
      expect(fake.liveSessions, hasLength(1));
    });
  });

  group('overrides and autotune', () {
    test('apply pins the winner as the override; reset returns to auto', () async {
      final rig = await PerfRig.create(host: FakeEngineHost(bench: scriptedBench(_byThreads)));
      addTearDown(rig.dispose);
      await rig.addModelAndStart();
      final tuner = rig.local.lifecycle!.autotuner!;
      const pick = LabConfig(nThreads: 2, nBatch: 256, nUbatch: 256, kv: KvType.q8_0, flashAttention: FlashAttention.on);

      // Not tuned yet: saved, but the lifecycle applies overrides on top of
      // a measured profile only.
      expect(await rig.lab.apply('m1', pick), isFalse);
      expect((await tuner.overrides('m1')).toJson(), pick.overrides.toJson());

      final progress = <AutotuneProgress>[];
      final tuned = await rig.lab.retune('m1', onProgress: progress.add);
      expect(progress.first.done, 0);
      expect(progress.last.fraction, 1);
      expect(progress.where((p) => p.last != null), hasLength(10), reason: '4 thread counts, 3 batch sizes, 3 KV variants');
      expect(tuned.source, AutotuneSource.override);
      expect(tuned.candidate, pick.candidate);

      expect(await rig.lab.apply('m1', pick), isTrue);
      await until(() => rig.local.lifecycle!.loaded == null);
      final plan = await rig.local.lifecycle!.plan('m1');
      expect(plan.config!.nThreads, 2);
      expect(plan.config!.nBatch, 256);
      expect(plan.config!.typeK, KvType.q8_0);

      await rig.lab.apply('m1', pick.copyWith(speculative: SpeculativeChoice.ngram));
      expect(rig.local.speculativeFor('m1'), SpeculativeMode.ngram);
      expect((await rig.local.lifecycle!.plan('m1')).config!.speculative, SpeculativeMode.ngram);

      await rig.lab.resetToAuto('m1');
      expect((await tuner.overrides('m1')).isEmpty, isTrue);
      expect(rig.local.speculativeFor('m1'), isNull);
      expect(rig.local.lifecycle!.spec('m1')!.sessionDefaults.speculative, SpeculativeMode.none);
      expect((await tuner.cached('m1'))!.source, AutotuneSource.measured);

      await expectLater(
        rig.lab.apply('m1', pick.copyWith(speculative: SpeculativeChoice.draft, draftModelId: 'd')),
        throwsA(isA<PerfLabException>().having((e) => e.message, 'message', contains('draft model'))),
      );
    });

    test('autotune can be cancelled and keeps the previous profile', () async {
      final rig = await PerfRig.create(host: FakeEngineHost(bench: scriptedBench(_byThreads)));
      addTearDown(rig.dispose);
      await rig.addModelAndStart();
      rig.host.holdBenches();
      final token = CancellationToken();
      final run = rig.lab.retune('m1', cancel: token);
      await until(() => rig.host.benchesStarted == 1);
      token.cancel();
      await expectLater(run, throwsA(isA<CancelledException>()));
      expect(await rig.local.lifecycle!.autotuner!.cached('m1'), isNull);
    });
  });
}
