import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:test/test.dart';

/// Exact, deterministic counter: 1 token per 4 chars, 4 per message.
/// Exact means no estimate margin, so tests reason about plain numbers.
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

  Message user(String text, {bool pinned = false}) => _add(
    (id, parent, at) =>
        Message(id: id, parentId: parent, role: Role.user, content: [TextPart(text)], createdAt: at, pinned: pinned),
  );

  Message assistant(String text, {List<ToolCall> calls = const [], String? reasoning, String? prefixKey}) => _add(
    (id, parent, at) => Message(
      id: id,
      parentId: parent,
      role: Role.assistant,
      createdAt: at,
      content: [
        if (reasoning != null) ReasoningPart(text: reasoning, signature: 'sig-$id'),
        if (text.isNotEmpty) TextPart(text),
        for (final c in calls) ToolCallPart(c),
      ],
      finishReason: calls.isEmpty ? 'stop' : 'toolCalls',
      metadata: prefixKey == null ? const {} : {'prefixKey': prefixKey},
    ),
  );

  Message results(List<ToolResultPart> parts, {bool pinned = false}) => _add(
    (id, parent, at) =>
        Message(id: id, parentId: parent, role: Role.tool, content: parts, createdAt: at, pinned: pinned),
  );

  /// An assistant call followed by its result.
  void toolTurn(
    String callId,
    String tool,
    Map<String, Object?> args,
    String result, {
    bool isError = false,
    bool pinned = false,
    JsonMap? structured,
  }) {
    assistant(
      '',
      calls: [ToolCall(id: callId, name: tool, arguments: args)],
    );
    results([
      ToolResultPart(
        callId: callId,
        toolName: tool,
        content: [TextPart(result)],
        isError: isError,
        structured: structured,
      ),
    ], pinned: pinned);
  }
}

ContextRequest req(
  List<Message> path, {
  List<ContextOverlay> overlays = const [],
  int window = 8192,
  int? maxOutput = 512,
  HistoryPolicy policy = HistoryPolicy.mutable,
  ContextSettings settings = const ContextSettings(),
  List<ToolDefinition> tools = const [],
  Plan? plan,
  MemoryState memory = MemoryState.unknown,
  ExecutionLocation? location,
  TokenCounter counter = const QuarterCounter(),
  String? systemPrompt = 'You are a test assistant.',
  String? nonce = 'nonce0123456789ab',
}) => ContextRequest(
  sessionId: 's1',
  path: path,
  overlays: overlays,
  tools: tools,
  capabilities: ModelCapabilities(contextLength: window, maxOutputTokens: maxOutput, historyPolicy: policy),
  counter: counter,
  systemPrompt: systemPrompt,
  plan: plan,
  memory: memory,
  settings: settings,
  boundaryNonce: nonce,
  location: location,
);

/// Thresholds that make every stage run (prune at 5%) without compacting.
final WindowProfile pruneEverything = WindowProfile(
  thresholds: const ContextThresholds(prune: 0.05, compact: 0.98, handoff: 0.99),
  keepRecentUserTurns: 2,
  keptTailFraction: 0.3,
);

/// Thresholds that compact whenever there is anything to compact (stage 1
/// runs first, so conversations without tool results are best here).
final WindowProfile compactEverything = WindowProfile(
  thresholds: const ContextThresholds(prune: 0.01, compact: 0.02, handoff: 0.99),
  keepRecentUserTurns: 1,
  keptTailFraction: 0.9,
);

String lines(int n, {String prefix = 'line'}) =>
    [for (var i = 0; i < n; i++) '$prefix $i of the payload text'].join('\n');

/// The provider-facing invariant on a message list sent to a model.
void expectProviderInvariants(List<Message> messages, {String? reason}) {
  expect(ToolPairing.validate(messages), isEmpty, reason: reason);
  for (final (i, m) in messages.indexed) {
    if (m.role == Role.tool) {
      expect(i, greaterThan(0), reason: reason);
      final prev = messages[i - 1];
      expect(prev.role, Role.assistant, reason: reason);
      expect(m.toolResults.map((r) => r.callId).toSet(), prev.toolCalls.map((c) => c.id).toSet(), reason: reason);
    }
    if (m.hasToolCalls && i < messages.length - 1) {
      expect(messages[i + 1].role, Role.tool, reason: reason);
    }
  }
}

const ToolDefinition readFile = ToolDefinition(
  name: 'read_file',
  description: 'Read a file',
  inputSchema: {'type': 'object'},
  annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: false),
);

const ToolDefinition writeFile = ToolDefinition(
  name: 'write_file',
  description: 'Write a file',
  inputSchema: {'type': 'object'},
  annotations: ToolAnnotations(destructiveHint: true),
);
