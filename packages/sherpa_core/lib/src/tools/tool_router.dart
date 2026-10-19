import 'package:meta/meta.dart';

import '../common/cancellation.dart';
import '../common/json.dart';
import '../model/content.dart';
import '../model/tool.dart';

@immutable
final class ToolProgress {
  const ToolProgress({required this.progress, this.total, this.message});
  final double progress;
  final double? total;
  final String? message;

  double? get fraction => total == null || total == 0 ? null : progress / total!;
}

/// What the router needs to run one call.
@immutable
final class ToolExecutionContext {
  const ToolExecutionContext({
    required this.sessionId,
    required this.cancel,
    this.timeout = const Duration(seconds: 60),
    this.onProgress,
    this.idempotencyKey,
  });

  final String sessionId;
  final CancellationToken cancel;
  final Duration timeout;
  final void Function(ToolProgress progress)? onProgress;

  /// Stable, unique key of this call: `<assistantMessageId>:<callId>` when
  /// the agent loop runs it. Call ids alone repeat across turns (local
  /// models and some servers emit `call_0` every turn); the assistant
  /// message id is persisted, so the key survives `AgentRunner.resume`
  /// and a re-run of an interrupted call carries the same key (R11 §9.8).
  /// Null for calls made outside the loop.
  final String? idempotencyKey;
}

/// What the agent loop knows about the model a turn's tools are for, so a
/// router can size its tool budget (R11 §9.5: at most 8 tools for local
/// models, at most 5 below 2B parameters).
@immutable
final class ToolSelectionHints {
  const ToolSelectionHints({this.onDevice = false, this.parameterBillions, this.reservedTools = 0});

  /// The model runs on the device (small context, small model).
  final bool onDevice;

  /// Model size in billions of parameters, when known.
  final double? parameterBillions;

  /// Tool slots already taken by other routers (e.g. `update_plan`):
  /// `CompositeToolRouter` passes the number of tools collected so far.
  final int reservedTools;

  ToolSelectionHints copyWith({int? reservedTools}) => ToolSelectionHints(
        onDevice: onDevice,
        parameterBillions: parameterBillions,
        reservedTools: reservedTools ?? this.reservedTools,
      );
}

/// A tool call resolved to what will actually run.
///
/// For a direct call this is the call and its definition. For a proxy such
/// as MCP's `call_tool`, [call] is the inner call (target name and
/// arguments, same id) and [tool] the target's definition: the loop gates,
/// audits and asks the user about the real tool, never the proxy.
@immutable
final class ResolvedToolCall {
  const ResolvedToolCall({required this.call, this.tool, this.refusal, this.correctedName = false});

  final ToolCall call;

  /// The definition of the tool that will run; null when there is none.
  final ToolDefinition? tool;

  /// Why the router will not run the call (model-facing text). The loop
  /// answers the model with it and does not ask the user.
  final String? refusal;

  /// The tool name had to be normalized or fuzzy-matched. A call to a tool
  /// that is not read-only then always needs a one-off confirmation
  /// (R11 §9.6.7).
  final bool correctedName;
}

/// The outcome of a tool call before it is wrapped into a [ToolResultPart].
@immutable
final class ToolResult {
  const ToolResult({
    required this.content,
    this.structured,
    this.isError = false,
    this.uiResourceUri,
    this.meta = const {},
  });

  factory ToolResult.text(String text, {bool isError = false}) =>
      ToolResult(content: [TextPart(text)], isError: isError);

  factory ToolResult.error(String message) =>
      ToolResult(content: [TextPart(message)], isError: true);

  final List<ContentPart> content;
  final JsonMap? structured;
  final bool isError;
  final String? uiResourceUri;
  final JsonMap meta;
}

/// Selects which tools the model sees this turn, and executes calls.
///
/// Implementations aggregate built-in, on-device and MCP tools, apply
/// namespacing and per-session enable lists, and enforce the tool budget
/// (deferred loading / tool search) so schemas don't swamp the context.
abstract interface class ToolRouter {
  /// Tools to offer for the next model call, already budget-filtered.
  /// [query] is the latest user intent, used for tool search ranking;
  /// [hints] describe the model, for routers that size their budget by it.
  Future<List<ToolDefinition>> toolsForTurn({
    required String sessionId,
    String? query,
    int? schemaTokenBudget,
    ToolSelectionHints? hints,
  });

  /// Looks up any known tool by its model-facing name (even if deferred).
  ToolDefinition? lookup(String name);

  /// What [call] will actually run, or null when this router does not know
  /// the call. Routers without proxies return the call unchanged with its
  /// [lookup] definition. Must not run anything.
  ResolvedToolCall? resolve(ToolCall call, {required String sessionId});

  /// Runs a call. Must not throw for tool-level failures: return
  /// [ToolResult.error] so the model can recover. Throws
  /// [CancelledException] only when cancelled.
  Future<ToolResult> execute(ToolCall call, ToolExecutionContext context);
}
