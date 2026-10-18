import 'package:meta/meta.dart';

import '../common/json.dart';

enum PlanStatus { pending, inProgress, done, blocked, cancelled }

@immutable
final class PlanItem {
  const PlanItem({required this.id, required this.title, this.status = PlanStatus.pending, this.notes});

  factory PlanItem.fromJson(JsonMap j) => PlanItem(
        id: j.req<String>('id'),
        title: j.req<String>('title'),
        status: PlanStatus.values.byName(j.opt<String>('status') ?? 'pending'),
        notes: j.opt<String>('notes'),
      );

  final String id;
  final String title;
  final PlanStatus status;
  final String? notes;

  PlanItem copyWith({PlanStatus? status, String? notes}) =>
      PlanItem(id: id, title: title, status: status ?? this.status, notes: notes ?? this.notes);

  JsonMap toJson() => compact({'id': id, 'title': title, 'status': status.name, 'notes': notes});
}

/// The visible plan/todo list. Always pinned in context; updated by the
/// model through the built-in `update_plan` tool or by the user.
@immutable
final class Plan {
  const Plan({required this.items, required this.updatedAt, this.task});

  factory Plan.fromJson(JsonMap j) => Plan(
        task: j.opt<String>('task'),
        items: j.mapList('items').map(PlanItem.fromJson).toList(),
        updatedAt: DateTime.parse(j.req<String>('updatedAt')),
      );

  /// Current task statement (pinned alongside the plan).
  final String? task;
  final List<PlanItem> items;
  final DateTime updatedAt;

  bool get isEmpty => items.isEmpty && (task == null || task!.isEmpty);

  String render() {
    final b = StringBuffer('## Current plan\n');
    if (task != null && task!.isNotEmpty) b.writeln('Task: $task\n');
    for (final i in items) {
      final box = switch (i.status) {
        PlanStatus.done => '[x]',
        PlanStatus.inProgress => '[~]',
        PlanStatus.blocked => '[!]',
        PlanStatus.cancelled => '[-]',
        PlanStatus.pending => '[ ]',
      };
      b.writeln('- $box ${i.title}${i.notes == null ? '' : ' — ${i.notes}'}');
    }
    return b.toString();
  }

  JsonMap toJson() => compact({
        'task': task,
        'items': [for (final i in items) i.toJson()],
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      });
}
