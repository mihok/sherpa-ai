import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';
import 'package:sherpa_inference/testing.dart';

TuningSample _s(int threads, double pp, double tg, {KvType kv = KvType.f16, int batch = 512}) =>
    TuningSample(TuningCandidate(nThreads: threads, nBatch: batch, typeK: kv, typeV: kv), pp, tg);

/// A device where 4 threads decode fastest, larger batches prefill faster up
/// to 256, and q8_0 + flash attention is slightly faster than f16.
BenchResult _deviceModel(BenchConfig c) {
  final tg = switch (c.nThreads) { 1 => 6.0, 2 => 11.0, 3 => 14.0, 4 => 16.0, 5 => 13.0, _ => 11.0 };
  final pp = switch (c.nBatch) { 128 => 60.0, 256 => 90.0, _ => 88.0 } * c.nThreads / 4;
  final kvBoost = c.typeK == KvType.q8_0 ? 1.05 : (c.flashAttention == FlashAttention.on ? 1.02 : 1.0);
  return BenchResult(
    nPrompt: c.nPrompt,
    nGen: c.nGen,
    nThreads: c.nThreads,
    promptTokensPerSec: pp * kvBoost,
    genTokensPerSec: tg * kvBoost,
    promptMs: 0,
    genMs: 0,
  );
}

const _env = AutotuneEnvironment(
  deviceId: 'Pixel 9',
  osVersion: '17',
  appVersion: '1.0.0',
  engineVersion: 'sherpa_engine 1.0.0 (abi 1, llama.cpp 0c1e570)',
  performanceCores: 6,
);

void main() {
  group('Autotuner.select', () {
    test('minimizes the turn time of the workload', () {
      const w = AutotuneWorkload(promptTokens: 512, genTokens: 150);
      // 2 threads: 23.9 s; 4 threads: 512/80 + 150/16 = 15.8 s; 6 threads: 17.6 s.
      final best = Autotuner.select([_s(2, 50, 11), _s(4, 80, 16), _s(6, 100, 12)], workload: w);
      expect(best!.nThreads, 4);
      // A prefill-heavy workload prefers the faster prefill.
      final prefillHeavy =
          Autotuner.select([_s(4, 80, 16), _s(6, 160, 15)], workload: const AutotuneWorkload(promptTokens: 4000, genTokens: 10));
      expect(prefillHeavy!.nThreads, 6);
    });

    test('ties within 3 % go to fewer threads, then to the smaller KV cache', () {
      expect(Autotuner.select([_s(6, 100, 16.2), _s(4, 100, 16)])!.nThreads, 4);
      expect(Autotuner.select([_s(4, 100, 16), _s(4, 100, 16.1, kv: KvType.q8_0)])!.typeK, KvType.q8_0);
    });

    test('respects the memory filter and ignores failed samples', () {
      final best = Autotuner.select(
        [_s(4, 100, 20), _s(4, 90, 18, kv: KvType.q8_0), _s(2, 0, 0)],
        allowed: (c) => c.typeK != KvType.f16,
      );
      expect(best!.typeK, KvType.q8_0);
      expect(Autotuner.select([_s(2, 0, 0)]), isNull);
      expect(Autotuner.select(const []), isNull);
    });
  });

  group('Autotuner.profileFor', () {
    late FakeEngineHost host;
    late InMemoryKeyValueStore store;
    const model = ModelRef(1, 0);

    setUp(() {
      host = FakeEngineHost(bench: _deviceModel);
      store = InMemoryKeyValueStore();
    });

    test('staged sweep: threads, then batch sizes, then KV × flash attention', () async {
      final tuner = Autotuner(host: host, store: store, environment: _env);
      final profile = await tuner.profileFor(model: model, modelKey: 'qwen');
      expect(profile.source, AutotuneSource.measured);
      expect(profile.candidate.nThreads, 4);
      expect(profile.candidate.nBatch, 256);
      expect(profile.candidate.typeK, KvType.q8_0);
      expect(profile.candidate.flashAttention, FlashAttention.on);
      // 6 thread counts + 2 new batch sizes + 3 KV variants (one already measured? no: f16/auto differs).
      expect(host.benches.length, lessThanOrEqualTo(6 + 3 + 3));
      expect(host.benches.map((b) => b.nThreads).toSet(), {1, 2, 3, 4, 5, 6});
      expect(profile.genTokensPerSec, greaterThan(16));
      expect(store.raw.keys.single, 'sherpa.autotune.profile.qwen');
    });

    test('a stored profile is reused; a new engine version re-tunes', () async {
      await Autotuner(host: host, store: store, environment: _env).profileFor(model: model, modelKey: 'qwen');
      final n = host.benches.length;
      final again = await Autotuner(host: host, store: store, environment: _env).profileFor(model: model, modelKey: 'qwen');
      expect(host.benches.length, n);
      expect(again.candidate.nThreads, 4);
      final newEngine = AutotuneEnvironment(
        deviceId: _env.deviceId,
        osVersion: _env.osVersion,
        appVersion: _env.appVersion,
        engineVersion: 'sherpa_engine 1.1.0',
        performanceCores: _env.performanceCores,
      );
      final tuner = Autotuner(host: host, store: store, environment: newEngine);
      expect(await tuner.cached('qwen'), isNull);
      await tuner.profileFor(model: model, modelKey: 'qwen');
      expect(host.benches.length, greaterThan(n));
    });

    test('power-user overrides win and can be cleared', () async {
      final tuner = Autotuner(host: host, store: store, environment: _env);
      await tuner.profileFor(model: model, modelKey: 'qwen');
      await tuner.setOverrides('qwen', const AutotuneOverrides(nThreads: 2, typeK: KvType.f16, typeV: KvType.f16));
      final p = (await tuner.cached('qwen'))!;
      expect(p.source, AutotuneSource.override);
      expect(p.candidate.nThreads, 2);
      expect(p.candidate.typeK, KvType.f16);
      expect(p.candidate.nBatch, 256, reason: 'measured values stay where not overridden');
      await tuner.setOverrides('qwen', const AutotuneOverrides());
      expect((await tuner.cached('qwen'))!.candidate.nThreads, 4);
    });

    test('candidates over the memory budget are not benched', () async {
      final tuner = Autotuner(host: host, store: store, environment: _env);
      final p = await tuner.profileFor(model: model, modelKey: 'qwen', fits: (c) async => c.typeK != KvType.q8_0);
      expect(p.candidate.typeK, KvType.f16);
      expect(host.benches.where((b) => b.typeK == KvType.q8_0), isEmpty);
    });

    test('unsupported combinations are skipped, not fatal', () async {
      final failing = FakeEngineHost(bench: (c) {
        if (c.flashAttention == FlashAttention.off) throw const EngineException(-1, 'quantized V needs FA');
        return _deviceModel(c);
      });
      final p = await Autotuner(host: failing, store: store, environment: _env).profileFor(model: model, modelKey: 'q');
      expect(p.candidate.flashAttention, isNot(FlashAttention.off));
    });

    test('cancellation stops the sweep', () async {
      final token = CancellationToken()..cancel();
      await expectLater(Autotuner(host: host, store: store, environment: _env).profileFor(model: model, modelKey: 'q', cancel: token),
          throwsA(isA<CancelledException>()));
      expect(store.raw, isEmpty);
    });

    test('profiles round-trip through JSON and apply to a session config', () async {
      final p = await Autotuner(host: host, store: store, environment: _env).profileFor(model: model, modelKey: 'qwen');
      final back = AutotuneProfile.fromJson(p.toJson());
      expect(back.candidate, p.candidate);
      expect(back.samples, hasLength(p.samples.length));
      final cfg = back.candidate.applyTo(const SessionConfig(nCtx: 4096, seed: 3));
      expect((cfg.nCtx, cfg.seed, cfg.nThreads, cfg.nBatch, cfg.typeV), (4096, 3, 4, 256, KvType.q8_0));
    });
  });

  group('overrides before a sweep, speculative mode and progress', () {
    late FakeEngineHost host;
    late InMemoryKeyValueStore store;
    const model = ModelRef(1, 0);

    setUp(() {
      host = FakeEngineHost(bench: _deviceModel);
      store = InMemoryKeyValueStore();
    });

    test('overrides apply on top of the defaults before anything is measured', () async {
      final tuner = Autotuner(host: host, store: store, environment: _env);
      expect(await tuner.cached('qwen'), isNull, reason: 'neither measured nor overridden');
      await tuner.setOverrides('qwen', const AutotuneOverrides(nThreads: 2, speculative: SpeculativeMode.ngram));
      final p = (await tuner.cached('qwen'))!;
      expect(p.source, AutotuneSource.override);
      expect(p.environmentKey, _env.key('qwen'));
      expect(p.candidate, tuner.defaults.copyWith(nThreads: 2, speculative: SpeculativeMode.ngram));
      expect(p.samples, isEmpty);
      expect(p.measuredAt, isNull);
      expect(await tuner.isTuned('qwen'), isFalse, reason: 'overrides do not replace the sweep');
      expect(await tuner.measured('qwen'), isNull);

      // The first-use sweep still runs, and the overrides win over it.
      final tuned = await tuner.profileFor(model: model, modelKey: 'qwen');
      expect(host.benches, isNotEmpty);
      expect(tuned.source, AutotuneSource.override);
      expect(tuned.candidate.nThreads, 2);
      expect(tuned.candidate.nBatch, 256, reason: 'measured where not overridden');
      expect(tuned.candidate.speculative, SpeculativeMode.ngram);
      expect(await tuner.isTuned('qwen'), isTrue);
      expect((await tuner.measured('qwen'))!.candidate.speculative, isNull, reason: 'the stored profile is the measurement');
    });

    test('speculative mode and draft model in candidates and overrides: JSON, apply, compatibility', () {
      const draft = TuningCandidate(nThreads: 4, typeK: KvType.q8_0, typeV: KvType.q8_0, speculative: SpeculativeMode.draft, draftModelId: 'qwen-0.5b');
      expect(TuningCandidate.fromJson(draft.toJson()), draft);
      expect(draft.toString(), endsWith('spec:draft(qwen-0.5b)'));
      const plain = TuningCandidate(nThreads: 4);
      expect(plain.toJson().containsKey('speculative'), isFalse, reason: 'older readers see the old shape');
      expect(TuningCandidate.fromJson(const {'nThreads': 4, 'nBatch': 512, 'nUbatch': 256}).speculative, isNull);
      expect(TuningCandidate.fromJson(const {'nThreads': 4, 'speculative': 'from_the_future'}).speculative, isNull);
      expect(plain == plain.copyWith(speculative: SpeculativeMode.none), isFalse);

      // Null leaves the session's own mode; a set mode replaces it.
      const ngramSession = SessionConfig(speculative: SpeculativeMode.ngram);
      expect(plain.applyTo(ngramSession).speculative, SpeculativeMode.ngram);
      expect(plain.copyWith(speculative: SpeculativeMode.none).applyTo(ngramSession).speculative, SpeculativeMode.none);
      expect(draft.applyTo(const SessionConfig()).speculative, SpeculativeMode.draft);

      const o = AutotuneOverrides(speculative: SpeculativeMode.draft, draftModelId: 'qwen-0.5b');
      expect(o.isEmpty, isFalse);
      expect(const AutotuneOverrides(draftModelId: 'x').isEmpty, isFalse);
      expect(AutotuneOverrides.fromJson(o.toJson()).toJson(), o.toJson());
      expect(o.apply(plain), plain.copyWith(speculative: SpeculativeMode.draft, draftModelId: 'qwen-0.5b'));
      expect(o.copyWith(nThreads: 3).nThreads, 3);
      expect(o.copyWith(clearDraftModelId: true).draftModelId, isNull);
      expect(o.copyWith(speculative: SpeculativeMode.ngram).speculative, SpeculativeMode.ngram);
      // Overrides stored by an older app still read.
      expect(AutotuneOverrides.fromJson(const {'nThreads': 2}).speculative, isNull);
    });

    test('progress reports every candidate the sweep considers', () async {
      final failing = FakeEngineHost(bench: (c) {
        if (c.flashAttention == FlashAttention.off) throw const EngineException(-1, 'not with this V type');
        return _deviceModel(c);
      });
      // (f16, auto) is the stage-2 winner itself: measured already.
      final tuner = Autotuner(
        host: failing,
        store: store,
        environment: _env,
        sweep: AutotuneSweep(threads: const [1, 2, 3, 4, 5, 6], kvVariants: const [
          (KvType.f16, FlashAttention.auto),
          (KvType.f16, FlashAttention.off),
          (KvType.q8_0, FlashAttention.on),
        ]),
      );
      final progress = <AutotuneProgress>[];
      final samples = <TuningCandidate>[];
      await tuner.profileFor(
        model: model,
        modelKey: 'qwen',
        fits: (c) async => c.nBatch != 128,
        onSample: (c, _) => samples.add(c),
        onProgress: progress.add,
      );
      expect(tuner.sweepSize, 6 + 3 + 3);
      expect(progress.first.done, 0);
      expect(progress.first.candidate, isNull);
      expect([for (final p in progress) p.done], [for (var i = 0; i <= tuner.sweepSize; i++) i]);
      expect(progress.last.isDone, isTrue);
      expect(progress.last.fraction, 1);
      final steps = [for (final p in progress.skip(1)) p.step];
      expect(steps.where((s) => s == AutotuneStep.measured), hasLength(samples.length));
      expect(steps, containsAll([AutotuneStep.repeated, AutotuneStep.doesNotFit, AutotuneStep.unsupported]));
      for (final p in progress.skip(1)) {
        expect(p.result != null, p.step == AutotuneStep.measured);
        expect(p.total, tuner.sweepSize);
      }
    });

    test('a stored profile reports no progress', () async {
      final tuner = Autotuner(host: host, store: store, environment: _env);
      await tuner.profileFor(model: model, modelKey: 'qwen');
      final progress = <AutotuneProgress>[];
      await tuner.profileFor(model: model, modelKey: 'qwen', onProgress: progress.add);
      expect(progress, isEmpty);
    });
  });

  test('AutotuneSweep.forCores caps at 8 threads', () {
    expect(AutotuneSweep.forCores(12).threads, [1, 2, 3, 4, 5, 6, 7, 8]);
    expect(AutotuneSweep.forCores(0).threads, [1]);
  });
}
