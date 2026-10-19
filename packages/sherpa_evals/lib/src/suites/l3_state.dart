/// L3 — long-horizon state tasks (R11 §9.9, MCPMark / τ-bench style):
/// stateful fake MCP servers behind the real router, a scripted user, k
/// trials per task, and a verification function over the final server
/// state. Reports pass@1 and pass^k.
library;

import 'package:sherpa_core/sherpa_core.dart';

import '../report.dart';
import '../runtime/agent.dart';
import '../runtime/mcp_env.dart';
import '../runtime/models.dart';
import '../runtime/state_servers.dart';
import '../stats.dart';
import 'l3_tasks.dart';
import 'suite.dart';

/// The agent's system prompt for every L3 run (scripted and real): what the
/// app would say, not tuned to any task.
const String l3SystemPrompt = 'You are Sherpa, an assistant that completes the user\'s tasks with the available tools. '
    'Today is Monday, 2026-10-19. Look things up with tools instead of guessing ids, and confirm briefly when done.';

/// A generic reply of the scripted user to a question once its scripted
/// follow-ups are used up (a cooperative τ-bench user).
const String l3GoAhead = 'Yes, please go ahead.';

/// Call id of act [i] of step [j] of the reply to user message [t].
String l3CallId(int t, int j, int i) => 'u${t}s${j}c$i';

/// The recorded ideal trajectory of [task] as a model policy. It decides
/// from the request alone (the transcript the harness built), reading
/// handles from the tool results the model was shown, and routes calls
/// through `call_tool` when the router deferred the tool.
ModelPolicy idealPolicy(StateTask task) => (request) {
      final users = [
        for (final m in request.messages)
          if (m.role == Role.user && m.toolResults.isEmpty && m.kind != MessageKind.summary) m,
      ];
      final t = users.length - 1;
      if (t < 0 || t >= task.ideal.length) return textEvents('OK.');
      final byId = {for (final r in resultsIn(request)) r.callId: r.text};
      final labels = <String, String>{};
      for (final (ti, turn) in task.ideal.indexed) {
        for (final (j, step) in turn.steps.indexed) {
          for (final (i, act) in step.indexed) {
            final text = byId[l3CallId(ti, j, i)];
            if (text != null) labels[act.label] = text;
          }
        }
      }
      final seen = Seen(labels);
      final issued = {for (final c in callsIn(request)) c.id};
      final offered = {for (final x in request.tools) x.name};
      final turn = task.ideal[t];
      for (final (j, step) in turn.steps.indexed) {
        if ([for (var i = 0; i < step.length; i++) l3CallId(t, j, i)].every(issued.contains)) continue;
        try {
          return toolCallEvents([
            for (final (i, act) in step.indexed)
              () {
                final args = act.args(seen);
                final direct = offered.contains(act.tool) || !offered.contains('call_tool');
                return direct
                    ? ToolCall(id: l3CallId(t, j, i), name: act.tool, arguments: args)
                    : ToolCall(id: l3CallId(t, j, i), name: 'call_tool', arguments: {'name': act.tool, 'arguments': args});
              }(),
          ]);
        } on StateError catch (e) {
          return textEvents('I could not finish: ${e.message}');
        }
      }
      return textEvents(turn.reply);
    };

/// How the scripted model presents itself to the router (its tool budget).
final Map<String, ModelCapabilities> l3ScriptedVariants = {
  // On-device, size unknown: the `local` budget (8 tools).
  'local': const ModelCapabilities(contextLength: 32768),
  // ≤ 2B: the `tiny` budget (5 tools), so most tasks run deferred.
  'tiny': smallLocalCapabilities,
};

/// One trial of one task.
final class L3Trial {
  L3Trial({
    required this.task,
    required this.variant,
    required this.trial,
    required this.problems,
    required this.outcome,
    required this.steps,
    required this.toolCalls,
    required this.toolErrors,
    required this.prompts,
    required this.userTurns,
    required this.unhandled,
    required this.usage,
    required this.durationMs,
    required this.deferred,
    required this.effects,
  });

  final String task;
  final String variant;
  final int trial;
  final List<String> problems;
  final String outcome;
  final int steps;
  final int toolCalls;
  final int toolErrors;
  final int prompts;
  final int userTurns;
  final int unhandled;
  final Usage usage;
  final int durationMs;
  final bool deferred;
  final List<String> effects;

  bool get pass => problems.isEmpty;

  Map<String, Object?> toJson() => {
        'trial': trial,
        'pass': pass,
        if (problems.isNotEmpty) 'problems': problems,
        'outcome': outcome,
        'steps': steps,
        'toolCalls': toolCalls,
        'toolErrors': toolErrors,
        'approvalPrompts': prompts,
        'userTurns': userTurns,
        'deferred': deferred,
        'inputTokens': usage.inputTokens,
        'outputTokens': usage.outputTokens,
        'ms': durationMs,
        'effects': effects,
      };
}

/// Runs [task] once: a fresh world, servers, store and runner.
Future<L3Trial> runL3Trial(
  StateTask task, {
  required int trial,
  required String variant,
  ModelRuntime? runtime,
  ModelCapabilities? scriptedCapabilities,
  GenerationParams? params,
  int maxSteps = 12,
}) async {
  final sw = Stopwatch()..start();
  final world = task.freshWorld();
  final before = WorldSnapshot(world);
  final clock = FakeClock(DateTime.utc(2026, 10, 19, 8));
  final env = McpEnv(clock: clock);
  for (final e in stateServers(world, task.servers).entries) {
    env.add(e.key, e.value);
  }
  await env.reviewAll();
  final user = ScriptedUser();
  final store = InMemorySessionStore();
  const sid = 'l3';
  await newSession(store, sid, clock);
  final provider = runtime?.provider ??
      policyProvider(idealPolicy(task), capabilities: scriptedCapabilities ?? const ModelCapabilities(contextLength: 32768));
  final runner = AgentRunner(
    store: store,
    provider: provider,
    modelId: runtime?.modelId ?? 'scripted',
    tools: env.router,
    approvals: ApprovalPolicy(clock: clock, trustedServers: env.trustedServerIds),
    approvalHandler: user,
    contextManager: () {
      final ladder = LadderContextManager(clock: clock, toolLookup: env.router.lookup);
      return runtime == null ? ladder : runtime.wrap(ladder);
    }(),
    counter: runtime?.counter,
    clock: clock,
    ids: SequentialIdGenerator(),
    config: AgentConfig(maxSteps: maxSteps, params: params ?? runtime?.params ?? const GenerationParams(), defaultSystemPrompt: l3SystemPrompt),
    sleep: (_) async {},
  );

  final events = <AgentEvent>[];
  final errors = <Object>[];
  final pending = [...task.messages];
  var nudged = false;
  var turns = 0;
  var outcome = 'completed';
  while (pending.isNotEmpty) {
    final text = pending.removeAt(0);
    turns++;
    final (got, errs) = await guarded(() => drive(runner.send(sid, [TextPart(text)]), timeout: const Duration(minutes: 8)));
    errors.addAll(errs);
    events.addAll(got ?? const []);
    final fin = finishedOf(got ?? const []);
    if (fin == null || fin.outcome != RunOutcome.completed) {
      outcome = fin == null ? 'no RunFinished' : '${fin.outcome.name}${fin.detail == null ? '' : ': ${fin.detail}'}';
      break;
    }
    final reply = (got ?? const []).whereType<AssistantMessageCompleted>().lastOrNull?.message.text ?? '';
    if (pending.isEmpty && !nudged && reply.contains('?') && task.verify(world, before).isNotEmpty) {
      nudged = true;
      pending.add(l3GoAhead);
    }
  }
  final problems = [
    ...task.verify(world, before),
    if (outcome != 'completed') 'run ended $outcome',
    for (final e in errors) 'unhandled: $e',
  ];
  final results = [for (final e in events.whereType<ToolCallFinished>()) e.result];
  var usage = Usage.zero;
  for (final f in events.whereType<RunFinished>()) {
    usage += f.usage;
  }
  final deferred = env.router.isDeferred(sid);
  await env.close();
  return L3Trial(
    task: task.id,
    variant: variant,
    trial: trial,
    problems: problems,
    outcome: outcome,
    steps: events.whereType<StepStarted>().length,
    toolCalls: events.whereType<ToolCallStarted>().length,
    toolErrors: results.where((r) => r.isError).length,
    prompts: user.prompts.length,
    userTurns: turns,
    unhandled: errors.length,
    usage: usage,
    durationMs: sw.elapsedMilliseconds,
    deferred: deferred,
    effects: [for (final e in world.effects) e.toString()],
  );
}

final class L3Suite implements EvalSuite {
  const L3Suite();

  @override
  String get id => 'L3';

  @override
  String get title => 'Long-horizon state tasks';

  @override
  bool supports(ModelSpec model) => true;

  @override
  Future<SuiteReport> run(EvalContext ctx) async {
    final tasks = ctx.select(l3Tasks, (t) => t.id);
    final k = ctx.trials ?? (ctx.scripted ? 4 : 2);
    final report = SuiteReport(
      suite: id,
      title: title,
      model: ctx.model.label,
      casePolicy: ctx.scripted ? CasePolicy.all : CasePolicy.none,
    );
    final variants = ctx.scripted ? l3ScriptedVariants : {'model': null};
    final all = <L3Trial>[];
    for (final v in variants.entries) {
      final perTask = <List<bool>>[];
      for (final task in tasks) {
        final trials = <L3Trial>[];
        for (var i = 0; i < k; i++) {
          // Real models sample (seeded per trial): pass^k measures
          // consistency, which temperature 0 would hide.
          final params = ctx.runtime == null
              ? null
              : GenerationParams(
                  temperature: 0.7,
                  topP: 0.8,
                  topK: 20,
                  seed: 1000 + i,
                  maxOutputTokens: ctx.runtime!.params.maxOutputTokens,
                  reasoning: ReasoningEffort.off,
                );
          final t = await runL3Trial(task, trial: i, variant: v.key, runtime: ctx.runtime, scriptedCapabilities: v.value, params: params);
          trials.add(t);
          if (!ctx.scripted || !t.pass) {
            ctx.log('  ${v.key}/${task.id} #$i: ${t.pass ? 'pass' : 'FAIL'} (${t.toolCalls} calls, ${t.steps} steps, '
              '${(t.durationMs / 1000).toStringAsFixed(1)} s)${t.pass ? '' : ' — ${t.problems.take(2).join('; ')}'}');
          }
        }
        all.addAll(trials);
        perTask.add([for (final t in trials) t.pass]);
        final passes = trials.where((t) => t.pass).length;
        report.cases.add(CaseResult(
          id: '${v.key}.${task.id}',
          group: v.key,
          pass: passes == trials.length,
          detail: passes == trials.length
              ? '$passes/${trials.length} trials pass (${trials.first.toolCalls} calls${trials.first.deferred ? ', deferred tools' : ''})'
              : '$passes/${trials.length} trials pass: ${trials.firstWhere((t) => !t.pass).problems.take(3).join('; ')}',
          data: {'trials': [for (final t in trials) t.toJson()]},
        ));
      }
      report.metrics.addAll([
        Metric('pass_at_1', passAt1(perTask), group: v.key, unit: 'ratio', better: Better.higher),
        Metric('pass_hat_k', passHatK(perTask, k), group: v.key, unit: 'ratio', better: Better.higher),
      ]);
    }
    final perTask = <List<bool>>[];
    for (final c in report.cases) {
      perTask.add([for (final t in (c.data['trials']! as List)) (t as Map)['pass'] == true]);
    }
    final n = all.length;
    final gate = ctx.scripted;
    report.metrics.insertAll(0, [
      Metric('pass_at_1', passAt1(perTask), unit: 'ratio', better: Better.higher, min: gate ? 1 : null,
          description: 'mean per-task success rate over trials'),
      Metric('pass_hat_k', passHatK(perTask, k), unit: 'ratio', better: Better.higher, min: gate ? 1 : null,
          description: 'share of tasks for which all k trials succeed (τ-bench pass^k)'),
      Metric('k', k.toDouble(), unit: 'count'),
      Metric('tasks', tasks.length.toDouble(), unit: 'count'),
      Metric('trials', n.toDouble(), unit: 'count'),
      Metric('mean_tool_calls', mean(all.map((t) => t.toolCalls)), better: gate ? Better.equal : Better.none,
          description: 'tool calls the harness started per trial'),
      Metric('mean_model_steps', mean(all.map((t) => t.steps)), better: gate ? Better.equal : Better.none),
      Metric('approval_prompts_per_task', mean(all.map((t) => t.prompts)), better: gate ? Better.equal : Better.none,
          description: 'approval sheets the scripted user answered per trial (UX cost)'),
      Metric.ratio('tool_error_rate', all.fold(0, (s, t) => s + t.toolErrors), all.fold(0, (s, t) => s + t.toolCalls),
          better: Better.lower, max: gate ? 0 : null, description: 'tool results with isError'),
      Metric('runs_not_completed', all.where((t) => t.outcome != 'completed').length.toDouble(),
          unit: 'count', better: Better.lower, max: gate ? 0 : null),
      Metric('unhandled_errors', all.fold(0, (s, t) => s + t.unhandled).toDouble(), unit: 'count', better: Better.lower, max: 0),
      Metric.ratio('deferred_trials', all.where((t) => t.deferred).length, n, description: 'trials whose tools were deferred (tool_search / call_tool)'),
      if (!gate) ...[
        Metric('mean_input_tokens', mean(all.map((t) => t.usage.inputTokens)), unit: 'tokens'),
        Metric('mean_output_tokens', mean(all.map((t) => t.usage.outputTokens)), unit: 'tokens'),
        Metric('mean_trial_seconds', mean(all.map((t) => t.durationMs / 1000)), unit: 's'),
      ],
    ]);
    if (!ctx.scripted) {
      report.notes.add('Real-model trials sample at temperature 0.7 / top-p 0.8 / top-k 20 with seed 1000+trial; '
          'the scripted user answers a leftover question with "$l3GoAhead" once.');
    }
    return report;
  }
}
