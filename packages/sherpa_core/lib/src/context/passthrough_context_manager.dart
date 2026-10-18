import '../model/content.dart';
import '../model/message.dart';
import 'budget.dart';
import 'context_manager.dart';
import 'overlay.dart';
import 'part_rewrite.dart';

/// The minimal context manager: applies already-recorded overlays, measures
/// the budget and refuses to overflow. It never creates new overlays; the
/// full escalation ladder lives in `LadderContextManager`.
final class PassthroughContextManager implements ContextManager {
  const PassthroughContextManager();

  @override
  Future<PreparedContext> prepare(ContextRequest request) async {
    final system = _systemWithPlan(request);
    final messages = applyOverlays(request.path, request.overlays);
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
    );
  }

  static String? _systemWithPlan(ContextRequest r) {
    final plan = r.plan;
    if (plan == null || plan.isEmpty) return r.systemPrompt;
    final base = r.systemPrompt ?? '';
    return base.isEmpty ? plan.render() : '$base\n\n${plan.render()}';
  }

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
  /// range started; ranges not on this path are ignored.
  static List<Message> applyOverlays(List<Message> path, List<ContextOverlay> overlays) {
    if (overlays.isEmpty) return path;
    final index = {for (final (i, m) in path.indexed) m.id: i};
    final replaceRange = <int, (int, CompactedRange)>{};
    for (final o in overlays.whereType<CompactedRange>()) {
      final from = index[o.fromMessageId];
      final to = index[o.toMessageId];
      if (from == null || to == null || to < from) continue;
      replaceRange[from] = (to, o);
    }
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
        final (to, overlay) = range;
        final first = path[i];
        out.add(Message(
          id: 'summary:${overlay.id}',
          parentId: first.parentId,
          role: Role.user,
          kind: MessageKind.summary,
          pinned: true,
          createdAt: overlay.createdAt,
          content: [TextPart(overlay.summary.render())],
          metadata: {'overlayId': overlay.id},
        ));
        // Pinned messages inside a compacted range survive verbatim.
        for (var k = i; k <= to; k++) {
          if (path[k].pinned) out.add(path[k]);
        }
        i = to + 1;
        continue;
      }
      out.add(_applyPartOverlays(path[i], elided, truncated));
      i++;
    }
    return out;
  }

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
