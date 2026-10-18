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
  });

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
