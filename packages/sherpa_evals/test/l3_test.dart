import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_evals/src/runtime/agent.dart';
import 'package:sherpa_evals/src/runtime/models.dart';
import 'package:sherpa_evals/src/runtime/state_servers.dart';
import 'package:sherpa_evals/src/suites/l3_state.dart';
import 'package:sherpa_evals/src/suites/l3_tasks.dart';
import 'package:sherpa_evals/src/suites/suite.dart';
import 'package:test/test.dart';

/// [task] with a different trajectory (for negative controls).
StateTask _with(StateTask task, List<AgentTurn> ideal) => StateTask(
      id: task.id,
      servers: task.servers,
      instruction: task.instruction,
      followUps: task.followUps,
      ideal: ideal,
      verify: task.verify,
      seed: task.seed,
      worldSeed: task.worldSeed,
    );

StateTask _task(String id) => l3Tasks.firstWhere((t) => t.id == id);

void main() {
  test('task ids are unique and every task seeds a fresh world', () {
    expect({for (final t in l3Tasks) t.id}, hasLength(l3Tasks.length));
    final a = _task('shop.adjust_open_basket').freshWorld();
    final b = _task('shop.adjust_open_basket').freshWorld();
    expect(a.baskets.keys, b.baskets.keys, reason: 'ids are deterministic per world seed');
    a.baskets.clear();
    expect(b.baskets, isNotEmpty, reason: 'trials do not share state');
  });

  test('the untouched seeded state fails every verification (no task is vacuous)', () {
    for (final t in l3Tasks) {
      final w = t.freshWorld();
      expect(t.verify(w, WorldSnapshot(w)), isNotEmpty, reason: t.id);
    }
  });

  for (final v in l3ScriptedVariants.entries) {
    test('the recorded ideal trajectories pass (${v.key} tool budget)', () async {
      for (final t in l3Tasks) {
        final r = await runL3Trial(t, trial: 0, variant: v.key, scriptedCapabilities: v.value);
        expect(r.problems, isEmpty, reason: '${t.id}: ${r.problems}');
        expect(r.toolErrors, 0, reason: t.id);
      }
    });
  }

  test('negative control: a trajectory that adds an item twice fails verification', () async {
    final t = _task('shop.new_basket_checkout');
    final steps = [...t.ideal.single.steps];
    // Re-issue the add step (fresh call ids come from its position).
    steps.insert(3, steps[2]);
    final r = await runL3Trial(_with(t, [AgentTurn(steps, 'done')]), trial: 0, variant: 'local');
    expect(r.pass, isFalse);
    expect(r.problems.join(), contains('ordered'));
  });

  test('negative control: asking instead of acting fails, the scripted user nudges once', () async {
    final t = _task('calendar.create_meeting');
    final r = await runL3Trial(_with(t, [const AgentTurn([], 'Should I create it?')]), trial: 0, variant: 'local');
    expect(r.pass, isFalse);
    expect(r.userTurns, 2, reason: 'the instruction, then "$l3GoAhead"');
  });

  test('the ideal policy routes through call_tool when the router defers', () async {
    final t = _task('cross.groceries_note_to_order');
    final r = await runL3Trial(t, trial: 0, variant: 'tiny', scriptedCapabilities: smallLocalCapabilities);
    expect(r.deferred, isTrue);
    expect(r.pass, isTrue, reason: '${r.problems}');
  });

  test('scripted L3 suite: pass@1 = pass^k = 1 with k = 2', () async {
    final r = await const L3Suite().run(EvalContext(model: const ScriptedModelSpec(), trials: 2, only: 'notes'));
    expect(r.metric('pass_at_1')!.value, 1);
    expect(r.metric('pass_hat_k')!.value, 1);
    expect(r.metric('k')!.value, 2);
    expect(r.cases, isNotEmpty);
  });

  test('the same create_note twice in one reply (Qwen3-0.6B trace) runs once, with one approval sheet', () async {
    final t = _task('notes.parallel_duplicate_create');
    for (final v in l3ScriptedVariants.entries) {
      final r = await runL3Trial(t, trial: 0, variant: v.key, scriptedCapabilities: v.value);
      expect(r.pass, isTrue, reason: '${v.key}: ${r.problems}');
      expect(r.effects.where((e) => e.startsWith('create_note')), hasLength(1), reason: v.key);
      expect(r.toolCalls, 2, reason: '${v.key}: create once, then append');
      expect(r.prompts, 2, reason: '${v.key}: no sheet for the copy');
    }
  });

  test('servers apply effects once per call and report handles', () async {
    final w = World()..stock(groceryCatalog);
    final env = stateServers(w, ['shop']);
    expect(env.keys, ['shop']);
    expect(mentions('Oat  Milk 1 l', 'oat milk'), isTrue);
    expect(textEvents('x').whereType<Finish>(), hasLength(1));
    expect(w.newId('bsk'), isNot(w.newId('bsk')));
  });
}
