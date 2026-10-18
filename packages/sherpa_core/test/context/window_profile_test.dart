import 'package:sherpa_core/sherpa_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('WindowProfile.forWindow (R11 §9.2 table)', () {
    WindowProfile at(int limit, {int reserve = 512, int margin = 0, int maxSummary = 1024}) =>
        WindowProfile.forWindow(
          limit: limit,
          usableInput: limit - reserve - margin,
          safetyMargin: margin,
          maxSummaryTokens: maxSummary,
        );

    test('≤ 4K: deterministic summary only, keep 1 turn, 40% tail', () {
      final p = at(4096);
      expect(p.tier, WindowTier.tiny);
      expect(p.thresholds.prune, 0.50);
      expect(p.thresholds.compact, 0.70);
      expect(p.thresholds.handoff, 0.85);
      expect(p.keepRecentUserTurns, 1);
      expect(p.keptTailFraction, 0.40);
      expect(p.modelCompaction, isFalse);
    });

    test('8K: compact capped at 0.70, keep 2, 35% tail', () {
      final p = at(8192);
      expect(p.tier, WindowTier.small);
      expect([p.thresholds.prune, p.thresholds.compact, p.thresholds.handoff], [0.55, 0.70, 0.90]);
      expect(p.keepRecentUserTurns, 2);
      expect(p.keptTailFraction, 0.35);
      expect(p.modelCompaction, isTrue);
    });

    test('16K and 32–64K rows', () {
      final m = at(16384);
      expect([m.thresholds.prune, m.thresholds.compact, m.thresholds.handoff], [0.60, 0.78, 0.92]);
      expect(m.keepRecentUserTurns, 2);
      final l = at(32768);
      expect(l.tier, WindowTier.large);
      expect([l.thresholds.prune, l.thresholds.compact, l.thresholds.handoff], [0.60, 0.80, 0.92]);
      expect(l.keepRecentUserTurns, 3);
      expect(l.keptTailFraction, 0.30);
      expect(at(65536).thresholds.compact, 0.80);
    });

    test('≥ 128K: absolute caps of 100K (prune) and 150K (compact)', () {
      final p = at(200000, reserve: 2048);
      expect(p.tier, WindowTier.huge);
      expect(p.thresholds.prune, closeTo(0.505, 0.01));
      expect(p.thresholds.compact, closeTo(150000 / 197952, 1e-9));
      expect(p.thresholds.handoff, 0.95);
      expect(p.keepRecentUserTurns, 4);
      final big = at(1000000, reserve: 2048);
      expect(big.thresholds.prune * 997952, closeTo(100000, 1));
      expect(big.thresholds.compact * 997952, closeTo(150000, 1));
    });

    test('compact-trigger formula binds when the summary call would not fit', () {
      // (8192 − 500 − 3000 − 0) / 7680 = 0.61 < 0.70.
      final p = at(8192, maxSummary: 3000);
      expect(p.thresholds.compact, closeTo(4692 / 7680, 1e-9));
      // Clamped to 0.5 at the bottom; prune is pulled below it.
      final q = at(8192, maxSummary: 6000);
      expect(q.thresholds.compact, 0.5);
      expect(q.thresholds.prune, lessThan(0.5));
      expect(
        WindowProfile.compactTrigger(limit: 100000, usableInput: 50000),
        0.85,
        reason: 'clamped to 0.85 at the top',
      );
    });

    test('thermal pressure prunes earlier, nothing else moves', () {
      final p = at(32768).pruneEarlier(0.1);
      expect(p.thresholds.prune, closeTo(0.5, 1e-9));
      expect(p.thresholds.compact, 0.80);
    });
  });

  group('safety fraction', () {
    test('exact counters need no margin', () {
      expect(WindowProfile.safetyFraction(const QuarterCounter(), denseShare: 0.9), 0);
    });

    test('0.20 until 3 calibrations, then 0.10; 0.20 again above 25% CJK', () {
      final c = HeuristicTokenCounter(family: 'qwen');
      expect(WindowProfile.safetyFraction(c, denseShare: 0), 0.20);
      for (var i = 0; i < 3; i++) {
        c.calibrate(estimated: 100, actual: 100);
      }
      expect(c.calibrationCount, 3);
      expect(WindowProfile.safetyFraction(c, denseShare: 0.1), 0.10);
      expect(WindowProfile.safetyFraction(c, denseShare: 0.3), 0.20);
      expect(HeuristicTokenCounter.denseShare('ab日本'), 0.5);
    });

    test('the ladder applies it to the budget margin', () {
      final c = HeuristicTokenCounter();
      final conv = Conv()..user('hello');
      final m = LadderContextManager(clock: FakeClock());
      expect(m.inspect(req(conv.messages, counter: c, window: 10000)).budget.safetyMargin, 2000);
      for (var i = 0; i < 3; i++) {
        c.calibrate(estimated: 50, actual: 50);
      }
      expect(m.inspect(req(conv.messages, counter: c, window: 10000)).budget.safetyMargin, 1000);
      final cjk = Conv()..user('日本語のテキスト' * 20);
      expect(m.inspect(req(cjk.messages, counter: c, window: 10000)).budget.safetyMargin, 2000);
    });
  });

  group('MemoryContextPolicy', () {
    final conv = Conv()..user('hi');
    final manager = LadderContextManager(clock: FakeClock());

    test('defaults: normal 1.0, moderate 0.75, critical 0.5 of the window', () {
      const p = MemoryContextPolicy();
      expect(p.effectiveContextLength(8192, MemoryState.unknown), 8192);
      expect(p.effectiveContextLength(8192, const MemoryState(pressure: MemoryPressure.moderate)), 6144);
      expect(p.effectiveContextLength(8192, const MemoryState(pressure: MemoryPressure.critical)), 4096);
      expect(p.effectiveContextLength(1500, const MemoryState(pressure: MemoryPressure.critical)), 1024,
          reason: 'never below the minimum');
    });

    test('shrinks only on-device windows', () {
      const critical = MemoryState(pressure: MemoryPressure.critical);
      final local = manager.inspect(req(conv.messages, memory: critical, location: ExecutionLocation.onDevice));
      expect(local.budget.limit, 4096);
      expect(local.profile.tier, WindowTier.tiny, reason: 'thresholds follow the effective window');
      final remote = manager.inspect(req(conv.messages, memory: critical, location: ExecutionLocation.remote));
      expect(remote.budget.limit, 8192);
      final unknown = manager.inspect(req(conv.messages, memory: critical));
      expect(unknown.budget.limit, 8192, reason: 'unknown location is not assumed on-device');
      final configured = LadderContextManager(clock: FakeClock(), location: ExecutionLocation.onDevice)
          .inspect(req(conv.messages, memory: critical));
      expect(configured.budget.limit, 4096);
    });

    test('thermal serious prunes earlier', () {
      const hot = MemoryState(pressure: MemoryPressure.normal, thermal: ThermalLevel.serious);
      final i = manager.inspect(req(conv.messages, window: 32768, memory: hot, location: ExecutionLocation.onDevice));
      expect(i.profile.thresholds.prune, closeTo(0.5, 1e-9));
      expect(i.budget.limit, 32768);
    });

    test('a settings profile overrides the table', () {
      final custom = WindowProfile(
        thresholds: const ContextThresholds(prune: 0.3, compact: 0.4, handoff: 0.9),
        keepRecentUserTurns: 1,
        keptTailFraction: 0.5,
      );
      final i = manager.inspect(req(conv.messages, settings: ContextSettings(profile: custom)));
      expect(i.profile.thresholds.prune, 0.3);
      expect(WindowProfile.fromJson(custom.toJson()).toJson(), custom.toJson());
    });
  });
}
