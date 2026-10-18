import 'package:meta/meta.dart';

import '../common/json.dart';
import 'content.dart';
import 'tool.dart';

enum Role { system, user, assistant, tool }

/// Why a message exists beyond being ordinary conversation. The context
/// manager keys its behaviour off this (e.g. summaries replace ranges,
/// plans are pinned).
enum MessageKind {
  normal,

  /// Structured compaction note standing in for a range of older turns.
  summary,

  /// The active plan/todo list rendered for the model.
  plan,

  /// Seeded from a handoff bundle when a session starts from one.
  handoff,

  /// Host-generated notice (e.g. "engine restarted", "context compacted").
  notice,
}

/// Token accounting for one model call, normalized across providers:
/// [inputTokens] counts uncached prompt tokens (including tokens written
/// to a prompt cache) and [cacheReadTokens] the prompt tokens served from
/// cache, so the full prompt is `inputTokens + cacheReadTokens`.
@immutable
final class Usage {
  const Usage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.reasoningTokens = 0,
  });

  factory Usage.fromJson(JsonMap j) => Usage(
        inputTokens: j.optInt('input') ?? 0,
        outputTokens: j.optInt('output') ?? 0,
        cacheReadTokens: j.optInt('cacheRead') ?? 0,
        cacheWriteTokens: j.optInt('cacheWrite') ?? 0,
        reasoningTokens: j.optInt('reasoning') ?? 0,
      );

  static const zero = Usage();

  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final int reasoningTokens;

  int get totalTokens => inputTokens + outputTokens;

  Usage operator +(Usage o) => Usage(
        inputTokens: inputTokens + o.inputTokens,
        outputTokens: outputTokens + o.outputTokens,
        cacheReadTokens: cacheReadTokens + o.cacheReadTokens,
        cacheWriteTokens: cacheWriteTokens + o.cacheWriteTokens,
        reasoningTokens: reasoningTokens + o.reasoningTokens,
      );

  JsonMap toJson() => compact({
        'input': inputTokens,
        'output': outputTokens,
        'cacheRead': cacheReadTokens == 0 ? null : cacheReadTokens,
        'cacheWrite': cacheWriteTokens == 0 ? null : cacheWriteTokens,
        'reasoning': reasoningTokens == 0 ? null : reasoningTokens,
      });
}

/// One node of the conversation tree. Messages are immutable once
/// finalized; the transcript is append-only and branching creates siblings
/// via [parentId], so edit-and-resubmit and retry never destroy history.
@immutable
final class Message {
  const Message({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
    this.parentId,
    this.kind = MessageKind.normal,
    this.pinned = false,
    this.providerId,
    this.modelId,
    this.usage,
    this.finishReason,
    this.metadata = const {},
  });

  factory Message.fromJson(JsonMap j) => Message(
        id: j.req<String>('id'),
        parentId: j.opt<String>('parentId'),
        role: Role.values.byName(j.req<String>('role')),
        kind: MessageKind.values.byName(j.opt<String>('kind') ?? 'normal'),
        content: j.mapList('content').map(ContentPart.fromJson).toList(),
        createdAt: DateTime.parse(j.req<String>('createdAt')),
        pinned: j.opt<bool>('pinned') ?? false,
        providerId: j.opt<String>('providerId'),
        modelId: j.opt<String>('modelId'),
        usage: j.optObj('usage') == null ? null : Usage.fromJson(j.obj('usage')),
        finishReason: j.opt<String>('finishReason'),
        metadata: j.optObj('metadata') ?? const {},
      );

  final String id;
  final String? parentId;
  final Role role;
  final MessageKind kind;
  final List<ContentPart> content;
  final DateTime createdAt;

  /// Pinned messages are never pruned or compacted.
  final bool pinned;
  final String? providerId;
  final String? modelId;
  final Usage? usage;
  final String? finishReason;

  /// Free-form, JSON-safe extras (e.g. attachment names, client hints).
  final JsonMap metadata;

  String get text => content.whereType<TextPart>().map((p) => p.text).join();

  List<ToolCall> get toolCalls =>
      content.whereType<ToolCallPart>().map((p) => p.call).toList();

  List<ToolResultPart> get toolResults =>
      content.whereType<ToolResultPart>().toList();

  List<ReasoningPart> get reasoning => content.whereType<ReasoningPart>().toList();

  bool get hasToolCalls => content.any((p) => p is ToolCallPart);

  Message copyWith({
    String? parentId,
    List<ContentPart>? content,
    bool? pinned,
    MessageKind? kind,
    Usage? usage,
    String? finishReason,
    JsonMap? metadata,
  }) =>
      Message(
        id: id,
        parentId: parentId ?? this.parentId,
        role: role,
        kind: kind ?? this.kind,
        content: content ?? this.content,
        createdAt: createdAt,
        pinned: pinned ?? this.pinned,
        providerId: providerId,
        modelId: modelId,
        usage: usage ?? this.usage,
        finishReason: finishReason ?? this.finishReason,
        metadata: metadata ?? this.metadata,
      );

  JsonMap toJson() => compact({
        'id': id,
        'parentId': parentId,
        'role': role.name,
        'kind': kind == MessageKind.normal ? null : kind.name,
        'content': [for (final c in content) c.toJson()],
        'createdAt': createdAt.toUtc().toIso8601String(),
        'pinned': pinned ? true : null,
        'providerId': providerId,
        'modelId': modelId,
        'usage': usage?.toJson(),
        'finishReason': finishReason,
        'metadata': metadata.isEmpty ? null : metadata,
      });
}
