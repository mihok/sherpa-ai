import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';
import 'package:sherpa_inference/testing.dart';

const _mib = 1024 * 1024;

LocalModelSpec _spec(String id, {int preferred = 8192, bool tools = true}) =>
    LocalModelSpec(id: id, path: '/models/$id.gguf', displayName: id.toUpperCase(), preferredContext: preferred, toolCalling: tools);

void main() {
  late Directory tmp;
  late FakeEngineHost host;
  late FakeMemoryMonitor memory;
  late EngineForensics forensics;
  late PrefixCacheStore cache;
  late InMemoryKeyValueStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lifecycle_test');
    host = FakeEngineHost();
    memory = FakeMemoryMonitor(const MemoryState(pressure: MemoryPressure.normal, availableBytes: 4096 * _mib));
    forensics = EngineForensics(Directory('${tmp.path}/forensics'));
    cache = PrefixCacheStore(directory: Directory('${tmp.path}/kv'));
    store = InMemoryKeyValueStore();
  });

  tearDown(() async {
    await memory.dispose();
    await tmp.delete(recursive: true);
  });

  ModelLifecycleManager make({BackgroundPolicy background = BackgroundPolicy.pauseAndPersist}) => ModelLifecycleManager(
        host: host,
        memory: memory,
        forensics: forensics,
        prefixCache: cache,
        store: store,
        backgroundPolicy: background,
        minTokensToPersist: 1,
        policy: const AdmissionPolicy(fitFraction: 1, safetyMarginBytes: 0),
      )
        ..register(_spec('a'))
        ..register(_spec('b'));

  /// Runs one fake generation on a lease bound to [conversation].
  Future<void> generate(ModelLifecycleManager lc, String model, String conversation, {int prompt = 100}) async {
    host.scripts.add((_) => fakeReply('hi', promptTokens: prompt));
    final lease = await lc.acquire(model);
    try {
      final fp = ['tools', 'm1'];
      await lease.beginGeneration(conversation: conversation, fingerprint: fp);
      await host.generate(lease.session, '{}').toList();
      await lease.endGeneration(fingerprint: fp, promptTokens: prompt, completionTokens: 1);
    } finally {
      lease.release();
    }
  }

  test('acquire plans, loads once and keeps the model warm', () async {
    final lc = make();
    final events = <LifecycleEvent>[];
    lc.events.listen(events.add);
    final l1 = await lc.acquire('a');
    final caps = l1.capabilities;
    l1.release();
    final l2 = await lc.acquire('a');
    l2.release();
    expect(host.loads, hasLength(1));
    expect(caps.contextLength, 8192);
    expect(host.sessionConfigs.single.typeK, KvType.f16, reason: 'plenty of memory: f16 at the preferred context');
    expect(events.whereType<ModelLoadedEvent>().single.config.nCtx, 8192);
    await lc.dispose();
    expect(host.liveModels, isEmpty);
    expect(host.liveSessions, isEmpty);
  });

  test('admission shrinks the session to the measured memory, or refuses', () async {
    memory.emit(const MemoryState(pressure: MemoryPressure.normal, availableBytes: 700 * _mib));
    final lc = make();
    final lease = await lc.acquire('a');
    expect(lease.capabilities.contextLength, 4608);
    expect(host.sessionConfigs.single.typeK, KvType.q8_0);
    lease.release();
    await lc.unload();
    memory.emit(const MemoryState(pressure: MemoryPressure.normal, availableBytes: 300 * _mib));
    final refused = <LifecycleEvent>[];
    lc.events.listen(refused.add);
    await expectLater(lc.acquire('a'), throwsA(isA<AdmissionRefusedException>()));
    await Future<void>.delayed(Duration.zero);
    expect(refused.whereType<AdmissionRefusedEvent>(), hasLength(1));
    await lc.dispose();
  });

  test('switching models unloads the warm one after saving its prefix', () async {
    final lc = make();
    await generate(lc, 'a', 'chat1');
    final lease = await lc.acquire('b');
    lease.release();
    expect(host.loads.map((l) => l.path), ['/models/a.gguf', '/models/b.gguf']);
    expect(host.liveModels, hasLength(1));
    expect(host.saved, hasLength(1), reason: 'chat1 was persisted before the switch');
    expect(cache.entries.single.key.sessionId, 'chat1');
    await lc.dispose();
  });

  test('conversations share the session: switching saves one and restores the other', () async {
    final lc = make();
    await generate(lc, 'a', 'chat1');
    await generate(lc, 'a', 'chat2'); // saves chat1
    expect(host.saved, hasLength(1));
    final restored = lc.events.firstWhere((e) => e is PrefixRestoredEvent);
    final lease = await lc.acquire('a');
    final r = await lease.beginGeneration(conversation: 'chat1', fingerprint: ['tools', 'm1', 'm2']);
    lease.release();
    expect(r!.outcome, PrefixRestoreOutcome.restored);
    expect(r.tokens, 101);
    expect(((await restored) as PrefixRestoredEvent).conversation, 'chat1');
    expect(host.saved, hasLength(2), reason: 'chat2 was persisted when chat1 took the session');
    await lc.dispose();
  });

  test('the prefix-cache key ignores the draft model: a prefix saved while drafting restores without it', () async {
    // State files hold the target context's KV only (se_state_save), and the
    // engine's identity header has no draft field; see PrefixCacheKey.
    final lc = make()
      ..register(const LocalModelSpec(
        id: 'drafting',
        path: '/models/a.gguf',
        draftModelPath: '/models/a-draft.gguf',
        sessionDefaults: SessionConfig(speculative: SpeculativeMode.draft),
      ))
      ..register(const LocalModelSpec(id: 'plain', path: '/models/a.gguf'));
    await generate(lc, 'drafting', 'chat1');
    expect(host.loads.last.draftModelPath, '/models/a-draft.gguf');
    final drafted = lc.loaded!.keyFor('chat1');
    final lease = await lc.acquire('plain'); // the switch persists chat1
    try {
      expect(host.loads.last.draftModelPath, isNull);
      expect(lc.loaded!.keyFor('chat1'), drafted);
      expect(drafted.toJson().keys, isNot(contains('draft')));
      final r = await lease.beginGeneration(conversation: 'chat1', fingerprint: ['tools', 'm1', 'm2']);
      expect(r!.outcome, PrefixRestoreOutcome.restored);
    } finally {
      lease.release();
    }
    await lc.dispose();
  });

  test('a vision projector is loaded only by an engine that takes images', () async {
    const vlm = LocalModelSpec(id: 'vlm', path: '/models/vlm.gguf', mmprojPath: '/models/mmproj.gguf');
    // An engine without mtmd would refuse the projector (and so the model).
    var lc = make()..register(vlm);
    final plan = await lc.plan('vlm');
    expect(plan.notes, contains('vision is off: this engine build cannot take images'));
    (await lc.acquire('vlm')).release();
    expect(host.loads.last.mmprojPath, isNull);
    await lc.dispose();

    host = FakeEngineHost()
      ..startSystemInfoJson = '{"mtmd": true, "image_input": true}'
      ..modelInfoJson = fakeModelInfoJson(vision: true);
    lc = make()..register(vlm);
    final lease = await lc.acquire('vlm');
    try {
      expect(host.loads.last.mmprojPath, '/models/mmproj.gguf');
      expect(lease.capabilities.vision, isTrue);
    } finally {
      lease.release();
    }
    await lc.dispose();
  });

  test('a changed transcript invalidates the saved prefix', () async {
    final lc = make();
    await generate(lc, 'a', 'chat1');
    await generate(lc, 'a', 'chat2');
    final lease = await lc.acquire('a');
    final r = await lease.beginGeneration(conversation: 'chat1', fingerprint: ['tools', 'EDITED']);
    lease.release();
    expect(r!.outcome, PrefixRestoreOutcome.invalidated);
    expect(cache.entryFor(lc.loaded!.keyFor('chat1')), isNull);
    await lc.dispose();
  });

  test('critical pressure interrupts the generation, persists and unloads', () async {
    final lc = make();
    final lease = await lc.acquire('a');
    await lease.beginGeneration(conversation: 'c', fingerprint: const ['x']);
    await lease.endGeneration(fingerprint: const ['x'], promptTokens: 50);
    await lease.beginGeneration(conversation: 'c', fingerprint: const ['x', 'y']);
    final unloaded = lc.events.firstWhere((e) => e is ModelUnloadedEvent);
    memory.emit(const MemoryState(pressure: MemoryPressure.critical, availableBytes: 100 * _mib));
    await Future<void>.delayed(Duration.zero);
    expect(lease.interruptReason, 'memory_pressure');
    expect(host.cancels, 1);
    expect(lc.loaded, isNotNull, reason: 'unload waits for the lease');
    lease.release();
    expect(((await unloaded) as ModelUnloadedEvent).reason, contains('critical'));
    expect(lc.loaded, isNull);
    expect(host.saved, hasLength(1));
    await lc.dispose();
  });

  test('moderate pressure recreates the session smaller when idle', () async {
    final lc = make();
    (await lc.acquire('a')).release();
    final down = lc.events.firstWhere((e) => e is SessionDowngradedEvent);
    memory.emit(const MemoryState(pressure: MemoryPressure.moderate, availableBytes: 2000 * _mib));
    final e = (await down) as SessionDowngradedEvent;
    expect(e.from.typeK, KvType.f16);
    expect(e.to.typeK, KvType.q8_0);
    expect(e.to.nCtx, 8192);
    expect(host.sessionConfigs.last.typeK, KvType.q8_0);
    expect(host.liveSessions, hasLength(1));
    final next = lc.events.firstWhere((e) => e is SessionDowngradedEvent);
    memory.emit(const MemoryState(pressure: MemoryPressure.moderate, availableBytes: 2000 * _mib));
    expect(((await next) as SessionDowngradedEvent).to.nCtx, 4096);
    expect(lc.loaded!.capabilities.contextLength, 4096);
    await lc.dispose();
  });

  test('background (pauseAndPersist) stops at a token boundary, unloads, and gates acquire until foreground', () async {
    final lc = make();
    await generate(lc, 'a', 'chat1');
    final lease = await lc.acquire('a');
    await lease.beginGeneration(conversation: 'chat1', fingerprint: const ['tools', 'm1']);
    final bg = lc.onAppBackground();
    await Future<void>.delayed(Duration.zero);
    expect(lease.interruptReason, 'app_background');
    lease.release();
    await bg;
    expect(lc.loaded, isNull);
    expect(lc.isPaused, isTrue);
    expect(host.saved, hasLength(1));
    var acquired = false;
    final pending = lc.acquire('a').then((l) {
      acquired = true;
      return l;
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(acquired, isFalse);
    lc.onAppForeground();
    final again = await pending;
    final r = await again.beginGeneration(conversation: 'chat1', fingerprint: const ['tools', 'm1', 'm2']);
    again.release();
    expect(r!.restored, isTrue, reason: 'the prefix comes back from disk after the reload');
    await lc.dispose();
  });

  test('persistOnly keeps the model and saves the prefix', () async {
    final lc = make(background: BackgroundPolicy.persistOnly);
    await generate(lc, 'a', 'chat1');
    await lc.onAppBackground();
    expect(lc.loaded, isNotNull);
    expect(host.saved, hasLength(1));
    await lc.dispose();
  });

  test('a crash during generation is reported on next start and halves the context', () async {
    final lc = make();
    await generate(lc, 'a', 'chat1');
    final lease = await lc.acquire('a');
    await lease.beginGeneration(conversation: 'chat1', fingerprint: const ['x']);
    // The process "dies" here: the phase file still says generating.
    final phase = jsonDecode(await File(forensics.phaseFilePath).readAsString()) as Map;
    expect(phase['phase'], 'generating');
    expect(phase['nCtx'], 8192);

    final next = make();
    final report = await next.start();
    expect(report, isNotNull);
    expect(report!.phase.phase, InferencePhase.generating);
    expect(report.isNativeAbort, isFalse);
    expect(report.description, contains('while generating a reply with A (8192-token context)'));
    expect(await next.downgradeFor('a'), 4096);
    final l = await next.acquire('a');
    expect(l.capabilities.contextLength, 4096);
    l.release();
    final plan = await next.plan('a');
    expect(plan.notes.first, contains('earlier engine crash'));
    await next.clearDowngrade('a');
    expect(await next.downgradeFor('a'), isNull);
    expect(await File(forensics.phaseFilePath).exists(), isTrue, reason: 'the new run records its own phases');
    await next.dispose();
  });

  test('an engine breadcrumb is a native abort', () async {
    await Directory('${tmp.path}/forensics').create(recursive: true);
    await File(forensics.engineBreadcrumbPath).writeAsString('GGML_ASSERT(n_outputs_max >= n_seq_max) failed\n');
    final lc = make();
    final report = await lc.start();
    expect(report!.isNativeAbort, isTrue);
    expect(report.engineMessage, contains('GGML_ASSERT'));
    expect(report.description, startsWith('The on-device engine crashed'));
    expect(await File(forensics.engineBreadcrumbPath).exists(), isFalse, reason: 'consumed');
    expect(await lc.start(), isNull, reason: 'start is idempotent');
    await lc.dispose();
  });

  test('a clean previous run reports nothing', () async {
    final lc = make();
    await generate(lc, 'a', 'chat1');
    await lc.dispose();
    expect(await make().start(), isNull);
  });

  test('after the host loses native state the model is reloaded', () async {
    final lc = make();
    (await lc.acquire('a')).release();
    host.simulateCrash();
    await Future<void>.delayed(Duration.zero);
    expect(lc.loaded, isNull);
    final lease = await lc.acquire('a');
    expect(lease.model.epoch, host.epoch);
    lease.release();
    expect(host.loads, hasLength(2));
    await lc.dispose();
  });

  test('session creation failing for memory retries with half the context', () async {
    final lc = make();
    host
      ..createSessionError = const EngineException(-5, 'llama_init_from_model failed')
      ..createSessionFailures = 1;
    final lease = await lc.acquire('a');
    expect(lease.capabilities.contextLength, 4096);
    expect(host.sessionConfigs.single.nCtx, 4096);
    lease.release();
    await lc.dispose();
  });

  test('onPhase reports compact summaries for Android kill forensics', () async {
    final records = <PhaseRecord>[];
    final lc = ModelLifecycleManager(host: host, onPhase: records.add)..register(_spec('a'));
    (await lc.acquire('a')).release();
    expect(records.map((r) => r.phase), containsAllInOrder([InferencePhase.loading, InferencePhase.idle]));
    expect(records.every((r) => r.compactSummary.length <= 128), isTrue);
    await lc.dispose();
  });

  group('draft models, overrides and autotune (perf lab API)', () {
    const env = AutotuneEnvironment(deviceId: 'd', osVersion: '1', appVersion: '1', engineVersion: 'e', performanceCores: 4);

    ModelLifecycleManager tuned({List<LocalModelSpec> specs = const [], void Function(PhaseRecord)? onPhase}) {
      final lc = ModelLifecycleManager(
        host: host,
        memory: memory,
        forensics: forensics,
        store: store,
        autotuner: Autotuner(host: host, store: store, environment: env),
        backgroundPolicy: BackgroundPolicy.none,
        policy: const AdmissionPolicy(fitFraction: 1, safetyMarginBytes: 0),
        onPhase: onPhase,
      );
      for (final s in specs) {
        lc.register(s);
      }
      return lc;
    }

    const paired = LocalModelSpec(
      id: 'big',
      path: '/models/big.gguf',
      draftModelPath: '/models/big.draft.gguf',
      sessionDefaults: SessionConfig(speculative: SpeculativeMode.draft),
    );

    test('a spec drafting with its own draft model loads it (and counts it in admission)', () async {
      final lc = tuned(specs: [paired, _spec('a')]);
      expect(paired.loadOptions.draftModelPath, '/models/big.draft.gguf');
      expect(_spec('a').loadOptions.draftModelPath, isNull);
      expect(const LocalModelSpec(id: 'x', path: '/x', draftModelPath: '/d').loadOptions.draftModelPath, isNull,
          reason: 'not drafting: the draft file is not loaded');
      final lease = await lc.acquire('big');
      expect(host.loads.single.draftModelPath, '/models/big.draft.gguf');
      expect(lease.loaded.loadOptions.draftModelPath, '/models/big.draft.gguf');
      expect(host.sessionConfigs.single.speculative, SpeculativeMode.draft);
      expect(host.estimateLoads.every((o) => o.draftModelPath == '/models/big.draft.gguf'), isTrue);
      lease.release();
      await lc.dispose();
    });

    test('an override picks the draft (another registered model) and applies without a measured profile', () async {
      final lc = tuned(specs: [_spec('a'), _spec('tiny')]);
      final tuner = lc.autotuner!;
      await tuner.setOverrides('a', const AutotuneOverrides(nThreads: 2, speculative: SpeculativeMode.draft, draftModelId: 'tiny'));
      expect(await tuner.isTuned('a'), isFalse);
      expect(lc.draftModelPathFor('a', draftModelId: 'tiny'), '/models/tiny.gguf');
      expect(lc.draftModelPathFor('a'), isNull, reason: 'a has no draft of its own');
      final plan = await lc.plan('a');
      expect(plan.config!.nThreads, 2, reason: 'overrides apply before autotune has run');
      expect(plan.config!.speculative, SpeculativeMode.draft);
      final lease = await lc.acquire('a');
      expect(host.loads.single.draftModelPath, '/models/tiny.gguf');
      expect(host.sessionConfigs.single.nThreads, 2);
      lease.release();

      // The draft left the library: no speculation, said in the plan.
      lc.unregister('tiny');
      final without = await lc.plan('a');
      expect(without.config!.speculative, SpeculativeMode.none);
      expect(without.notes, contains(contains('draft model is not available')));
      expect(host.estimateLoads.last.draftModelPath, isNull);

      // Back to n-gram or off: the draft is never loaded.
      await tuner.setOverrides('a', const AutotuneOverrides(speculative: SpeculativeMode.ngram));
      expect((await lc.plan('a')).config!.speculative, SpeculativeMode.ngram);
      await tuner.setOverrides('a', const AutotuneOverrides(speculative: SpeculativeMode.none));
      expect((await lc.plan('a')).config!.speculative, SpeculativeMode.none);
      await lc.dispose();
    });

    test('an override with no draft id uses the spec\'s own draft; one turning drafting off wins over the spec', () async {
      final lc = tuned(specs: [paired]);
      await lc.autotuner!.setOverrides('big', const AutotuneOverrides(speculative: SpeculativeMode.none));
      (await lc.acquire('big')).release();
      expect(host.loads.last.draftModelPath, isNull);
      expect(host.sessionConfigs.last.speculative, SpeculativeMode.none);
      await lc.unload();
      await lc.autotuner!.setOverrides('big', const AutotuneOverrides(speculative: SpeculativeMode.draft));
      (await lc.acquire('big')).release();
      expect(host.loads.last.draftModelPath, '/models/big.draft.gguf');
      await lc.dispose();
    });

    test('autotune reports progress, runs in the benchmarking phase and honours cancellation', () async {
      final records = <PhaseRecord>[];
      final lc = tuned(specs: [_spec('a')], onPhase: records.add);
      final progress = <AutotuneProgress>[];
      final profile = await lc.autotune('a', onProgress: progress.add);
      expect(profile!.source, AutotuneSource.measured);
      expect(progress.first.done, 0);
      expect(progress.last.done, lc.autotuner!.sweepSize);
      expect(progress.where((p) => p.step == AutotuneStep.measured), hasLength(host.benches.length));
      final phases = records.map((r) => r.phase).toList();
      expect(phases, containsAllInOrder([InferencePhase.loading, InferencePhase.idle, InferencePhase.benchmarking, InferencePhase.idle]));
      expect(records.lastWhere((r) => r.phase == InferencePhase.benchmarking).modelId, 'a');
      expect(host.benches.every((b) => b.nThreads >= 1), isTrue);

      final token = CancellationToken()..cancel();
      await expectLater(lc.autotune('a', force: true, cancel: token), throwsA(isA<CancelledException>()));
      expect(lc.loaded!.leases, 0, reason: 'the lease is released');
      await lc.dispose();
    });

    test('a crash while benchmarking stops automatic autotune until a forced run completes', () async {
      final lc = tuned(specs: [_spec('a')]);
      final lease = await lc.acquire('a');
      // The process dies while the sweep benches.
      await forensics.enter(PhaseRecord(phase: InferencePhase.benchmarking, at: DateTime.utc(2026), modelId: 'a', nCtx: 8192));
      lease.release();

      final next = tuned(specs: [_spec('a')]);
      final report = await next.start();
      expect(report!.phase.phase, InferencePhase.benchmarking);
      expect(report.description, contains('while benchmarking'));
      expect(await next.downgradeFor('a'), isNull, reason: 'the chat context is not the culprit');
      expect(await next.autotuneCrashFor('a'), contains('benchmarking'));
      final benches = host.benches.length;
      expect(await next.autotune('a'), isNull);
      expect(host.benches.length, benches, reason: 'not retried automatically');
      expect(await next.autotune('a', force: true), isNotNull);
      expect(await next.autotuneCrashFor('a'), isNull);
      await next.dispose();
    });

    test('autotune counts the warm model\'s own memory as available', () async {
      final lc = tuned(specs: [_spec('a', preferred: 4096)]);
      (await lc.acquire('a')).release();
      expect(lc.loaded!.estimate!.anonymousBytes, 498 * _mib, reason: 'f16 at 4096 tokens in the fake estimator');
      // With the model loaded, 600 MB are left: neither a fresh f16 (878 MB)
      // nor q8_0 (668 MB) load would fit, but the warm model's own memory
      // is freed before a tuned config loads.
      memory.emit(const MemoryState(pressure: MemoryPressure.normal, availableBytes: 600 * _mib, source: 'test'));
      final p = await lc.autotune('a');
      expect(p!.source, AutotuneSource.measured);
      expect(host.benches.where((b) => b.typeK == KvType.f16), isNotEmpty);
      await lc.dispose();
    });
  });
}
