import '../model/tool.dart';
import 'tool_router.dart';

/// Fans a turn's tool selection out to several routers (built-ins,
/// on-device servers, MCP) and dispatches calls to whichever owns the name.
/// Earlier routers win on name collisions; MCP routers namespace their
/// tools so collisions only happen through misconfiguration.
final class CompositeToolRouter implements ToolRouter {
  CompositeToolRouter(this.routers);

  final List<ToolRouter> routers;

  /// Each router learns how many tools the earlier ones already offer
  /// ([ToolSelectionHints.reservedTools]), so budgets add up.
  @override
  Future<List<ToolDefinition>> toolsForTurn({
    required String sessionId,
    String? query,
    int? schemaTokenBudget,
    ToolSelectionHints? hints,
  }) async {
    final seen = <String>{};
    final out = <ToolDefinition>[];
    for (final r in routers) {
      final tools = await r.toolsForTurn(
        sessionId: sessionId,
        query: query,
        schemaTokenBudget: schemaTokenBudget,
        hints: hints?.copyWith(reservedTools: hints.reservedTools + out.length),
      );
      for (final t in tools) {
        if (seen.add(t.name)) out.add(t);
      }
    }
    return out;
  }

  @override
  ToolDefinition? lookup(String name) => _owner(name)?.lookup(name);

  /// Delegates to the router that owns the called name (the one [execute]
  /// would use).
  @override
  ResolvedToolCall? resolve(ToolCall call, {required String sessionId}) {
    final r = _owner(call.name);
    if (r == null) return null;
    return r.resolve(call, sessionId: sessionId) ?? ResolvedToolCall(call: call, tool: r.lookup(call.name));
  }

  @override
  Future<ToolResult> execute(ToolCall call, ToolExecutionContext context) async {
    final r = _owner(call.name);
    if (r != null) return r.execute(call, context);
    return ToolResult.error('Unknown tool "${call.name}". Use only the tools provided.');
  }

  ToolRouter? _owner(String name) {
    for (final r in routers) {
      if (r.lookup(name) != null) return r;
    }
    return null;
  }
}

/// A router over a fixed set of in-process Dart tools.
final class LocalToolRouter implements ToolRouter {
  LocalToolRouter(List<LocalTool> tools) : _tools = {for (final t in tools) t.definition.name: t};

  final Map<String, LocalTool> _tools;

  @override
  Future<List<ToolDefinition>> toolsForTurn({
    required String sessionId,
    String? query,
    int? schemaTokenBudget,
    ToolSelectionHints? hints,
  }) async =>
      [for (final t in _tools.values) t.definition];

  @override
  ToolDefinition? lookup(String name) => _tools[name]?.definition;

  @override
  ResolvedToolCall? resolve(ToolCall call, {required String sessionId}) {
    final d = lookup(call.name);
    return d == null ? null : ResolvedToolCall(call: call, tool: d);
  }

  @override
  Future<ToolResult> execute(ToolCall call, ToolExecutionContext context) async {
    final tool = _tools[call.name];
    if (tool == null) return ToolResult.error('Unknown tool "${call.name}".');
    try {
      return await tool.run(call.arguments, context);
    } on Exception catch (e) {
      return ToolResult.error('Tool "${call.name}" failed: $e');
    }
  }
}

/// An in-process tool implementation.
abstract interface class LocalTool {
  ToolDefinition get definition;

  Future<ToolResult> run(Map<String, Object?> arguments, ToolExecutionContext context);
}
