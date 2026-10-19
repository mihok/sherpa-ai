import 'package:flutter/foundation.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart' show EngineTokenCounter, WarmingContextManager;

import '../../../state/services.dart';
import '../../chat/state/chat_dependencies.dart' show RunnerExtrasFor;
import 'format.dart';

/// Everything the context inspector shows for one chat, read in one pass so
/// the budget, the items and the overlay diffs always describe the same
/// moment.
@immutable
final class ContextSnapshot {
  const ContextSnapshot({
    required this.sessionId,
    required this.model,
    required this.inspection,
    required this.overlays,
    required this.path,
    required this.capabilities,
    required this.settings,
    required this.canCompact,
    this.tools = const [],
    this.recommendation,
  });

  final String sessionId;
  final ModelChoice model;

  /// The model-facing view with per-item tokens and one diff per overlay.
  final ContextInspection inspection;

  /// Overlays as persisted (the inspection's diffs refer to them by id).
  final List<ContextOverlay> overlays;

  /// The active branch, root → leaf, unmodified.
  final List<Message> path;
  final ModelCapabilities capabilities;
  final ContextSettings settings;

  /// The tool definitions the request offers (what the model can call).
  final List<ToolDefinition> tools;

  /// The chat's context manager can compact on request (the ladder); the
  /// passthrough manager only measures.
  final bool canCompact;

  /// Set when the next request should not go ahead as is.
  final ContextRecommendation? recommendation;

  ContextBudget get budget => inspection.budget;

  ContextOverlay? overlay(String id) => overlays.where((o) => o.id == id).firstOrNull;

  Message? message(String id) => path.where((m) => m.id == id).firstOrNull;

  /// The latest compaction that is in effect, if any.
  CompactedRange? get activeCompaction {
    CompactedRange? best;
    for (final d in inspection.diffs) {
      if (d.kind != ContextDiffKind.compaction || d.status != OverlayStatus.active) continue;
      final o = overlay(d.overlayId);
      if (o is CompactedRange && (best == null || o.createdAt.isAfter(best.createdAt))) best = o;
    }
    return best;
  }
}

/// Context operations behind the inspector and "Compact now".
///
/// Why this exists apart from `AgentRunner`: the runner only prepares
/// context inside a run. The inspector must show the *same* view without
/// starting one, so [request] rebuilds the runner's `ContextRequest` field by
/// field (session prompt through `PromptBoundary`, offered tools, plan,
/// memory, nonce, location) and applies the same per-provider [extras] the
/// chat's runner gets (`chatContextExtrasProvider`): a local chat is counted
/// with the engine's own tokenizer and summarized by its own model, exactly
/// as its next run would be. Writes go through the same store calls and
/// audit lines the runner uses, so a manual compaction or an undo is
/// indistinguishable from one the ladder made by itself.
///
/// The chat controller owns the only instance per chat and serializes
/// these calls against runs; nothing here checks whether a run is active.
final class ContextActions {
  ContextActions({
    required this.store,
    required this.registry,
    required this.router,
    required this.config,
    required this.manager,
    required this.clock,
    required this.ids,
    this.memory,
    this.extras,
    TokenCounter Function()? counter,
  }) : _counter = counter ?? HeuristicTokenCounter.new;

  final SessionStore store;
  final ProviderRegistry registry;
  final ToolRouter router;
  final AgentConfig config;

  /// The app's base context manager; [extras] may replace it per provider.
  final ContextManager manager;
  final Clock clock;
  final IdGenerator ids;
  final MemoryMonitor? memory;

  /// The runner's per-provider extras (counter, context manager); null =
  /// [manager] and a heuristic counter for every provider.
  final RunnerExtrasFor? extras;
  final TokenCounter Function() _counter;

  /// The ladder inside [m] (through a token-warming wrapper), if any.
  static LadderContextManager? ladderOf(ContextManager m) => switch (m) {
        LadderContextManager() => m,
        WarmingContextManager(:final inner) => ladderOf(inner),
        _ => null,
      };

  /// Inspection is pure, so when the app runs the passthrough manager a
  /// default ladder can still *show* the view (it never writes anything).
  LadderContextManager _inspector(ContextManager m) => ladderOf(m) ?? LadderContextManager(clock: clock);

  /// The request the runner would build for the next model call on
  /// [model] (mirrors `AgentRunner._modelStep`).
  Future<ContextRequest> request(String sessionId, ModelChoice model) async => (await _resolve(sessionId, model)).request;

  /// [request] plus the context manager a run on [model] uses; an exact
  /// engine counter is warmed, so the synchronous counts hit its cache.
  Future<({ContextRequest request, ContextManager manager})> _resolve(String sessionId, ModelChoice model) async {
    final session = await store.getSession(sessionId) ?? (throw StateError('unknown session $sessionId'));
    final leaf = session.activeLeafId;
    final path = leaf == null ? const <Message>[] : await store.path(sessionId, leaf);
    final overlays = await store.overlays(sessionId);
    final plan = await store.getPlan(sessionId);
    String? query;
    for (final m in path.reversed) {
      if (m.role == Role.user) {
        query = m.text;
        break;
      }
    }
    final provider = await registry.resolve(model.providerId);
    final e = extras?.call(provider, model, manager);
    final caps = await provider.capabilities(model.modelId);
    final hints = ToolSelectionHints(
      onDevice: provider.info.location == ExecutionLocation.onDevice,
      parameterBillions: caps.parameterCount == null ? null : caps.parameterCount! / 1e9,
    );
    final offered = caps.canCallTools
        ? (await router.toolsForTurn(sessionId: sessionId, query: query, hints: hints))
            .where((t) => t.modelVisible)
            .toList()
        : const <ToolDefinition>[];
    final system = PromptBoundary.compose(session.systemPrompt ?? config.defaultSystemPrompt);
    final counter = e?.counter ?? _counter();
    if (counter is EngineTokenCounter) {
      try {
        await counter.warm(systemPrompt: system, messages: path, tools: offered);
      } on Object {
        // Counting falls back to (pessimistic) estimates.
      }
    }
    final r = ContextRequest(
      sessionId: sessionId,
      path: path,
      overlays: overlays,
      tools: offered,
      capabilities: caps,
      counter: counter,
      systemPrompt: system,
      plan: plan,
      memory: memory?.current ?? MemoryState.unknown,
      settings: config.contextSettings,
      location: provider.info.location,
      boundaryNonce: session.settings.opt<String>('boundaryNonce'),
    );
    return (request: r, manager: e?.contextManager ?? manager);
  }

  Future<ContextSnapshot> snapshot(String sessionId, ModelChoice model) async {
    final (:request, :manager) = await _resolve(sessionId, model);
    final inspection = _inspector(manager).inspect(request);
    return ContextSnapshot(
      sessionId: sessionId,
      model: model,
      inspection: inspection,
      overlays: request.overlays,
      path: request.path,
      capabilities: request.capabilities,
      settings: request.settings,
      canCompact: ladderOf(manager) != null,
      tools: request.tools,
      recommendation: recommend(inspection, request.overlays, request.settings),
    );
  }

  /// Compacts now and persists the overlay exactly like a ladder-made one
  /// (store + `contextAction` audit line). Throws [StateError] when the
  /// configured manager cannot compact.
  Future<CompactionOutcome> compactNow(String sessionId, ModelChoice model) async {
    final (:request, :manager) = await _resolve(sessionId, model);
    final ladder = ladderOf(manager);
    if (ladder == null) {
      throw StateError('this build summarizes context only when it fills up');
    }
    final outcome = await ladder.compactNow(request);
    final o = outcome.overlay;
    if (o != null) {
      await store.putOverlay(sessionId, o);
      await _audit(sessionId, o.reason, {
        'overlay': o.type,
        'tokensSaved': o.tokensSaved,
        'trigger': 'user',
        if (outcome.usedFallback) 'fallback': true,
      });
    }
    return outcome;
  }

  /// Removes [overlayId] and every overlay built on it (a later rolling
  /// compaction that merged its summary), newest first. Returns the ids
  /// removed. The transcript itself never changed, so the original text is
  /// in the next request again.
  Future<List<String>> undo(String sessionId, ModelChoice model, String overlayId) async {
    final (request: r, :manager) = await _resolve(sessionId, model);
    final set = _inspector(manager).inspect(r).undoSet(overlayId);
    final byId = {for (final o in r.overlays) o.id: o};
    final removed = <String>[];
    for (final id in set.reversed) {
      final o = byId[id];
      if (o == null) continue;
      await store.removeOverlay(sessionId, id);
      removed.add(id);
      await _audit(sessionId, 'Undid a context change: ${o.reason}', {'overlay': o.type, 'overlayId': id, 'undo': true});
    }
    return removed;
  }

  /// The most recent overlay, whatever its state (for "last change" lines).
  Future<ContextOverlay?> latestOverlay(String sessionId) async {
    final all = await store.overlays(sessionId);
    if (all.isEmpty) return null;
    return all.reduce((a, b) => b.createdAt.isAfter(a.createdAt) ? b : a);
  }

  Future<void> _audit(String sessionId, String summary, JsonMap data) => store.appendAudit(
        AuditEntry(
          id: ids.next('aud'),
          sessionId: sessionId,
          at: clock.now(),
          kind: AuditKind.contextAction,
          summary: summary,
          data: data,
        ),
      );

  /// The ladder's stage-5/6 advice for a view it did not just compact
  /// (`LadderContextManager._recommend` without a fresh compaction).
  ///
  /// Recomputed here because inspecting never runs `prepare` (which may
  /// call a summarizer model); the copy matches what the runner shows.
  static ContextRecommendation? recommend(
    ContextInspection inspection,
    List<ContextOverlay> overlays,
    ContextSettings settings,
  ) {
    final b = inspection.budget;
    final t = inspection.profile.thresholds;
    if (!b.fits) {
      return ContextRecommendation(
        ContextRecommendationKind.hardStop,
        "This conversation no longer fits the model's context window (${groupDigits(b.inputTokens)} of "
        '${groupDigits(b.usableInput)} tokens). Continue in a new session from a handoff, or switch to a '
        'model with a larger window.',
      );
    }
    var count = 0;
    for (final d in inspection.diffs) {
      if (d.kind != ContextDiffKind.compaction || d.status != OverlayStatus.active) continue;
      final o = overlays.where((x) => x.id == d.overlayId).firstOrNull;
      if (o is CompactedRange && o.summary.compactionCount > count) count = o.summary.compactionCount;
    }
    final reasons = <String>[
      if (b.ratio >= t.handoff) 'it is ${formatPercent(b.ratio)} full',
      if (count >= settings.handoffAfterCompactions && b.ratio >= t.compact) 'it has been summarized $count times',
    ];
    if (reasons.isEmpty) return null;
    return ContextRecommendation(
      ContextRecommendationKind.handoff,
      'Consider continuing in a new session from a handoff: ${reasons.join(', ')}. Each summary loses detail.',
    );
  }

}
