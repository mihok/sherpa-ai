import 'package:flutter/foundation.dart';
import 'package:sherpa_core/sherpa_core.dart';

import 'context_actions.dart';
import 'format.dart';

/// Why an item of the model-facing view differs from the transcript.
enum ItemMarker {
  /// Stands in for older messages (a compaction summary or its ack).
  compacted,

  /// A stale tool result replaced by a short stub.
  elided,

  /// A large payload (tool result or tool input) cut down.
  truncated,

  /// Reasoning from an older prefix was left out (append-only models).
  reasoningDropped,

  /// Added by Sherpa to keep tool calls and results paired.
  added,
}

/// Plain-language facts about one [InspectedItem], computed once so the
/// tile, its semantics label and the detail sheet agree.
@immutable
final class ItemFacts {
  const ItemFacts({
    required this.item,
    required this.title,
    required this.preview,
    required this.markers,
    this.summary,
  });

  /// Derives the facts for [item] against the recorded overlays.
  factory ItemFacts.of(InspectedItem item, ContextSnapshot snapshot) {
    final m = item.message;
    final markers = <ItemMarker>{};
    CompactedRange? summary;
    switch (item.source) {
      case ContextItemSource.summary:
        markers.add(ItemMarker.compacted);
        final o = item.overlayIds.isEmpty ? null : snapshot.overlay(item.overlayIds.first);
        if (o is CompactedRange) summary = o;
      case ContextItemSource.synthetic:
        markers.add(ItemMarker.added);
      case ContextItemSource.edited:
        if (item.overlayIds.isEmpty) markers.add(ItemMarker.reasoningDropped);
        for (final id in item.overlayIds) {
          switch (snapshot.overlay(id)) {
            case ToolOutputElided():
              markers.add(ItemMarker.elided);
            case PayloadTruncated():
              markers.add(ItemMarker.truncated);
            case CompactedRange() || null:
              break;
          }
        }
      case ContextItemSource.transcript:
        break;
    }
    final isAck = m.metadata['ack'] == true;
    final title = switch (m.role) {
      _ when summary != null && !isAck => 'Summary of earlier messages',
      _ when isAck => 'Summary acknowledgement',
      Role.user when m.kind == MessageKind.handoff => 'Handoff from an earlier chat',
      Role.user => 'You',
      Role.assistant when m.kind == MessageKind.notice => 'Sherpa notice',
      Role.assistant => m.toolCalls.isEmpty
          ? 'Assistant'
          : 'Assistant · calls ${m.toolCalls.map((c) => c.name).toSet().join(', ')}',
      Role.tool => 'Tool result${m.toolResults.isEmpty ? '' : ': ${m.toolResults.map((r) => r.toolName).toSet().join(', ')}'}',
      Role.system => 'System',
    };
    return ItemFacts(item: item, title: title, preview: _preview(m, summary), markers: markers, summary: summary);
  }

  final InspectedItem item;
  final String title;
  final String preview;
  final Set<ItemMarker> markers;

  /// The compaction this item renders, for summary items.
  final CompactedRange? summary;

  Message get message => item.message;

  /// Kind badge text, when the message is not ordinary conversation.
  String? get kindLabel => switch (message.kind) {
        MessageKind.normal => null,
        MessageKind.summary => 'Summary',
        MessageKind.plan => 'Plan',
        MessageKind.handoff => 'Handoff',
        MessageKind.notice => 'Notice',
      };

  /// Everything a screen reader needs in one sentence.
  String get semanticLabel {
    final parts = <String>[
      title,
      '${groupDigits(item.tokens)} tokens',
      if (summary == null) ?kindLabel,
      if (message.pinned) 'pinned',
      for (final mk in markers) markerLabel(mk).toLowerCase(),
      if (preview.isNotEmpty) preview,
    ];
    return parts.join(', ');
  }

  static String markerLabel(ItemMarker m) => switch (m) {
        ItemMarker.compacted => 'Compacted',
        ItemMarker.elided => 'Elided',
        ItemMarker.truncated => 'Truncated',
        ItemMarker.reasoningDropped => 'Reasoning left out',
        ItemMarker.added => 'Added by Sherpa',
      };

  /// One sentence on why the marker is there (detail sheet).
  static String markerExplanation(ItemMarker m) => switch (m) {
        ItemMarker.compacted =>
          'Older messages are replaced by this summary. They are still in your transcript; undo the summary '
              'to send them again.',
        ItemMarker.elided =>
          'An old tool result was shortened to its first and last lines. The full result is still in your '
              'transcript, and the model can call the tool again if it needs it.',
        ItemMarker.truncated =>
          'A large payload was cut down so the request fits the window. The full text is still in your '
              'transcript.',
        ItemMarker.reasoningDropped =>
          'The model\'s earlier reasoning is left out: it was produced before the context changed, and this '
              'model only accepts reasoning under the exact same history.',
        ItemMarker.added =>
          'Sherpa added this so every tool call has an answer, which models require. It was not in your '
              'transcript.',
      };

  static String _preview(Message m, CompactedRange? summary) {
    if (summary != null && m.metadata['ack'] != true) {
      final s = summary.summary;
      final goal = s.goal.trim().isNotEmpty ? s.goal : (s.task ?? '');
      final n = summary.summary.compactionCount;
      return previewLine('${n > 1 ? 'Merged $n times. ' : ''}Goal: $goal');
    }
    final text = m.text.trim();
    if (text.isNotEmpty) return previewLine(text);
    for (final r in m.toolResults) {
      final t = r.text.trim();
      if (t.isNotEmpty) return previewLine('${r.isError ? 'Error: ' : ''}$t');
    }
    if (m.toolCalls.isNotEmpty) return previewLine(m.toolCalls.map((c) => '${c.name}(…)').join(', '));
    if (m.reasoning.isNotEmpty) return 'Reasoning only';
    return '';
  }
}
