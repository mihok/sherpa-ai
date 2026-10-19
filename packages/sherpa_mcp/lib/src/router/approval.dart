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
/// Why it exists: the agent loop gates a call by the definition its router
/// returns for the CALLED name. For `call_tool` that is the proxy, which
/// says nothing about the target, and a grant recorded for "call_tool"
/// would cover every tool. The proxy is therefore declared destructive so
/// the loop always asks this handler, and this handler:
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
///
/// Note for the core: with a `ToolRouter.resolve(call)` hook the loop could
/// do this itself (and emit approval events for the real tool); until then
/// this wrapper is required whenever [McpToolRouter] is used.
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
    var decision = policy.evaluate(target, sessionId, tainted: assumeTainted);
    if (decision is AutoApprove && r.correctedName && !target.annotations.isReadOnly) {
      decision = NeedsConfirmation(
        ApprovalPolicy.riskOf(target),
        'The tool name "${call.arguments['name']}" was corrected to "${target.name}"; confirm this is the right tool.',
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
        policy.recordFor(target, sessionId, response);
        return ApprovalResponse(response.decision);
    }
  }
}
