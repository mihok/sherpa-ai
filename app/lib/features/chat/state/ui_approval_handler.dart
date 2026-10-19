import 'dart:async';

import 'package:sherpa_core/sherpa_core.dart';

import 'chat_view_state.dart';

/// [ApprovalHandler] that hands requests to the chat UI and waits for the
/// user's answer.
///
/// Guarantees the core contract: a request completes with `deny` as soon as
/// the run is cancelled (Stop, leaving the app for good, dispose), so a run
/// can never hang on an unanswered card. Requests are queued in arrival
/// order; the runner asks one at a time today, but parallel MCP calls may
/// not.
final class UiApprovalHandler implements ApprovalHandler {
  UiApprovalHandler({required this.onChanged, required Clock clock}) : _clock = clock;

  /// Called with the request the UI should show now (null: none).
  final void Function(PendingApproval? current) onChanged;
  final Clock _clock;
  final List<_Request> _queue = [];

  PendingApproval? get current => _queue.isEmpty ? null : _queue.first.view;

  @override
  Future<ApprovalResponse> requestApproval({
    required String sessionId,
    required ToolCall call,
    required ToolDefinition? tool,
    required NeedsConfirmation requirement,
    required CancellationToken cancel,
  }) {
    if (cancel.isCancelled) return Future.value(const ApprovalResponse(UserDecision.deny));
    final request = _Request(
      PendingApproval.of(call: call, tool: tool, requirement: requirement, requestedAt: _clock.now()),
    );
    _queue.add(request);
    unawaited(cancel.whenCancelled.then((_) => _resolve(request, const ApprovalResponse(UserDecision.deny))));
    if (_queue.length == 1) onChanged(request.view);
    return request.completer.future;
  }

  /// Answers the request for [callId]. Returns false when it is no longer
  /// pending (already answered, or the run was stopped meanwhile).
  bool respond(String callId, ApprovalResponse response) {
    for (final r in _queue) {
      if (r.view.call.id == callId) {
        _resolve(r, response);
        return true;
      }
    }
    return false;
  }

  /// Denies everything still waiting (controller disposal).
  void denyAll() => denyWhere((_) => true);

  /// Denies the waiting requests that match [test] (a run ending denies its
  /// own calls but not ones an MCP App view asked for meanwhile).
  void denyWhere(bool Function(PendingApproval request) test) {
    for (final r in List.of(_queue)) {
      if (test(r.view)) _resolve(r, const ApprovalResponse(UserDecision.deny));
    }
  }

  void _resolve(_Request r, ApprovalResponse response) {
    if (r.completer.isCompleted) return;
    final wasCurrent = _queue.isNotEmpty && identical(_queue.first, r);
    _queue.remove(r);
    r.completer.complete(response);
    if (wasCurrent) onChanged(current);
  }
}

final class _Request {
  _Request(this.view);
  final PendingApproval view;
  final Completer<ApprovalResponse> completer = Completer();
}
