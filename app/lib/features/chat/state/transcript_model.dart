import 'package:flutter/foundation.dart';
import 'package:sherpa_core/sherpa_core.dart';

/// Position of a message among its siblings (branches created by edit or
/// retry), for the "‹ 2/3 ›" switcher.
@immutable
final class BranchInfo {
  const BranchInfo({required this.messageId, required this.index, required this.count});

  /// The message the switcher acts on.
  final String messageId;

  /// Zero-based position among siblings of the same role, oldest first.
  final int index;
  final int count;

  bool get hasSiblings => count > 1;
  bool get canGoBack => index > 0;
  bool get canGoForward => index < count - 1;

  @override
  bool operator ==(Object other) =>
      other is BranchInfo && other.messageId == messageId && other.index == index && other.count == count;

  @override
  int get hashCode => Object.hash(messageId, index, count);
}

/// One row of the transcript. Items are immutable and the controller reuses
/// the same instance while a message is unchanged, so widgets can be cached
/// by identity and finished messages never rebuild while a reply streams.
@immutable
sealed class ChatItem {
  const ChatItem();

  /// Stable widget key across rebuilds.
  String get key;

  /// Changes whenever anything the item renders changes.
  String get signature;
}

/// A message the user sent.
final class UserItem extends ChatItem {
  UserItem({required this.message, required this.branch})
      : signature = '${message.id}|${message.text.hashCode}|${branch.index}/${branch.count}';

  final Message message;
  final BranchInfo branch;

  @override
  final String signature;

  @override
  String get key => 'u:${message.id}';

  String get text => message.text;

  /// Set on messages created with "edit", so the bubble can say "Edited".
  bool get isEdit => message.metadata['editOf'] != null;
}

/// Optimistic stand-in for the message being sent, shown until the runner
/// has persisted the real one (a few microtasks later).
final class PendingUserItem extends ChatItem {
  PendingUserItem(this.text) : signature = 'pending|${text.hashCode}';

  final String text;

  @override
  final String signature;

  @override
  String get key => 'u:pending';
}

/// Everything the assistant did between two user messages: every model step
/// (reasoning, text, tool calls) with tool results folded into their calls.
final class AssistantTurnItem extends ChatItem {
  AssistantTurnItem({
    required this.key,
    required this.steps,
    required this.blocks,
    required this.branch,
    required this.live,
    required this.showActions,
  }) : signature = _signatureOf(key, steps, blocks, branch, live, showActions);

  @override
  final String key;

  /// The assistant messages of this turn, in order.
  final List<Message> steps;
  final List<TurnBlock> blocks;

  /// Siblings of the first step: retries of this turn.
  final BranchInfo? branch;

  /// A run is producing this turn right now; the live draft renders at its
  /// end and the action row is hidden.
  final bool live;

  /// Copy/share/retry are offered on finished turns only.
  final bool showActions;

  @override
  final String signature;

  String? get firstMessageId => steps.isEmpty ? null : steps.first.id;

  /// Text the user sees as "the reply": every text block of the turn.
  String get copyText => blocks.whereType<TextBlock>().map((b) => b.text.trim()).where((t) => t.isNotEmpty).join('\n\n');

  /// Model of the final step, for the per-turn model label.
  String? get modelId => steps.isEmpty ? null : steps.last.modelId;

  /// Error recorded on a partially streamed reply that failed.
  String? get errorText {
    final e = steps.isEmpty ? null : steps.last.metadata['error'];
    return e is String ? e : null;
  }

  /// The reply was cut off by the user or the token limit.
  String? get finishReason => steps.isEmpty ? null : steps.last.finishReason;

  static String _signatureOf(
    String key,
    List<Message> steps,
    List<TurnBlock> blocks,
    BranchInfo? branch,
    bool live,
    bool showActions,
  ) {
    final b = StringBuffer('$key|$live|$showActions|${branch?.index}/${branch?.count}');
    for (final m in steps) {
      b.write('|${m.id}:${m.content.length}:${m.finishReason}:${m.text.length}:${m.metadata['reasoningMs']}');
    }
    b.write('|${blocks.length}');
    return b.toString();
  }
}

/// A displayable piece of an assistant turn.
@immutable
sealed class TurnBlock {
  const TurnBlock();
  String get key;
}

final class ReasoningBlock extends TurnBlock {
  const ReasoningBlock({
    required this.key,
    required this.messageId,
    required this.text,
    this.redacted = false,
    this.duration,
  });

  @override
  final String key;
  final String messageId;
  final String text;

  /// Encrypted reasoning: the header shows, the body has nothing to read.
  final bool redacted;

  /// Known for replies streamed on this device (persisted as a client hint).
  final Duration? duration;
}

final class TextBlock extends TurnBlock {
  const TextBlock({required this.key, required this.messageId, required this.text});

  @override
  final String key;
  final String messageId;
  final String text;
}

/// Consecutive tool calls with nothing visible between them, rendered as
/// one "Ran 3 tools" group (a single call renders as a plain card).
final class ToolGroupBlock extends TurnBlock {
  const ToolGroupBlock({required this.key, required this.calls});

  @override
  final String key;
  final List<ToolCall> calls;
}

/// Lifecycle of one tool call as the user sees it.
enum ToolRunStatus {
  /// Arguments still streaming from the model.
  preparing,

  /// Waiting its turn (approval of an earlier call, or the parallel pool).
  pending,
  awaitingApproval,
  running,
  succeeded,
  failed,
  denied,
  cancelled,
}

extension ToolRunStatusX on ToolRunStatus {
  bool get isActive =>
      this == ToolRunStatus.preparing ||
      this == ToolRunStatus.pending ||
      this == ToolRunStatus.awaitingApproval ||
      this == ToolRunStatus.running;

  bool get isProblem => this == ToolRunStatus.failed;
}

/// Execution state of one tool call.
@immutable
final class ToolExecutionView {
  const ToolExecutionView({
    required this.callId,
    required this.toolName,
    required this.displayName,
    required this.status,
    this.sourceLabel,
    this.progress,
    this.progressMessage,
    this.startedAt,
    this.duration,
    this.resultText,
    this.structured,
    this.errorText,
  });

  final String callId;
  final String toolName;
  final String displayName;
  final ToolRunStatus status;
  final String? sourceLabel;

  /// 0..1 when the tool reports a total; null for indeterminate progress.
  final double? progress;
  final String? progressMessage;
  final DateTime? startedAt;
  final Duration? duration;
  final String? resultText;
  final JsonMap? structured;
  final String? errorText;

  ToolExecutionView copyWith({
    ToolRunStatus? status,
    double? progress,
    String? progressMessage,
    DateTime? startedAt,
  }) =>
      ToolExecutionView(
        callId: callId,
        toolName: toolName,
        displayName: displayName,
        status: status ?? this.status,
        sourceLabel: sourceLabel,
        progress: progress ?? this.progress,
        progressMessage: progressMessage ?? this.progressMessage,
        startedAt: startedAt ?? this.startedAt,
        duration: duration,
        resultText: resultText,
        structured: structured,
        errorText: errorText,
      );

  bool sameAs(ToolExecutionView o) =>
      o.callId == callId &&
      o.status == status &&
      o.progress == progress &&
      o.progressMessage == progressMessage &&
      o.duration == duration &&
      o.resultText == resultText &&
      o.errorText == errorText &&
      o.displayName == displayName;
}

/// Prefixes of the error results `AgentRunner` writes for calls that never
/// ran. Results carry no structured "denied" flag, so the transcript is the
/// only durable record; keep these in sync with agent_runner.dart.
const String _declinedPrefix = 'The user declined';
const String _cancelledPrefix = 'Cancelled by the user';

/// Builds display items from the active path.
///
/// Pure and synchronous: [siblings] maps a parent id to its non-draft
/// children (oldest first) and must already contain every parent on the
/// path that the caller wants branch counts for; missing entries count as
/// "no siblings". [previous] items with an identical signature are reused
/// so widget caches keyed by identity stay valid.
List<ChatItem> buildTranscriptItems({
  required List<Message> path,
  required Map<String?, List<Message>> siblings,
  required bool runActive,
  required List<ChatItem> previous,
  String? pendingUserText,
}) {
  final old = {for (final i in previous) i.key: i};
  T reuse<T extends ChatItem>(T fresh) {
    final o = old[fresh.key];
    return o is T && o.signature == fresh.signature ? o : fresh;
  }

  BranchInfo branchOf(Message m) {
    final sibs = (siblings[m.parentId] ?? const <Message>[]).where((s) => s.role == m.role).toList();
    final index = sibs.indexWhere((s) => s.id == m.id);
    return BranchInfo(messageId: m.id, index: index < 0 ? 0 : index, count: index < 0 ? 1 : sibs.length);
  }

  final items = <ChatItem>[];
  var i = 0;
  while (i < path.length) {
    final m = path[i];
    if (m.role == Role.system) {
      i++;
      continue;
    }
    if (m.role == Role.user) {
      items.add(reuse(UserItem(message: m, branch: branchOf(m))));
      i++;
      continue;
    }
    final turnKey = 'turn:${m.parentId ?? 'root'}';
    final steps = <Message>[];
    while (i < path.length && path[i].role != Role.user) {
      if (path[i].role == Role.assistant) steps.add(path[i]);
      i++;
    }
    items.add(AssistantTurnItem(
      key: turnKey,
      steps: steps,
      blocks: buildTurnBlocks(steps),
      branch: steps.isEmpty ? null : branchOf(steps.first),
      live: false,
      showActions: steps.isNotEmpty,
    ));
  }

  if (pendingUserText != null) items.add(PendingUserItem(pendingUserText));

  if (runActive) {
    final last = items.isEmpty ? null : items.last;
    if (last is AssistantTurnItem) {
      items[items.length - 1] = AssistantTurnItem(
        key: last.key,
        steps: last.steps,
        blocks: last.blocks,
        branch: last.branch,
        live: true,
        showActions: false,
      );
    } else {
      final anchor = pendingUserText != null ? 'pending' : (path.isEmpty ? 'root' : path.last.id);
      items.add(AssistantTurnItem(
        key: 'turn:$anchor',
        steps: const [],
        blocks: const [],
        branch: null,
        live: true,
        showActions: false,
      ));
    }
  }

  return [for (final item in items) item is AssistantTurnItem ? reuse(item) : item];
}

/// Flattens a turn's steps into display blocks, merging adjacent text or
/// reasoning of one message and grouping consecutive tool calls across
/// steps (nothing visible between them → one group).
List<TurnBlock> buildTurnBlocks(List<Message> steps) {
  final blocks = <TurnBlock>[];
  for (final m in steps) {
    final ms = m.metadata['reasoningMs'];
    final duration = ms is num ? Duration(milliseconds: ms.round()) : null;
    for (final (pi, part) in m.content.indexed) {
      final last = blocks.isEmpty ? null : blocks.last;
      switch (part) {
        case ReasoningPart(:final text, :final isRedacted):
          if (text.isEmpty && !isRedacted) continue;
          if (last is ReasoningBlock && last.messageId == m.id) {
            blocks[blocks.length - 1] = ReasoningBlock(
              key: last.key,
              messageId: m.id,
              text: last.text.isEmpty ? text : (text.isEmpty ? last.text : '${last.text}\n\n$text'),
              redacted: last.redacted && isRedacted,
              duration: duration,
            );
          } else {
            blocks.add(ReasoningBlock(
              key: 'r:${m.id}:$pi',
              messageId: m.id,
              text: text,
              redacted: isRedacted && text.isEmpty,
              duration: duration,
            ));
          }
        case TextPart(:final text):
          if (text.trim().isEmpty) continue;
          if (last is TextBlock && last.messageId == m.id) {
            blocks[blocks.length - 1] = TextBlock(key: last.key, messageId: m.id, text: last.text + text);
          } else {
            blocks.add(TextBlock(key: 't:${m.id}:$pi', messageId: m.id, text: text));
          }
        case ToolCallPart(:final call):
          if (last is ToolGroupBlock) {
            blocks[blocks.length - 1] = ToolGroupBlock(key: last.key, calls: [...last.calls, call]);
          } else {
            blocks.add(ToolGroupBlock(key: 'g:${call.id}', calls: [call]));
          }
        default:
          // Images, resources and MCP Apps views arrive in later milestones.
          continue;
      }
    }
  }
  return blocks;
}

/// Reconstructs finished tool executions from the tool messages on [path].
/// Calls without a result yet are left to the live event stream.
Map<String, ToolExecutionView> toolViewsFromPath(
  List<Message> path, {
  required ToolDefinition? Function(String name) lookup,
  String Function(ToolSource? source)? sourceLabel,
  Map<String, ToolExecutionView> previous = const {},
}) {
  final out = <String, ToolExecutionView>{};
  for (final m in path) {
    if (m.role != Role.tool) continue;
    for (final r in m.toolResults) {
      // A proxied call (`call_tool`) names the tool that actually ran.
      final target = r.meta[ToolResultPart.metaTool];
      final def = target is String ? lookup(target) : lookup(r.toolName);
      final text = r.text;
      final status = !r.isError
          ? ToolRunStatus.succeeded
          : text.startsWith(_declinedPrefix)
              ? ToolRunStatus.denied
              : text.startsWith(_cancelledPrefix)
                  ? ToolRunStatus.cancelled
                  : ToolRunStatus.failed;
      final view = ToolExecutionView(
        callId: r.callId,
        toolName: r.toolName,
        displayName: def?.displayName ?? (target is String ? target : r.toolName),
        sourceLabel: sourceLabel?.call(def?.source),
        status: status,
        duration: r.durationMs == null ? null : Duration(milliseconds: r.durationMs!),
        resultText: r.isError ? null : text,
        structured: r.structured,
        errorText: r.isError ? text : null,
      );
      final prev = previous[r.callId];
      out[r.callId] = prev != null && prev.sameAs(view) ? prev : view;
    }
  }
  return out;
}
