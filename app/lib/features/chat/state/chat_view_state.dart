import 'package:flutter/foundation.dart';
import 'package:sherpa_core/sherpa_core.dart';

import 'chat_errors.dart';
import 'model_selection.dart';
import 'transcript_model.dart';

/// Where the chat's current (or last) run is.
///
/// `error` and `cancelled` describe how the *last* run ended; the composer is
/// usable again in both. Only [isActive] states show the Stop button.
enum ChatRunStatus { idle, streaming, runningTools, awaitingApproval, error, cancelled }

extension ChatRunStatusX on ChatRunStatus {
  /// A run is in flight: Stop must be visible and sending is blocked.
  bool get isActive =>
      this == ChatRunStatus.streaming ||
      this == ChatRunStatus.runningTools ||
      this == ChatRunStatus.awaitingApproval;
}

/// Whether the chat can talk to a model at all, and if not, why.
enum ProviderAvailability {
  /// Still resolving the session's provider.
  loading,
  ready,

  /// No provider is configured anywhere: the composer explains and links to
  /// provider setup.
  noProviders,

  /// Providers exist (or models on this phone, [ChatViewState.onDeviceModels])
  /// but neither the chat nor the defaults name a model.
  needsModel,

  /// The chat names a provider that was removed or can't be built.
  providerMissing,
}

/// The assistant message currently being streamed, rebuilt at most once
/// per frame from coalesced `ModelStreamed` deltas.
@immutable
final class LiveDraft {
  const LiveDraft({
    required this.messageId,
    this.text = '',
    this.reasoning = '',
    this.reasoningRedacted = false,
    this.reasoningStartedAt,
    this.reasoningDuration,
    this.toolCalls = const [],
  });

  final String messageId;
  final String text;
  final String reasoning;

  /// The provider sent an encrypted reasoning block: there is nothing to
  /// read, but the user should still see that the model was thinking.
  final bool reasoningRedacted;
  final DateTime? reasoningStartedAt;

  /// Null while the model is still reasoning; set once text or a tool call
  /// starts, which flips the header from "Thinking…" to "Thought for Ns".
  final Duration? reasoningDuration;
  final List<ToolCallDraft> toolCalls;

  bool get hasReasoning => reasoning.isNotEmpty || reasoningRedacted;
  bool get isThinking => hasReasoning && reasoningDuration == null;
  bool get isEmpty => text.isEmpty && !hasReasoning && toolCalls.isEmpty;

  /// Cheap growth measure for "new content below" tracking.
  int get contentLength =>
      text.length + reasoning.length + toolCalls.fold(0, (n, c) => n + c.argsText.length + 1);
}

/// A tool call whose arguments are still streaming in.
@immutable
final class ToolCallDraft {
  const ToolCallDraft({
    required this.index,
    required this.id,
    required this.name,
    this.argsText = '',
    this.complete = false,
  });

  final int index;
  final String id;
  final String name;

  /// Raw JSON fragments received so far (not yet parseable).
  final String argsText;
  final bool complete;
}

/// A tool call that needs the user's decision before it may run.
///
/// For a proxied call (MCP `call_tool`) the runner resolves the target
/// first: [call] is the target call (its name and arguments) and [tool] the
/// target's definition, so the card names the tool and server that would
/// actually run, never the proxy.
@immutable
final class PendingApproval {
  const PendingApproval({
    required this.call,
    required this.tool,
    required this.risk,
    required this.reason,
    required this.requestedAt,
    this.oneOffOnly = false,
    this.allowedScopes = ApprovalScope.values,
  });

  /// The card for [requirement], as the core policy decided it.
  factory PendingApproval.of({
    required ToolCall call,
    required ToolDefinition? tool,
    required NeedsConfirmation requirement,
    required DateTime requestedAt,
  }) =>
      PendingApproval(
        call: call,
        tool: tool,
        risk: requirement.risk,
        reason: requirement.reason,
        requestedAt: requestedAt,
        oneOffOnly: requirement.oneOffOnly,
        allowedScopes: requirement.allowedScopes,
      );

  final ToolCall call;
  final ToolDefinition? tool;
  final RiskLevel risk;
  final String reason;
  final DateTime requestedAt;

  /// The call was repaired or its tool name corrected: only "Deny" and
  /// "Allow once" are possible, and nothing is remembered.
  final bool oneOffOnly;

  /// The grants the card may offer for "allow" ([NeedsConfirmation.allowedScopes]):
  /// never "always" for a destructive tool or one from an untrusted server
  /// (it counts as destructive), only "once" for [oneOffOnly].
  final List<ApprovalScope> allowedScopes;

  String get toolDisplayName => tool?.displayName ?? call.name;

  /// "Built-in" for Sherpa's own tools, otherwise the server's name.
  String get sourceLabel => sourceLabelOf(tool?.source);

  /// "Allow for this chat" may be offered.
  bool get offersSession => !oneOffOnly && allowedScopes.contains(ApprovalScope.session);

  /// "Always allow" may be offered.
  bool get offersAlways => !oneOffOnly && allowedScopes.contains(ApprovalScope.always);

  /// The tool says it is not destructive, but its server isn't trusted, so
  /// the policy treats it as destructive (and never offers "always").
  bool get untrustedSource =>
      tool != null &&
      tool!.source.kind != ToolSourceKind.builtin &&
      risk == RiskLevel.destructive &&
      ApprovalPolicy.riskOf(tool!) != RiskLevel.destructive;
}

String sourceLabelOf(ToolSource? source) {
  if (source == null) return 'Unknown source';
  return switch (source.kind) {
    ToolSourceKind.builtin => 'Built-in',
    ToolSourceKind.onDevice => source.serverName ?? 'On-device tool',
    ToolSourceKind.mcp => source.serverName ?? source.serverId ?? 'MCP server',
  };
}

/// A non-error event worth showing inline in the transcript.
enum ChatNoticeKind { progress, info, warning }

/// What an inline notice can offer.
enum ChatNoticeAction { continueRun, handOff }

@immutable
final class ChatNotice {
  const ChatNotice({
    required this.code,
    required this.message,
    this.kind = ChatNoticeKind.info,
    this.action,
    this.dismissible = false,
  });

  /// `retrying`, `handoff_recommended`, `tool_rerun`, `stopped`,
  /// `max_steps`, `truncated`, `untrusted_content`, `tool_call_truncated`,
  /// `tool_interrupted`, … (RunNotice codes, provider notice codes such as
  /// `tool_args_truncated`, plus UI-owned ones).
  final String code;
  final String message;
  final ChatNoticeKind kind;
  final ChatNoticeAction? action;

  /// Shows a close button: for information the user may want to read once
  /// and put away (a cut-off tool call, untrusted content in the chat).
  final bool dismissible;
}

/// A run that was interrupted (process death, crash) and can be resumed.
@immutable
final class InterruptedRun {
  const InterruptedRun({required this.phase, required this.updatedAt});

  final RunPhase phase;
  final DateTime updatedAt;

  /// Resuming an approval phase re-asks: approvals are never auto-granted.
  bool get wasAwaitingApproval => phase == RunPhase.awaitingApproval;
}

/// A one-shot request for the transcript to move its scroll position.
enum ChatScrollKind {
  /// Pin to the newest content.
  bottom,

  /// Show the start of the live region (used after a branch switch so the
  /// user lands on the alternative they picked, not at its far end).
  revealLive,
}

@immutable
final class ChatScrollRequest {
  const ChatScrollRequest(this.id, this.kind);
  final int id;
  final ChatScrollKind kind;
}

const Object _keep = Object();

/// Everything the chat UI renders, as one immutable value.
///
/// Widgets subscribe to *slices* of it with `select`, and the controller
/// reuses unchanged instances (items, tool views) across updates, so a
/// streaming frame only rebuilds the live draft, never finished messages.
@immutable
final class ChatViewState {
  const ChatViewState({
    required this.sessionId,
    this.loading = true,
    this.title = '',
    this.availability = ProviderAvailability.loading,
    this.model,
    this.items = const [],
    this.historyCount = 0,
    this.pendingUserText,
    this.draft,
    this.tools = const {},
    this.pendingApproval,
    this.status = ChatRunStatus.idle,
    this.lastOutcome,
    this.budget,
    this.contextLevel,
    this.budgetIsEstimate = false,
    this.notices = const [],
    this.error,
    this.interrupted,
    this.scrollRequest,
    this.onDeviceModels = 0,
  });

  final String sessionId;
  final bool loading;
  final String title;
  final ProviderAvailability availability;
  final ModelSelection? model;

  /// The active branch, root → leaf, grouped for display: user messages and
  /// assistant turns (all steps between two user messages, with tool results
  /// folded into their calls).
  final List<ChatItem> items;

  /// `items[0, historyCount)` render above the scroll view's center key and
  /// grow upward; the rest render below it and grow downward. Moving the
  /// boundary only happens at structural changes, so streaming never shifts
  /// what a reader scrolled up to.
  final int historyCount;

  /// Shown immediately on send, before the runner has persisted the message.
  final String? pendingUserText;
  final LiveDraft? draft;

  /// Execution state per tool call id (live and reconstructed from results).
  final Map<String, ToolExecutionView> tools;
  final PendingApproval? pendingApproval;
  final ChatRunStatus status;

  /// How the last run in this controller's lifetime ended (drives the
  /// "Response complete" announcement); null before any run.
  final RunOutcome? lastOutcome;
  final ContextBudget? budget;
  final ContextLevel? contextLevel;

  /// True while [budget] is our own estimate rather than the runner's.
  final bool budgetIsEstimate;
  final List<ChatNotice> notices;
  final ChatError? error;
  final InterruptedRun? interrupted;
  final ChatScrollRequest? scrollRequest;

  /// Models installed on this phone, counted while the chat has no model
  /// yet: with no provider configured they still make the chat usable
  /// ([ProviderAvailability.needsModel] rather than `noProviders`).
  final int onDeviceModels;

  bool get isRunActive => status.isActive;
  bool get canSend => availability == ProviderAvailability.ready && !isRunActive && !loading;

  /// The live (below-center) part of [items].
  List<ChatItem> get liveItems => items.sublist(historyCount.clamp(0, items.length));

  /// Name of a tool that is executing right now, for the status line.
  String? get runningToolName {
    for (final t in tools.values) {
      if (t.status == ToolRunStatus.running) return t.displayName;
    }
    return null;
  }

  ChatViewState copyWith({
    bool? loading,
    String? title,
    ProviderAvailability? availability,
    Object? model = _keep,
    List<ChatItem>? items,
    int? historyCount,
    Object? pendingUserText = _keep,
    Object? draft = _keep,
    Map<String, ToolExecutionView>? tools,
    Object? pendingApproval = _keep,
    ChatRunStatus? status,
    Object? lastOutcome = _keep,
    Object? budget = _keep,
    Object? contextLevel = _keep,
    bool? budgetIsEstimate,
    List<ChatNotice>? notices,
    Object? error = _keep,
    Object? interrupted = _keep,
    Object? scrollRequest = _keep,
    int? onDeviceModels,
  }) =>
      ChatViewState(
        sessionId: sessionId,
        loading: loading ?? this.loading,
        title: title ?? this.title,
        availability: availability ?? this.availability,
        model: identical(model, _keep) ? this.model : model as ModelSelection?,
        items: items ?? this.items,
        historyCount: historyCount ?? this.historyCount,
        pendingUserText:
            identical(pendingUserText, _keep) ? this.pendingUserText : pendingUserText as String?,
        draft: identical(draft, _keep) ? this.draft : draft as LiveDraft?,
        tools: tools ?? this.tools,
        pendingApproval:
            identical(pendingApproval, _keep) ? this.pendingApproval : pendingApproval as PendingApproval?,
        status: status ?? this.status,
        lastOutcome: identical(lastOutcome, _keep) ? this.lastOutcome : lastOutcome as RunOutcome?,
        budget: identical(budget, _keep) ? this.budget : budget as ContextBudget?,
        contextLevel: identical(contextLevel, _keep) ? this.contextLevel : contextLevel as ContextLevel?,
        budgetIsEstimate: budgetIsEstimate ?? this.budgetIsEstimate,
        notices: notices ?? this.notices,
        error: identical(error, _keep) ? this.error : error as ChatError?,
        interrupted: identical(interrupted, _keep) ? this.interrupted : interrupted as InterruptedRun?,
        scrollRequest:
            identical(scrollRequest, _keep) ? this.scrollRequest : scrollRequest as ChatScrollRequest?,
        onDeviceModels: onDeviceModels ?? this.onDeviceModels,
      );
}
