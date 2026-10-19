/// Tool-budget profiles (R11 §9.5, PLAN "Context segments").
library;

import 'package:meta/meta.dart';

import 'result_limits.dart';
import 'schema_normalizer.dart';

/// How many tools, and how many schema tokens, one session may be offered,
/// and how the deferred core set is filled.
///
/// The defaults are the research numbers:
/// * remote ([remote]): Anthropic's guidance is to defer when there are
///   ≥ 10 tools or > 10K tokens of definitions and that selection degrades
///   past 30–50 tools (R11 §(c)); 20 direct tools / 10K tokens keeps
///   ordinary setups direct and defers big ones, keeping the 3–5 most used
///   tools (here: 5 sticky) non-deferred.
/// * local ([local]): "Model-visible tools: at most 8" (R11 §9.5), with
///   normalized schemas (§9.6.5) and small result limits.
/// * ≤ 2B ([tiny]): "at most 5 for models ≤ 2B".
///
/// [maxTools] counts what THIS router offers including the two proxies;
/// set [reservedSlots] to the number of built-in tools other routers add
/// (e.g. `update_plan`) so the total stays within the model's limit.
@immutable
final class ToolBudget {
  const ToolBudget({
    required this.maxTools,
    required this.maxSchemaTokens,
    this.stickyTools = 3,
    this.queryTools = 2,
    this.searchLimit = 5,
    this.reservedSlots = 0,
    this.normalizeSchemas = false,
    this.normalization = const SchemaNormalizationOptions(),
    this.resultLimits = const ToolResultLimits(),
  });

  /// Remote models (Anthropic, OpenAI, compatible servers).
  static const ToolBudget remote = ToolBudget(maxTools: 20, maxSchemaTokens: 10000, stickyTools: 5, queryTools: 3);

  /// On-device models above 2B parameters.
  static const ToolBudget local = ToolBudget(
    maxTools: 8,
    maxSchemaTokens: 3000,
    stickyTools: 2,
    queryTools: 2,
    normalizeSchemas: true,
    resultLimits: ToolResultLimits.local,
  );

  /// On-device models of 2B parameters or fewer.
  static const ToolBudget tiny = ToolBudget(
    maxTools: 5,
    maxSchemaTokens: 1500,
    stickyTools: 1,
    queryTools: 1,
    searchLimit: 3,
    normalizeSchemas: true,
    resultLimits: ToolResultLimits.tiny,
  );

  /// Picks a profile from what the app knows about the session's model.
  static ToolBudget forModel({required bool onDevice, double? parameterBillions, int reservedSlots = 0}) {
    final base = !onDevice
        ? remote
        : (parameterBillions != null && parameterBillions <= 2.0 ? tiny : local);
    return reservedSlots == 0 ? base : base.copyWith(reservedSlots: reservedSlots);
  }

  /// Tools this router may offer in direct mode (all of them, or switch to
  /// deferred mode when there are more).
  final int maxTools;

  /// Schema tokens this router may spend; the caller's
  /// `schemaTokenBudget` lowers it further.
  final int maxSchemaTokens;

  /// Deferred mode: recently used tools carried into the next segment's
  /// core set ("tools used in the last 2 turns stay", R11 §9.5).
  final int stickyTools;

  /// Deferred mode: tools ranked by the turn's query added to a new
  /// segment's core set.
  final int queryTools;

  /// Default `tool_search` result count ("top-k = 5").
  final int searchLimit;

  /// Slots taken by other routers' always-on tools.
  final int reservedSlots;

  /// Render schemas through [SchemaNormalizer] (local models).
  final bool normalizeSchemas;
  final SchemaNormalizationOptions normalization;
  final ToolResultLimits resultLimits;

  /// Tool slots this router has.
  int get slots => (maxTools - reservedSlots).clamp(2, 1 << 20);

  /// Core tools in deferred mode (the two proxies take two slots).
  int get coreSlots => slots - 2;

  ToolBudget copyWith({
    int? maxTools,
    int? maxSchemaTokens,
    int? stickyTools,
    int? queryTools,
    int? searchLimit,
    int? reservedSlots,
    bool? normalizeSchemas,
    SchemaNormalizationOptions? normalization,
    ToolResultLimits? resultLimits,
  }) =>
      ToolBudget(
        maxTools: maxTools ?? this.maxTools,
        maxSchemaTokens: maxSchemaTokens ?? this.maxSchemaTokens,
        stickyTools: stickyTools ?? this.stickyTools,
        queryTools: queryTools ?? this.queryTools,
        searchLimit: searchLimit ?? this.searchLimit,
        reservedSlots: reservedSlots ?? this.reservedSlots,
        normalizeSchemas: normalizeSchemas ?? this.normalizeSchemas,
        normalization: normalization ?? this.normalization,
        resultLimits: resultLimits ?? this.resultLimits,
      );
}
