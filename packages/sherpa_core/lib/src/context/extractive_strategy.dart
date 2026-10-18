import '../common/cancellation.dart';
import '../model/content.dart';
import '../model/message.dart';
import '../session/plan.dart';
import 'compaction.dart';
import 'summary_harvest.dart';
import 'text.dart';
import 'turns.dart';

/// Deterministic summarizer: no model call, same output for the same input.
///
/// Used for ≤ 4K windows (where a summarization call would not fit, R11
/// §9.2), offline, as the fallback when a model summary fails or is
/// rejected, and in tests and L4 evals. Its [M] fields are heuristics over
/// the transcript (constraint and preference sentences from user turns,
/// first lines of tool results, the plan), carried forward with the same
/// rolling merge as model summaries; the [H] fields carry the real weight.
final class ExtractiveContextStrategy implements ContextStrategy {
  const ExtractiveContextStrategy();

  @override
  String get id => 'extractive';

  static final RegExp _preference = RegExp(
    r"\b(i prefer|i'd prefer|i would prefer|i like|i'd like|i would like|please use|my preference)\b",
    caseSensitive: false,
  );
  static final RegExp _constraint = RegExp(
    r"\b(must|mustn't|never|always|do not|don't|only|no more than|at most|at least|make sure|ensure|"
    r'required|requirement|constraint|forbidden|avoid)\b',
    caseSensitive: false,
  );
  static final RegExp _decision = RegExp(
    r"\b(i will use|i'll use|we'll use|we will use|decided|decision:|going with|chose|i chose|switching to)\b",
    caseSensitive: false,
  );

  @override
  Future<CompactionSummary> summarize(CompactionInput input, {CancellationToken? cancel}) async {
    cancel?.throwIfCancelled();
    final prev = input.previousSummary;
    final users = [
      for (final m in input.messages)
        if (isRealUserTurn(m)) m,
    ];
    final constraints = <String>[];
    final preferences = <String>[];
    for (final m in users) {
      for (final s in sentences(m.text)) {
        if (_preference.hasMatch(s)) {
          preferences.add('${Provenance.user} ${clipText(s, 150)}');
        } else if (_constraint.hasMatch(s)) {
          constraints.add('${Provenance.user} ${clipText(s, 190)}');
        }
      }
    }
    final plan = input.plan ?? prev?.plan;
    final model = CompactionSummary(
      goal: clipText(
        input.taskStatement ?? prev?.goal ?? (users.isEmpty ? '' : firstLine(users.first.text)),
        CompactionSummary.goalChars,
      ),
      constraints: SummaryComposer.carryForward(prev?.constraints ?? const [], constraints, cap: 12),
      userPreferences: SummaryComposer.carryForward(prev?.userPreferences ?? const [], preferences, cap: 8),
      decisions: SummaryComposer.carryForward(prev?.decisions ?? const [], _decisions(input.messages), cap: 12),
      completed: _carry(prev?.completed, _planItems(plan, done: true), 12),
      openTasks: plan != null ? _planItems(plan, done: false) : (prev?.openTasks ?? const []),
      currentWork: _currentWork(input.messages) ?? prev?.currentWork ?? '',
      nextStep: _nextStep(input, plan),
      keyFacts: _carry(prev?.keyFacts, _toolFacts(input.messages, errors: false), 16),
      failedApproaches: _carry(prev?.failedApproaches, _toolFacts(input.messages, errors: true), 8),
      notes: prev?.notes,
    );
    return SummaryComposer.compose(input, model);
  }

  /// Newest items first, previous ones after, deduped, capped.
  static List<String> _carry(List<String>? previous, List<String> fresh, int cap) =>
      CompactionSummary.dedupeItems([...fresh.reversed, ...?previous]).take(cap).toList();

  static List<String> _decisions(List<Message> messages) => [
    for (final m in messages)
      if (m.role == Role.assistant)
        for (final s in sentences(m.text))
          if (_decision.hasMatch(s)) '${Provenance.model} ${clipText(s, 230)}',
  ];

  static List<String> _planItems(Plan? plan, {required bool done}) => [
    for (final i in plan?.items ?? const <PlanItem>[])
      if ((i.status == PlanStatus.done) == done && i.status != PlanStatus.cancelled)
        '${Provenance.model} ${clipText(i.title, 190)}',
  ];

  static String? _currentWork(List<Message> messages) {
    for (final m in messages.reversed) {
      if (m.role != Role.assistant) continue;
      final text = squash(m.text);
      if (text.isNotEmpty) return clipText(text, CompactionSummary.currentWorkChars);
      final calls = m.toolCalls;
      if (calls.isNotEmpty) return 'Was calling ${calls.map((c) => c.name).join(', ')}.';
    }
    return null;
  }

  static String _nextStep(CompactionInput input, Plan? plan) {
    final all = [...input.messages, ...input.keptMessages];
    final i = lastRealUserTurn(all);
    if (i >= 0 && input.keptMessages.contains(all[i])) {
      return 'Respond to the latest user message, which follows this summary.';
    }
    if (i >= 0) return clipText('Continue with the latest user request: ${firstLine(all[i].text)}', 300);
    final open = plan?.items.where((p) => p.status == PlanStatus.pending || p.status == PlanStatus.inProgress);
    return open == null || open.isEmpty ? '' : clipText('Continue the plan: ${open.first.title}', 300);
  }

  static List<String> _toolFacts(List<Message> messages, {required bool errors}) {
    final calls = <String, String>{};
    final out = <String>[];
    for (final m in messages) {
      for (final p in m.content) {
        if (p is ToolCallPart) calls[p.call.id] = p.call.name;
        if (p is! ToolResultPart || p.isError != errors) continue;
        final line = firstLine(p.text);
        if (line.isEmpty) continue;
        final tag = Provenance.tool(p.toolName);
        out.add(
          errors
              ? '$tag ${calls[p.callId] ?? p.toolName} failed: ${clipText(line, 180)}'
              : '$tag ${clipText(line, 220)}',
        );
      }
    }
    return out;
  }
}
