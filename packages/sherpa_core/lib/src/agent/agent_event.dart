import 'package:meta/meta.dart';

import '../context/budget.dart';
import '../context/overlay.dart';
import '../model/message.dart';
import '../model/tool.dart';
import '../provider/model_event.dart';
import '../session/checkpoint.dart';
import '../session/plan.dart';
import '../tools/approval.dart';
import '../tools/tool_router.dart';

enum RunOutcome { completed, cancelled, maxSteps, needsUserAction, failed }

/// Everything the UI needs to render a run live. Emitted by `AgentRunner`.
@immutable
sealed class AgentEvent {
  const AgentEvent();
}

final class RunStarted extends AgentEvent {
  const RunStarted({required this.runId, required this.sessionId, this.resumed = false});
  final String runId;
  final String sessionId;
  final bool resumed;
}

final class StepStarted extends AgentEvent {
  const StepStarted(this.step);
  final int step;
}

/// Context was assembled for the next model call.
final class ContextPrepared extends AgentEvent {
  const ContextPrepared({required this.budget, required this.level, this.newOverlays = const []});
  final ContextBudget budget;
  final ContextLevel level;
  final List<ContextOverlay> newOverlays;
}

/// A raw provider event for the assistant message being streamed.
final class ModelStreamed extends AgentEvent {
  const ModelStreamed({required this.messageId, required this.event});
  final String messageId;
  final ModelEvent event;
}

/// The streamed assistant message reached its final form and was persisted.
final class AssistantMessageCompleted extends AgentEvent {
  const AssistantMessageCompleted(this.message);
  final Message message;
}

final class ToolApprovalRequested extends AgentEvent {
  const ToolApprovalRequested({required this.call, required this.tool, required this.requirement});
  final ToolCall call;
  final ToolDefinition? tool;
  final NeedsConfirmation requirement;
}

final class ToolApprovalResolved extends AgentEvent {
  const ToolApprovalResolved({required this.callId, required this.approved, required this.reason});
  final String callId;
  final bool approved;
  final String reason;
}

final class ToolCallStarted extends AgentEvent {
  const ToolCallStarted(this.call);
  final ToolCall call;
}

final class ToolCallProgressed extends AgentEvent {
  const ToolCallProgressed({required this.callId, required this.progress});
  final String callId;
  final ToolProgress progress;
}

final class ToolCallFinished extends AgentEvent {
  const ToolCallFinished({required this.call, required this.result, required this.message});
  final ToolCall call;
  final ToolResult result;

  /// The persisted `Role.tool` message carrying the result.
  final Message message;
}

final class PlanUpdated extends AgentEvent {
  const PlanUpdated(this.plan);
  final Plan plan;
}

final class Checkpointed extends AgentEvent {
  const Checkpointed(this.checkpoint);
  final RunCheckpoint checkpoint;
}

/// Something the user should know that is not an error (retrying,
/// engine restarted, thermal throttling slowed the run…).
final class RunNotice extends AgentEvent {
  const RunNotice(this.code, this.message);
  final String code;
  final String message;
}

/// Always the last event of a run.
final class RunFinished extends AgentEvent {
  const RunFinished({required this.outcome, required this.usage, this.error, this.detail});
  final RunOutcome outcome;
  final Usage usage;
  final Object? error;
  final String? detail;
}
