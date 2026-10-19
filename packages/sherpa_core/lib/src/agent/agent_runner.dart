import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../common/cancellation.dart';
import '../common/clock.dart';
import '../common/ids.dart';
import '../common/json.dart';
import '../context/context_manager.dart';
import '../context/passthrough_context_manager.dart';
import '../context/token_estimator.dart';
import '../memory/memory_monitor.dart';
import '../model/content.dart';
import '../model/message.dart';
import '../model/tool.dart';
import '../provider/capabilities.dart';
import '../provider/model_event.dart';
import '../provider/model_provider.dart';
import '../session/checkpoint.dart';
import '../session/session_store.dart';
import '../tools/approval.dart';
import '../tools/tool_router.dart';
import 'agent_event.dart';
import 'approval_handler.dart';
import 'prompt_boundary.dart';

typedef Sleeper = Future<void> Function(Duration duration);

@immutable
final class AgentConfig {
  const AgentConfig({
    this.maxSteps = 24,
    this.maxParallelTools = 4,
    this.toolTimeout = const Duration(seconds: 90),
    this.providerRetries = 2,
    this.retryBaseDelay = const Duration(milliseconds: 800),
    this.draftPersistEvery = 48,
    this.params = const GenerationParams(),
    this.contextSettings = const ContextSettings(),
    this.defaultSystemPrompt,
  });

  /// Model calls per run before the loop stops and asks the user.
  final int maxSteps;
  final int maxParallelTools;
  final Duration toolTimeout;

  /// Retries for retryable provider errors that happen before any output.
  final int providerRetries;
  final Duration retryBaseDelay;

  /// Persist the streaming draft every N events so a crash loses little.
  final int draftPersistEvery;
  final GenerationParams params;
  final ContextSettings contextSettings;
  final String? defaultSystemPrompt;
}

const String defaultSessionTitle = 'New chat';

/// The ReAct loop: prepare context → stream the model → gate and run tool
/// calls (in parallel) → repeat, persisting a checkpoint after every
/// transition so a run survives process death and resumes exactly.
///
/// Invariants the loop maintains for every provider:
/// * every tool call in an assistant message gets a result in the following
///   `Role.tool` message before the next model call (even if cancelled,
///   denied or interrupted);
/// * the transcript is append-only; retries and edits create branches;
/// * tool output is data — the boundary clause is always in the system
///   prompt and results stay in tool-result blocks.
final class AgentRunner {
  AgentRunner({
    required SessionStore store,
    required ModelProvider provider,
    required String modelId,
    required ToolRouter tools,
    required ApprovalPolicy approvals,
    required ApprovalHandler approvalHandler,
    ContextManager contextManager = const PassthroughContextManager(),
    TokenCounter? counter,
    MemoryMonitor? memory,
    Clock clock = const SystemClock(),
    IdGenerator? ids,
    AgentConfig config = const AgentConfig(),
    Sleeper? sleep,
  })  : _store = store,
        _provider = provider,
        _modelId = modelId,
        _tools = tools,
        _approvals = approvals,
        _approvalHandler = approvalHandler,
        _context = contextManager,
        _counter = counter ?? HeuristicTokenCounter(),
        _memory = memory,
        _clock = clock,
        _ids = ids ?? RandomIdGenerator(),
        _config = config,
        _sleep = sleep ?? Future<void>.delayed;

  final SessionStore _store;
  final ModelProvider _provider;
  final String _modelId;
  final ToolRouter _tools;
  final ApprovalPolicy _approvals;
  final ApprovalHandler _approvalHandler;
  final ContextManager _context;
  final TokenCounter _counter;
  final MemoryMonitor? _memory;
  final Clock _clock;
  final IdGenerator _ids;
  final AgentConfig _config;
  final Sleeper _sleep;

  _Run? _active;

  bool get isRunning => _active != null;
  String get modelId => _modelId;
  ModelProvider get provider => _provider;

  /// Stops the active run: aborts streaming, cancels tools, denies pending
  /// approvals. Safe to call at any time.
  void cancel([String reason = 'stopped by user']) => _active?.token.cancel(reason);

  /// Appends a user message (child of [parentId], or of the active leaf) and
  /// runs.
  Stream<AgentEvent> send(
    String sessionId,
    List<ContentPart> content, {
    String? parentId,
    JsonMap metadata = const {},
  }) =>
      _start(sessionId, (run) async {
        final session = await _requireSession(sessionId);
        final user = Message(
          id: _ids.next('msg'),
          parentId: parentId ?? session.activeLeafId,
          role: Role.user,
          content: content,
          createdAt: _clock.now(),
          metadata: metadata,
        );
        await _store.putMessage(sessionId, user);
        await _setLeaf(sessionId, user.id, titleHint: user.text);
        await _loop(run, leafId: user.id, startStep: 1);
      });

  /// Edit-and-resubmit: a new user message as a sibling of [messageId]
  /// (same parent), so the original exchange stays as another branch.
  Stream<AgentEvent> edit(String sessionId, String messageId, List<ContentPart> content) =>
      _start(sessionId, (run) async {
        final original = await _store.getMessage(sessionId, messageId);
        if (original == null) throw StateError('unknown message $messageId');
        final user = Message(
          id: _ids.next('msg'),
          parentId: original.parentId,
          role: Role.user,
          content: content,
          createdAt: _clock.now(),
          metadata: {'editOf': messageId},
        );
        await _store.putMessage(sessionId, user);
        await _setLeaf(sessionId, user.id);
        await _loop(run, leafId: user.id, startStep: 1);
      });

  /// Generates a new reply after [fromMessageId] (a user or tool message),
  /// leaving the previous reply as a sibling branch.
  Stream<AgentEvent> regenerate(String sessionId, {required String fromMessageId}) =>
      _start(sessionId, (run) async {
        await _setLeaf(sessionId, fromMessageId);
        await _loop(run, leafId: fromMessageId, startStep: 1);
      });

  /// Continues an interrupted run from its last checkpoint.
  Stream<AgentEvent> resume(String sessionId) => _start(sessionId, resumed: true, (run) async {
        final cp = await _store.getCheckpoint(sessionId);
        if (cp == null || cp.isTerminal || cp.leafMessageId == null) {
          run.finish(RunOutcome.completed, detail: 'nothing to resume');
          return;
        }
        switch (cp.phase) {
          case RunPhase.preparingContext:
            await _loop(run, leafId: cp.leafMessageId!, startStep: cp.step);
          case RunPhase.streamingModel:
            // Re-stream into the same draft id: the partial reply is replaced.
            await _loop(run, leafId: cp.leafMessageId!, startStep: cp.step, draftId: cp.draftMessageId);
          case RunPhase.awaitingApproval || RunPhase.executingTools:
            final assistant = await _store.getMessage(sessionId, cp.leafMessageId!);
            if (assistant == null) throw StateError('checkpoint references a missing message');
            run.step = cp.step;
            run.leafId = assistant.id;
            final toolLeaf = await _toolStep(run, cp.step, assistant, resume: cp);
            if (run.token.isCancelled) return _onCancelled(run);
            await _loop(run, leafId: toolLeaf, startStep: cp.step + 1);
          case RunPhase.finished || RunPhase.failed || RunPhase.cancelled:
            run.finish(RunOutcome.completed, detail: 'nothing to resume');
        }
      });

  Stream<AgentEvent> _start(
    String sessionId,
    Future<void> Function(_Run run) body, {
    bool resumed = false,
  }) {
    if (_active != null) throw StateError('a run is already active on this runner');
    final run = _Run(sessionId: sessionId, runId: _ids.next('run'));
    _active = run;
    run.controller = StreamController<AgentEvent>(
      onListen: () async {
        run.emit(RunStarted(runId: run.runId, sessionId: sessionId, resumed: resumed));
        var threw = false;
        try {
          await body(run);
        } on Object catch (e) {
          threw = true;
          await _settleFailure(run, e);
        } finally {
          // Only a body that returned normally may count as completed.
          if (!run.finished) run.finish(threw ? RunOutcome.failed : RunOutcome.completed);
          _active = null;
          await run.controller.close();
        }
      },
      onCancel: () => run.token.cancel('listener cancelled'),
    );
    return run.controller.stream;
  }

  Future<void> _onCancelled(_Run run) async {
    await _checkpoint(run, RunPhase.cancelled);
    run.finish(RunOutcome.cancelled, detail: run.token.reason);
  }

  /// Ends a run whose body threw [error]. The outcome comes from [error];
  /// the audit entry and terminal checkpoint are best effort, because they
  /// usually hit the same store that just failed (disk full, a session
  /// deleted mid-run). If they fail too, the run still ends: as failed with
  /// the original error, or, when it was cancelled or overflowed, as failed
  /// with the write error, since nothing of it could be saved. Nothing
  /// escapes as an uncaught error and nothing reports success.
  Future<void> _settleFailure(_Run run, Object error) async {
    final cancelled = error is CancelledException || run.token.isCancelled;
    Object? writeError;
    try {
      if (cancelled) {
        await _checkpoint(run, RunPhase.cancelled);
      } else if (error is ContextOverflowException) {
        await _checkpoint(run, RunPhase.failed, error: error.message);
      } else {
        await _audit(run, AuditKind.error, 'run failed: $error');
        await _checkpoint(run, RunPhase.failed, error: error.toString());
      }
    } on Object catch (e) {
      writeError = e;
    }
    if (cancelled) {
      if (writeError == null) return run.finish(RunOutcome.cancelled, detail: run.token.reason);
      return run.finish(RunOutcome.failed, error: writeError, detail: 'could not save the stopped run: $writeError');
    }
    if (error is ContextOverflowException) {
      if (writeError == null) return run.finish(RunOutcome.needsUserAction, error: error, detail: error.message);
      return run.finish(RunOutcome.failed, error: writeError, detail: 'could not save the run: $writeError');
    }
    run.finish(RunOutcome.failed, error: error, detail: error.toString());
  }

  Future<void> _loop(_Run run, {required String leafId, required int startStep, String? draftId}) async {
    var leaf = leafId;
    var resumeDraft = draftId;
    for (var step = startStep; step <= _config.maxSteps; step++) {
      run.token.throwIfCancelled();
      run.step = step;
      run.leafId = leaf;
      run.emit(StepStarted(step));
      await _checkpoint(run, RunPhase.preparingContext);

      final assistant = await _modelStep(run, leaf, draftId: resumeDraft);
      resumeDraft = null;
      leaf = assistant.id;
      run.leafId = leaf;
      if (run.token.isCancelled) {
        if (assistant.hasToolCalls) await _closeDanglingCalls(run, assistant);
        return _onCancelled(run);
      }

      final calls = assistant.toolCalls;
      if (calls.isEmpty) {
        if (assistant.finishReason == FinishReason.pause.name) continue;
        await _checkpoint(run, RunPhase.finished);
        return run.finish(
          RunOutcome.completed,
          detail: assistant.finishReason == FinishReason.length.name ? 'reply truncated at max output tokens' : null,
        );
      }
      leaf = await _toolStep(run, step, assistant);
      run.leafId = leaf;
      if (run.token.isCancelled) return _onCancelled(run);
    }
    await _checkpoint(run, RunPhase.finished);
    run.finish(RunOutcome.maxSteps, detail: 'stopped after ${_config.maxSteps} steps');
  }

  // ---------------------------------------------------------------------------
  // Model step

  Future<Message> _modelStep(_Run run, String leafId, {String? draftId}) async {
    final sid = run.sessionId;
    final session = await _requireSession(sid);
    final path = await _store.path(sid, leafId);
    final overlays = await _store.overlays(sid);
    final plan = await _store.getPlan(sid);
    final query = path.lastWhereOrNull((m) => m.role == Role.user)?.text;
    final caps = await _provider.capabilities(_modelId);
    final hints = ToolSelectionHints(
      onDevice: _provider.info.location == ExecutionLocation.onDevice,
      parameterBillions: caps.parameterCount == null ? null : caps.parameterCount! / 1e9,
    );
    final offered = caps.canCallTools
        ? (await _tools.toolsForTurn(sessionId: sid, query: query, hints: hints)).where((t) => t.modelVisible).toList()
        : const <ToolDefinition>[];

    final prepared = await _context.prepare(ContextRequest(
      sessionId: sid,
      path: path,
      overlays: overlays,
      tools: offered,
      capabilities: caps,
      counter: _counter,
      systemPrompt: PromptBoundary.compose(session.systemPrompt ?? _config.defaultSystemPrompt),
      plan: plan,
      memory: _memory?.current ?? MemoryState.unknown,
      settings: _config.contextSettings,
      cancel: run.token,
      location: _provider.info.location,
      boundaryNonce: session.settings.opt<String>('boundaryNonce'),
    ));
    for (final o in prepared.newOverlays) {
      await _store.putOverlay(sid, o);
      await _audit(run, AuditKind.contextAction, o.reason, {'overlay': o.type, 'tokensSaved': o.tokensSaved});
    }
    run.emit(ContextPrepared(budget: prepared.budget, level: prepared.level, newOverlays: prepared.newOverlays));
    final rec = prepared.recommendation;
    if (rec != null) {
      if (rec.kind == ContextRecommendationKind.hardStop) {
        throw ContextOverflowException(prepared.budget, rec.message);
      }
      if (!run.handoffNoticed) {
        run.handoffNoticed = true;
        run.emit(RunNotice('handoff_recommended', rec.message));
      }
    }

    final id = draftId ?? _ids.next('msg');
    await _checkpoint(run, RunPhase.streamingModel, draftId: id);
    if (_provider.info.dataLeavesDevice) {
      await _audit(run, AuditKind.dataEgress, 'sent context to ${_provider.info.displayName}', {
        'provider': _provider.info.id,
        'model': _modelId,
        'inputTokens': prepared.budget.inputTokens,
        if (_provider.info.baseUrl != null) 'host': _provider.info.baseUrl!.host,
      });
    }

    final request = ModelRequest(
      modelId: _modelId,
      systemPrompt: prepared.systemPrompt,
      messages: prepared.messages,
      tools: prepared.tools,
      params: _config.params,
      cache: CacheHints(sessionId: sid),
    );

    for (var attempt = 0;; attempt++) {
      final acc = _Accumulator(
        id: id,
        parentId: leafId,
        createdAt: _clock.now(),
        providerId: _provider.info.id,
        modelId: _modelId,
      );
      try {
        final streamed = await _streamOnce(run, request, acc);
        final message = prepared.prefixKey == null
            ? streamed
            : streamed.copyWith(metadata: {...streamed.metadata, 'prefixKey': prepared.prefixKey});
        // Through the write queue, so no draft snapshot can land after it.
        await run.serial(() => _store.putMessage(sid, message));
        await _setLeaf(sid, message.id);
        _calibrate(prepared.budget.inputTokens, message.usage);
        run.usage += message.usage ?? Usage.zero;
        run.emit(AssistantMessageCompleted(message));
        return message;
      } on ProviderException catch (e) {
        final canRetry = e.isRetryable && attempt < _config.providerRetries && !acc.hasOutput;
        if (!canRetry) {
          if (acc.hasOutput) {
            // Keep what the user already saw, marked as failed. Unanswered
            // tool calls are dropped so the branch stays valid to continue.
            final partial = acc.build(finishReason: FinishReason.error.name);
            // Through the write queue: a draft snapshot still waiting there
            // must not overwrite this final version (it would bring back
            // the unanswered tool calls and drop the error marker).
            await run.serial(() => _store.putMessage(
                  sid,
                  partial.copyWith(
                    content: partial.content.where((p) => p is! ToolCallPart).toList(),
                    metadata: {'error': e.message},
                  ),
                ));
            await _setLeaf(sid, partial.id);
          }
          rethrow;
        }
        final delay = e.retryAfter ?? _config.retryBaseDelay * (1 << attempt);
        run.emit(RunNotice('retrying', '${e.kind.name}: retrying in ${delay.inMilliseconds} ms'));
        await Future.any([_sleep(delay), run.token.whenCancelled]);
        run.token.throwIfCancelled();
      }
    }
  }

  Future<Message> _streamOnce(_Run run, ModelRequest request, _Accumulator acc) {
    final done = Completer<Message>();
    final providerToken = run.token.child();
    late final StreamSubscription<ModelEvent> sub;
    var sinceFlush = 0;

    Future<void> finalize(String reason) async {
      if (done.isCompleted) return;
      done.complete(acc.build(finishReason: reason));
    }

    sub = _provider.stream(request, cancel: providerToken).listen(
      (event) {
        acc.add(event);
        run.emit(ModelStreamed(messageId: acc.id, event: event));
        if (++sinceFlush >= _config.draftPersistEvery) {
          sinceFlush = 0;
          unawaited(run.serial(() async {
            // A snapshot whose turn comes after the stream ended is stale:
            // the final message (or the failed partial) is written next.
            if (done.isCompleted) return;
            await _store.putMessage(run.sessionId, acc.build(draft: true));
          }));
        }
      },
      onError: (Object e, StackTrace st) {
        if (done.isCompleted) return;
        if (run.token.isCancelled) {
          unawaited(finalize(FinishReason.cancelled.name));
        } else {
          done.completeError(e, st);
        }
      },
      onDone: () => finalize((acc.finish ?? FinishReason.stop).name),
      cancelOnError: true,
    );
    run.token.whenCancelled.then((_) async {
      if (done.isCompleted) return;
      providerToken.cancel(run.token.reason ?? 'cancelled');
      await sub.cancel();
      await finalize(FinishReason.cancelled.name);
    });
    // Drain the write queue on every outcome, errors included, so whatever
    // the caller writes next is ordered after the last draft snapshot.
    return done.future.whenComplete(() => run.serial(() async {})).whenComplete(providerToken.detach);
  }

  void _calibrate(int estimatedInput, Usage? usage) {
    final c = _counter;
    if (c is HeuristicTokenCounter && usage != null && usage.inputTokens > 0) {
      c.calibrate(estimated: estimatedInput, actual: usage.inputTokens + usage.cacheReadTokens);
    }
  }

  // ---------------------------------------------------------------------------
  // Tool step

  /// Gates and runs the assistant's tool calls; returns the tool message id.
  ///
  /// Every decision that answers a call (denied, invalid, unknown, refused,
  /// cut off, interrupted) is written to the tool message BEFORE the
  /// checkpoint that records it, so a resume after process death never asks
  /// again about a call the user already answered.
  Future<String> _toolStep(_Run run, int step, Message assistant, {RunCheckpoint? resume}) async {
    final sid = run.sessionId;
    final calls = assistant.toolCalls;
    final toolMsgId = resume?.draftMessageId ?? _ids.next('msg');
    final existing = resume == null ? null : await _store.getMessage(sid, toolMsgId);
    final results = <String, ToolResultPart>{
      for (final r in existing?.toolResults ?? const <ToolResultPart>[]) r.callId: r,
    };
    final resumeStatus = {for (final p in resume?.pendingCalls ?? const <PendingCall>[]) p.callId: p.status};
    final status = <String, PendingCallStatus>{
      for (final c in calls)
        c.id: results.containsKey(c.id) ? PendingCallStatus.done : (resumeStatus[c.id] ?? PendingCallStatus.pending),
    };
    final createdAt = existing?.createdAt ?? _clock.now();
    // A reply cut off by the output limit can end inside a tool call whose
    // JSON only parses after repair; such calls never run (R10 §7.5).
    final truncated = assistant.finishReason == FinishReason.length.name;
    final targets = <String, ResolvedToolCall>{};
    run.leafId = assistant.id;

    Future<void> persistResults() => run.serial(() async {
          final parts = [for (final c in calls) if (results[c.id] != null) results[c.id]!];
          await _store.putMessage(
            sid,
            Message(id: toolMsgId, parentId: assistant.id, role: Role.tool, content: parts, createdAt: createdAt),
          );
        });

    Future<void> saveStatus(RunPhase phase) => _checkpoint(run, phase,
        draftId: toolMsgId,
        pending: [for (final c in calls) PendingCall(callId: c.id, toolName: c.name, status: status[c.id]!)]);

    ToolResultPart errorResult(ToolCall c, String text) =>
        ToolResultPart(callId: c.id, toolName: c.name, content: [TextPart(text)], isError: true);

    // The result is durable before the status that refers to it.
    Future<void> answer(ToolCall c, String text, [PendingCallStatus s = PendingCallStatus.done]) async {
      results[c.id] = errorResult(c, text);
      status[c.id] = s;
      await persistResults();
      await saveStatus(RunPhase.awaitingApproval);
    }

    try {
      await saveStatus(RunPhase.awaitingApproval);
      final tainted = await _isTainted(sid, assistant.id);
      if (tainted && !run.taintNoticed) {
        run.taintNoticed = true;
        run.emit(const RunNotice('untrusted_content',
            'Untrusted tool output is in this conversation; actions now need your approval.'));
      }
      if (truncated && calls.any((c) => !results.containsKey(c.id))) {
        run.emit(const RunNotice('tool_call_truncated',
            'The reply reached the output limit inside a tool call, so the call was not run.'));
      }
      final toRun = <ToolCall>[];
      for (final c in calls) {
        if (results.containsKey(c.id)) continue;
        if (truncated) {
          await answer(c, 'This call to "${c.name}" was cut off by the output token limit before its arguments '
              'were complete, so it was not run. Call the tool again with shorter arguments (for example, '
              'split large content across several calls).');
          continue;
        }
        if (!c.isValid) {
          await answer(c, 'Invalid arguments for "${c.name}": ${c.argumentsError}. Fix the JSON and call the tool again.');
          continue;
        }
        final r = _tools.resolve(c, sessionId: sid);
        final tool = r?.tool;
        if (r != null && r.refusal != null) {
          await answer(c, r.refusal!);
          continue;
        }
        if (r == null || tool == null) {
          await answer(c, 'Unknown tool "${c.name}". Use only the tools provided.');
          continue;
        }
        if (!tool.modelVisible) {
          await answer(c, '"${tool.name}" is not available to the model (it can only be used from its app view).');
          continue;
        }
        targets[c.id] = r;
        switch (status[c.id]!) {
          case PendingCallStatus.denied:
            // Declined before the process died (an older version may not
            // have saved the result): never ask again.
            await answer(c, _declinedText, PendingCallStatus.denied);
          case PendingCallStatus.done:
            // Marked done but its result never reached the store (older
            // versions): the outcome is unknown.
            await answer(c, _interruptedText(tool));
          case PendingCallStatus.running:
            // Interrupted mid-execution by process death. Re-run only on
            // trusted read-only / idempotent annotations (R11 §9.8).
            if (_approvals.mayRerunInterrupted(tool)) {
              run.emit(RunNotice('tool_rerun', 'Re-running interrupted ${tool.displayName} (idempotent).'));
              toRun.add(c);
            } else {
              run.emit(RunNotice('tool_interrupted',
                  '${tool.displayName} was interrupted while running; its outcome is unknown and it was not run again.'));
              await answer(c, _interruptedText(tool));
            }
          case PendingCallStatus.approved:
            toRun.add(c);
          case PendingCallStatus.pending:
            if (await _gate(run, c, r, tainted: tainted)) {
              status[c.id] = PendingCallStatus.approved;
              await saveStatus(RunPhase.awaitingApproval);
              toRun.add(c);
            } else {
              await answer(c, _declinedText, PendingCallStatus.denied);
            }
        }
      }

      await saveStatus(RunPhase.executingTools);
      await _runPool(toRun, run.token, (c) async {
        status[c.id] = PendingCallStatus.running;
        await saveStatus(RunPhase.executingTools);
        final part = await _execute(run, c, targets[c.id]!, idempotencyKey: '${assistant.id}:${c.id}');
        results[c.id] = part;
        status[c.id] = PendingCallStatus.done;
        await persistResults();
        await saveStatus(RunPhase.executingTools);
        final msg = await _store.getMessage(sid, toolMsgId);
        run.emit(ToolCallFinished(
          call: c,
          result: ToolResult(
            content: part.content,
            structured: part.structured,
            isError: part.isError,
            uiResourceUri: part.uiResourceUri,
            meta: part.meta,
          ),
          message: msg!,
        ));
      });
    } finally {
      // Pairing invariant: every call gets a result, even when cancelled.
      for (final c in calls) {
        results[c.id] ??= errorResult(c, 'Cancelled by the user before it ran.');
      }
      await persistResults();
      await _setLeaf(sid, toolMsgId);
      run.leafId = toolMsgId;
    }
    await _checkpoint(run, RunPhase.preparingContext, step: step + 1);
    return toolMsgId;
  }

  static const String _declinedText =
      'The user declined this tool call. Do not retry it; ask the user how to proceed if it was necessary.';

  static String _interruptedText(ToolDefinition tool) =>
      'The app was interrupted while "${tool.name}" was running, so its outcome is unknown. It was not run again '
      'automatically because Sherpa cannot confirm that repeating it is safe; ask the user before trying again.';

  /// True when the context holds output of a non-built-in tool (MCP or
  /// on-device server) or an MCP resource: content an attacker may control.
  Future<bool> _isTainted(String sessionId, String leafId) async {
    for (final m in await _store.path(sessionId, leafId)) {
      if (m.content.any((p) => p is EmbeddedResourcePart || p is ResourceLinkPart || p is UiResourcePart)) {
        return true;
      }
      for (final r in m.toolResults) {
        final source = _tools.lookup(r.toolName)?.source.kind;
        // Unknown tools (e.g. from a removed server) count as untrusted.
        if (source != ToolSourceKind.builtin) return true;
      }
    }
    return false;
  }

  /// Answers tool calls of a reply that was stopped before they could run.
  Future<void> _closeDanglingCalls(_Run run, Message assistant) async {
    final id = _ids.next('msg');
    await _store.putMessage(
      run.sessionId,
      Message(
        id: id,
        parentId: assistant.id,
        role: Role.tool,
        createdAt: _clock.now(),
        content: [
          for (final c in assistant.toolCalls)
            ToolResultPart(
              callId: c.id,
              toolName: c.name,
              content: const [TextPart('Cancelled by the user before it ran.')],
              isError: true,
            ),
        ],
      ),
    );
    await _setLeaf(run.sessionId, id);
    run.leafId = id;
  }

  /// Decides on [c] by what will actually run ([r]: for a proxy such as
  /// `call_tool`, its target), so grants, prompts and the audit name the
  /// real tool and nothing is ever granted to the proxy.
  Future<bool> _gate(_Run run, ToolCall c, ResolvedToolCall r, {bool tainted = false}) async {
    final call = r.call;
    final tool = r.tool!;
    final via = call.name == c.name ? null : c.name;
    final req = _approvals.evaluate(
      tool,
      run.sessionId,
      tainted: tainted,
      repaired: c.repaired || call.repaired,
      nameCorrected: r.correctedName,
    );
    switch (req) {
      case AutoApprove(:final reason):
        await _audit(run, AuditKind.approval, 'auto-approved ${call.name}: $reason', {'callId': c.id, 'via': via});
        return true;
      case Denied(:final reason):
        run.emit(ToolApprovalResolved(callId: c.id, approved: false, reason: reason));
        await _audit(run, AuditKind.approval, 'denied ${call.name}: $reason', {'callId': c.id, 'via': via});
        return false;
      case NeedsConfirmation():
        run.emit(ToolApprovalRequested(call: call, tool: tool, requirement: req));
        final response = await _approvalHandler.requestApproval(
          sessionId: run.sessionId,
          call: call,
          tool: tool,
          requirement: req,
          cancel: run.token,
        );
        run.token.throwIfCancelled();
        final ok = response.decision == UserDecision.approve;
        // A one-off prompt (repaired / corrected call) never leaves a grant,
        // whatever scope the handler answered with.
        _approvals.recordFor(tool, run.sessionId, response, requirement: req);
        final scope = req.oneOffOnly ? ApprovalScope.once : response.scope;
        run.emit(ToolApprovalResolved(callId: c.id, approved: ok, reason: ok ? 'approved by user' : 'declined by user'));
        await _audit(run, AuditKind.approval, '${ok ? 'user approved' : 'user declined'} ${call.name}', {
          'callId': c.id,
          'scope': scope.name,
          'risk': req.risk.name,
          'via': via,
          if (req.oneOffOnly) 'oneOffOnly': true,
        });
        return ok;
    }
  }

  Future<ToolResultPart> _execute(_Run run, ToolCall c, ResolvedToolCall r, {String? idempotencyKey}) async {
    final tool = r.tool!;
    final target = r.call.name;
    run.emit(ToolCallStarted(c));
    final started = _clock.now();
    final token = run.token.child();
    ToolResult result;
    try {
      result = await _tools
          .execute(
            c,
            ToolExecutionContext(
              sessionId: run.sessionId,
              cancel: token,
              timeout: _config.toolTimeout,
              onProgress: (p) => run.emit(ToolCallProgressed(callId: c.id, progress: p)),
              idempotencyKey: idempotencyKey,
            ),
          )
          .timeout(_config.toolTimeout, onTimeout: () {
        token.cancel('timeout');
        return ToolResult.error('"${c.name}" timed out after ${_config.toolTimeout.inSeconds}s.');
      });
    } on CancelledException {
      result = ToolResult.error('Cancelled by the user while running.');
    } on Object catch (e) {
      result = ToolResult.error('"${c.name}" failed: $e');
    }
    token.detach();
    final ms = _clock.now().difference(started).inMilliseconds;
    await _audit(run, AuditKind.toolCall, '$target${result.isError ? ' (error)' : ''}', {
      'callId': c.id,
      'tool': target,
      'server': tool.source.serverId,
      'via': target == c.name ? null : c.name,
      'durationMs': ms,
      'argsBytes': utf8.encode(jsonEncode(c.arguments)).length,
    });
    final serverId = tool.source.serverId;
    return ToolResultPart(
      callId: c.id,
      toolName: c.name,
      content: result.content,
      structured: result.structured,
      isError: result.isError,
      uiResourceUri: result.uiResourceUri ?? tool.uiResourceUri,
      durationMs: ms,
      // Attribution is the harness's: it overrides whatever the server put
      // in its own `_meta`.
      meta: {
        ...result.meta,
        ToolResultPart.metaServerId: ?serverId,
        if (target != c.name) ToolResultPart.metaTool: target,
      },
    );
  }

  Future<void> _runPool(
    List<ToolCall> calls,
    CancellationToken token,
    Future<void> Function(ToolCall c) work,
  ) async {
    var next = 0;
    Future<void> worker() async {
      while (next < calls.length && !token.isCancelled) {
        final c = calls[next++];
        await work(c);
      }
    }

    final n = calls.length < _config.maxParallelTools ? calls.length : _config.maxParallelTools;
    await Future.wait([for (var i = 0; i < n; i++) worker()]);
  }

  // ---------------------------------------------------------------------------
  // Persistence helpers

  Future<SessionRecord> _requireSession(String id) async {
    final s = await _store.getSession(id);
    if (s == null) throw StateError('unknown session $id');
    return s;
  }

  Future<void> _setLeaf(String sessionId, String leafId, {String? titleHint}) async {
    final s = await _requireSession(sessionId);
    var title = s.title;
    if ((title.isEmpty || title == defaultSessionTitle) && titleHint != null && titleHint.trim().isNotEmpty) {
      final t = titleHint.trim().replaceAll(RegExp(r'\s+'), ' ');
      title = t.length > 60 ? '${t.substring(0, 57)}…' : t;
    }
    await _store.putSession(s.copyWith(activeLeafId: leafId, updatedAt: _clock.now(), title: title));
  }

  Future<void> _checkpoint(
    _Run run,
    RunPhase phase, {
    int? step,
    String? draftId,
    List<PendingCall>? pending,
    String? error,
  }) async {
    final cp = RunCheckpoint(
      sessionId: run.sessionId,
      runId: run.runId,
      phase: phase,
      step: step ?? run.step,
      updatedAt: _clock.now(),
      leafMessageId: run.leafId,
      draftMessageId: draftId,
      pendingCalls: pending ?? const [],
      providerId: _provider.info.id,
      modelId: _modelId,
      error: error,
    );
    await run.serial(() => _store.putCheckpoint(cp));
    run.emit(Checkpointed(cp));
  }

  Future<void> _audit(_Run run, AuditKind kind, String summary, [JsonMap data = const {}]) =>
      _store.appendAudit(AuditEntry(
        id: _ids.next('aud'),
        sessionId: run.sessionId,
        at: _clock.now(),
        kind: kind,
        summary: summary,
        data: {for (final e in data.entries) if (e.value != null) e.key: e.value},
      ));
}

/// Mutable state of one run.
final class _Run {
  _Run({required this.sessionId, required this.runId});

  final String sessionId;
  final String runId;
  final CancellationToken token = CancellationToken();
  late final StreamController<AgentEvent> controller;
  Usage usage = Usage.zero;
  int step = 0;
  String? leafId;
  bool finished = false;
  bool handoffNoticed = false;
  bool taintNoticed = false;
  Future<void> _tail = Future.value();

  void emit(AgentEvent e) {
    if (!controller.isClosed && !finished) controller.add(e);
  }

  void finish(RunOutcome outcome, {Object? error, String? detail}) {
    if (finished) return;
    emit(RunFinished(outcome: outcome, usage: usage, error: error, detail: detail));
    finished = true;
  }

  /// Serializes store writes so concurrent tool completions can't commit an
  /// older snapshot after a newer one.
  Future<void> serial(Future<void> Function() write) {
    final next = _tail.then((_) => write());
    _tail = next.catchError((Object _) {});
    return next;
  }
}

/// Builds the assistant message from streamed events, preserving block
/// order (reasoning → text → tool calls, possibly interleaved) because
/// Anthropic requires thinking blocks to be echoed back exactly.
final class _Accumulator {
  _Accumulator({
    required this.id,
    required this.parentId,
    required this.createdAt,
    required this.providerId,
    required this.modelId,
  });

  final String id;
  final String parentId;
  final DateTime createdAt;
  final String providerId;
  final String modelId;

  final List<_Segment> _segments = [];
  final Map<int, _PartialCall> _partial = {};
  final Set<int> _completed = {};
  Usage? usage;
  FinishReason? finish;
  bool hasOutput = false;

  void add(ModelEvent e) {
    switch (e) {
      case TextDelta(:final text):
        hasOutput = true;
        _appendText(text, reasoning: false);
      case ReasoningDelta(:final text):
        hasOutput = true;
        _appendText(text, reasoning: true);
      case ReasoningSignature(:final signature, :final redactedData):
        final last = _segments.lastOrNull;
        if (last != null && last.reasoning && last.signature == null && redactedData == null) {
          last.signature = signature;
        } else {
          _segments.add(_Segment(reasoning: true)
            ..signature = signature
            ..redacted = redactedData);
        }
      case ToolCallStart(:final index, :final id, :final name):
        hasOutput = true;
        _partial[index] = _PartialCall(id, name);
      case ToolCallArgsDelta(:final index, :final fragment):
        _partial[index]?.args.write(fragment);
      case ToolCallComplete(:final index, :final call):
        hasOutput = true;
        _completed.add(index);
        _segments.add(_Segment(reasoning: false)..call = call);
      case UsageUpdate(usage: final u):
        usage = u;
      case Finish(:final reason):
        finish = reason;
      case ProviderNotice() || PerfSample():
        break;
    }
  }

  void _appendText(String text, {required bool reasoning}) {
    final last = _segments.lastOrNull;
    if (last != null &&
        last.call == null &&
        last.reasoning == reasoning &&
        last.signature == null &&
        last.redacted == null) {
      last.text.write(text);
    } else {
      _segments.add(_Segment(reasoning: reasoning)..text.write(text));
    }
  }

  Message build({String? finishReason, bool draft = false}) {
    final parts = <ContentPart>[];
    for (final s in _segments) {
      if (s.call != null) {
        parts.add(ToolCallPart(s.call!));
      } else if (s.reasoning) {
        parts.add(ReasoningPart(
          text: s.text.toString(),
          signature: s.signature,
          redactedData: s.redacted,
          providerId: providerId,
        ));
      } else if (s.text.isNotEmpty) {
        parts.add(TextPart(s.text.toString()));
      }
    }
    // Calls that started streaming but never completed: assemble them here so
    // the loop can still answer them (with an error if the JSON is broken).
    for (final e in _partial.entries) {
      if (_completed.contains(e.key)) continue;
      final raw = e.value.args.toString();
      Map<String, Object?>? args;
      String? error;
      try {
        final decoded = raw.trim().isEmpty ? <String, Object?>{} : jsonDecode(raw);
        if (decoded is Map) {
          args = decoded.cast<String, Object?>();
        } else {
          error = 'arguments must be a JSON object';
        }
      } on FormatException catch (fe) {
        error = 'malformed JSON (${fe.message})';
      }
      parts.add(ToolCallPart(ToolCall(
        id: e.value.id,
        name: e.value.name,
        arguments: args ?? const {},
        rawArguments: raw,
        argumentsError: draft ? null : error,
      )));
    }
    var reason = finishReason;
    if (reason == FinishReason.refusal.name) {
      // A refused turn's tool calls must never execute, even if some were
      // streamed before the refusal arrived.
      parts.removeWhere((p) => p is ToolCallPart);
    }
    if (reason == FinishReason.toolCalls.name && !parts.any((p) => p is ToolCallPart)) {
      reason = FinishReason.stop.name;
    }
    return Message(
      id: id,
      parentId: parentId,
      role: Role.assistant,
      content: parts,
      createdAt: createdAt,
      providerId: providerId,
      modelId: modelId,
      usage: usage,
      finishReason: draft ? null : reason,
      metadata: draft ? const {'draft': true} : const {},
    );
  }
}

final class _Segment {
  _Segment({required this.reasoning});
  final bool reasoning;
  final StringBuffer text = StringBuffer();
  String? signature;
  String? redacted;
  ToolCall? call;
}

final class _PartialCall {
  _PartialCall(this.id, this.name);
  final String id;
  final String name;
  final StringBuffer args = StringBuffer();
}

extension<T> on List<T> {
  T? lastWhereOrNull(bool Function(T) test) {
    for (var i = length - 1; i >= 0; i--) {
      if (test(this[i])) return this[i];
    }
    return null;
  }
}
