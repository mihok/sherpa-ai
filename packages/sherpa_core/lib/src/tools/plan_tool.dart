import 'dart:async';

import '../common/clock.dart';
import '../model/tool.dart';
import '../session/plan.dart';
import '../session/session_store.dart';
import 'composite_router.dart';
import 'tool_router.dart';

/// Built-in `update_plan` tool: the model maintains a visible todo list that
/// the context manager pins. Replacing the whole list each call (rather than
/// patching) keeps small models from corrupting it.
final class UpdatePlanTool implements LocalTool {
  UpdatePlanTool({required this.store, this.clock = const SystemClock(), this.onUpdated});

  static const String toolName = 'update_plan';

  final SessionStore store;
  final Clock clock;
  final void Function(String sessionId, Plan plan)? onUpdated;

  @override
  ToolDefinition get definition => const ToolDefinition(
        name: toolName,
        title: 'Update plan',
        description: 'Create or replace the visible task plan. Call it when starting a multi-step '
            'task and whenever a step changes status. Send the FULL list each time.',
        annotations: ToolAnnotations(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false),
        inputSchema: {
          'type': 'object',
          'properties': {
            'task': {'type': 'string', 'description': 'One-sentence statement of the overall task.'},
            'items': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'title': {'type': 'string'},
                  'status': {
                    'type': 'string',
                    'enum': ['pending', 'inProgress', 'done', 'blocked', 'cancelled'],
                  },
                  'notes': {'type': 'string'},
                },
                'required': ['title', 'status'],
              },
            },
          },
          'required': ['items'],
        },
      );

  @override
  Future<ToolResult> run(Map<String, Object?> arguments, ToolExecutionContext context) async {
    final raw = arguments['items'];
    if (raw is! List) return ToolResult.error('"items" must be an array.');
    final items = <PlanItem>[];
    for (final (i, e) in raw.indexed) {
      if (e is! Map) return ToolResult.error('items[$i] must be an object.');
      final title = e['title'];
      if (title is! String || title.trim().isEmpty) {
        return ToolResult.error('items[$i].title must be a non-empty string.');
      }
      final status = PlanStatus.values.where((s) => s.name == e['status']).firstOrNull ??
          _lenientStatus(e['status']);
      final notes = e['notes'];
      items.add(PlanItem(
        id: '${i + 1}',
        title: title.trim(),
        status: status,
        notes: notes is String && notes.isNotEmpty ? notes : null,
      ));
    }
    final previous = await store.getPlan(context.sessionId);
    final task = arguments['task'];
    final plan = Plan(
      task: task is String && task.isNotEmpty ? task : previous?.task,
      items: items,
      updatedAt: clock.now(),
    );
    await store.putPlan(context.sessionId, plan);
    onUpdated?.call(context.sessionId, plan);
    // The rendered plan goes into the transcript via this result rather than
    // the system prompt, so updating it never rewrites the cached prefix.
    final done = items.where((i) => i.status == PlanStatus.done).length;
    return ToolResult.text('Plan updated ($done/${items.length} done).\n\n${plan.render()}');
  }

  /// Small models often say "in_progress", "completed", "todo"…
  static PlanStatus _lenientStatus(Object? s) {
    final v = s?.toString().toLowerCase().replaceAll(RegExp(r'[^a-z]'), '') ?? '';
    return switch (v) {
      'inprogress' || 'active' || 'doing' || 'started' => PlanStatus.inProgress,
      'done' || 'complete' || 'completed' || 'finished' => PlanStatus.done,
      'blocked' || 'failed' => PlanStatus.blocked,
      'cancelled' || 'canceled' || 'skipped' => PlanStatus.cancelled,
      _ => PlanStatus.pending,
    };
  }
}
