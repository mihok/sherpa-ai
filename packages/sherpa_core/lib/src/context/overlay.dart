import 'package:meta/meta.dart';

import '../common/json.dart';
import 'compaction.dart';

/// A reversible transformation applied to the *context view* of a session.
///
/// The transcript itself is never rewritten: pruning, truncation and
/// compaction are stored as overlays on top of it, so the original stays on
/// disk for audit, the UI can show a diff, and undo is "delete the overlay".
@immutable
sealed class ContextOverlay {
  const ContextOverlay({
    required this.id,
    required this.createdAt,
    required this.reason,
    required this.tokensSaved,
  });

  final String id;
  final DateTime createdAt;

  /// Human-readable explanation shown in the context health UI.
  final String reason;
  final int tokensSaved;

  String get type;

  JsonMap toJson();

  JsonMap baseJson() => {
        'type': type,
        'id': id,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'reason': reason,
        'tokensSaved': tokensSaved,
      };

  static ContextOverlay fromJson(JsonMap j) {
    final id = j.req<String>('id');
    final at = DateTime.parse(j.req<String>('createdAt'));
    final reason = j.req<String>('reason');
    final saved = j.optInt('tokensSaved') ?? 0;
    return switch (j.req<String>('type')) {
      'elide_tool_output' => ToolOutputElided(
          id: id,
          createdAt: at,
          reason: reason,
          tokensSaved: saved,
          messageId: j.req<String>('messageId'),
          callId: j.req<String>('callId'),
          stub: j.req<String>('stub'),
        ),
      'truncate_payload' => PayloadTruncated(
          id: id,
          createdAt: at,
          reason: reason,
          tokensSaved: saved,
          messageId: j.req<String>('messageId'),
          partIndex: j.optInt('partIndex') ?? 0,
          replacement: j.req<String>('replacement'),
        ),
      'compact_range' => CompactedRange(
          id: id,
          createdAt: at,
          reason: reason,
          tokensSaved: saved,
          fromMessageId: j.req<String>('fromMessageId'),
          toMessageId: j.req<String>('toMessageId'),
          summary: CompactionSummary.fromJson(j.obj('summary')),
          strategyId: j.req<String>('strategyId'),
          transcriptRef: j.opt<String>('transcriptRef'),
        ),
      final t => throw FormatError('unknown overlay type $t'),
    };
  }
}

/// Stage 1: a stale, large tool result replaced by a stub. The call
/// metadata (name, args, id) stays so tool_call/tool_result pairing holds.
final class ToolOutputElided extends ContextOverlay {
  const ToolOutputElided({
    required super.id,
    required super.createdAt,
    required super.reason,
    required super.tokensSaved,
    required this.messageId,
    required this.callId,
    required this.stub,
  });

  final String messageId;
  final String callId;
  final String stub;

  @override
  String get type => 'elide_tool_output';

  @override
  JsonMap toJson() =>
      {...baseJson(), 'messageId': messageId, 'callId': callId, 'stub': stub};
}

/// Stage 2: a big payload reduced to head/tail and extracted fields.
final class PayloadTruncated extends ContextOverlay {
  const PayloadTruncated({
    required super.id,
    required super.createdAt,
    required super.reason,
    required super.tokensSaved,
    required this.messageId,
    required this.partIndex,
    required this.replacement,
  });

  final String messageId;
  final int partIndex;
  final String replacement;

  @override
  String get type => 'truncate_payload';

  @override
  JsonMap toJson() => {
        ...baseJson(),
        'messageId': messageId,
        'partIndex': partIndex,
        'replacement': replacement,
      };
}

/// Stage 3: messages `[fromMessageId..toMessageId]` (inclusive, along the
/// active path) replaced in context by one structured summary.
final class CompactedRange extends ContextOverlay {
  const CompactedRange({
    required super.id,
    required super.createdAt,
    required super.reason,
    required super.tokensSaved,
    required this.fromMessageId,
    required this.toMessageId,
    required this.summary,
    required this.strategyId,
    this.transcriptRef,
  });

  final String fromMessageId;
  final String toMessageId;
  final CompactionSummary summary;
  final String strategyId;

  /// Path of the archived verbatim transcript for this range.
  final String? transcriptRef;

  @override
  String get type => 'compact_range';

  @override
  JsonMap toJson() => compact({
        ...baseJson(),
        'fromMessageId': fromMessageId,
        'toMessageId': toMessageId,
        'summary': summary.toJson(),
        'strategyId': strategyId,
        'transcriptRef': transcriptRef,
      });
}
