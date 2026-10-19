/// Synthetic transcripts for the context-manager suites (L0 carry-forward,
/// L4 fidelity) and the context-ladder benchmark.
library;

import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';

/// Exact, deterministic counter: 1 token per 4 chars, 4 per message, so
/// budgets and summary costs are plain numbers.
final class QuarterCounter implements TokenCounter {
  const QuarterCounter();

  @override
  bool get isExact => true;

  @override
  int countText(String text) => (text.length / 4).ceil();

  @override
  int countMessage(Message message) {
    var n = 4;
    for (final p in message.content) {
      n += switch (p) {
        TextPart(:final text) => countText(text),
        ReasoningPart(:final text) => countText(text),
        ToolCallPart(:final call) => countText(call.name) + countText(jsonEncode(call.arguments)) + 2,
        ToolResultPart() => countText(p.text) + (p.structured == null ? 0 : countText(jsonEncode(p.structured))) + 2,
        _ => 8,
      };
    }
    return n;
  }

  @override
  int countTools(List<ToolDefinition> tools) =>
      tools.fold(0, (n, t) => n + countText(t.name) + countText(t.description) + countText(jsonEncode(t.inputSchema)));
}

/// Builds a linear transcript with sequential ids and parent links.
final class Conv {
  Conv([DateTime? start]) : _t = start ?? DateTime.utc(2026, 10, 18);

  final List<Message> messages = [];
  DateTime _t;
  int _n = 0;

  String get _next => 'm${++_n}';

  Message _add(Message Function(String id, String? parent, DateTime at) build) {
    _t = _t.add(const Duration(seconds: 1));
    final m = build(_next, messages.isEmpty ? null : messages.last.id, _t);
    messages.add(m);
    return m;
  }

  Message user(String text) => _add(
        (id, parent, at) => Message(id: id, parentId: parent, role: Role.user, content: [TextPart(text)], createdAt: at),
      );

  Message assistant(String text, {List<ToolCall> calls = const []}) => _add(
        (id, parent, at) => Message(
          id: id,
          parentId: parent,
          role: Role.assistant,
          createdAt: at,
          content: [
            if (text.isNotEmpty) TextPart(text),
            for (final c in calls) ToolCallPart(c),
          ],
          finishReason: calls.isEmpty ? 'stop' : 'toolCalls',
        ),
      );

  Message results(List<ToolResultPart> parts) =>
      _add((id, parent, at) => Message(id: id, parentId: parent, role: Role.tool, content: parts, createdAt: at));

  /// An assistant call followed by its result.
  void toolTurn(String callId, String tool, Map<String, Object?> args, String result, {bool isError = false}) {
    assistant('', calls: [ToolCall(id: callId, name: tool, arguments: args)]);
    results([
      ToolResultPart(callId: callId, toolName: tool, content: [TextPart(result)], isError: isError),
    ]);
  }
}

/// A context request over [path] with an exact counter.
ContextRequest contextRequest(
  List<Message> path, {
  List<ContextOverlay> overlays = const [],
  int window = 65536,
  int maxOutput = 512,
  ContextSettings settings = const ContextSettings(),
  List<ToolDefinition> tools = const [],
  TokenCounter counter = const QuarterCounter(),
  String systemPrompt = 'You are a test assistant.',
  String sessionId = 's1',
}) =>
    ContextRequest(
      sessionId: sessionId,
      path: path,
      overlays: overlays,
      tools: tools,
      capabilities: ModelCapabilities(contextLength: window, maxOutputTokens: maxOutput),
      counter: counter,
      systemPrompt: systemPrompt,
      settings: settings,
      boundaryNonce: 'nonce0123456789ab',
    );

/// Thresholds that compact whenever there is anything to compact.
final WindowProfile compactEverything = WindowProfile(
  thresholds: const ContextThresholds(prune: 0.01, compact: 0.02, handoff: 0.99),
  keepRecentUserTurns: 1,
  keptTailFraction: 0.9,
);

String filler(int n, {String prefix = 'line'}) => [for (var i = 0; i < n; i++) '$prefix $i of the payload text'].join('\n');
