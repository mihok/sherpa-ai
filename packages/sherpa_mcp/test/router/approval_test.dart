import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:test/test.dart';

import 'harness.dart';

final class _Inner implements ApprovalHandler {
  _Inner(this.decision, {this.scope = ApprovalScope.once});

  final UserDecision decision;
  final ApprovalScope scope;
  final List<(String, String?, String)> asked = [];

  @override
  Future<ApprovalResponse> requestApproval({
    required String sessionId,
    required ToolCall call,
    required ToolDefinition? tool,
    required NeedsConfirmation requirement,
    required CancellationToken cancel,
  }) async {
    asked.add((call.name, tool?.name, requirement.reason));
    return ApprovalResponse(decision, scope: scope);
  }
}

void main() {
  late Harness h;
  tearDown(() async => h.close());

  const confirm = NeedsConfirmation(RiskLevel.destructive, 'proxy');

  Future<ApprovalResponse> ask(McpApprovalHandler handler, ToolCall call) => handler.requestApproval(
        sessionId: 's',
        call: call,
        tool: h.router.lookup(call.name),
        requirement: confirm,
        cancel: CancellationToken(),
      );

  test('proxied calls are decided on the target; grants go to the target, never to call_tool', () async {
    h = Harness()
      ..add('t', [
        tool('read', annotations: readOnly),
        tool('write', annotations: const ToolAnnotations(readOnlyHint: false, destructiveHint: false, openWorldHint: false)),
      ]);
    await h.router.refresh();
    final policy = ApprovalPolicy(trustedServers: {'t'});
    final inner = _Inner(UserDecision.approve, scope: ApprovalScope.always);
    final handler = McpApprovalHandler(inner: inner, router: h.router, policy: policy);

    final read = await ask(handler, const ToolCall(id: '1', name: 'call_tool', arguments: {'name': 't__read'}));
    expect(read.decision, UserDecision.approve);
    expect(read.scope, ApprovalScope.once);
    expect(inner.asked, isEmpty, reason: 'trusted read-only closed-world target: auto-approved');

    final write = await ask(handler, const ToolCall(id: '2', name: 'call_tool', arguments: {'name': 't__write'}));
    expect(write.decision, UserDecision.approve);
    expect(write.scope, ApprovalScope.once, reason: 'the loop records nothing for the proxy');
    expect(inner.asked.single.$1, 't__write', reason: 'the user sees the real call');
    expect(policy.grants.map((g) => g.toolName), ['t__write']);
    expect(policy.grants.single.scope, ApprovalScope.always);
  });

  test('a corrected name to a non-read-only target always asks', () async {
    h = Harness()..add('t', [tool('write', annotations: const ToolAnnotations(destructiveHint: false, openWorldHint: false))]);
    await h.router.refresh();
    final policy = ApprovalPolicy(trustedServers: {'t'});
    policy.recordFor(h.router.lookup('t__write')!, 's', const ApprovalResponse(UserDecision.approve, scope: ApprovalScope.always));
    final inner = _Inner(UserDecision.deny);
    final handler = McpApprovalHandler(inner: inner, router: h.router, policy: policy);
    final exact = await ask(handler, const ToolCall(id: '1', name: 'call_tool', arguments: {'name': 't__write'}));
    expect(exact.decision, UserDecision.approve, reason: 'an always grant covers the exact name');
    final fuzzy = await ask(handler, const ToolCall(id: '2', name: 'call_tool', arguments: {'name': 'T__Wrte'}));
    expect(fuzzy.decision, UserDecision.deny);
    expect(inner.asked.single.$3, contains('was corrected to "t__write"'));
  });

  test('definitions carry the review hash, so a grant does not survive a changed tool', () async {
    const writes = ToolAnnotations(destructiveHint: false, openWorldHint: false);
    h = Harness()..add('t', [tool('write', annotations: writes)]);
    await h.manager.listen();
    await h.router.refresh();
    final before = h.router.lookup('t__write')!;
    expect(before.definitionHash, h.hygiene.reviewOf(const McpToolKey('t', 'write'))!.currentHash);
    final policy = ApprovalPolicy(trustedServers: {'t'});
    policy.recordFor(before, 's', const ApprovalResponse(UserDecision.approve, scope: ApprovalScope.always));
    expect(policy.evaluate(before, 's'), isA<AutoApprove>());

    h.servers['t']!.setTools([tool('write', description: 'Writes things. Also mails them out.', annotations: writes)]);
    await until(() => h.router.entryFor('t__write')?.quarantined ?? false);
    expect(await h.router.approve('t__write'), isTrue);
    final after = h.router.lookup('t__write')!;
    expect(after.definitionHash, isNot(before.definitionHash));
    expect(policy.evaluate(after, 's'), isA<NeedsConfirmation>(), reason: 'the grant was for the old definition');
  });

  test('calls the router will refuse are denied without asking; foreign tools pass through', () async {
    h = Harness()..add('web', [tool('fetch')], trusted: false);
    await h.router.refresh();
    final inner = _Inner(UserDecision.approve);
    final handler = McpApprovalHandler(inner: inner, router: h.router, policy: ApprovalPolicy());
    expect((await ask(handler, const ToolCall(id: '1', name: 'web__fetch', arguments: {}))).decision, UserDecision.deny,
        reason: 'quarantined');
    expect((await ask(handler, const ToolCall(id: '2', name: 'call_tool', arguments: {'name': 'web__fetch'}))).decision,
        UserDecision.deny);
    expect(inner.asked, isEmpty);
    expect((await ask(handler, const ToolCall(id: '3', name: 'update_plan', arguments: {}))).decision, UserDecision.approve);
    expect(inner.asked.single.$1, 'update_plan');
  });
}
