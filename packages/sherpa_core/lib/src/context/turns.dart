/// Internal helpers for reasoning about turns on a transcript path.
library;

import '../model/content.dart';
import '../model/message.dart';
import 'overlay.dart';

/// A "real" user turn: typed by the user, not a summary/handoff/notice and
/// carrying no tool results. Cut points sit immediately before one (the
/// Gemini CLI rule, R11 §9.3), which keeps tool call/result pairs intact.
bool isRealUserTurn(Message m) =>
    m.role == Role.user && m.kind == MessageKind.normal && !m.content.any((p) => p is ToolResultPart);

/// Index of the last real user turn in [messages], or -1.
int lastRealUserTurn(List<Message> messages) {
  for (var i = messages.length - 1; i >= 0; i--) {
    if (isRealUserTurn(messages[i])) return i;
  }
  return -1;
}

/// Synthetic messages created by overlay rendering (summary placeholders,
/// acks, repaired tool results) rather than stored in the transcript.
bool isSyntheticView(Message m) => m.id.startsWith('summary:') || m.id.startsWith('synthetic:');

/// A compacted range as `PassthroughContextManager.applyOverlays` applies
/// it: raw path indices [from, to] inclusive.
typedef ActiveRange = ({int from, int to, CompactedRange overlay});

/// The compactions in effect on [path], in path order. Mirrors
/// `applyOverlays`: the widest range per start wins, and a range starting
/// inside an applied one is shadowed.
List<ActiveRange> activeCompactions(List<Message> path, List<ContextOverlay> overlays) {
  final index = {for (final (i, m) in path.indexed) m.id: i};
  final byStart = <int, ActiveRange>{};
  for (final o in overlays.whereType<CompactedRange>()) {
    final from = index[o.fromMessageId];
    final to = index[o.toMessageId];
    if (from == null || to == null || to < from) continue;
    final existing = byStart[from];
    if (existing == null || to > existing.to) byStart[from] = (from: from, to: to, overlay: o);
  }
  final out = <ActiveRange>[];
  var end = -1;
  for (final start in byStart.keys.toList()..sort()) {
    if (start <= end) continue;
    final r = byStart[start]!;
    out.add(r);
    end = r.to;
  }
  return out;
}

/// Raw indices in [from, to] that survive compaction of that range: pinned
/// messages plus the other half of their tool call/result pair, so a pinned
/// result never loses its call (which pairing repair would then have to
/// drop) and a pinned call never loses its result.
List<int> compactionSurvivors(List<Message> path, int from, int to) {
  final keep = <int>{};
  for (var k = from; k <= to; k++) {
    final m = path[k];
    if (!m.pinned) continue;
    keep.add(k);
    if (m.role == Role.tool && k - 1 >= from && path[k - 1].role == Role.assistant) keep.add(k - 1);
    if (m.role == Role.assistant && m.hasToolCalls && k + 1 <= to && path[k + 1].role == Role.tool) keep.add(k + 1);
  }
  return keep.toList()..sort();
}
