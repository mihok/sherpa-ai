import 'package:meta/meta.dart';

import '../model/content.dart';
import '../model/message.dart';

enum PairingIssueKind {
  /// A tool result whose call is not in the preceding assistant message.
  orphanResult,

  /// A tool call (other than the in-flight leaf) with no result after it.
  unansweredCall,
}

@immutable
final class PairingIssue {
  const PairingIssue(this.kind, {required this.messageId, required this.callId});

  final PairingIssueKind kind;
  final String messageId;
  final String callId;

  @override
  String toString() => '${kind.name}($callId in $messageId)';
}

/// The provider-facing tool pairing invariant (R11 §9.3), checked and
/// repaired on every view the context manager produces:
/// * each tool result's call is in the assistant message right before it;
/// * every call except one in the in-flight leaf has a result right after.
///
/// Every provider rejects a broken pair (Anthropic 400s on an unanswered
/// `tool_use` and on a `tool_result` without its `tool_use`), so a rewrite
/// that breaks one must never reach the wire. Repair is deterministic, so a
/// repaired view is byte-identical on every recompute.
abstract final class ToolPairing {
  /// The text of a synthesized result (Roo's approach).
  static const String notExecuted = 'not executed: context was compacted';

  static List<PairingIssue> validate(List<Message> messages) => repair(messages).$2;

  /// Synthesizes `isError` results for unanswered calls and drops orphan
  /// results (a tool message left empty is dropped).
  static (List<Message>, List<PairingIssue>) repair(List<Message> messages) {
    final issues = <PairingIssue>[];
    final out = <Message>[];
    final src = [...messages];
    for (var i = 0; i < src.length; i++) {
      final m = src[i];
      if (m.role == Role.tool) {
        final prev = out.isEmpty ? null : out.last;
        final owned = prev != null && prev.role == Role.assistant
            ? {for (final c in prev.toolCalls) c.id}
            : const <String>{};
        final kept = <ContentPart>[];
        for (final p in m.content) {
          if (p is ToolResultPart && !owned.contains(p.callId)) {
            issues.add(PairingIssue(PairingIssueKind.orphanResult, messageId: m.id, callId: p.callId));
          } else {
            kept.add(p);
          }
        }
        if (kept.length != m.content.length) {
          if (kept.any((p) => p is ToolResultPart)) out.add(m.copyWith(content: kept));
          continue;
        }
        out.add(m);
        continue;
      }
      out.add(m);
      if (m.role != Role.assistant || !m.hasToolCalls) continue;
      final isLeaf = i == src.length - 1;
      if (isLeaf) continue;
      final next = src[i + 1];
      final answered = next.role == Role.tool ? {for (final r in next.toolResults) r.callId} : const <String>{};
      final missing = m.toolCalls.where((c) => !answered.contains(c.id)).toList();
      if (missing.isEmpty) continue;
      for (final c in missing) {
        issues.add(PairingIssue(PairingIssueKind.unansweredCall, messageId: m.id, callId: c.id));
      }
      final synthesized = [
        for (final c in missing)
          ToolResultPart(callId: c.id, toolName: c.name, content: const [TextPart(notExecuted)], isError: true),
      ];
      if (next.role == Role.tool) {
        // Answer in the existing tool message, keeping call order.
        final owned = {for (final c in m.toolCalls) c.id};
        for (final r in next.toolResults.where((r) => !owned.contains(r.callId))) {
          issues.add(PairingIssue(PairingIssueKind.orphanResult, messageId: next.id, callId: r.callId));
        }
        final byId = {
          for (final r in [...next.toolResults, ...synthesized]) r.callId: r,
        };
        final ordered = [for (final c in m.toolCalls) byId[c.id]!];
        final other = next.content.where((p) => p is! ToolResultPart);
        src[i + 1] = next.copyWith(content: [...ordered, ...other]);
      } else {
        out.add(
          Message(
            id: 'synthetic:results:${m.id}',
            parentId: m.id,
            role: Role.tool,
            createdAt: m.createdAt,
            content: synthesized,
            metadata: const {'synthetic': true},
          ),
        );
      }
    }
    // An intact view is returned as the same list, so callers can tell.
    return (issues.isEmpty ? messages : out, issues);
  }
}
