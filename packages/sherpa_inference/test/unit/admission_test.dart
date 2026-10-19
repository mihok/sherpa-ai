import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart';
import 'package:sherpa_inference/sherpa_inference.dart';
import 'package:sherpa_inference/testing.dart';

const _mib = 1024 * 1024;

void main() {
  final host = FakeEngineHost(); // 400 MiB model (380 mapped) + 30 MiB compute + KV
  Future<MemoryEstimate> est(SessionConfig c) => host.estimateMemory(const ModelLoadOptions(path: 'x'), c);
  MemoryBudget budget(int bytes) => MemoryBudget(totalBytes: bytes, source: 'test');
  const tools = [KvType.f16, KvType.q8_0];

  AdmissionRequest req({int preferred = 8192, int min = 2048, List<KvType> ladder = tools, int? train}) =>
      AdmissionRequest(base: const SessionConfig(seed: 1), preferredContext: preferred, minContext: min, kvLadder: ladder, trainContext: train);

  group('planAdmission', () {
    test('keeps the preferred context and best KV type when it fits', () async {
      final plan = await planAdmission(req(), budget(4096 * _mib), est);
      expect(plan.admitted, isTrue);
      expect(plan.config!.nCtx, 8192);
      expect(plan.config!.typeK, KvType.f16);
      expect(plan.config!.seed, 1, reason: 'base parameters are kept');
      expect(plan.notes, isEmpty);
    });

    test('lowers KV precision before shrinking the context', () async {
      // f16 @ 8192 = 430 + 896 MiB; q8_0 @ 8192 = 430 + 476 MiB.
      final plan = await planAdmission(req(), budget(1000 * _mib), est);
      expect(plan.config!.nCtx, 8192);
      expect(plan.config!.typeK, KvType.q8_0);
      expect(plan.config!.typeV, KvType.q8_0);
      expect(plan.notes.single, contains('q8_0'));
    });

    test('shrinks the context to the largest that fits, across KV types', () async {
      final plan = await planAdmission(req(), budget(700 * _mib), est);
      expect(plan.admitted, isTrue);
      // (700 - 430) MiB / 60928 B per token = 4646 → 4608 with q8_0 (f16 would give only 2304).
      expect(plan.config!.typeK, KvType.q8_0);
      expect(plan.config!.nCtx, 4608);
      expect(plan.estimate!.totalBytes, lessThanOrEqualTo(700 * _mib));
      expect(plan.notes.single, contains('context reduced to 4608'));
    });

    test('refuses below the minimum context with a clear reason', () async {
      final plan = await planAdmission(req(), budget(450 * _mib), est);
      expect(plan.admitted, isFalse);
      expect(plan.config, isNull);
      expect(plan.refusal, contains('Not enough memory'));
      expect(plan.refusal, contains('2048-token context'));
      expect(plan.refusal, contains('450 MB'));
    });

    test('q4_0 is only on the ladder for sessions without tools', () async {
      const budgetBytes = 430 * _mib + 2048 * 40000;
      final withTools = await planAdmission(req(), budget(budgetBytes), est);
      expect(withTools.admitted, isFalse);
      final noTools = await planAdmission(req(ladder: [KvType.f16, KvType.q8_0, KvType.q4_0]), budget(budgetBytes), est);
      expect(noTools.config!.typeK, KvType.q4_0);
    });

    test('caps the context at the training length', () async {
      final plan = await planAdmission(req(train: 4096), budget(4096 * _mib), est);
      expect(plan.config!.nCtx, 4096);
      expect(plan.notes.single, contains('training length'));
    });

    test('an unknown budget admits the preferred configuration', () async {
      final plan = await planAdmission(req(), const MemoryBudget(totalBytes: null, source: 'unknown'), est);
      expect(plan.config!.nCtx, 8192);
      expect(plan.config!.typeK, KvType.f16);
    });

    test('an Android anonymous-memory cap counts only non-mapped bytes', () async {
      // 50 MiB of the 400 MiB model is anonymous (repack), mapped pages are exempt.
      final b = MemoryBudget(totalBytes: 4096 * _mib, anonymousCapBytes: 600 * _mib, source: 'test');
      final plan = await planAdmission(req(), b, est);
      expect(plan.admitted, isTrue);
      expect(plan.estimate!.anonymousBytes, lessThanOrEqualTo(600 * _mib));
      expect((plan.config!.nCtx, plan.config!.typeK), (8192, KvType.q8_0), reason: 'f16 KV would exceed the cap');
    });
  });

  group('MemoryBudget.from', () {
    test('uses the measured availability and the platform fraction', () {
      final ios = MemoryBudget.from(
        const MemoryState(pressure: MemoryPressure.normal, availableBytes: 3000 * _mib, source: 'os_proc_available_memory'),
        device: const DeviceProfile(platform: DevicePlatform.ios, totalRamBytes: 8192 * _mib),
      );
      expect(ios.totalBytes, (3000 * _mib * FitConstants.iosFitFraction).round() - 128 * _mib);
      expect(ios.source, 'os_proc_available_memory');
      final android = MemoryBudget.from(
        const MemoryState(pressure: MemoryPressure.normal, availableBytes: 3000 * _mib),
        device: const DeviceProfile(platform: DevicePlatform.android, totalRamBytes: 4096 * _mib, osVersion: '17'),
      );
      expect(android.totalBytes, (3000 * _mib * FitConstants.androidFitFraction).round() - 128 * _mib);
      expect(android.anonymousCapBytes, isNotNull, reason: 'Android 17 limiter');
    });

    test('moderate pressure shrinks and critical pressure zeroes the budget', () {
      const avail = 2000 * _mib;
      final normal = MemoryBudget.from(const MemoryState(pressure: MemoryPressure.normal, availableBytes: avail));
      final moderate = MemoryBudget.from(const MemoryState(pressure: MemoryPressure.moderate, availableBytes: avail));
      final critical = MemoryBudget.from(const MemoryState(pressure: MemoryPressure.critical, availableBytes: avail));
      expect(moderate.totalBytes, lessThan(normal.totalBytes!));
      expect(critical.totalBytes, 0);
    });

    test('estimates from total RAM without a measurement, unknown without a device', () {
      expect(MemoryBudget.from(MemoryState.unknown).isKnown, isFalse);
      final est = MemoryBudget.from(MemoryState.unknown,
          device: const DeviceProfile(platform: DevicePlatform.android, totalRamBytes: 8192 * _mib));
      expect(est.isKnown, isTrue);
      expect(est.source, contains('estimated'));
    });
  });

  group('ModelLifecycleManager.downgradeOf', () {
    const spec = LocalModelSpec(id: 'm', path: 'x', minContext: 2048);
    test('f16 → q8_0, then halve the context, never below q8_0 with tools', () {
      var c = const SessionConfig(nCtx: 8192, typeK: KvType.f16, typeV: KvType.f16);
      c = ModelLifecycleManager.downgradeOf(c, spec)!;
      expect((c.nCtx, c.typeK), (8192, KvType.q8_0));
      c = ModelLifecycleManager.downgradeOf(c, spec)!;
      expect((c.nCtx, c.typeK), (4096, KvType.q8_0));
      c = ModelLifecycleManager.downgradeOf(c, spec)!;
      expect(c.nCtx, 2048);
      expect(ModelLifecycleManager.downgradeOf(c, spec), isNull);
      const noTools = LocalModelSpec(id: 'm', path: 'x', minContext: 2048, toolCalling: false);
      expect(ModelLifecycleManager.downgradeOf(c, noTools)!.typeK, KvType.q4_0);
    });
  });
}
