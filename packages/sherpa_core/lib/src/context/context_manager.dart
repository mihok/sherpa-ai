import 'package:meta/meta.dart';

import '../common/cancellation.dart';
import '../memory/memory_monitor.dart';
import '../model/message.dart';
import '../model/tool.dart';
import '../provider/capabilities.dart';
import '../provider/model_provider.dart';
import '../session/plan.dart';
import 'budget.dart';
import 'overlay.dart';
import 'window_profile.dart';

@immutable
final class ContextSettings {
  const ContextSettings({
    this.thresholds = const ContextThresholds(),
    this.keepRecentTurns = 4,
    this.outputReserveTokens = 2048,
    this.estimateSafetyFraction = 0.10,
    this.largeToolResultTokens = 1500,
    this.staleAfterTurns = 2,
    this.autoCompact = true,
    this.autoHandoff = false,
    this.profile,
    this.uncalibratedSafetyFraction = 0.20,
    this.keepRecentToolCalls = 3,
    this.smallErrorResultTokens = 300,
    this.largeToolInputTokens = 1000,
    this.excludedTools = const <String>{},
    this.maxSummaryTokens = 1024,
    this.elideKeepLines = 5,
    this.handoffAfterCompactions = 3,
    this.minCompactionGain = 0.20,
    this.maxPostCompactionRatio = 0.60,
  });

  /// Used by `PassthroughContextManager`. `LadderContextManager` derives
  /// window-scaled thresholds instead (R11 §9.2) unless [profile] is set.
  final ContextThresholds thresholds;

  /// Most recent user turns (and everything after the oldest of them) kept
  /// verbatim by compaction.
  final int keepRecentTurns;
  final int outputReserveTokens;

  /// Margin added when counts are estimated (no native tokenizer).
  final double estimateSafetyFraction;

  /// Tool results above this size are candidates for elision/truncation.
  final int largeToolResultTokens;

  /// A tool result is stale once this many user turns have passed since it.
  final int staleAfterTurns;
  final bool autoCompact;

  /// When false the manager proposes a handoff instead of performing it.
  final bool autoHandoff;

  /// Overrides the window-scaled ladder parameters (thresholds, kept user
  /// turns, kept-tail cap) that `LadderContextManager` would derive from
  /// the R11 §9.2 table. Null = derive from the model window.
  final WindowProfile? profile;

  /// Margin while a heuristic counter has fewer than 3 calibrations or the
  /// context is > 25% dense script; [estimateSafetyFraction] applies after.
  final double uncalibratedSafetyFraction;

  /// Results of this many most recent tool calls are never elided
  /// (Anthropic `keep=3`, Gemini `RECENT_TURNS_PROTECTED=3`).
  final int keepRecentToolCalls;

  /// Error results smaller than this are never elided: they are cheap and
  /// tell the model what not to try again.
  final int smallErrorResultTokens;

  /// Tool-call arguments above this size (e.g. file-write bodies) are
  /// cleared in stage 2, keeping keys and `argsDigest`.
  final int largeToolInputTokens;

  /// Tools whose results are never elided or truncated before compaction
  /// (by analogy with Gemini's retrieval-tool exemption). Pinning a message
  /// protects it from everything.
  final Set<String> excludedTools;

  /// Output budget of a model-written summary; also enters the compact
  /// trigger formula.
  final int maxSummaryTokens;

  /// Lines kept at each end of an elided tool result.
  final int elideKeepLines;

  /// Recommend a handoff once this many compactions accumulated (summaries
  /// lose detail each time; Codex warns after repeated compaction).
  final int handoffAfterCompactions;

  /// Recommend a handoff when a compaction frees less than this share of W.
  final double minCompactionGain;

  /// Recommend a handoff when the ratio after compaction is above this.
  final double maxPostCompactionRatio;
}

/// Everything the context manager needs for one model call.
@immutable
final class ContextRequest {
  const ContextRequest({
    required this.sessionId,
    required this.path,
    required this.overlays,
    required this.tools,
    required this.capabilities,
    required this.counter,
    this.systemPrompt,
    this.plan,
    this.memory = MemoryState.unknown,
    this.settings = const ContextSettings(),
    this.cancel,
    this.boundaryNonce,
    this.location,
  });

  final String sessionId;

  /// Pinned plan/task; the manager decides where it is placed so it can
  /// trade freshness against prompt-cache stability.
  final Plan? plan;

  /// Active branch of the transcript, root → leaf, unmodified.
  final List<Message> path;

  /// Overlays already recorded for this session.
  final List<ContextOverlay> overlays;
  final String? systemPrompt;
  final List<ToolDefinition> tools;
  final ModelCapabilities capabilities;
  final TokenCounter counter;
  final MemoryState memory;
  final ContextSettings settings;
  final CancellationToken? cancel;

  /// Per-session random nonce for the untrusted-data wrapper in summaries
  /// (R11 §9.7). Null lets the context manager pick one per session; it is
  /// then persisted inside the summary it renders.
  final String? boundaryNonce;

  /// Where the model runs; memory pressure only shrinks on-device windows.
  /// Null falls back to the context manager's configured location.
  final ExecutionLocation? location;
}

/// What the model should be sent, plus how we got there.
@immutable
final class PreparedContext {
  const PreparedContext({
    required this.messages,
    required this.tools,
    required this.budget,
    required this.level,
    this.systemPrompt,
    this.newOverlays = const [],
    this.recommendation,
    this.prefixKey,
  });

  final String? systemPrompt;
  final List<Message> messages;
  final List<ToolDefinition> tools;
  final ContextBudget budget;
  final ContextLevel level;

  /// Overlays created during this preparation; the caller persists them.
  final List<ContextOverlay> newOverlays;

  /// Set when the manager could not make the call fit by itself.
  final ContextRecommendation? recommendation;

  /// Fingerprint of everything before the conversation messages (system
  /// prompt, tool schemas, applied overlays). The runner stamps it on the
  /// assistant reply so reasoning can later be replayed only under the
  /// same prefix.
  final String? prefixKey;
}

enum ContextRecommendationKind { handoff, hardStop }

@immutable
final class ContextRecommendation {
  const ContextRecommendation(this.kind, this.message);
  final ContextRecommendationKind kind;
  final String message;
}

/// Thrown instead of silently overflowing the window.
final class ContextOverflowException implements Exception {
  const ContextOverflowException(this.budget, this.message);
  final ContextBudget budget;
  final String message;

  @override
  String toString() => 'ContextOverflowException: $message';
}

abstract interface class ContextManager {
  Future<PreparedContext> prepare(ContextRequest request);
}
