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
  });

  final String sessionId;
  final CancellationToken cancel;
  final Duration timeout;
  final void Function(ToolProgress progress)? onProgress;
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
  /// [query] is the latest user intent, used for tool search ranking.
  Future<List<ToolDefinition>> toolsForTurn({
    required String sessionId,
    String? query,
    int? schemaTokenBudget,
  });

  /// Looks up any known tool by its model-facing name (even if deferred).
  ToolDefinition? lookup(String name);

  /// Runs a call. Must not throw for tool-level failures: return
  /// [ToolResult.error] so the model can recover. Throws
  /// [CancelledException] only when cancelled.
  Future<ToolResult> execute(ToolCall call, ToolExecutionContext context);
}
