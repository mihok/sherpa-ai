import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sherpa_core/sherpa_core.dart';

final DateTime t0 = DateTime.utc(2026, 10, 19);

Message user(String id, String text, {String? parent}) =>
    Message(id: id, role: Role.user, content: [TextPart(text)], createdAt: t0, parentId: parent);

Message assistant(String id, String text, {List<ToolCall> calls = const [], String? finish, String? providerId}) =>
    Message(
      id: id,
      role: Role.assistant,
      content: [if (text.isNotEmpty) TextPart(text), for (final c in calls) ToolCallPart(c)],
      createdAt: t0,
      finishReason: finish,
      providerId: providerId,
    );

Message toolResult(String id, String callId, String name, String text, {bool isError = false}) => Message(
  id: id,
  role: Role.tool,
  content: [
    ToolResultPart(callId: callId, toolName: name, content: [TextPart(text)], isError: isError),
  ],
  createdAt: t0,
);

const weatherTool = ToolDefinition(
  name: 'get_weather',
  title: 'Weather',
  description: 'Current weather for a city.',
  inputSchema: {
    r'$schema': 'https://json-schema.org/draft/2020-12/schema',
    'type': 'object',
    'title': 'Args',
    'properties': {
      'city': {'type': 'string', 'description': 'City name'},
      'unit': {
        'type': 'string',
        'enum': ['c', 'f'],
      },
    },
    'required': ['city'],
  },
);

ModelRequest request(
  List<Message> messages, {
  String model = 'qwen3',
  String? session = 's1',
  String? system = 'You are Sherpa.',
  List<ToolDefinition> tools = const [],
  GenerationParams params = const GenerationParams(),
}) => ModelRequest(
  modelId: model,
  messages: messages,
  systemPrompt: system,
  tools: tools,
  params: params,
  cache: CacheHints(sessionId: session),
);

/// Writes a minimal, complete Qwen3-style MLX model directory.
Directory mlxModelDir({
  String modelType = 'qwen3',
  bool tokenizer = true,
  bool template = true,
  bool shardMissing = false,
  bool npzOnly = false,
  int weightBytes = 1024,
}) {
  final dir = Directory.systemTemp.createTempSync('sherpa_apple_ml_');
  File('${dir.path}/config.json').writeAsStringSync(
    jsonEncode({
      'model_type': modelType,
      'max_position_embeddings': 40960,
      'num_hidden_layers': 28,
      'num_attention_heads': 16,
      'num_key_value_heads': 8,
      'head_dim': 128,
      'hidden_size': 1024,
      'quantization': {'bits': 4, 'group_size': 64},
    }),
  );
  if (npzOnly) {
    File('${dir.path}/weights.npz').writeAsBytesSync(List.filled(16, 0));
  } else {
    File('${dir.path}/model-00001-of-00002.safetensors').writeAsBytesSync(List.filled(weightBytes, 0));
    if (!shardMissing) {
      File('${dir.path}/model-00002-of-00002.safetensors').writeAsBytesSync(List.filled(weightBytes, 0));
    }
    File('${dir.path}/model.safetensors.index.json').writeAsStringSync(
      jsonEncode({
        'weight_map': {'a': 'model-00001-of-00002.safetensors', 'b': 'model-00002-of-00002.safetensors'},
      }),
    );
  }
  if (tokenizer) File('${dir.path}/tokenizer.json').writeAsStringSync('{}');
  File('${dir.path}/tokenizer_config.json').writeAsStringSync(
    jsonEncode({
      if (template) 'chat_template': '{% if tools %}{{ tools }}{% endif %}{% if enable_thinking %}<think>{% endif %}',
    }),
  );
  return dir;
}

/// Collects a stream's events and its error (if any).
Future<(List<ModelEvent>, Object?)> collect(Stream<ModelEvent> s) async {
  final out = <ModelEvent>[];
  Object? error;
  try {
    await for (final e in s) {
      out.add(e);
    }
  } on Object catch (e) {
    error = e;
  }
  return (out, error);
}

/// Waits until [condition] holds (pumping the event loop).
Future<void> until(bool Function() condition, {Duration timeout = const Duration(seconds: 2)}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

String textOf(List<ModelEvent> events) => events.whereType<TextDelta>().map((e) => e.text).join();

String reasoningOf(List<ModelEvent> events) => events.whereType<ReasoningDelta>().map((e) => e.text).join();

Finish finishOf(List<ModelEvent> events) => events.whereType<Finish>().single;

/// The assistant message the agent loop would store for [events].
Message storedReply(String id, List<ModelEvent> events) {
  final calls = events.whereType<ToolCallComplete>().map((e) => e.call).toList();
  return assistant(id, textOf(events), calls: calls, finish: finishOf(events).reason.name);
}
