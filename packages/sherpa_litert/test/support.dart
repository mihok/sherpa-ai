import 'dart:async';

import 'package:sherpa_core/sherpa_core.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 19);
int _n = 0;

Message user(String text, {List<ContentPart> extra = const []}) =>
    Message(id: 'u${_n++}', role: Role.user, content: [TextPart(text), ...extra], createdAt: _t0);

Message assistant(String text, {List<ToolCall> calls = const [], String? finishReason, String? providerId}) => Message(
      id: 'a${_n++}',
      role: Role.assistant,
      content: [if (text.isNotEmpty) TextPart(text), for (final c in calls) ToolCallPart(c)],
      createdAt: _t0,
      finishReason: finishReason,
      providerId: providerId,
    );

Message system(String text) => Message(id: 's${_n++}', role: Role.system, content: [TextPart(text)], createdAt: _t0);

Message toolResults(List<ToolResultPart> results) =>
    Message(id: 't${_n++}', role: Role.tool, content: results, createdAt: _t0);

ToolResultPart result(String callId, String name, String text, {bool isError = false}) =>
    ToolResultPart(callId: callId, toolName: name, content: [TextPart(text)], isError: isError);

const ToolDefinition weatherTool = ToolDefinition(
  name: 'get_weather',
  description: 'Current weather for a city.',
  inputSchema: {
    r'$schema': 'https://json-schema.org/draft/2020-12/schema',
    'type': 'object',
    'title': 'GetWeather',
    'properties': {
      'city': {'type': 'string', 'title': 'City'},
    },
    'required': ['city'],
  },
);

const ToolDefinition searchTool = ToolDefinition(
  name: 'search',
  description: 'Search the web.',
  inputSchema: {
    'type': 'object',
    'properties': {
      'q': {'type': 'string'},
    },
  },
);

ModelRequest request(
  List<Message> messages, {
  String modelId = 'gemma',
  String? system = 'You are Sherpa.',
  List<ToolDefinition> tools = const [],
  GenerationParams params = const GenerationParams(),
  String? session = 's1',
}) =>
    ModelRequest(
      modelId: modelId,
      systemPrompt: system,
      messages: messages,
      tools: tools,
      params: params,
      cache: CacheHints(sessionId: session),
    );

/// Collects a provider stream: events, or the error it failed with.
Future<({List<ModelEvent> events, Object? error})> collect(Stream<ModelEvent> s) async {
  final events = <ModelEvent>[];
  Object? error;
  try {
    await for (final e in s) {
      events.add(e);
    }
  } on Object catch (e) {
    error = e;
  }
  return (events: events, error: error);
}

String textOf(List<ModelEvent> events) => events.whereType<TextDelta>().map((e) => e.text).join();

List<ToolCall> callsOf(List<ModelEvent> events) =>
    events.whereType<ToolCallComplete>().map((e) => e.call).toList();

Finish? finishOf(List<ModelEvent> events) => events.whereType<Finish>().lastOrNull;

/// Builds the assistant message the agent loop would store from [events].
Message replyFrom(List<ModelEvent> events, {String providerId = 'litert_lm'}) => Message(
      id: 'r${_n++}',
      role: Role.assistant,
      content: [
        if (textOf(events).isNotEmpty) TextPart(textOf(events)),
        for (final c in callsOf(events)) ToolCallPart(c),
      ],
      createdAt: _t0,
      providerId: providerId,
      finishReason: finishOf(events)?.reason.name,
    );

/// Lets queued microtasks and zero-delay timers run.
Future<void> settle([int rounds = 5]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
