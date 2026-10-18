import '../model/tool.dart';
import 'tool_router.dart';

/// Fans a turn's tool selection out to several routers (built-ins,
/// on-device servers, MCP) and dispatches calls to whichever owns the name.
/// Earlier routers win on name collisions; MCP routers namespace their
/// tools so collisions only happen through misconfiguration.
final class CompositeToolRouter implements ToolRouter {
  CompositeToolRouter(this.routers);

  final List<ToolRouter> routers;

  @override
  Future<List<ToolDefinition>> toolsForTurn({
    required String sessionId,
    String? query,
    int? schemaTokenBudget,
  }) async {
    final seen = <String>{};
    final out = <ToolDefinition>[];
    for (final r in routers) {
      final tools = await r.toolsForTurn(
        sessionId: sessionId,
        query: query,
        schemaTokenBudget: schemaTokenBudget,
      );
      for (final t in tools) {
        if (seen.add(t.name)) out.add(t);
      }
    }
    return out;
  }

  @override
  ToolDefinition? lookup(String name) {
    for (final r in routers) {
      final t = r.lookup(name);
      if (t != null) return t;
    }
    return null;
  }

  @override
  Future<ToolResult> execute(ToolCall call, ToolExecutionContext context) async {
    for (final r in routers) {
      if (r.lookup(call.name) != null) return r.execute(call, context);
    }
    return ToolResult.error('Unknown tool "${call.name}". Use only the tools provided.');
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
  }) async =>
      [for (final t in _tools.values) t.definition];

  @override
  ToolDefinition? lookup(String name) => _tools[name]?.definition;

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
