/// L0 rug-pull detection through `McpToolRouter` and `ToolHygiene`.
library;

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';

import '../data.dart';
import '../report.dart';
import '../runtime/mcp_env.dart';

final class RugPullTotals {
  int changed = 0;
  int detected = 0;
  int silent = 0;
  int silentDetected = 0;
  int staleGrants = 0;
  int falseQuarantines = 0;
  int callsBeforeDetection = 0;
}

DartMcpTool _tool(Map<String, Object?> spec, {Map<String, Object?>? change, List<String>? log}) {
  final c = change ?? const <String, Object?>{};
  return mcpTool(
    spec['name']! as String,
    title: c['title'] as String?,
    description: (c['description'] ?? spec['description'])! as String,
    properties: ((c['properties'] ?? spec['properties'])! as Map).cast<String, Object?>(),
    annotations: Hints.byName((c['kind'] ?? spec['kind'])! as String),
    handler: (args, ctx) async {
      log?.add('save_note ${args['text']}');
      return DartToolResult.text('saved');
    },
  );
}

Future<(List<CaseResult>, RugPullTotals)> runRugPull({String? only}) async {
  final data = loadData('l0/rugpull.json');
  final target = (data['target']! as Map).cast<String, Object?>();
  final name = 'notes__${target['name']}';
  final t = RugPullTotals();
  final cases = <CaseResult>[];
  for (final c in objectList(data['cases'])) {
    final id = c['id']! as String;
    if (only != null && !'rugpull.$id'.contains(only)) continue;
    final change = (c['change'] as Map?)?.cast<String, Object?>();
    final changed = change != null;
    final notify = c['notify'] == true;
    final clock = FakeClock();
    final env = McpEnv(clock: clock, maxCatalogAge: const Duration(minutes: 1));
    if (!notify) env.muteListChanged.add('notes');
    final other = mcpTool('list_notes', description: 'Lists notes.', annotations: Hints.read,
        handler: (args, ctx) async => DartToolResult.text('[]'));
    final server = DartMcpServer(info: McpImplementation(name: 'notes', version: '1'), tools: [_tool(target), other]);
    env.add('notes', server, trusted: c['trusted'] == true);
    await env.reviewAll();
    final policy = ApprovalPolicy(clock: clock, trustedServers: env.trustedServerIds);
    const sid = 's';
    ToolExecutionContext ctx() => ToolExecutionContext(sessionId: sid, cancel: CancellationToken(), timeout: const Duration(seconds: 5));
    final call = ToolCall(id: 'c1', name: name, arguments: const {'text': 'buy milk'});
    final problems = <String>[];

    final offered0 = (await env.router.toolsForTurn(sessionId: sid)).any((x) => x.name == name);
    if (!offered0) problems.add('not offered before the change');
    policy.recordFor(env.router.lookup(name)!, sid, const ApprovalResponse(UserDecision.approve, scope: ApprovalScope.always));
    if (policy.evaluate(env.router.lookup(name)!, sid) is! AutoApprove) problems.add('grant did not apply before the change');
    if ((await env.router.execute(call, ctx())).isError) problems.add('call failed before the change');

    server.setTools([_tool(target, change: change), other]);
    var detected = false;
    if (notify) {
      detected = await waitUntil(() => env.router.entryFor(name)?.quarantined ?? false, timeout: const Duration(seconds: 2));
    } else {
      // Still the old segment: the call uses the reviewed state.
      if (!(await env.router.execute(call, ctx())).isError && changed) t.callsBeforeDetection++;
      clock.advance(const Duration(minutes: 2));
      env.router.resetSegment(sid);
      await env.router.toolsForTurn(sessionId: sid);
      detected = env.router.entryFor(name)?.quarantined ?? false;
    }
    env.router.resetSegment(sid);
    final offered = (await env.router.toolsForTurn(sessionId: sid)).any((x) => x.name == name);
    final ran = !(await env.router.execute(call, ctx())).isError;
    final stale = policy.evaluate(env.router.lookup(name)!, sid) is AutoApprove;

    if (changed) {
      t.changed++;
      if (!notify) t.silent++;
      if (detected && !offered && !ran) {
        t.detected++;
        if (!notify) t.silentDetected++;
      }
      if (!detected) problems.add('change not detected');
      if (offered) problems.add('changed tool still offered in a new segment');
      if (ran) problems.add('changed tool still executable');
      if (stale) {
        t.staleGrants++;
        problems.add('the old grant still auto-approves the changed tool');
      }
      // The user re-approves from the diff: old grants must go.
      await env.router.approve(name);
      for (final n in env.invalidated) {
        policy.revoke(n);
      }
      if (policy.evaluate(env.router.lookup(name)!, sid) is AutoApprove) {
        t.staleGrants++;
        problems.add('after re-approval the old grant still applies');
      }
    } else {
      if (detected || !offered || !ran) {
        t.falseQuarantines++;
        problems.add('unchanged tool was quarantined or blocked');
      }
      if (!stale) problems.add('grant for the unchanged definition stopped applying');
    }
    await env.close();
    cases.add(CaseResult(
      id: 'rugpull.$id',
      group: 'rugpull',
      pass: problems.isEmpty,
      detail: problems.isEmpty
          ? (changed ? 'quarantined ${notify ? 'on list_changed' : 'at the next re-list'}; grant invalidated' : 'no false positive')
          : problems.join('; '),
    ));
  }
  return (cases, t);
}
