/// The suite contract and what the runner hands each suite.
library;

import '../report.dart';
import '../runtime/models.dart';

/// Everything a suite run needs.
final class EvalContext {
  EvalContext({
    required this.model,
    this.runtime,
    this.trials,
    this.limit,
    this.only,
    void Function(String line)? log,
  }) : log = log ?? ((_) {});

  final ModelSpec model;

  /// The live model for non-scripted runs (shared across suites).
  final ModelRuntime? runtime;

  /// Trials per task (pass^k); suites pick a default when null.
  final int? trials;

  /// Run at most this many cases/tasks (real-model subsets).
  final int? limit;

  /// Only cases whose id contains this (or any entry of a comma list).
  final String? only;
  final void Function(String line) log;

  bool get scripted => model.isScripted;

  /// Applies [only] (a comma list: ids containing any entry) and [limit]
  /// to a case list.
  List<T> select<T>(List<T> items, String Function(T) id, {int? defaultLimit}) {
    final want = only?.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    var out = want == null || want.isEmpty ? items : items.where((x) => want.any(id(x).contains)).toList();
    final n = limit ?? defaultLimit;
    if (n != null && out.length > n) out = out.sublist(0, n);
    return out;
  }
}

abstract interface class EvalSuite {
  /// `L0` … `L5`.
  String get id;
  String get title;

  /// Whether the suite has anything to run for [model] (L2 needs a real
  /// model for numbers, but proves its scorer with the scripted oracle).
  bool supports(ModelSpec model);

  Future<SuiteReport> run(EvalContext ctx);
}
