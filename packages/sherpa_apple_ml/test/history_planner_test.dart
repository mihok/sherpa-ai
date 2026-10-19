import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_apple_ml/sherpa_apple_ml.dart';
import 'package:sherpa_apple_ml/src/common/wire.dart';
import 'package:sherpa_apple_ml/testing.dart';
import 'package:sherpa_core/sherpa_core.dart';

import 'support/harness.dart';

AmWireMessage w(String role, String content) => AmWireMessage(role: role, content: content);

void main() {
  group('HistoryPlanner (MLX: any roles may be appended)', () {
    late HistoryPlanner p;
    setUp(() => p = HistoryPlanner(appendShape: AppendShape.anyRoles));

    test('first request rebuilds from everything before the trailing input', () {
      final plan = p.plan(
        sessionKey: 's',
        configKey: 'm',
        messages: [w('user', 'a'), w('assistant', 'b'), w('user', 'c')],
      );
      expect(plan.mode, AmHistoryMode.rebuild);
      expect(plan.reason, 'new_session');
      expect(plan.history.map((m) => m.content), ['a', 'b']);
      expect(plan.pending.map((m) => m.content), ['c']);
    });

    test('append after commit; config change and divergence rebuild', () {
      final m1 = [w('user', 'a')];
      p.commit('s', 'm', m1, w('assistant', 'b'));
      final next = [...m1, w('assistant', 'b'), w('user', 'c')];
      final plan = p.plan(sessionKey: 's', configKey: 'm', messages: next);
      expect((plan.mode, plan.reason), (AmHistoryMode.append, 'appended'));
      expect(plan.pending.single.content, 'c');

      expect(p.plan(sessionKey: 's', configKey: 'other-model', messages: next).reason, 'config_changed');
      final edited = [w('user', 'a!'), w('assistant', 'b'), w('user', 'c')];
      expect(p.plan(sessionKey: 's', configKey: 'm', messages: edited).reason, 'history_changed');
      // Compaction replaced the head with a summary: also a divergence.
      final compacted = [w('user', '[summary]'), w('assistant', 'Understood.'), w('user', 'c')];
      expect(p.plan(sessionKey: 's', configKey: 'm', messages: compacted).mode, AmHistoryMode.rebuild);
    });

    test('a changed tool call argument or tool result is a divergence', () {
      final a = w('assistant', '')..toolCalls = [AmToolCallWire(id: '1', name: 't', argumentsJson: '{"x":1}')];
      final t = w('tool', 'out')
        ..toolCallId = '1'
        ..toolName = 't';
      p.commit('s', 'm', [w('user', 'q'), a, t], w('assistant', 'done'));
      final truncated = w('tool', 'out [truncated]')
        ..toolCallId = '1'
        ..toolName = 't';
      final plan = p.plan(
        sessionKey: 's',
        configKey: 'm',
        messages: [w('user', 'q'), a, truncated, w('assistant', 'done'), w('user', 'more')],
      );
      expect(plan.mode, AmHistoryMode.rebuild);
    });

    test('an assistant-final request continues the paused reply', () {
      final plan = p.plan(sessionKey: 's', configKey: 'm', messages: [w('user', 'q'), w('assistant', 'partial')]);
      expect(plan.mode, AmHistoryMode.continueAssistant);
      expect(plan.partialAssistant, 'partial');
      expect(plan.history.single.content, 'q');
    });

    test('a suffix ending with an assistant message is not appendable', () {
      p.commit('s', 'm', [w('user', 'q')], w('assistant', 'a'));
      // Same prefix but nothing new to answer → (continue) the last reply.
      expect(
        p.plan(sessionKey: 's', configKey: 'm', messages: [w('user', 'q'), w('assistant', 'a')]).mode,
        AmHistoryMode.continueAssistant,
      );
    });

    test('invalidate forces a rebuild; sessions are independent', () {
      p.commit('s', 'm', [w('user', 'q')], w('assistant', 'a'));
      p.commit('t', 'm', [w('user', 'q')], w('assistant', 'a'));
      p.invalidate('s');
      final msgs = [w('user', 'q'), w('assistant', 'a'), w('user', 'n')];
      expect(p.plan(sessionKey: 's', configKey: 'm', messages: msgs).mode, AmHistoryMode.rebuild);
      expect(p.plan(sessionKey: 't', configKey: 'm', messages: msgs).mode, AmHistoryMode.append);
    });
  });

  group('HistoryPlanner (Foundation Models: one prompt per turn)', () {
    late HistoryPlanner p;
    setUp(() => p = HistoryPlanner(appendShape: AppendShape.singleUserPrompt));

    test('only a single trailing user prompt is appended', () {
      p.commit('s', 'cfg', [w('user', 'q')], w('assistant', 'a'));
      expect(
        p.plan(sessionKey: 's', configKey: 'cfg', messages: [w('user', 'q'), w('assistant', 'a'), w('user', 'n')]).mode,
        AmHistoryMode.append,
      );
      final foreign = [w('user', 'q'), w('assistant', 'a'), w('user', 'n'), w('assistant', 'x'), w('user', 'm')];
      final plan = p.plan(sessionKey: 's', configKey: 'cfg', messages: foreign);
      expect(plan.mode, AmHistoryMode.rebuild, reason: 'FM cannot append an assistant turn it did not produce');
      expect(plan.history, hasLength(4));
      expect(plan.pending.single.content, 'm');
    });
  });

  group('WireMapper', () {
    test('merges a paused reply with its continuation; drops reasoning; flags tool errors', () {
      final msgs = [
        user('u1', 'q'),
        Message(
          id: 'a1',
          role: Role.assistant,
          content: const [
            ReasoningPart(text: 'hmm'),
            TextPart('Part one'),
          ],
          createdAt: t0,
          finishReason: FinishReason.pause.name,
        ),
        assistant('a2', ' and two.'),
        toolResult('t1', 'c', 'x', 'nope', isError: true),
      ];
      final wire = const WireMapper().map(msgs);
      expect(wire.map((m) => m.role), ['user', 'assistant', 'tool']);
      expect(wire[1].content, 'Part one and two.');
      expect(wire[2].content, '[tool error] nope');
    });

    test('repaired tool arguments are re-encoded, raw text kept otherwise', () {
      const raw = ToolCall(id: '1', name: 't', arguments: {'a': 1}, rawArguments: '{ "a": 1 }');
      const repaired = ToolCall(id: '2', name: 't', arguments: {'a': 1}, rawArguments: '{a:1', repaired: true);
      expect(WireMapper.argumentsForHistory(raw), '{ "a": 1 }');
      expect(WireMapper.argumentsForHistory(repaired), '{"a":1}');
    });

    test('FM merge: system notes become user turns, consecutive users join', () {
      final merged = WireMapper.mergeForSinglePrompt([
        w('system', 'note'),
        w('user', 'a'),
        w('assistant', 'b'),
        w('user', 'c'),
      ]);
      expect(merged.map((m) => m.role), ['user', 'assistant', 'user']);
      expect(merged.first.content, '[System note] note\n\na');
    });

    test('fingerprints are content-based and order-sensitive', () {
      expect(wireFingerprint(w('user', 'a')), wireFingerprint(w('user', 'a')));
      expect(wireFingerprint(w('user', 'a')), isNot(wireFingerprint(w('assistant', 'a'))));
      expect(configFingerprint({'b': 1, 'a': 2}), configFingerprint({'a': 2, 'b': 1}));
    });
  });
}
