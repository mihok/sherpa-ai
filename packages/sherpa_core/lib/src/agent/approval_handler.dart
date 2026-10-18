import '../common/cancellation.dart';
import '../model/tool.dart';
import '../tools/approval.dart';

/// Asks the human. The UI implements this with the approval sheet; evals
/// use scripted handlers. Implementations must complete with `deny` if
/// [cancel] fires so a stopped run never hangs on a dialog.
abstract interface class ApprovalHandler {
  Future<ApprovalResponse> requestApproval({
    required String sessionId,
    required ToolCall call,
    required ToolDefinition? tool,
    required NeedsConfirmation requirement,
    required CancellationToken cancel,
  });
}

/// Approves or denies everything; for tests and headless evals.
final class StaticApprovalHandler implements ApprovalHandler {
  const StaticApprovalHandler(this.decision);

  const StaticApprovalHandler.approveAll() : decision = UserDecision.approve;
  const StaticApprovalHandler.denyAll() : decision = UserDecision.deny;

  final UserDecision decision;

  @override
  Future<ApprovalResponse> requestApproval({
    required String sessionId,
    required ToolCall call,
    required ToolDefinition? tool,
    required NeedsConfirmation requirement,
    required CancellationToken cancel,
  }) async =>
      ApprovalResponse(decision);
}
