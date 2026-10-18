import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/src/anthropic/anthropic.dart';
import 'package:test/test.dart';

void main() {
  group('AnthropicModelTraits.forModel', () {
    test('current families (R10 §7.3 / §7.2)', () {
      final opus55 = AnthropicModelTraits.forModel('claude-opus-5-5');
      expect(opus55.thinking, AnthropicThinkingStyle.alwaysOn);
      expect(opus55.rejectsSampling, isTrue);
      expect(opus55.rejectsForcedToolChoice, isTrue);
      expect(opus55.contextLength, 1000000);
      expect(opus55.maxOutputTokens, 128000);
      expect(opus55.effortLevels, containsAll(AnthropicEffort.values));

      expect(AnthropicModelTraits.forModel('claude-sonnet-5-5').thinking, AnthropicThinkingStyle.betweenToolsOff);
      expect(AnthropicModelTraits.forModel('claude-haiku-5-5').rejectsForcedToolChoice, isFalse);
      expect(AnthropicModelTraits.forModel('claude-fable-5').rejectsForcedToolChoice, isFalse);
      expect(AnthropicModelTraits.forModel('claude-fable-5-1').rejectsForcedToolChoice, isTrue);
      expect(AnthropicModelTraits.forModel('claude-mythos-5-1').rejectsForcedToolChoice, isTrue);
      expect(AnthropicModelTraits.forModel('claude-opus-5').thinking, AnthropicThinkingStyle.adaptive);
      expect(AnthropicModelTraits.forModel('claude-opus-4-8').thinking, AnthropicThinkingStyle.adaptiveOptIn);
      expect(AnthropicModelTraits.forModel('claude-opus-4-7').rejectsSampling, isTrue);
      final opus46 = AnthropicModelTraits.forModel('claude-opus-4-6');
      expect(opus46.rejectsSampling, isFalse);
      expect(opus46.displayDefaultsToOmitted, isFalse);
      expect(opus46.effortLevels, isNot(contains(AnthropicEffort.xhigh)));
      final haiku45 = AnthropicModelTraits.forModel('claude-haiku-4-5');
      expect(haiku45.thinking, AnthropicThinkingStyle.budget);
      expect(haiku45.effortLevels, isEmpty);
      expect((haiku45.contextLength, haiku45.maxOutputTokens), (200000, 64000));
    });

    test('platform prefixes, snapshots, [1m] suffixes and legacy ids', () {
      for (final id in [
        'anthropic.claude-opus-5-5',
        'us.anthropic.claude-opus-5-5-v1:0',
        'claude-opus-5-5[1m]',
        'CLAUDE-OPUS-5-5',
      ]) {
        expect(AnthropicModelTraits.forModel(id).thinking, AnthropicThinkingStyle.alwaysOn, reason: id);
      }
      expect(AnthropicModelTraits.forModel('claude-opus-4-20250514').thinking, AnthropicThinkingStyle.budget);
      expect(AnthropicModelTraits.forModel('claude-opus-4-20250514').maxOutputTokens, 32000);
      expect(AnthropicModelTraits.forModel('claude-3-7-sonnet-20250219').thinking, AnthropicThinkingStyle.budget);
      expect(AnthropicModelTraits.forModel('claude-3-5-haiku-20241022').thinking, AnthropicThinkingStyle.none);
      final unknown = AnthropicModelTraits.forModel('my-gateway-model');
      expect(unknown.known, isFalse);
      expect(unknown.rejectsSampling, isTrue);
      expect(unknown.rejectsForcedToolChoice, isTrue);
    });

    test('every Anthropic model is append-only with the claude tokenizer', () {
      for (final (id, _) in AnthropicModelTraits.currentModels) {
        final caps = AnthropicModelTraits.forModel(id).toCapabilities();
        expect(caps.historyPolicy, HistoryPolicy.appendOnly, reason: id);
        expect(caps.tokenizerFamily, 'claude');
        expect(caps.supportsPromptCache, isTrue);
        expect(caps.toolCallFormat, ToolCallFormat.native);
        expect(caps.vision, isTrue);
      }
    });

    test('refine narrows effort levels and thinking style from the Models API tree', () {
      final t = AnthropicModelTraits.forModel('claude-opus-4-8').refine({
        'effort': {
          'supported': true,
          'low': {'supported': true},
          'medium': {'supported': true},
          'high': {'supported': true},
          'xhigh': {'supported': false},
          'max': {'supported': false},
        },
        'thinking': {
          'types': {
            'adaptive': {'supported': false},
            'enabled': {'supported': true},
          },
        },
      });
      expect(t.effortLevels, {AnthropicEffort.low, AnthropicEffort.medium, AnthropicEffort.high});
      expect(t.thinking, AnthropicThinkingStyle.budget);
      expect(t.rejectsSampling, isTrue, reason: 'not discoverable, kept from the table');
      final noEffort = AnthropicModelTraits.forModel('claude-opus-5').refine({
        'effort': {'supported': false},
        'thinking': {
          'types': {
            'adaptive': {'supported': true},
            'disabled': {'supported': false},
          },
        },
      });
      expect(noEffort.effortLevels, isEmpty);
      expect(noEffort.thinking, AnthropicThinkingStyle.alwaysOn);
      expect(AnthropicModelTraits.forModel('claude-opus-5').refine(null).thinking, AnthropicThinkingStyle.adaptive);
    });
  });

  group('AnthropicToolNames', () {
    test('sanitize is pure, bounded and only rewrites invalid names', () {
      expect(AnthropicToolNames.sanitize('get_weather'), 'get_weather');
      expect(AnthropicToolNames.sanitize('github.create_issue'), 'github_create_issue');
      expect(AnthropicToolNames.sanitize('日本'), matches(RegExp(r'^__$')));
      expect(AnthropicToolNames.sanitize(''), matches(RegExp(r'^tool_[0-9a-f]{8}$')));
      final long = AnthropicToolNames.sanitize('a' * 100);
      expect(long.length, AnthropicToolNames.maxLength);
      expect(AnthropicToolNames.sanitize('a' * 100), long);
    });

    test('collisions get distinct, stable, reversible names', () {
      final names = AnthropicToolNames(['a.b', 'a/b', 'a_b', 'a b']);
      final wire = ['a.b', 'a/b', 'a_b', 'a b'].map(names.toWire).toList();
      expect(wire[2], 'a_b', reason: 'a valid name keeps its spelling');
      expect(wire.toSet(), hasLength(4));
      for (final n in ['a.b', 'a/b', 'a_b', 'a b']) {
        expect(names.fromWire(names.toWire(n)), n);
      }
      expect(AnthropicToolNames(['a.b', 'a/b', 'a_b', 'a b']).toWire('a/b'), names.toWire('a/b'));
      expect(names.fromWire('unknown_tool'), 'unknown_tool');
    });

    test('tool ids are sanitized deterministically and stay unique', () {
      expect(AnthropicToolNames.sanitizeId('toolu_01AbC-d'), 'toolu_01AbC-d');
      final a = AnthropicToolNames.sanitizeId('call:1');
      final b = AnthropicToolNames.sanitizeId('call.1');
      expect(a, matches(RegExp(r'^[a-zA-Z0-9_-]+$')));
      expect(a, isNot(b));
      expect(AnthropicToolNames.sanitizeId('call:1'), a);
    });
  });

  test('rate-limit headers parse (case-insensitive, RFC 3339 resets)', () {
    final limits = parseAnthropicRateLimits({
      'Anthropic-RateLimit-Tokens-Limit': '100000',
      'anthropic-ratelimit-tokens-remaining': '0',
      'anthropic-ratelimit-tokens-reset': '2026-10-18T12:00:30Z',
      'anthropic-ratelimit-requests-limit': '50',
      'anthropic-ratelimit-requests-remaining': '49',
    });
    expect(limits.map((l) => l.kind), ['requests', 'tokens']);
    final tokens = limits.last;
    expect(tokens.exhausted, isTrue);
    expect(tokens.low, isTrue);
    expect(tokens.reset, DateTime.utc(2026, 10, 18, 12, 0, 30));
    expect(limits.first.low, isFalse);
  });
}
