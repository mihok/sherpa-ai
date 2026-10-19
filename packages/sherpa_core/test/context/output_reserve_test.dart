import 'package:sherpa_core/sherpa_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// The reply reserve scales with the window unless it is set explicitly.
void main() {
  group('ContextSettings.defaultOutputReserve', () {
    test('a quarter of the window, between 256 and 2048', () {
      expect(ContextSettings.defaultOutputReserve(2048), 512);
      expect(ContextSettings.defaultOutputReserve(4096), 1024);
      expect(ContextSettings.defaultOutputReserve(8192), 2048);
      expect(ContextSettings.defaultOutputReserve(32768), 2048);
      expect(ContextSettings.defaultOutputReserve(200000), 2048);
      expect(ContextSettings.defaultOutputReserve(600), 256);
    });

    test('an explicit setting wins; the model output cap lowers either', () {
      const auto = ContextSettings();
      const fixed = ContextSettings(outputReserveTokens: 2048);
      expect(auto.outputReserveFor(2048), 512);
      expect(fixed.outputReserveFor(2048), 2048);
      expect(const ContextSettings(outputReserveTokens: 300).outputReserveFor(200000), 300);
      expect(auto.outputReserveFor(32768, maxOutput: 512), 512);
      expect(fixed.outputReserveFor(2048, maxOutput: 100), 100);
      expect(auto.outputReserveFor(4096, maxOutput: 8192), 1024);
    });
  });

  group('the ladder on small and large windows', () {
    Conv shortChat() => Conv()
      ..user('What is a context window?')
      ..assistant('The number of tokens a model can read at once.')
      ..user('And on a phone?');

    final cases = <int, ({int reserve, WindowTier tier})>{
      2048: (reserve: 512, tier: WindowTier.tiny),
      4096: (reserve: 1024, tier: WindowTier.tiny),
      32768: (reserve: 2048, tier: WindowTier.large),
      200000: (reserve: 2048, tier: WindowTier.huge),
    };

    for (final MapEntry(key: window, value: want) in cases.entries) {
      test('$window-token window: reserve ${want.reserve}, the turn fits, ${want.tier.name} tier', () async {
        final r = req(shortChat().messages, window: window, maxOutput: null);
        final p = await LadderContextManager().prepare(r);
        expect(p.budget.outputReserve, want.reserve);
        expect(p.budget.usableInput, window - want.reserve);
        expect(p.budget.fits, isTrue);
        expect(p.recommendation, isNull);
        expect(p.level, ContextLevel.healthy);
        final inspection = LadderContextManager().inspect(r);
        expect(inspection.profile.tier, want.tier);
        // The thresholds stay ordered and leave room to act before a stop.
        final t = inspection.profile.thresholds;
        expect(t.prune, lessThan(t.compact));
        expect(t.compact, lessThan(t.handoff));
        expect(t.handoff, lessThanOrEqualTo(1.0));
        // The passthrough measure agrees with the ladder.
        final m = PassthroughContextManager.measure(r, r.systemPrompt, r.path);
        expect(m.outputReserve, want.reserve);
      });
    }

    test('2K window: a fixed 2048 reserve leaves no input, so the turn hard-stops', () async {
      final r = req(
        shortChat().messages,
        window: 2048,
        maxOutput: null,
        settings: const ContextSettings(outputReserveTokens: 2048),
      );
      final p = await LadderContextManager().prepare(r);
      expect(p.budget.outputReserve, 2048);
      expect(p.budget.usableInput, 0);
      expect(p.recommendation?.kind, ContextRecommendationKind.hardStop);
    });

    test('2K window with an estimating counter: the margin and reserve still leave room', () async {
      final r = req(shortChat().messages, window: 2048, maxOutput: null, counter: HeuristicTokenCounter());
      final p = await LadderContextManager().prepare(r);
      expect(p.budget.outputReserve, 512);
      expect(p.budget.safetyMargin, greaterThan(0));
      expect(p.budget.usableInput, greaterThan(1000));
      expect(p.budget.fits, isTrue);
    });

    test('2K window: a long chat compacts extractively instead of stopping', () async {
      final c = Conv();
      for (var i = 0; i < 30; i++) {
        c
          ..user('Question $i about the trip, with some detail to make it longer than a line.')
          ..assistant('Answer $i: here is a reasonably long reply so the window fills up over time.');
      }
      c.user('What did we decide?');
      final p = await LadderContextManager().prepare(req(c.messages, window: 2048, maxOutput: null));
      final o = p.newOverlays.whereType<CompactedRange>().single;
      expect(o.strategyId, 'extractive', reason: 'no summarizer call has to fit a tiny window');
      expect(p.budget.fits, isTrue);
      expect(p.recommendation?.kind, isNot(ContextRecommendationKind.hardStop));
    });

    test('memory pressure shrinks the window and the default reserve with it', () async {
      final r = req(
        shortChat().messages,
        window: 8192,
        maxOutput: null,
        memory: const MemoryState(pressure: MemoryPressure.critical),
        location: ExecutionLocation.onDevice,
      );
      final p = await LadderContextManager().prepare(r);
      expect(p.budget.limit, lessThan(8192));
      expect(p.budget.outputReserve, ContextSettings.defaultOutputReserve(p.budget.limit));
    });
  });
}
