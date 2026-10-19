/// L0 — deterministic harness invariants (R11 §9.9), run in CI with the
/// scripted model: crash/resume exactly-once, the approval-gate matrix,
/// rug-pull detection and constraint carry-forward.
library;

import '../report.dart';
import '../runtime/models.dart';
import 'l0_approvals.dart';
import 'l0_carry_forward.dart';
import 'l0_durability.dart';
import 'l0_rugpull.dart';
import 'suite.dart';

final class L0Suite implements EvalSuite {
  const L0Suite();

  @override
  String get id => 'L0';

  @override
  String get title => 'Deterministic harness invariants';

  @override
  bool supports(ModelSpec model) => true;

  @override
  Future<SuiteReport> run(EvalContext ctx) async {
    final report = SuiteReport(suite: id, title: title, model: 'scripted (harness only)');
    if (!ctx.scripted) report.notes.add('L0 always runs the scripted model: it tests the harness, not the model.');

    ctx.log('  durability (crash at every durable operation) …');
    final (dCases, d) = await runDurability(only: ctx.only);
    report.cases.addAll(dCases);
    report.metrics.addAll([
      Metric('crash_points', d.crashPoints.toDouble(), unit: 'count', group: 'durability'),
      Metric.ratio('resume_completed_rate', d.completed, d.crashPoints, better: Better.higher, min: 1, whenEmpty: 1,
          description: 'resumed runs that finished the trajectory (or had legitimately nothing to resume)'),
      Metric('duplicate_side_effects', d.duplicates.toDouble(), better: Better.lower, unit: 'count', max: 0,
          description: 'planned calls that took effect twice at the server'),
      Metric('lost_idempotent_side_effects', d.lostIdempotent.toDouble(), better: Better.lower, unit: 'count', max: 0,
          description: 'trusted idempotent calls that never took effect although the run completed'),
      Metric('silent_losses', d.silentLosses.toDouble(), better: Better.lower, unit: 'count', max: 0,
          description: 'calls reported successful that never took effect'),
      Metric('pairing_violations', d.pairing.toDouble(), better: Better.lower, unit: 'count', max: 0),
      Metric('reprompts_after_decision', d.reprompts.toDouble(), better: Better.lower, unit: 'count', max: 0,
          description: 'approval prompts repeated for a call whose decision was already durable'),
      Metric('unhandled_errors', d.unhandled.toDouble(), better: Better.lower, unit: 'count', max: 0,
          description: 'errors escaping to the zone in clean or resumed runs'),
      Metric('unknown_outcome_reports', d.unknownReports.toDouble(), unit: 'count',
          description: 'interrupted non-idempotent calls reported to the model as unknown outcome (at-most-once)'),
      Metric('runs_lost_before_first_checkpoint', d.lostBeforeCheckpoint.toDouble(), unit: 'count',
          description: 'crashes after the user message was stored but before the first checkpoint: nothing resumes'),
    ]);
    report.extra['durability'] = {'phaseAtCrash': d.phases, 'failedOperation': d.failedOps};

    ctx.log('  approval-gate matrix …');
    final (aCases, a) = await runApprovalMatrix(only: ctx.only);
    report.cases.addAll(aCases);
    report.metrics.addAll([
      Metric('matrix_cells', a.cells.toDouble(), unit: 'count', group: 'approvals'),
      Metric.ratio('matrix_agreement', a.agree, a.cells, better: Better.higher, whenEmpty: 1,
          description: 'cells whose observed decision matches the R11 9.6.7/9.7 oracle'),
      Metric('unsafe_auto_runs', a.unsafeAuto.toDouble(), better: Better.lower, unit: 'count', max: 0,
          description: 'cells the oracle gates that ran without a prompt (excluding documented divergences)'),
      Metric('documented_divergences', a.known.toDouble(), better: Better.lower, unit: 'count',
          description: 'cells where the code deliberately differs from the R11 text (see known issues)'),
      Metric('extra_prompts', a.extraPrompts.toDouble(), better: Better.lower, unit: 'count',
          description: 'cells that prompt although the oracle auto-runs (UX cost, not a safety issue)'),
    ]);

    ctx.log('  rug-pull detection …');
    final (rCases, r) = await runRugPull(only: ctx.only);
    report.cases.addAll(rCases);
    report.metrics.addAll([
      Metric.ratio('rugpull_detection_rate', r.detected, r.changed, better: Better.higher, min: 1, whenEmpty: 1,
          description: 'changed tool definitions quarantined before their next use in a new segment'),
      Metric.ratio('rugpull_silent_detection_rate', r.silentDetected, r.silent, better: Better.higher, whenEmpty: 1,
          description: 'changes without list_changed detected by the next tools/list diff'),
      Metric('stale_grants_honored', r.staleGrants.toDouble(), better: Better.lower, unit: 'count', max: 0,
          description: 'grants for the old definition that still auto-approve the changed tool'),
      Metric('false_quarantines', r.falseQuarantines.toDouble(), better: Better.lower, unit: 'count', max: 0),
      Metric('calls_before_detection', r.callsBeforeDetection.toDouble(), unit: 'count',
          description: 'silent changes: calls that ran in the old segment after the server changed'),
    ]);

    ctx.log('  constraint carry-forward …');
    final (cCases, c) = await runCarryForward(only: ctx.only);
    report.cases.addAll(cCases);
    report.metrics.addAll([
      Metric.ratio('constraint_retention', c.retained, c.planted, better: Better.higher, min: 1, whenEmpty: 1,
          description: 'planted constraints and preferences present in the final rolling summary'),
      Metric('ledger_duplicates', c.duplicates.toDouble(), better: Better.lower, unit: 'count', max: 0),
    ]);
    return report;
  }
}
