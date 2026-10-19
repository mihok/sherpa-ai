/// L0 durability: crash and resume at every durable operation (R11 §9.8),
/// with exactly-once accounting of side effects at the servers.
library;

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';

import '../data.dart';
import '../report.dart';
import '../runtime/agent.dart';
import '../runtime/mcp_env.dart';

/// Thrown by every durable operation once the simulated process is dead.
final class ProcessDeath implements Exception {
  const ProcessDeath(this.op);
  final String op;

  @override
  String toString() => 'ProcessDeath(before $op)';
}

/// Counts durable operations; after [budget] of them the process is dead
/// and every later operation throws without taking effect.
final class CrashSwitch {
  CrashSwitch([this.budget]);

  final int? budget;
  final List<String> ops = [];
  String? failedOp;

  bool get dead => failedOp != null;

  void op(String label) {
    if (dead) throw ProcessDeath(label);
    if (budget != null && ops.length >= budget!) {
      failedOp = label;
      throw ProcessDeath(label);
    }
    ops.add(label);
  }
}

/// The session store on "disk": writes count as durable operations.
final class FaultStore implements SessionStore {
  FaultStore(this.disk, this.sw);

  final InMemorySessionStore disk;
  final CrashSwitch sw;

  Future<T> _w<T>(String label, Future<T> Function() f) async {
    sw.op(label);
    return f();
  }

  @override
  Future<SessionRecord> putSession(SessionRecord session) => _w('session', () => disk.putSession(session));

  @override
  Future<SessionRecord?> getSession(String id) => disk.getSession(id);

  @override
  Future<List<SessionRecord>> listSessions({bool includeArchived = false}) =>
      disk.listSessions(includeArchived: includeArchived);

  @override
  Future<void> deleteSession(String id) => _w('delete', () => disk.deleteSession(id));

  @override
  Future<void> putMessage(String sessionId, Message message) =>
      _w('message:${message.role.name}${message.metadata['draft'] == true ? ':draft' : ''}',
          () => disk.putMessage(sessionId, message));

  @override
  Future<Message?> getMessage(String sessionId, String messageId) => disk.getMessage(sessionId, messageId);

  @override
  Future<List<Message>> path(String sessionId, String leafId) => disk.path(sessionId, leafId);

  @override
  Future<List<Message>> children(String sessionId, String? parentId) => disk.children(sessionId, parentId);

  @override
  Future<void> putOverlay(String sessionId, ContextOverlay overlay) => _w('overlay', () => disk.putOverlay(sessionId, overlay));

  @override
  Future<void> removeOverlay(String sessionId, String overlayId) =>
      _w('overlay:remove', () => disk.removeOverlay(sessionId, overlayId));

  @override
  Future<List<ContextOverlay>> overlays(String sessionId) => disk.overlays(sessionId);

  @override
  Future<void> putPlan(String sessionId, Plan plan) => _w('plan', () => disk.putPlan(sessionId, plan));

  @override
  Future<Plan?> getPlan(String sessionId) => disk.getPlan(sessionId);

  @override
  Future<void> putCheckpoint(RunCheckpoint checkpoint) =>
      _w('checkpoint:${checkpoint.phase.name}', () => disk.putCheckpoint(checkpoint));

  @override
  Future<RunCheckpoint?> getCheckpoint(String sessionId) => disk.getCheckpoint(sessionId);

  @override
  Future<void> appendAudit(AuditEntry entry) => _w('audit', () => disk.appendAudit(entry));

  @override
  Future<List<AuditEntry>> audit(String sessionId, {int? limit}) => disk.audit(sessionId, limit: limit);
}

/// The process's side of tool calls: a call that has not left the process
/// when it dies never reaches the server.
final class FaultRouter implements ToolRouter {
  FaultRouter(this.inner, this.sw);

  final ToolRouter inner;
  final CrashSwitch sw;

  @override
  Future<List<ToolDefinition>> toolsForTurn({
    required String sessionId,
    String? query,
    int? schemaTokenBudget,
    ToolSelectionHints? hints,
  }) =>
      inner.toolsForTurn(sessionId: sessionId, query: query, schemaTokenBudget: schemaTokenBudget, hints: hints);

  @override
  ToolDefinition? lookup(String name) => inner.lookup(name);

  @override
  ResolvedToolCall? resolve(ToolCall call, {required String sessionId}) => inner.resolve(call, sessionId: sessionId);

  @override
  Future<ToolResult> execute(ToolCall call, ToolExecutionContext context) async {
    sw.op('tool:${call.name}');
    return inner.execute(call, context);
  }
}

/// Side effects as the servers saw them, keyed by idempotency key
/// (`<assistantMessageId>:<callId>`). Survives "process death".
final class EffectLedger {
  final Map<String, int> applied = {};
  final Map<String, int> attempts = {};
  final Map<String, String> _cached = {};

  int appliedFor(String callId) =>
      applied.entries.where((e) => e.key.endsWith(':$callId')).fold(0, (n, e) => n + e.value);

  int attemptsFor(String callId) =>
      attempts.entries.where((e) => e.key.endsWith(':$callId')).fold(0, (n, e) => n + e.value);
}

/// A server whose tools count side effects per idempotency key.
/// `idempotent_write` dedupes by key (returns the first result again);
/// `write`, `send` and `destructive` apply every call.
DartMcpServer effectServer(String id, List<Map<String, Object?>> tools, EffectLedger ledger, Map<String, Set<String>> argKeys) =>
    DartMcpServer(
      info: McpImplementation(name: id, version: '1'),
      tools: [
        for (final t in tools)
          mcpTool(
            t['name']! as String,
            description: 'Eval tool ${t['name']} (${t['kind']}).',
            annotations: Hints.byName(t['kind']! as String),
            properties: {for (final k in argKeys['${id}__${t['name']}'] ?? const <String>{}) k: {'type': 'string'}},
            handler: (args, ctx) async {
              final kind = t['kind']! as String;
              final key = ctx.idempotencyKey ?? 'nokey';
              ledger.attempts[key] = (ledger.attempts[key] ?? 0) + 1;
              if (kind == 'read') return DartToolResult.text('${t['name']}: value for ${args.values.join(',')}');
              if (kind == 'idempotent_write' && ledger._cached.containsKey(key)) {
                return DartToolResult.text(ledger._cached[key]!);
              }
              ledger.applied[key] = (ledger.applied[key] ?? 0) + 1;
              final text = '${t['name']} applied';
              ledger._cached[key] = text;
              return DartToolResult.text(text);
            },
          ),
      ],
    );

/// Ids of one process generation (a restarted process must not reuse ids).
final class GenerationIds implements IdGenerator {
  GenerationIds(this.prefix);

  final String prefix;
  final SequentialIdGenerator _inner = SequentialIdGenerator();

  @override
  String next([String p = 'id']) => '$prefix${_inner.next(p)}';
}

final class _Scenario {
  _Scenario(this.json)
      : id = json['id']! as String,
        task = json['task']! as String,
        servers = objectList(json['servers']),
        steps = [for (final s in (json['steps']! as List)) objectList(s)];

  final Map<String, Object?> json;
  final String id;
  final String task;
  final List<Map<String, Object?>> servers;
  final List<List<Map<String, Object?>>> steps;

  String callId(int step, int i) => 's${step}c$i';

  /// Tool kind by model-facing name.
  Map<String, String> get kinds => {
        for (final s in servers)
          for (final t in objectList(s['tools'])) '${s['id']}__${t['name']}': t['kind']! as String,
      };

  Map<String, Set<String>> get argKeys {
    final out = <String, Set<String>>{};
    for (final step in steps) {
      for (final c in step) {
        (out[c['tool']! as String] ??= {}).addAll((c['args']! as Map).keys.cast<String>());
      }
    }
    return out;
  }

  /// The recorded ideal trajectory as a policy: issue the first step whose
  /// calls are not in the transcript yet, then finish. Deterministic call
  /// ids make a re-streamed step identical.
  List<ModelEvent> policy(ModelRequest request) {
    final issued = {for (final c in callsIn(request)) c.id};
    for (final (i, step) in steps.indexed) {
      final ids = [for (var j = 0; j < step.length; j++) callId(i, j)];
      if (ids.every(issued.contains)) continue;
      return toolCallEvents([
        for (final (j, c) in step.indexed)
          ToolCall(id: callId(i, j), name: c['tool']! as String, arguments: (c['args']! as Map).cast<String, Object?>()),
      ]);
    }
    return textEvents('Done: ${steps.length} step(s) finished.');
  }
}

final class _Process {
  _Process(this.events, this.errors, this.prompts, this.ops, this.failedOp);

  final List<AgentEvent> events;
  final List<Object> errors;
  final List<ApprovalPrompt> prompts;
  final List<String> ops;
  final String? failedOp;

  RunFinished? get finished => finishedOf(events);
}

/// Totals over every crash point.
final class DurabilityTotals {
  int crashPoints = 0;
  int completed = 0;
  int duplicates = 0;
  int lostIdempotent = 0;
  int silentLosses = 0;
  int unknownReports = 0;
  int pairing = 0;
  int reprompts = 0;
  int unhandled = 0;
  int lostBeforeCheckpoint = 0;
  final Map<String, int> phases = {};
  final Map<String, int> failedOps = {};
}

const String _sid = 's';

Future<_Process> _runProcess(
  _Scenario s, {
  required InMemorySessionStore disk,
  required CrashSwitch sw,
  required bool resume,
  required int generation,
  required InMemoryToolPinStore pins,
  required Map<String, DartMcpServer> servers,
  required Clock clock,
}) async {
  final env = McpEnv(pins: pins, clock: clock);
  for (final srv in s.servers) {
    env.add(srv['id']! as String, servers[srv['id']]!, trusted: srv['trusted'] == true);
  }
  await env.reviewAll();
  final user = ScriptedUser();
  final runner = AgentRunner(
    store: FaultStore(disk, sw),
    provider: policyProvider(s.policy),
    modelId: 'scripted',
    tools: FaultRouter(env.router, sw),
    approvals: ApprovalPolicy(clock: clock, trustedServers: env.trustedServerIds),
    approvalHandler: user,
    clock: clock,
    ids: GenerationIds('g$generation'),
    sleep: (_) async {},
  );
  final (events, errors) = await guarded(
      () => (resume ? runner.resume(_sid) : runner.send(_sid, [TextPart(s.task)])).toList());
  await env.close();
  return _Process(events ?? const [], errors, user.prompts, [...sw.ops], sw.failedOp);
}

/// Runs every scenario of `data/l0/durability.json` at every crash point.
Future<(List<CaseResult>, DurabilityTotals)> runDurability({String? only}) async {
  final data = loadData('l0/durability.json');
  final cases = <CaseResult>[];
  final t = DurabilityTotals();
  for (final json in objectList(data['scenarios'])) {
    final s = _Scenario(json);
    if (only != null && !s.id.contains(only)) continue;
    final clock = FakeClock();

    Future<(InMemorySessionStore, EffectLedger, InMemoryToolPinStore, Map<String, DartMcpServer>)> fresh() async {
      final disk = InMemorySessionStore();
      await newSession(disk, _sid, clock);
      final ledger = EffectLedger();
      final servers = {
        for (final srv in s.servers)
          srv['id']! as String: effectServer(srv['id']! as String, objectList(srv['tools']), ledger, s.argKeys),
      };
      return (disk, ledger, InMemoryToolPinStore(), servers);
    }

    // Clean run: enumerates the durable operations.
    final (cDisk, cLedger, cPins, cServers) = await fresh();
    final clean = await _runProcess(s,
        disk: cDisk, sw: CrashSwitch(), resume: false, generation: 0, pins: cPins, servers: cServers, clock: clock);
    for (final srv in cServers.values) {
      await srv.close();
    }
    final cleanProblems = <String>[
      if (clean.finished?.outcome != RunOutcome.completed) 'clean run ended ${clean.finished?.outcome.name}',
      if (clean.errors.isNotEmpty) 'clean run: unhandled ${clean.errors.first}',
      ..._effectProblems(s, cLedger, completed: true, results: _results(await activePath(cDisk, _sid))),
    ];
    t.unhandled += clean.errors.length;
    cases.add(CaseResult(
      id: '${s.id}.clean',
      group: 'durability',
      pass: cleanProblems.isEmpty,
      detail: cleanProblems.isEmpty ? '${clean.ops.length} durable operations' : cleanProblems.join('; '),
      data: {'ops': clean.ops},
    ));

    for (var k = 0; k < clean.ops.length; k++) {
      final (disk, ledger, pins, servers) = await fresh();
      final first = await _runProcess(s,
          disk: disk, sw: CrashSwitch(k), resume: false, generation: 1, pins: pins, servers: servers, clock: clock);
      final atCrash = await disk.getCheckpoint(_sid);
      final decided = <String>{
        for (final p in atCrash?.pendingCalls ?? const <PendingCall>[])
          if (p.status != PendingCallStatus.pending) p.callId,
        if (atCrash?.draftMessageId case final draft?)
          for (final r in (await disk.getMessage(_sid, draft))?.toolResults ?? const <ToolResultPart>[]) r.callId,
      };
      final second = await _runProcess(s,
          disk: disk, sw: CrashSwitch(), resume: true, generation: 2, pins: pins, servers: servers, clock: clock);
      for (final srv in servers.values) {
        await srv.close();
      }
      final path = await activePath(disk, _sid);
      final results = _results(path);
      final phase = atCrash?.phase.name ?? 'none';
      t.crashPoints++;
      t.phases[phase] = (t.phases[phase] ?? 0) + 1;
      final failedOp = first.failedOp ?? '?';
      final opKind = failedOp.split(':').take(2).join(':');
      t.failedOps[opKind] = (t.failedOps[opKind] ?? 0) + 1;

      final problems = <String>[];
      final nothing = second.finished?.detail == 'nothing to resume';
      // Completed: the resumed run finished the whole trajectory.
      final completed = second.finished?.outcome == RunOutcome.completed && !nothing;
      if (nothing) {
        if (atCrash == null) {
          t.lostBeforeCheckpoint++;
          if (ledger.applied.isNotEmpty) problems.add('no checkpoint, yet side effects happened');
        } else if (!atCrash.isTerminal) {
          problems.add('resume found nothing to do at phase $phase');
        }
      } else if (!completed) {
        problems.add('resume ended ${second.finished?.outcome.name}: ${second.finished?.detail ?? second.finished?.error}');
      }
      if (completed || nothing && (atCrash == null || atCrash.isTerminal)) t.completed++;
      final effects = _effectProblems(s, ledger, completed: completed || atCrash?.isTerminal == true, results: results);
      problems.addAll(effects);
      for (final e in effects) {
        if (e.startsWith('duplicate')) t.duplicates++;
        if (e.startsWith('lost idempotent')) t.lostIdempotent++;
        if (e.startsWith('silently lost')) t.silentLosses++;
      }
      t.unknownReports += results.values.where((r) => r.isError && r.text.contains('interrupted')).length;
      final pairing = pairingViolations(path);
      t.pairing += pairing.length;
      problems.addAll(pairing);
      final reasked = [for (final p in second.prompts) if (decided.contains(p.call.id)) p.call.id];
      t.reprompts += reasked.length;
      if (reasked.isNotEmpty) problems.add('asked again after a persisted decision: ${reasked.join(', ')}');
      t.unhandled += second.errors.length;
      if (second.errors.isNotEmpty) problems.add('resume: unhandled ${second.errors.first}');
      cases.add(CaseResult(
        id: '${s.id}.crash@$k',
        group: 'durability',
        pass: problems.isEmpty,
        detail: problems.isEmpty
            ? 'died before $failedOp (checkpoint $phase); resumed ${nothing ? '(nothing to resume)' : 'and finished'}'
            : problems.join('; '),
        data: {'failedOp': failedOp, 'phase': phase, 'firstProcessErrors': first.errors.length},
      ));
    }
  }
  return (cases, t);
}

Map<String, ToolResultPart> _results(List<Message> path) => {
      for (final m in path)
        for (final r in m.toolResults) r.callId: r,
    };

/// Side-effect accounting for one run (R11 §9.8):
/// * no planned call may take effect twice (any kind);
/// * a trusted idempotent call takes effect exactly once when the run
///   completed (the server dedupes the re-run by key);
/// * a call that did not take effect must not be reported as a success.
List<String> _effectProblems(_Scenario s, EffectLedger ledger, {required bool completed, required Map<String, ToolResultPart> results}) {
  final out = <String>[];
  final kinds = s.kinds;
  final trusted = {for (final srv in s.servers) if (srv['trusted'] == true) srv['id']};
  for (final (i, step) in s.steps.indexed) {
    for (final (j, c) in step.indexed) {
      final id = s.callId(i, j);
      final tool = c['tool']! as String;
      final kind = kinds[tool]!;
      if (kind == 'read') continue;
      final n = ledger.appliedFor(id);
      final r = results[id];
      if (n > 1) out.add('duplicate side effect: $tool ($id) applied $n times');
      if (!completed) continue;
      final idempotent = kind == 'idempotent_write' && trusted.contains(tool.split('__').first);
      if (idempotent && n == 0) out.add('lost idempotent side effect: $tool ($id) never applied');
      if (n == 0 && r != null && !r.isError) out.add('silently lost: $tool ($id) reported success but never applied');
    }
  }
  return out;
}
