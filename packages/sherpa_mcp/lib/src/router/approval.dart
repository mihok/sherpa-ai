/// Approval for proxied (`call_tool`) and quarantined MCP calls.
library;

import 'package:sherpa_core/sherpa_core.dart'
    show
        ApprovalHandler,
        ApprovalPolicy,
        ApprovalResponse,
        AutoApprove,
        CancellationToken,
        Denied,
        NeedsConfirmation,
        ToolCall,
        ToolDefinition,
        UserDecision;

import 'mcp_tool_router.dart';

/// Wraps the app's [ApprovalHandler] so approvals are decided on the tool
/// that will actually run.
///
/// **Not needed with `AgentRunner`.** The core loop now resolves calls
/// through `ToolRouter.resolve` ([McpToolRouter.resolve]) before gating:
/// it evaluates the policy on the target, answers refusals without asking,
/// forces a one-off confirmation for corrected names and records grants for
/// the target. It hands this handler the resolved call, which passes
/// straight through to [inner]. The wrapper remains for code that drives
/// approvals for raw `call_tool` calls itself.
///
/// For a raw `call_tool` call (the proxy's definition says nothing about the
/// target, and a grant recorded for "call_tool" would cover every tool),
/// this handler:
///
/// * evaluates the [ApprovalPolicy] on the TARGET (with `tainted: true`,
///   because the handler cannot see the session's taint and the proxy's
///   own results — tool cards quoting server text — taint it anyway);
///   auto-approves when the policy would, asks the inner handler with the
///   target's call and definition otherwise, records the grant for the
///   target, and answers the loop with a one-off approval so nothing is
///   ever granted to the proxy;
/// * forces confirmation for a name-corrected (normalized / fuzzy-matched)
///   call to a non-read-only target (R11 §9.6.7);
/// * denies at once a call the router will refuse anyway (quarantined,
///   disabled, app-only), so the user is not asked to approve something
///   that cannot run;
/// * passes everything else to the inner handler unchanged.
final class McpApprovalHandler implements ApprovalHandler {
  McpApprovalHandler({required this.inner, required this.router, required this.policy, this.assumeTainted = true});

  final ApprovalHandler inner;
  final McpToolRouter router;
  final ApprovalPolicy policy;

  /// Evaluate proxied targets as if the session were tainted (default).
  final bool assumeTainted;

  @override
  Future<ApprovalResponse> requestApproval({
    required String sessionId,
    required ToolCall call,
    required ToolDefinition? tool,
    required NeedsConfirmation requirement,
    required CancellationToken cancel,
  }) async {
    final r = router.resolveCall(call, sessionId: sessionId);
    if (!r.known) {
      return inner.requestApproval(sessionId: sessionId, call: call, tool: tool, requirement: requirement, cancel: cancel);
    }
    if (r.refusal != null) return const ApprovalResponse(UserDecision.deny);
    if (!r.viaProxy) {
      return inner.requestApproval(sessionId: sessionId, call: call, tool: tool, requirement: requirement, cancel: cancel);
    }
    final target = r.definition!;
    var decision = policy.evaluate(target, sessionId, tainted: assumeTainted, repaired: call.repaired);
    if (decision is AutoApprove && r.correctedName && !policy.annotationsFor(target).isReadOnly) {
      decision = NeedsConfirmation(
        policy.riskFor(target),
        'The tool name "${call.arguments['name']}" was corrected to "${target.name}"; confirm this is the right tool.',
        oneOffOnly: true,
      );
    }
    switch (decision) {
      case AutoApprove():
        return const ApprovalResponse(UserDecision.approve);
      case Denied():
        return const ApprovalResponse(UserDecision.deny);
      case NeedsConfirmation():
        final response = await inner.requestApproval(
          sessionId: sessionId,
          call: r.call,
          tool: target,
          requirement: decision,
          cancel: cancel,
        );
        if (cancel.isCancelled) return const ApprovalResponse(UserDecision.deny);
        policy.recordFor(target, sessionId, response, requirement: decision);
        return ApprovalResponse(response.decision);
    }
  }
}
