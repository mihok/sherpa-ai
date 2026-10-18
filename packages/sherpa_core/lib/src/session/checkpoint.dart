import 'package:meta/meta.dart';

import '../common/json.dart';

/// Where a run was when it was last persisted. The loop writes a checkpoint
/// after every transition so a run survives process death.
enum RunPhase {
  preparingContext,
  streamingModel,
  awaitingApproval,
  executingTools,
  finished,
  failed,
  cancelled,
}

enum PendingCallStatus { pending, approved, denied, running, done }

@immutable
final class PendingCall {
  const PendingCall({required this.callId, required this.toolName, required this.status});

  factory PendingCall.fromJson(JsonMap j) => PendingCall(
        callId: j.req<String>('callId'),
        toolName: j.req<String>('toolName'),
        status: PendingCallStatus.values.byName(j.req<String>('status')),
      );

  final String callId;
  final String toolName;
  final PendingCallStatus status;

  PendingCall withStatus(PendingCallStatus s) =>
      PendingCall(callId: callId, toolName: toolName, status: s);

  JsonMap toJson() => {'callId': callId, 'toolName': toolName, 'status': status.name};
}

@immutable
final class RunCheckpoint {
  const RunCheckpoint({
    required this.sessionId,
    required this.runId,
    required this.phase,
    required this.step,
    required this.updatedAt,
    this.leafMessageId,
    this.draftMessageId,
    this.pendingCalls = const [],
    this.providerId,
    this.modelId,
    this.error,
  });

  factory RunCheckpoint.fromJson(JsonMap j) => RunCheckpoint(
        sessionId: j.req<String>('sessionId'),
        runId: j.req<String>('runId'),
        phase: RunPhase.values.byName(j.req<String>('phase')),
        step: j.optInt('step') ?? 0,
        updatedAt: DateTime.parse(j.req<String>('updatedAt')),
        leafMessageId: j.opt<String>('leafMessageId'),
        draftMessageId: j.opt<String>('draftMessageId'),
        pendingCalls: j.mapList('pendingCalls').map(PendingCall.fromJson).toList(),
        providerId: j.opt<String>('providerId'),
        modelId: j.opt<String>('modelId'),
        error: j.opt<String>('error'),
      );

  final String sessionId;
  final String runId;
  final RunPhase phase;
  final int step;
  final DateTime updatedAt;

  /// Last finalized message on the active path.
  final String? leafMessageId;

  /// Assistant message being streamed (partial) when the checkpoint was taken.
  final String? draftMessageId;
  final List<PendingCall> pendingCalls;
  final String? providerId;
  final String? modelId;
  final String? error;

  bool get isTerminal =>
      phase == RunPhase.finished || phase == RunPhase.failed || phase == RunPhase.cancelled;

  RunCheckpoint copyWith({
    RunPhase? phase,
    int? step,
    DateTime? updatedAt,
    String? leafMessageId,
    String? draftMessageId,
    bool clearDraft = false,
    List<PendingCall>? pendingCalls,
    String? error,
  }) =>
      RunCheckpoint(
        sessionId: sessionId,
        runId: runId,
        phase: phase ?? this.phase,
        step: step ?? this.step,
        updatedAt: updatedAt ?? this.updatedAt,
        leafMessageId: leafMessageId ?? this.leafMessageId,
        draftMessageId: clearDraft ? null : (draftMessageId ?? this.draftMessageId),
        pendingCalls: pendingCalls ?? this.pendingCalls,
        providerId: providerId,
        modelId: modelId,
        error: error ?? this.error,
      );

  JsonMap toJson() => compact({
        'sessionId': sessionId,
        'runId': runId,
        'phase': phase.name,
        'step': step,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'leafMessageId': leafMessageId,
        'draftMessageId': draftMessageId,
        'pendingCalls': [for (final p in pendingCalls) p.toJson()],
        'providerId': providerId,
        'modelId': modelId,
        'error': error,
      });
}
