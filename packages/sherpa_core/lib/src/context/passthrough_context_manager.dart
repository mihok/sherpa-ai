import 'dart:convert';

import '../model/content.dart';
import '../model/message.dart';
import '../model/tool.dart';
import '../provider/capabilities.dart';
import 'budget.dart';
import 'context_manager.dart';
import 'digest.dart';
import 'overlay.dart';
import 'part_rewrite.dart';
import 'turns.dart';

/// The minimal context manager: applies already-recorded overlays, measures
/// the budget and refuses to overflow. It never creates new overlays; the
/// full escalation ladder lives in `LadderContextManager`.
final class PassthroughContextManager implements ContextManager {
  const PassthroughContextManager();

  @override
  Future<PreparedContext> prepare(ContextRequest request) async {
    final system = request.systemPrompt;
    final key = prefixKeyOf(system, request.tools, request.overlays);
    var messages = applyOverlays(request.path, request.overlays);
    if (request.capabilities.historyPolicy == HistoryPolicy.appendOnly) {
      messages = stripStaleReasoning(messages, key);
    }
    final budget = measure(request, system, messages);
    final level = budget.levelFor(request.settings.thresholds);
    if (!budget.fits) {
      throw ContextOverflowException(
        budget,
        'This conversation no longer fits the model\'s context window '
        '(${budget.inputTokens} of ${budget.usableInput} tokens). '
        'Compact it, start a handoff, or switch to a model with a larger window.',
      );
    }
    return PreparedContext(
      systemPrompt: system,
      messages: messages,
      tools: request.tools,
      budget: budget,
      level: level,
      prefixKey: key,
    );
  }

  /// FNV-1a 64 over the canonical prefix. Not a security hash: it only
  /// detects that the system prompt, tool schemas or overlays changed.
  /// Overlay ids are sorted so a store that lists overlays in a different
  /// order does not look like a rewrite (which would drop reasoning).
  static String prefixKeyOf(String? system, List<ToolDefinition> tools, List<ContextOverlay> overlays) =>
      Digest.fnv64(jsonEncode({
        's': system ?? '',
        't': [for (final t in tools) if (t.modelVisible) [t.name, t.description, t.inputSchema]],
        'o': [for (final o in overlays) o.id]..sort(),
      }));

  /// Drops reasoning produced under a different prefix. Providers that bind
  /// thinking to the prefix reject replays after any rewrite; reasoning is
  /// optional context, so dropping it is always safe.
  static List<Message> stripStaleReasoning(List<Message> messages, String key) => [
        for (final m in messages)
          if (m.role == Role.assistant && m.metadata['prefixKey'] != key && m.content.any((p) => p is ReasoningPart))
            m.copyWith(content: m.content.where((p) => p is! ReasoningPart).toList())
          else
            m,
      ];

  /// Computes the budget for [messages] as they would be sent.
  static ContextBudget measure(ContextRequest r, String? system, List<Message> messages) {
    final c = r.counter;
    var pinned = 0;
    var history = 0;
    for (final m in messages) {
      final n = c.countMessage(m);
      if (m.pinned) {
        pinned += n;
      } else {
        history += n;
      }
    }
    final limit = r.capabilities.contextLength;
    final reserve = r.capabilities.maxOutputTokens == null
        ? r.settings.outputReserveTokens
        : (r.capabilities.maxOutputTokens! < r.settings.outputReserveTokens
            ? r.capabilities.maxOutputTokens!
            : r.settings.outputReserveTokens);
    return ContextBudget(
      limit: limit,
      outputReserve: reserve,
      safetyMargin: c.isExact ? 0 : (limit * r.settings.estimateSafetyFraction).round(),
      systemTokens: system == null ? 0 : c.countText(system),
      toolTokens: c.countTools(r.tools.where((t) => t.modelVisible).toList()),
      pinnedTokens: pinned,
      historyTokens: history,
      exact: c.isExact,
    );
  }

  /// Applies elisions, truncations and compactions to the transcript path.
  /// Compacted ranges are replaced by one summary message placed where the
  /// range started; ranges not on this path are ignored. Compaction is
  /// rolling, so several ranges may share a start: the widest one wins and a
  /// range that starts inside an applied one is shadowed by it.
  static List<Message> applyOverlays(List<Message> path, List<ContextOverlay> overlays) {
    if (overlays.isEmpty) return path;
    final replaceRange = {for (final r in activeCompactions(path, overlays)) r.from: r};
    final elided = {
      for (final o in overlays.whereType<ToolOutputElided>()) '${o.messageId}/${o.callId}': o,
    };
    final truncated = {
      for (final o in overlays.whereType<PayloadTruncated>()) '${o.messageId}/${o.partIndex}': o,
    };

    final out = <Message>[];
    var i = 0;
    while (i < path.length) {
      final range = replaceRange[i];
      if (range != null) {
        final (:to, :overlay, from: _) = range;
        out.add(summaryMessage(overlay, parentId: path[i].parentId));
        // Pinned messages inside a compacted range survive verbatim, with
        // the other half of their tool call/result pair.
        for (final k in compactionSurvivors(path, i, to)) {
          out.add(path[k].pinned ? path[k] : _applyPartOverlays(path[k], elided, truncated));
        }
        // Strict-alternation chat templates reject user→user; a fixed ack
        // keeps roles alternating (Gemini CLI does the same, R11 §9.3).
        final next = to + 1 < path.length ? path[to + 1] : null;
        if (out.last.role == Role.user && (next == null || next.role == Role.user)) {
          out.add(summaryAck(overlay));
        }
        i = to + 1;
        continue;
      }
      out.add(_applyPartOverlays(path[i], elided, truncated));
      i++;
    }
    return out;
  }

  /// The synthetic, pinned user message standing in for a compacted range.
  static Message summaryMessage(CompactedRange overlay, {String? parentId}) => Message(
        id: 'summary:${overlay.id}',
        parentId: parentId,
        role: Role.user,
        kind: MessageKind.summary,
        pinned: true,
        createdAt: overlay.createdAt,
        content: [TextPart(overlay.summary.render())],
        metadata: {'overlayId': overlay.id},
      );

  /// Fixed assistant acknowledgement placed after a summary when the next
  /// message is a user turn.
  static Message summaryAck(CompactedRange overlay) => Message(
        id: 'summary:${overlay.id}:ack',
        parentId: 'summary:${overlay.id}',
        role: Role.assistant,
        kind: MessageKind.summary,
        pinned: true,
        createdAt: overlay.createdAt,
        content: const [TextPart(summaryAckText)],
        metadata: {'overlayId': overlay.id, 'ack': true},
      );

  static const String summaryAckText = 'Understood. I will continue from this summary.';

  static Message _applyPartOverlays(
    Message m,
    Map<String, ToolOutputElided> elided,
    Map<String, PayloadTruncated> truncated,
  ) {
    if (m.pinned) return m;
    var changed = false;
    final parts = [
      for (final (pi, p) in m.content.indexed)
        () {
          final t = truncated['${m.id}/$pi'];
          if (t != null) {
            changed = true;
            return PartRewrite.replacePayload(p, t.replacement);
          }
          final callId = PartRewrite.callIdOf(p);
          final e = callId == null ? null : elided['${m.id}/$callId'];
          if (e != null) {
            changed = true;
            return PartRewrite.replacePayload(p, e.stub);
          }
          return p;
        }(),
    ];
    return changed ? m.copyWith(content: parts) : m;
  }
}
