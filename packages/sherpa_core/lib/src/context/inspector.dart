import 'dart:convert';

import 'package:meta/meta.dart';

import '../model/content.dart';
import '../model/message.dart';
import '../provider/model_provider.dart';
import 'budget.dart';
import 'overlay.dart';
import 'pairing.dart';
import 'part_rewrite.dart';
import 'passthrough_context_manager.dart';
import 'turns.dart';
import 'window_profile.dart';

/// Where an item of the model-facing view came from.
enum ContextItemSource {
  /// A transcript message sent unchanged.
  transcript,

  /// A transcript message with parts elided/truncated or reasoning dropped.
  edited,

  /// A compaction summary (or its fixed acknowledgement).
  summary,

  /// Synthesized by pairing repair (`not executed: context was compacted`).
  synthetic,
}

/// One message exactly as the model would see it.
@immutable
final class InspectedItem {
  const InspectedItem({
    required this.message,
    required this.tokens,
    required this.source,
    this.overlayIds = const [],
  });

  final Message message;
  final int tokens;
  final ContextItemSource source;

  /// Overlays that produced or edited this item.
  final List<String> overlayIds;
}

enum ContextDiffKind { elision, truncation, compaction }

enum OverlayStatus {
  /// Applied to the current view.
  active,

  /// Recorded, but its target is inside an active compaction.
  shadowed,

  /// Not applicable here: target not on this branch, missing, or pinned.
  inactive,
}

/// What one overlay changed, for the "what the model sees" screen, its
/// reason line, a before/after diff and one-tap undo.
@immutable
final class ContextDiff {
  const ContextDiff({
    required this.overlayId,
    required this.kind,
    required this.reason,
    required this.createdAt,
    required this.status,
    required this.messageIds,
    required this.after,
    required this.tokensBefore,
    required this.tokensAfter,
    required this.recordedTokensSaved,
    this.before,
    this.callId,
    this.partIndex,
    this.shadowedBy,
    this.strategyId,
    this.dependents = const [],
  });

  final String overlayId;
  final ContextDiffKind kind;
  final String reason;
  final DateTime createdAt;
  final OverlayStatus status;

  /// Transcript messages dropped (compaction) or edited (elision/truncation).
  final List<String> messageIds;

  /// The original payload (null for compactions: see [messageIds]).
  final String? before;

  /// The replacement the model sees instead.
  final String after;
  final int tokensBefore;
  final int tokensAfter;

  /// What the overlay recorded when it was created.
  final int recordedTokensSaved;
  final String? callId;
  final int? partIndex;

  /// The active compaction hiding this overlay's target.
  final String? shadowedBy;
  final String? strategyId;

  /// Overlays built on top of this one (later compactions that integrated
  /// its summary). Undoing this overlay should also undo them.
  final List<String> dependents;

  int get tokensSaved => tokensBefore - tokensAfter;
}

/// The model-facing view plus per-overlay diffs. Pure data: building it
/// never calls a model or writes anything.
@immutable
final class ContextInspection {
  const ContextInspection({
    required this.items,
    required this.systemPrompt,
    required this.systemTokens,
    required this.toolTokens,
    required this.budget,
    required this.level,
    required this.prefixKey,
    required this.profile,
    required this.diffs,
    this.pairingIssues = const [],
  });

  final List<InspectedItem> items;
  final String? systemPrompt;
  final int systemTokens;
  final int toolTokens;
  final ContextBudget budget;
  final ContextLevel level;
  final String prefixKey;
  final WindowProfile profile;
  final List<ContextDiff> diffs;

  /// Problems the view had before pairing repair (should be empty).
  final List<PairingIssue> pairingIssues;

  List<Message> get messages => [for (final i in items) i.message];

  ContextDiff? diffFor(String overlayId) => diffs.where((d) => d.overlayId == overlayId).firstOrNull;

  /// Overlays to remove together for "undo [overlayId]": the overlay and
  /// everything built on it. Undoing a rolling compaction restores the
  /// previous one; undoing the first restores the verbatim turns.
  List<String> undoSet(String overlayId) {
    final out = <String>[overlayId];
    for (var i = 0; i < out.length; i++) {
      for (final d in diffFor(out[i])?.dependents ?? const <String>[]) {
        if (!out.contains(d)) out.add(d);
      }
    }
    return out;
  }
}

/// Builds [ContextDiff]s for the recorded overlays of one path.
abstract final class ContextDiffs {
  static List<ContextDiff> build({
    required List<Message> path,
    required List<ContextOverlay> overlays,
    required TokenCounter counter,
  }) {
    final index = {for (final (i, m) in path.indexed) m.id: i};
    final active = activeCompactions(path, overlays);
    String? coveringRange(int i) {
      for (final r in active) {
        if (i >= r.from && i <= r.to) return r.overlay.id;
      }
      return null;
    }

    return [
      for (final o in overlays)
        switch (o) {
          ToolOutputElided() => _partDiff(o, path, index, counter, coveringRange,
              kind: ContextDiffKind.elision, callId: o.callId, replacement: o.stub),
          PayloadTruncated() => _partDiff(o, path, index, counter, coveringRange,
              kind: ContextDiffKind.truncation, partIndex: o.partIndex, replacement: o.replacement),
          CompactedRange() => _rangeDiff(o, path, index, counter, active, overlays),
        },
    ];
  }

  static ContextDiff _partDiff(
    ContextOverlay o,
    List<Message> path,
    Map<String, int> index,
    TokenCounter counter,
    String? Function(int) coveringRange, {
    required ContextDiffKind kind,
    required String replacement,
    String? callId,
    int? partIndex,
  }) {
    final messageId = switch (o) {
      ToolOutputElided(:final messageId) || PayloadTruncated(:final messageId) => messageId,
      _ => '',
    };
    final i = index[messageId];
    final message = i == null ? null : path[i];
    final pi = message == null
        ? -1
        : (partIndex ?? message.content.indexWhere((p) => p is ToolResultPart && p.callId == callId));
    final part = message == null || pi < 0 || pi >= message.content.length ? null : message.content[pi];
    final covering = i == null ? null : coveringRange(i);
    final status = part == null || message!.pinned
        ? OverlayStatus.inactive
        : (covering != null ? OverlayStatus.shadowed : OverlayStatus.active);
    final edited = part == null ? null : PartRewrite.replacePayload(part, replacement);
    return ContextDiff(
      overlayId: o.id,
      kind: kind,
      reason: o.reason,
      createdAt: o.createdAt,
      status: status,
      messageIds: [messageId],
      before: part == null ? null : payloadText(part),
      after: replacement,
      tokensBefore: part == null ? 0 : partTokens(counter, message!, part),
      tokensAfter: edited == null ? 0 : partTokens(counter, message!, edited),
      recordedTokensSaved: o.tokensSaved,
      callId: callId ?? (part is ToolResultPart ? part.callId : (part is ToolCallPart ? part.call.id : null)),
      partIndex: pi < 0 ? partIndex : pi,
      shadowedBy: status == OverlayStatus.shadowed ? covering : null,
    );
  }

  static ContextDiff _rangeDiff(
    CompactedRange o,
    List<Message> path,
    Map<String, int> index,
    TokenCounter counter,
    List<ActiveRange> active,
    List<ContextOverlay> overlays,
  ) {
    final from = index[o.fromMessageId];
    final to = index[o.toMessageId];
    final onPath = from != null && to != null && to >= from;
    final kept = onPath ? compactionSurvivors(path, from, to).toSet() : const <int>{};
    final dropped = onPath ? [for (var k = from; k <= to; k++) if (!kept.contains(k)) path[k]] : const <Message>[];
    final isActive = active.any((r) => r.overlay.id == o.id);
    final covering = !onPath || isActive
        ? null
        : active.where((r) => r.from <= from && r.to >= to).map((r) => r.overlay.id).firstOrNull;
    final rendered = PassthroughContextManager.summaryMessage(o);
    return ContextDiff(
      overlayId: o.id,
      kind: ContextDiffKind.compaction,
      reason: o.reason,
      createdAt: o.createdAt,
      status: isActive ? OverlayStatus.active : (covering != null ? OverlayStatus.shadowed : OverlayStatus.inactive),
      messageIds: [for (final m in dropped) m.id],
      after: rendered.text,
      tokensBefore: dropped.fold(0, (n, m) => n + counter.countMessage(m)),
      tokensAfter: counter.countMessage(rendered) + counter.countMessage(PassthroughContextManager.summaryAck(o)),
      recordedTokensSaved: o.tokensSaved,
      shadowedBy: covering,
      strategyId: o.strategyId,
      dependents: onPath
          ? [
              for (final other in overlays.whereType<CompactedRange>())
                if (other.id != o.id && _covers(other, from, to, index)) other.id,
            ]
          : const [],
    );
  }

  /// True when [other] starts at or before [from] and ends after [to]: it
  /// was built on top of the range (rolling merge) and supersedes it.
  static bool _covers(CompactedRange other, int from, int to, Map<String, int> index) {
    final f = index[other.fromMessageId];
    final t = index[other.toMessageId];
    return f != null && t != null && f <= from && t > to;
  }

  /// Tokens [part] adds to [message].
  static int partTokens(TokenCounter counter, Message message, ContentPart part) =>
      counter.countMessage(message.copyWith(content: [part])) - counter.countMessage(message.copyWith(content: const []));

  /// Human-readable payload of a part (diff "before" side).
  static String payloadText(ContentPart part) => switch (part) {
        ToolResultPart() => part.structured == null || part.structured!.isEmpty
            ? part.text
            : '${part.text}\n${jsonEncode(part.structured)}'.trim(),
        ToolCallPart(:final call) => jsonEncode(call.arguments),
        TextPart(:final text) => text,
        _ => jsonEncode(part.toJson()),
      };
}
