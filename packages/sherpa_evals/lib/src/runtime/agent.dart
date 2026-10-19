/// Agent-loop plumbing shared by the suites: scripted users (approval
/// handlers that record every prompt), scripted model policies on top of
/// `ScriptedProvider`, and run helpers.
library;

import 'dart:async';
import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';

/// One approval sheet the harness showed.
final class ApprovalPrompt {
  ApprovalPrompt({
    required this.sessionId,
    required this.call,
    required this.tool,
    required this.requirement,
    required this.approved,
  });

  final String sessionId;
  final ToolCall call;
  final ToolDefinition? tool;
  final NeedsConfirmation requirement;
  final bool approved;
}

/// The human, scripted: answers approval prompts with [decide] (approve
/// everything by default) and records each one.
final class ScriptedUser implements ApprovalHandler {
  ScriptedUser({bool Function(ToolCall call, ToolDefinition? tool, NeedsConfirmation req)? decide, this.scope = ApprovalScope.once})
      : _decide = decide ?? ((_, _, _) => true);

  final bool Function(ToolCall call, ToolDefinition? tool, NeedsConfirmation req) _decide;
  final ApprovalScope scope;
  final List<ApprovalPrompt> prompts = [];

  @override
  Future<ApprovalResponse> requestApproval({
    required String sessionId,
    required ToolCall call,
    required ToolDefinition? tool,
    required NeedsConfirmation requirement,
    required CancellationToken cancel,
  }) async {
    final ok = _decide(call, tool, requirement);
    prompts.add(ApprovalPrompt(sessionId: sessionId, call: call, tool: tool, requirement: requirement, approved: ok));
    return ApprovalResponse(ok ? UserDecision.approve : UserDecision.deny, scope: scope);
  }
}

/// Events of one model turn that calls [calls] (streamed like
/// `ScriptedTurn.toolCalls`: start, argument fragments, complete).
List<ModelEvent> toolCallEvents(List<ToolCall> calls, {String? preamble, FinishReason finish = FinishReason.toolCalls}) => [
      if (preamble != null) TextDelta(preamble),
      for (final (i, c) in calls.indexed) ...[
        ToolCallStart(index: i, id: c.id, name: c.name),
        for (final f in splitForStreaming(jsonEncode(c.arguments), size: 7)) ToolCallArgsDelta(index: i, fragment: f),
        ToolCallComplete(index: i, call: c),
      ],
      const UsageUpdate(Usage(inputTokens: 20, outputTokens: 15)),
      Finish(finish),
    ];

/// Events of a plain text reply.
List<ModelEvent> textEvents(String text) => [
      for (final chunk in splitForStreaming(text)) TextDelta(chunk),
      const UsageUpdate(Usage(inputTokens: 10, outputTokens: 10)),
      const Finish(FinishReason.stop),
    ];

/// A decision function from the request the agent sent to the next turn.
typedef ModelPolicy = List<ModelEvent> Function(ModelRequest request);

/// A `ScriptedProvider` whose every turn is decided by [policy] from the
/// actual request, so a recorded trajectory follows the real tool results
/// (handles, ids) and survives a resume after process death.
ScriptedProvider policyProvider(
  ModelPolicy policy, {
  int maxTurns = 64,
  ModelCapabilities capabilities = const ModelCapabilities(contextLength: 32768),
  ProviderInfo? info,
}) =>
    ScriptedProvider(
      [for (var i = 0; i < maxTurns; i++) ScriptedTurn.dynamic(policy)],
      capabilitiesValue: capabilities,
      info: info,
    );

/// Capabilities that give the scripted model the same tool budget as the
/// real one it stands in for (on-device, ≤ 2B → at most 5 tools).
const ModelCapabilities smallLocalCapabilities = ModelCapabilities(contextLength: 32768, parameterCount: 600000000);

/// Tool results in [request], newest first, by the call's (model-facing)
/// tool name.
Iterable<ToolResultPart> resultsIn(ModelRequest request) sync* {
  for (final m in request.messages.reversed) {
    yield* m.toolResults.reversed;
  }
}

/// Tool calls the assistant made in [request], oldest first.
List<ToolCall> callsIn(ModelRequest request) => [for (final m in request.messages) ...m.toolCalls];

/// The text of the latest user message in [request].
String lastUserText(ModelRequest request) {
  for (final m in request.messages.reversed) {
    if (m.role == Role.user && m.toolResults.isEmpty) return m.text;
  }
  return '';
}

/// A fresh session record.
Future<void> newSession(SessionStore store, String id, Clock clock, {String? systemPrompt}) => store.putSession(
      SessionRecord(
        id: id,
        title: defaultSessionTitle,
        createdAt: clock.now(),
        updatedAt: clock.now(),
        systemPrompt: systemPrompt,
      ),
    );

/// Collects a run's events, failing fast on a hang.
Future<List<AgentEvent>> drive(Stream<AgentEvent> run, {Duration timeout = const Duration(minutes: 10)}) =>
    run.toList().timeout(timeout);

RunFinished? finishedOf(List<AgentEvent> events) => events.whereType<RunFinished>().lastOrNull;

/// Calls the harness actually started (after gating).
List<ToolCall> startedCalls(List<AgentEvent> events) => [for (final e in events.whereType<ToolCallStarted>()) e.call];

/// The active branch of a session.
Future<List<Message>> activePath(SessionStore store, String sessionId) async {
  final leaf = (await store.getSession(sessionId))?.activeLeafId;
  return leaf == null ? const [] : store.path(sessionId, leaf);
}

/// Pairing problems on [path]: calls without results, results without
/// calls (the agent loop's first invariant).
List<String> pairingViolations(List<Message> path) {
  final out = <String>[];
  for (final (i, m) in path.indexed) {
    if (!m.hasToolCalls) continue;
    final next = i + 1 < path.length ? path[i + 1] : null;
    final answered = {for (final r in next?.toolResults ?? const <ToolResultPart>[]) r.callId};
    for (final c in m.toolCalls) {
      if (!answered.contains(c.id)) out.add('call ${c.id} (${c.name}) in ${m.id} has no result');
    }
  }
  return out;
}

/// Runs [body] catching errors that escape to the zone (unawaited futures
/// inside the code under test); returns them alongside the result.
Future<(T?, List<Object>)> guarded<T>(Future<T> Function() body) async {
  final errors = <Object>[];
  final done = Completer<T?>();
  // ignore: unawaited_futures
  runZonedGuarded(() async {
    try {
      final v = await body();
      if (!done.isCompleted) done.complete(v);
    } on Object catch (e) {
      errors.add(e);
      if (!done.isCompleted) done.complete(null);
    }
  }, (e, _) => errors.add(e));
  final v = await done.future;
  // Let stray microtasks of the body land in the zone handler.
  await Future<void>.delayed(Duration.zero);
  return (v, errors);
}
