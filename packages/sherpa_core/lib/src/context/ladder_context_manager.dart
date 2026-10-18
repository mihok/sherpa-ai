import 'dart:convert';
import 'dart:math';

import 'package:meta/meta.dart';

import '../common/cancellation.dart';
import '../common/clock.dart';
import '../model/content.dart';
import '../model/message.dart';
import '../model/tool.dart';
import '../provider/capabilities.dart';
import '../provider/model_provider.dart';
import '../tools/plan_tool.dart';
import 'budget.dart';
import 'compaction.dart';
import 'context_manager.dart';
import 'extractive_strategy.dart';
import 'inspector.dart';
import 'memory_policy.dart';
import 'overlay.dart';
import 'pairing.dart';
import 'part_rewrite.dart';
import 'passthrough_context_manager.dart';
import 'payload_shrink.dart';
import 'summary_harvest.dart';
import 'text.dart';
import 'token_estimator.dart';
import 'turns.dart';
import 'untrusted.dart';
import 'window_profile.dart';

/// Result of one compaction attempt ([LadderContextManager.compactNow] and
/// stage 3 of [LadderContextManager.prepare]).
@immutable
final class CompactionOutcome {
  const CompactionOutcome({
    this.overlay,
    this.skippedReason,
    this.ratioBefore = 0,
    this.ratioAfter = 0,
    this.usedFallback = false,
  });

  /// The overlay to persist; null when nothing was compacted.
  final CompactedRange? overlay;
  final String? skippedReason;
  final double ratioBefore;
  final double ratioAfter;

  /// True when the configured strategy failed or was rejected and the
  /// deterministic fallback produced the summary.
  final bool usedFallback;

  bool get compacted => overlay != null;
}

/// The M3 context manager: the R11 escalation ladder under the segment
/// rules (PLAN "Context segments").
///
/// Each model call runs, stopping as soon as the budget fits:
/// 1. elide stale large tool results (stub + first/last lines; the call and
///    the result shell stay, so pairing holds; the full text stays in the
///    transcript);
/// 2. clear large old tool inputs (keys and `argsDigest` kept);
/// 3. compact at a legal cut point with the configured [ContextStrategy];
/// 4. truncate recent large payloads, only if the call still would not fit
///    (truncating what the model is reading now is worse than summarizing
///    what it read long ago, so this tier runs after compaction);
/// 5. recommend a handoff, or 6. hard stop: never overflow silently.
///
/// Thresholds scale with the window (R11 §9.2, [WindowProfile]); the
/// estimate margin is 20% until a heuristic counter is calibrated. Every
/// rewrite is an overlay with a deterministic id, so recomputing with the
/// overlays already persisted creates nothing new, and every view is
/// pairing-checked before it is returned.
///
/// For [HistoryPolicy.appendOnly] models (Anthropic preserved thinking,
/// local KV reuse) new overlays are created only when the path ends with a
/// fresh user message; mid tool loop the manager recommends a handoff or
/// stops instead, and after a rewrite reasoning from older prefixes is
/// dropped (R10 §7.9).
final class LadderContextManager implements ContextManager {
  LadderContextManager({
    this.strategy = const ExtractiveContextStrategy(),
    this.fallbackStrategy = const ExtractiveContextStrategy(),
    this.memoryPolicy = const MemoryContextPolicy(),
    this.location,
    this.toolLookup,
    Clock clock = const SystemClock(),
    Random? random,
  })  : _clock = clock,
        _random = random ?? Random.secure();

  /// Summarizer for windows above 4K (e.g. `ModelContextStrategy`).
  final ContextStrategy strategy;

  /// Used for ≤ 4K windows and when [strategy] fails or is rejected.
  final ContextStrategy fallbackStrategy;
  final MemoryContextPolicy memoryPolicy;

  /// Where the model runs when [ContextRequest.location] is null.
  final ExecutionLocation? location;

  /// Resolves tools not offered this turn (e.g. `ToolRouter.lookup`), so
  /// read-only calls stay out of the side-effect ledger.
  final ToolDefinition? Function(String name)? toolLookup;
  final Clock _clock;
  final Random _random;
  final Map<String, String> _nonces = {};

  /// Elision stops this far below the prune threshold, so the cache-breaking
  /// rewrite happens in batches rather than every turn (Anthropic's
  /// `clear_at_least` rationale).
  static const double hysteresis = 0.10;

  /// Edits that save fewer tokens than this are not worth a cache miss.
  static const int minSaving = 32;

  @override
  Future<PreparedContext> prepare(ContextRequest request) async {
    final p = _Pass(this, request);
    final t = p.profile.thresholds;
    var view = p.render();
    final initial = view.budget.ratio;
    CompactionOutcome? compaction;
    if (p.canRewrite && initial >= t.prune) {
      view = p.apply(view, _elisions(p, view.budget.ratio), target: t.prune - hysteresis);
      if (view.budget.ratio >= t.prune) {
        view = p.apply(view, _inputClearing(p, view.budget.ratio), target: t.prune - hysteresis);
      }
      if (view.budget.ratio >= t.compact && request.settings.autoCompact) {
        compaction = await _compact(p, view);
        if (compaction.compacted) view = p.render();
      }
      if (!view.budget.fits) view = p.apply(view, _rescue(p, view), target: 1.0);
    }
    return PreparedContext(
      systemPrompt: p.system,
      messages: view.messages,
      tools: request.tools,
      budget: view.budget,
      level: view.budget.levelFor(t),
      newOverlays: p.created,
      recommendation: _recommend(p, view, compaction),
      prefixKey: view.key,
    );
  }

  /// What the model would see for [request] with only the recorded
  /// overlays, with per-item token counts and a diff per overlay. Pure: no
  /// model calls, nothing created.
  ContextInspection inspect(ContextRequest request) {
    final p = _Pass(this, request);
    final view = p.render();
    final index = {for (final (i, m) in request.path.indexed) m.id: i};
    final partOverlays = <String, List<String>>{};
    for (final o in request.overlays) {
      final id = switch (o) {
        ToolOutputElided(:final messageId) || PayloadTruncated(:final messageId) => messageId,
        CompactedRange() => null,
      };
      if (id != null) (partOverlays[id] ??= []).add(o.id);
    }
    final items = <InspectedItem>[];
    for (final (j, m) in view.messages.indexed) {
      final raw = index[m.id];
      final (source, ids) = m.id.startsWith('summary:')
          ? (ContextItemSource.summary, ['${m.metadata['overlayId']}'])
          : m.id.startsWith('synthetic:')
              ? (ContextItemSource.synthetic, const <String>[])
              : raw != null && identical(request.path[raw], m)
                  ? (ContextItemSource.transcript, const <String>[])
                  : (ContextItemSource.edited, partOverlays[m.id] ?? const <String>[]);
      items.add(InspectedItem(message: m, tokens: view.counts[j], source: source, overlayIds: ids));
    }
    return ContextInspection(
      items: items,
      systemPrompt: p.system,
      systemTokens: p.systemTokens,
      toolTokens: p.toolTokens,
      budget: view.budget,
      level: view.budget.levelFor(p.profile.thresholds),
      prefixKey: view.key,
      profile: p.profile,
      diffs: ContextDiffs.build(path: request.path, overlays: request.overlays, counter: request.counter),
      pairingIssues: view.issues,
    );
  }

  /// Compacts now, whatever the thresholds ("Compact now" in the UI, L4
  /// evals). Uses the same cut-point, merge and size rules as stage 3. The
  /// caller persists [CompactionOutcome.overlay]. Call it only while no run
  /// is active: for append-only models a rewrite inside a tool-use turn
  /// would invalidate that turn's reasoning.
  Future<CompactionOutcome> compactNow(ContextRequest request) async {
    final p = _Pass(this, request);
    return _compact(p, p.render(), forced: true);
  }

  // ---------------------------------------------------------------------------
  // Stage 1: elide stale tool results

  List<ContextOverlay> _elisions(_Pass p, double ratio) {
    final s = p.settings;
    final protected = p.recentCallIds(s.keepRecentToolCalls);
    final out = <ContextOverlay>[];
    for (final (i, m) in p.path.indexed) {
      if (m.role != Role.tool || m.pinned || p.hidden(i)) continue;
      for (final (pi, r) in m.content.indexed) {
        if (r is! ToolResultPart || p.hasPartOverlay(m.id, pi, callId: r.callId)) continue;
        // Never-elide rules (R11 §9.3 rule 2).
        if (protected.contains(r.callId) || s.excludedTools.contains(r.toolName)) continue;
        if (r.callId == p.latestPlanCallId || p.isReferenced(r.callId)) continue;
        final tokens = ContextDiffs.partTokens(p.counter, m, r);
        if (r.isError && tokens < s.smallErrorResultTokens) continue;
        if (tokens <= s.largeToolResultTokens && p.userTurnsAfter(i) < s.staleAfterTurns) continue;
        final stub = PayloadShrink.elisionStub(
          toolName: r.toolName,
          tokens: tokens,
          callId: r.callId,
          text: r.text,
          keepLines: s.elideKeepLines,
        );
        final saved = tokens - ContextDiffs.partTokens(p.counter, m, PartRewrite.replacePayload(r, stub));
        if (saved < minSaving) continue;
        out.add(ToolOutputElided(
          id: 'ctx-elide:${m.id}:${r.callId}',
          createdAt: p.now,
          reason: 'Elided a stale ${r.toolName} result (call ${r.callId}, ${groupDigits(tokens)} → '
              '${groupDigits(tokens - saved)} tokens): context was ${_pct(ratio)} full, pruning starts at '
              '${_pct(p.profile.thresholds.prune)}.',
          tokensSaved: saved,
          messageId: m.id,
          callId: r.callId,
          stub: stub,
        ));
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Stage 2: clear large old tool inputs

  List<ContextOverlay> _inputClearing(_Pass p, double ratio) {
    final s = p.settings;
    final protected = p.recentCallIds(s.keepRecentToolCalls);
    final out = <ContextOverlay>[];
    for (final (i, m) in p.path.indexed) {
      if (m.role != Role.assistant || m.pinned || p.hidden(i) || i == p.path.length - 1) continue;
      for (final (pi, part) in m.content.indexed) {
        if (part is! ToolCallPart || p.hasPartOverlay(m.id, pi)) continue;
        final call = part.call;
        if (protected.contains(call.id) || s.excludedTools.contains(call.name)) continue;
        final tokens = ContextDiffs.partTokens(p.counter, m, part);
        if (tokens <= s.largeToolInputTokens) continue;
        final replacement = jsonEncode(PayloadShrink.shrinkArguments(call.arguments));
        final o = _truncation(p, m, pi, part, tokens, replacement,
            reason: (after) => 'Cleared the large input of ${call.name} (call ${call.id}, ${groupDigits(tokens)} → '
                '${groupDigits(after)} tokens; argsDigest kept): context was ${_pct(ratio)} full.');
        if (o != null) out.add(o);
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Stage 4: overflow rescue

  List<ContextOverlay> _rescue(_Pass p, _View view) {
    final w = view.budget.usableInput;
    final keep = (w * 0.15).round().clamp(64, p.settings.largeToolResultTokens);
    final normal = <ContextOverlay>[];
    final excluded = <ContextOverlay>[];
    for (final (i, m) in p.path.indexed) {
      if (m.pinned || p.hidden(i) || (i == p.path.length - 1 && m.role == Role.assistant)) continue;
      for (final (pi, part) in m.content.indexed) {
        final callId = switch (part) {
          ToolResultPart(:final callId) => callId,
          ToolCallPart(:final call) => call.id,
          _ => null,
        };
        if (callId == null || p.hasPartOverlay(m.id, pi, callId: part is ToolResultPart ? callId : null)) continue;
        final tokens = ContextDiffs.partTokens(p.counter, m, part);
        if (tokens <= keep * 2) continue;
        final text = ContextDiffs.payloadText(part);
        final charsPerToken = (text.length / tokens).clamp(1.0, 6.0);
        final replacement = switch (part) {
          ToolResultPart() => PayloadShrink.truncatedResult(
              toolName: part.toolName,
              callId: callId,
              tokens: tokens,
              text: part.text,
              structured: part.structured,
              maxChars: (keep * charsPerToken).round(),
            ),
          ToolCallPart(:final call) => jsonEncode(PayloadShrink.shrinkArguments(call.arguments, maxStringChars: 40)),
          _ => text,
        };
        final name = part is ToolResultPart ? part.toolName : (part as ToolCallPart).call.name;
        final o = _truncation(p, m, pi, part, tokens, replacement,
            reason: (after) => 'Truncated a recent ${part is ToolResultPart ? 'result' : 'input'} of $name '
                '(call $callId, ${groupDigits(tokens)} → ${groupDigits(after)} tokens): the request would not '
                'fit the window otherwise.');
        if (o == null) continue;
        (p.settings.excludedTools.contains(name) ? excluded : normal).add(o);
      }
    }
    return [...normal, ...excluded];
  }

  PayloadTruncated? _truncation(
    _Pass p,
    Message m,
    int partIndex,
    ContentPart part,
    int tokens,
    String replacement, {
    required String Function(int after) reason,
  }) {
    final after = ContextDiffs.partTokens(p.counter, m, PartRewrite.replacePayload(part, replacement));
    if (tokens - after < minSaving) return null;
    return PayloadTruncated(
      id: 'ctx-trunc:${m.id}:$partIndex',
      createdAt: p.now,
      reason: reason(after),
      tokensSaved: tokens - after,
      messageId: m.id,
      partIndex: partIndex,
      replacement: replacement,
    );
  }

  // ---------------------------------------------------------------------------
  // Stage 3: compaction

  Future<CompactionOutcome> _compact(_Pass p, _View view, {bool forced = false}) async {
    final ratio = view.budget.ratio;
    CompactionOutcome skip(String why) => CompactionOutcome(skippedReason: why, ratioBefore: ratio, ratioAfter: ratio);
    if (p.path.isEmpty) return skip('the conversation is empty');
    final prev = p.latestCompaction;
    final prevTo = prev?.to ?? -1;
    final turns = [
      for (var i = prevTo + 1; i < p.path.length; i++)
        if (isRealUserTurn(p.path[i])) i,
    ];
    if (turns.isEmpty) return skip('there is no user turn after the last summary to cut before');
    // Cut immediately before a real user turn: the oldest of the last K,
    // with K shrinking until the kept tail fits its share of W (§9.3).
    final w = view.budget.usableInput;
    final cap = (p.profile.keptTailFraction * w).floor();
    var k = min(p.profile.keepRecentUserTurns, turns.length);
    var cut = turns[turns.length - k];
    while (k > 1 && view.tokensFrom(cut) > cap) {
      k--;
      cut = turns[turns.length - k];
    }
    final survivors = compactionSurvivors(p.path, 0, cut - 1).toSet();
    final fresh = [
      for (var i = 0; i < cut; i++)
        if (!p.hidden(i) && !survivors.contains(i)) p.path[i],
    ];
    if (fresh.isEmpty) return skip('nothing new to compact before the kept turns');
    final replaced = view.tokensBefore(cut, survivors: {for (final i in survivors) p.path[i].id});
    final previousSummary = prev?.overlay.summary;
    final input = CompactionInput(
      messages: fresh,
      previousSummary: previousSummary,
      taskStatement: p.request.plan?.task ?? previousSummary?.task ?? p.firstUserText,
      maxSummaryTokens: p.settings.maxSummaryTokens,
      contextMessages: view.before(cut),
      keptMessages: p.path.sublist(cut),
      systemPrompt: p.system,
      tools: p.tools,
      toolLookup: toolLookup,
      plan: p.request.plan,
      counter: p.counter,
      userMessageTokens: min((0.2 * w).floor(), 4000),
      replacedTokens: replaced,
      nonce: p.nonce(previousSummary),
    );
    CompactedRange build(CompactionSummary summary, String strategyId, int size) => CompactedRange(
          id: 'ctx-compact:${p.path.first.id}:${p.path[cut - 1].id}',
          createdAt: p.now,
          reason: '${forced ? 'Compacted on request' : 'Context was ${_pct(ratio)} full (compaction starts at '
              '${_pct(p.profile.thresholds.compact)})'}: summarized ${fresh.length} earlier messages with '
              '$strategyId (${groupDigits(replaced)} → ${groupDigits(size)} tokens) and kept the last $k user '
              '${k == 1 ? 'turn' : 'turns'} verbatim.',
          tokensSaved: replaced - size,
          fromMessageId: p.path.first.id,
          toMessageId: p.path[cut - 1].id,
          summary: summary,
          strategyId: strategyId,
        );

    final primary = p.profile.modelCompaction ? strategy : fallbackStrategy;
    final first = await _summarize(p, primary, input, replaced, build);
    var result = first.overlay;
    var usedFallback = false;
    var failure = first.failure;
    if (result == null && !identical(primary, fallbackStrategy)) {
      final second = await _summarize(p, fallbackStrategy, input, replaced, build);
      result = second.overlay;
      usedFallback = result != null;
      failure = '${first.failure}; ${second.failure}';
    }
    if (result == null) return skip(failure ?? 'no summary');
    p.add(result);
    final after = p.render().budget.ratio;
    return CompactionOutcome(overlay: result, ratioBefore: ratio, ratioAfter: after, usedFallback: usedFallback);
  }

  Future<({CompactedRange? overlay, String? failure})> _summarize(
    _Pass p,
    ContextStrategy s,
    CompactionInput input,
    int replaced,
    CompactedRange Function(CompactionSummary, String, int) build,
  ) async {
    try {
      final summary = await s.summarize(input, cancel: p.request.cancel);
      final probe = build(summary, s.id, 0);
      final size = p.counter.countMessage(PassthroughContextManager.summaryMessage(probe)) +
          p.counter.countMessage(PassthroughContextManager.summaryAck(probe));
      // Gemini rule: a summary that is not smaller than its range is useless.
      if (size >= replaced) {
        return (overlay: null, failure: 'the ${s.id} summary ($size tokens) is not smaller than the $replaced tokens it replaces');
      }
      return (overlay: build(summary, s.id, size), failure: null);
    } on CancelledException {
      rethrow;
    } on Object catch (e) {
      return (overlay: null, failure: '${s.id} failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Stages 5–6: recommendations

  ContextRecommendation? _recommend(_Pass p, _View view, CompactionOutcome? compaction) {
    final b = view.budget;
    final t = p.profile.thresholds;
    final s = p.settings;
    if (!b.fits) {
      return ContextRecommendation(
        ContextRecommendationKind.hardStop,
        p.canRewrite
            ? 'This conversation no longer fits the model\'s context window (${groupDigits(b.inputTokens)} of '
                '${groupDigits(b.usableInput)} tokens) even after pruning and compaction. Continue in a new '
                'session from a handoff, or switch to a model with a larger window.'
            : 'This conversation no longer fits the model\'s context window (${groupDigits(b.inputTokens)} of '
                '${groupDigits(b.usableInput)} tokens) in the middle of a tool loop, and this model only accepts '
                'context rewrites at a new user turn. Send a message to let Sherpa compact, or continue in a new '
                'session from a handoff.',
      );
    }
    final reasons = <String>[];
    final summary = compaction?.overlay?.summary;
    final count = summary?.compactionCount ?? p.latestCompaction?.overlay.summary.compactionCount ?? 0;
    if (compaction != null && compaction.compacted) {
      final freed = b.usableInput == 0 ? 0.0 : compaction.overlay!.tokensSaved / b.usableInput;
      if (count >= s.handoffAfterCompactions) reasons.add('it has been summarized $count times');
      if (freed < s.minCompactionGain) reasons.add('the last summary freed only ${_pct(freed)} of the window');
      if (compaction.ratioAfter > s.maxPostCompactionRatio) {
        reasons.add('it is still ${_pct(compaction.ratioAfter)} full after summarizing');
      }
      if (p.profile.tier == WindowTier.tiny) reasons.add('this model\'s window is too small for repeated summaries');
    } else {
      if (b.ratio >= t.handoff) reasons.add('it is ${_pct(b.ratio)} full');
      if (count >= s.handoffAfterCompactions && b.ratio >= t.compact) {
        reasons.add('it has been summarized $count times');
      }
    }
    if (reasons.isEmpty) return null;
    return ContextRecommendation(
      ContextRecommendationKind.handoff,
      'Consider continuing in a new session from a handoff: ${reasons.join(', ')}. Each summary loses detail.',
    );
  }

  static String _pct(double r) => r.isFinite ? '${(r * 100).round()}%' : '∞';
}

/// One model-facing view and its accounting.
final class _View {
  _View({
    required this.messages,
    required this.counts,
    required this.raw,
    required this.key,
    required this.issues,
    required this.budget,
  });

  final List<Message> messages;
  final List<int> counts;

  /// Raw path index each item stands for (summaries: the range start).
  final List<int> raw;
  final String key;
  final List<PairingIssue> issues;
  final ContextBudget budget;

  int tokensFrom(int rawIndex) {
    var n = 0;
    for (var j = 0; j < messages.length; j++) {
      if (raw[j] >= rawIndex) n += counts[j];
    }
    return n;
  }

  /// Tokens a compaction ending before [rawIndex] removes: everything before
  /// it except the transcript messages that survive it ([survivors]).
  int tokensBefore(int rawIndex, {Set<String> survivors = const {}}) {
    var n = 0;
    for (var j = 0; j < messages.length; j++) {
      if (raw[j] < rawIndex && !survivors.contains(messages[j].id)) n += counts[j];
    }
    return n;
  }

  List<Message> before(int rawIndex) => [
        for (var j = 0; j < messages.length; j++)
          if (raw[j] < rawIndex) messages[j],
      ];
}

/// Per-call working state: the request, derived limits and the overlays
/// recorded so far plus those created during this call.
final class _Pass {
  _Pass(this.manager, this.request)
      : overlays = [...request.overlays],
        now = manager._clock.now() {
    final caps = request.capabilities;
    final loc = request.location ?? manager.location;
    limit = manager.memoryPolicy.appliesTo(loc)
        ? manager.memoryPolicy.effectiveContextLength(caps.contextLength, request.memory)
        : caps.contextLength;
    final reserveSetting = settings.outputReserveTokens;
    reserve = caps.maxOutputTokens == null || caps.maxOutputTokens! > reserveSetting
        ? reserveSetting
        : caps.maxOutputTokens!;
    final fraction = WindowProfile.safetyFraction(
      counter,
      denseShare: _denseShare(),
      calibrated: settings.estimateSafetyFraction,
      uncalibrated: settings.uncalibratedSafetyFraction,
    );
    margin = counter.isExact ? 0 : (limit * fraction).round();
    final usable = (limit - reserve - margin).clamp(0, limit);
    final derived = settings.profile ??
        WindowProfile.forWindow(
          limit: limit,
          usableInput: usable,
          safetyMargin: margin,
          maxSummaryTokens: settings.maxSummaryTokens,
        );
    profile = manager.memoryPolicy.appliesTo(loc)
        ? derived.pruneEarlier(manager.memoryPolicy.pruneShift(request.memory))
        : derived;
    systemTokens = system == null ? 0 : counter.countText(system!);
    toolTokens = counter.countTools(tools);
    _index();
  }

  final LadderContextManager manager;
  final ContextRequest request;
  final List<ContextOverlay> overlays;
  final List<ContextOverlay> created = [];
  final DateTime now;
  late final int limit;
  late final int reserve;
  late final int margin;
  late final WindowProfile profile;
  late final int systemTokens;
  late final int toolTokens;
  final Map<Message, int> _counts = {};

  List<Message> get path => request.path;
  ContextSettings get settings => request.settings;
  TokenCounter get counter => request.counter;
  String? get system => request.systemPrompt;
  late final List<ToolDefinition> tools = request.tools.where((t) => t.modelVisible).toList();
  bool get appendOnly => request.capabilities.historyPolicy == HistoryPolicy.appendOnly;

  /// Segment rule: append-only models are rewritten only at a user turn.
  bool get canRewrite => !appendOnly || (path.isNotEmpty && isRealUserTurn(path.last));

  // Path analysis, computed once.
  final Map<String, ToolCall> _calls = {};
  late final List<int> _userTurnsAfter;
  late final String _currentTurnText;
  String? latestPlanCallId;
  List<ActiveRange> _active = const [];

  void _index() {
    final after = List.filled(path.length + 1, 0);
    for (var i = path.length - 1; i >= 0; i--) {
      after[i] = after[i + 1] + (isRealUserTurn(path[i]) ? 1 : 0);
    }
    // Turns strictly after message i.
    _userTurnsAfter = [for (var i = 0; i < path.length; i++) after[i + 1]];
    for (final m in path) {
      for (final c in m.toolCalls) {
        _calls[c.id] = c;
      }
      for (final r in m.toolResults) {
        if (r.toolName == UpdatePlanTool.toolName) latestPlanCallId = r.callId;
      }
    }
    final last = lastRealUserTurn(path);
    final b = StringBuffer();
    if (last >= 0) {
      b.writeln(path[last].text);
      for (final m in path.skip(last + 1)) {
        if (m.role == Role.assistant) b.writeln(m.text);
      }
    }
    _currentTurnText = b.toString();
    _active = activeCompactions(path, overlays);
  }

  double _denseShare() {
    final b = StringBuffer(system ?? '');
    for (final m in path.reversed) {
      if (b.length > 100000) break;
      for (final p in m.content) {
        if (p is TextPart) b.write(p.text);
        if (p is ToolResultPart) b.write(p.text);
      }
    }
    return HeuristicTokenCounter.denseShare(b.toString());
  }

  int userTurnsAfter(int i) => _userTurnsAfter[i];

  String? get firstUserText {
    for (final m in path) {
      if (isRealUserTurn(m) && m.text.trim().isNotEmpty) return clipText(m.text.trim(), CompactionSummary.maxTaskChars);
    }
    return null;
  }

  bool hidden(int i) => _active.any((r) => i >= r.from && i <= r.to);

  ActiveRange? get latestCompaction => _active.isEmpty ? null : _active.reduce((a, b) => a.to >= b.to ? a : b);

  bool hasPartOverlay(String messageId, int partIndex, {String? callId}) => overlays.any((o) => switch (o) {
        ToolOutputElided() => o.messageId == messageId && o.callId == callId,
        PayloadTruncated() => o.messageId == messageId && o.partIndex == partIndex,
        CompactedRange() => false,
      });

  /// Ids of the [n] most recent visible tool calls.
  Set<String> recentCallIds(int n) {
    final out = <String>{};
    for (var i = path.length - 1; i >= 0 && out.length < n; i--) {
      if (hidden(i)) continue;
      for (final c in path[i].toolCalls.reversed) {
        if (out.length < n) out.add(c.id);
      }
    }
    return out;
  }

  /// The current turn (latest user message and the assistant text after it)
  /// mentions the call id or a path/URL from the call's arguments.
  bool isReferenced(String callId) {
    if (_currentTurnText.isEmpty) return false;
    if (_currentTurnText.contains(callId)) return true;
    final call = _calls[callId];
    if (call == null) return false;
    return SummaryComposer.artifactsInJson(call.arguments).any((a) => a.length >= 4 && _currentTurnText.contains(a));
  }

  String nonce(CompactionSummary? previous) =>
      request.boundaryNonce ??
      previous?.nonce ??
      manager._nonces.putIfAbsent(request.sessionId, () => UntrustedData.newNonce(manager._random));

  void add(ContextOverlay o) {
    overlays.add(o);
    created.add(o);
  }

  /// Adds [candidates] oldest first until the ratio is at most [target].
  _View apply(_View view, List<ContextOverlay> candidates, {required double target}) {
    if (candidates.isEmpty) return view;
    final usable = view.budget.usableInput;
    var total = view.budget.inputTokens;
    var changed = false;
    for (final o in candidates) {
      if (usable > 0 && total / usable <= target) break;
      add(o);
      total -= o.tokensSaved;
      changed = true;
    }
    return changed ? render() : view;
  }

  _View render() {
    _active = activeCompactions(path, overlays);
    final key = PassthroughContextManager.prefixKeyOf(system, request.tools, overlays);
    var messages = PassthroughContextManager.applyOverlays(path, overlays);
    if (appendOnly) messages = PassthroughContextManager.stripStaleReasoning(messages, key);
    final (repaired, issues) = ToolPairing.repair(messages);
    final index = {for (final (i, m) in path.indexed) m.id: i};
    final rangeStart = {for (final r in _active) r.overlay.id: r.from};
    final raw = <int>[];
    final counts = <int>[];
    var pinned = 0;
    var history = 0;
    for (final m in repaired) {
      final n = _counts[m] ??= counter.countMessage(m);
      counts.add(n);
      raw.add(index[m.id] ??
          rangeStart['${m.metadata['overlayId']}'] ??
          index[m.id.replaceFirst('synthetic:results:', '')] ??
          path.length);
      if (m.pinned) {
        pinned += n;
      } else {
        history += n;
      }
    }
    return _View(
      messages: repaired,
      counts: counts,
      raw: raw,
      key: key,
      issues: issues,
      budget: ContextBudget(
        limit: limit,
        outputReserve: reserve,
        safetyMargin: margin,
        systemTokens: systemTokens,
        toolTokens: toolTokens,
        pinnedTokens: pinned,
        historyTokens: history,
        exact: counter.isExact,
      ),
    );
  }
}
