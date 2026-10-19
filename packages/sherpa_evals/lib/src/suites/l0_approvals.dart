/// L0 approval-gate matrix: taint × tool source × tool effect × call
/// condition × mode, through the real agent loop, router and policy.
library;

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';

import '../data.dart';
import '../report.dart';
import '../runtime/agent.dart';
import '../runtime/mcp_env.dart';

/// One matrix cell.
final class MatrixCell {
  const MatrixCell(this.taint, this.source, this.effect, this.condition, this.mode);

  final String taint;
  final String source;
  final String effect;
  final String condition;
  final String mode;

  String get id => '$taint.$source.$effect.$condition.$mode';

  bool get tainted => taint == 'tainted';
}

/// What a correct gate does with [c] (see `data/l0/approval_matrix.json`).
/// With [builtinExemptFromTaint] it encodes the code's documented
/// divergence instead (built-in tools skip taint gating).
({String outcome, List<String> scopes}) approvalOracle(MatrixCell c, {bool builtinExemptFromTaint = false}) {
  if (c.condition == 'truncated') return (outcome: 'blocked', scopes: const []);
  final declared = Hints.byName(c.effect);
  // A flagged tool's annotations are not trusted either (the router offers
  // it with the untrusted defaults).
  final untrusted = c.source == 'untrusted' || c.condition == 'flagged';
  final readOnly = !untrusted && declared.isReadOnly;
  final destructive = untrusted || declared.isDestructive;
  final openWorld = untrusted || declared.isOpenWorld;
  List<String> scopes({bool once = false}) => once
      ? const ['once']
      : destructive
          ? const ['once', 'session']
          : const ['once', 'session', 'always'];
  if ((c.condition == 'repaired' || c.condition == 'name_corrected') && !readOnly) {
    return (outcome: 'prompt_once', scopes: scopes(once: true));
  }
  // "Always" for a destructive tool is downgraded to the session.
  final always = c.mode == 'always_grant' && !destructive;
  final grant = c.mode == 'session_grant' || c.mode == 'always_grant';
  if (c.condition == 'flagged' && !grant) return (outcome: 'prompt', scopes: scopes());
  final exempt = builtinExemptFromTaint && c.source == 'builtin';
  if (c.tainted && !exempt && (!readOnly || openWorld)) {
    return always ? (outcome: 'auto', scopes: const []) : (outcome: 'prompt', scopes: scopes());
  }
  if (grant) return (outcome: 'auto', scopes: const []);
  if (readOnly && c.mode != 'ask_all') return (outcome: 'auto', scopes: const []);
  return (outcome: 'prompt', scopes: scopes());
}

final class _Builtin implements LocalTool {
  _Builtin(this.effect);

  final String effect;

  @override
  ToolDefinition get definition => ToolDefinition(
        name: 'builtin_$effect',
        description: 'Built-in eval tool ($effect).',
        inputSchema: const {
          'type': 'object',
          'properties': {'path': {'type': 'string'}},
        },
        annotations: Hints.byName(effect),
      );

  @override
  Future<ToolResult> run(Map<String, Object?> arguments, ToolExecutionContext context) async =>
      ToolResult.text('builtin_$effect ok');
}

final class MatrixTotals {
  int cells = 0;
  int agree = 0;
  int unsafeAuto = 0;
  int extraPrompts = 0;
  int known = 0;
}

Future<(List<CaseResult>, MatrixTotals)> runApprovalMatrix({String? only}) async {
  final data = loadData('l0/approval_matrix.json');
  final dims = (data['dims']! as Map).cast<String, Object?>();
  List<String> dim(String k) => [...(dims[k]! as List).cast<String>()];
  final na = objectList(data['notApplicable']);
  final knownIssue = objectList(data['divergences']).first['knownIssue']! as String;
  final flaggedDescription = data['flaggedDescription']! as String;
  final clock = FakeClock();

  final env = McpEnv(clock: clock);
  DartMcpServer server(String id) => DartMcpServer(
        info: McpImplementation(name: id, version: '1'),
        tools: [
          for (final e in dim('effect')) ...[
            for (final flagged in [false, true])
              mcpTool(
                flagged ? 'flagged_$e' : e,
                description: flagged ? flaggedDescription : 'Eval tool ($e).',
                properties: const {'path': {'type': 'string'}},
                annotations: Hints.byName(e),
                handler: (args, ctx) async => DartToolResult.text('$id $e ok'),
              ),
          ],
          if (id == 'untrusted')
            mcpTool('source', description: 'Returns a document.', annotations: Hints.read,
                handler: (args, ctx) async => DartToolResult.text('A document from the web.')),
        ],
      );
  env
    ..add('trusted', server('trusted'))
    ..add('untrusted', server('untrusted'), trusted: false);
  await env.reviewAll();
  final router = CompositeToolRouter([
    LocalToolRouter([for (final e in dim('effect')) _Builtin(e)]),
    env.router,
  ]);

  final cases = <CaseResult>[];
  final t = MatrixTotals();
  var n = 0;
  for (final taint in dim('taint')) {
    for (final source in dim('source')) {
      for (final effect in dim('effect')) {
        for (final condition in dim('condition')) {
          if (na.any((x) => x['source'] == source && x['condition'] == condition)) continue;
          for (final mode in dim('mode')) {
            final cell = MatrixCell(taint, source, effect, condition, mode);
            if (only != null && !cell.id.contains(only)) continue;
            n++;
            final observed = await _runCell(cell, n, router, env, clock);
            final want = approvalOracle(cell);
            final lenient = approvalOracle(cell, builtinExemptFromTaint: true);
            final ok = observed.outcome == want.outcome && _sameScopes(observed.scopes, want.scopes);
            final isKnown = !ok &&
                observed.outcome == lenient.outcome &&
                _sameScopes(observed.scopes, lenient.scopes) &&
                (want.outcome != lenient.outcome || !_sameScopes(want.scopes, lenient.scopes));
            t.cells++;
            if (ok) t.agree++;
            if (isKnown) t.known++;
            if (!ok && !isKnown && observed.outcome == 'auto') t.unsafeAuto++;
            if (!ok && want.outcome == 'auto' && observed.outcome.startsWith('prompt')) t.extraPrompts++;
            cases.add(CaseResult(
              id: 'approvals.${cell.id}',
              group: 'approvals',
              pass: ok,
              knownIssue: isKnown ? knownIssue : null,
              detail: ok
                  ? observed.describe()
                  : 'expected ${want.outcome}${want.scopes.isEmpty ? '' : ' ${want.scopes}'}, observed ${observed.describe()}',
            ));
          }
        }
      }
    }
  }
  await env.close();
  return (cases, t);
}

bool _sameScopes(List<String> a, List<String> b) => a.length == b.length && a.toSet().containsAll(b);

final class _Observed {
  _Observed(this.outcome, this.scopes, this.reason);

  final String outcome;
  final List<String> scopes;
  final String? reason;

  String describe() => '$outcome${scopes.isEmpty ? '' : ' $scopes'}${reason == null ? '' : ' ("${_clip(reason!)}")'}';

  static String _clip(String s) => s.length > 70 ? '${s.substring(0, 69)}…' : s;
}

Future<_Observed> _runCell(MatrixCell c, int n, ToolRouter router, McpEnv env, Clock clock) async {
  final sid = 'cell$n';
  final store = InMemorySessionStore();
  await newSession(store, sid, clock);
  if (c.tainted) {
    final at = clock.now();
    await store.putMessage(sid, Message(id: 'u0', role: Role.user, content: const [TextPart('Read the page.')], createdAt: at));
    await store.putMessage(sid, Message(
      id: 'a0',
      parentId: 'u0',
      role: Role.assistant,
      content: const [ToolCallPart(ToolCall(id: 't0', name: 'untrusted__source', arguments: {}))],
      createdAt: at,
      finishReason: 'toolCalls',
    ));
    await store.putMessage(sid, Message(
      id: 'r0',
      parentId: 'a0',
      role: Role.tool,
      content: const [ToolResultPart(callId: 't0', toolName: 'untrusted__source', content: [TextPart('A document.')])],
      createdAt: at,
    ));
    final s = (await store.getSession(sid))!;
    await store.putSession(s.copyWith(activeLeafId: 'r0'));
  }
  final policy = ApprovalPolicy(clock: clock, trustedServers: env.trustedServerIds, autoRunReadOnly: c.mode != 'ask_all');
  final flagged = c.condition == 'flagged';
  final target = c.source == 'builtin' ? 'builtin_${c.effect}' : '${c.source}__${flagged ? 'flagged_' : ''}${c.effect}';
  final def = router.lookup(target);
  if (def == null) throw StateError('no tool $target');
  if (c.mode == 'session_grant' || c.mode == 'always_grant') {
    policy.recordFor(def, sid,
        ApprovalResponse(UserDecision.approve, scope: c.mode == 'session_grant' ? ApprovalScope.session : ApprovalScope.always));
  }
  const args = {'path': '/x'};
  final call = switch (c.condition) {
    'repaired' => const ToolCall(id: 'c1', name: '', arguments: args, repaired: true),
    'name_corrected' => ToolCall(id: 'c1', name: 'call_tool', arguments: {'name': target.toUpperCase(), 'arguments': args}),
    _ => const ToolCall(id: 'c1', name: '', arguments: args),
  };
  final named = call.name.isEmpty
      ? ToolCall(id: call.id, name: target, arguments: call.arguments, repaired: call.repaired)
      : call;
  final provider = ScriptedProvider([
    ScriptedTurn(toolCallEvents([named], finish: c.condition == 'truncated' ? FinishReason.length : FinishReason.toolCalls)),
    ScriptedTurn.text('ok'),
  ]);
  final user = ScriptedUser();
  final runner = AgentRunner(
    store: store,
    provider: provider,
    modelId: 'scripted',
    tools: router,
    approvals: policy,
    approvalHandler: user,
    clock: clock,
    ids: SequentialIdGenerator(),
    sleep: (_) async {},
  );
  final events = await drive(runner.send(sid, const [TextPart('go')]));
  final ran = startedCalls(events).any((x) => x.id == 'c1');
  final prompt = user.prompts.where((p) => p.call.id == 'c1').firstOrNull;
  if (prompt != null) {
    final req = prompt.requirement;
    return _Observed(req.oneOffOnly ? 'prompt_once' : 'prompt', [for (final s in req.allowedScopes) s.name], req.reason);
  }
  return _Observed(ran ? 'auto' : 'blocked', const [], null);
}
