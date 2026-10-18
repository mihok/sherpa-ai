import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

/// Raw text of a golden SSE fixture (test/fixtures/sse).
String fixture(String name) => File('test/fixtures/sse/$name').readAsStringSync();

/// A provider config for tests. Loopback is only reachable with
/// [allowLocalNetwork], which the fake servers need.
ProviderConfig testConfig(
  Uri baseUrl, {
  ServerProfile profile = ServerProfile.openAi,
  ApiFlavor flavor = ApiFlavor.openAiChat,
  bool allowLocalNetwork = true,
  Map<String, String> headers = const {},
  Map<String, ModelCapabilities> overrides = const {},
  String id = 'test-provider',
}) =>
    ProviderConfig(
      id: id,
      flavor: flavor,
      displayName: 'Test',
      baseUrl: baseUrl,
      profile: profile,
      allowLocalNetwork: allowLocalNetwork,
      headers: headers,
      modelOverrides: overrides,
    );

/// A literal loopback base URL (no DNS) for MockClient-backed tests.
final Uri mockBase = Uri.parse('http://127.0.0.1:9/v1');

/// A [MockClient] answering every request with [text] as an event stream,
/// split into byte chunks at [splitAt] offsets. [requests] records bodies.
http.Client mockSse(
  String text, {
  List<int> splitAt = const [],
  int status = 200,
  Map<String, String> headers = const {'content-type': 'text/event-stream'},
  List<http.BaseRequest>? requests,
  List<String>? bodies,
}) {
  final bytes = utf8.encode(text);
  return MockClient.streaming((request, body) async {
    requests?.add(request);
    final sent = await body.bytesToString();
    bodies?.add(sent);
    final chunks = <List<int>>[];
    var start = 0;
    for (final cut in [...splitAt, bytes.length]) {
      if (cut <= start || cut > bytes.length) continue;
      chunks.add(bytes.sublist(start, cut));
      start = cut;
    }
    if (start < bytes.length) chunks.add(bytes.sublist(start));
    return http.StreamedResponse(Stream.fromIterable(chunks), status, headers: headers);
  });
}

Future<List<ModelEvent>> collect(Stream<ModelEvent> s) => s.toList();

/// Collects events until the stream ends or fails; returns both.
Future<(List<ModelEvent>, Object?)> collectWithError(Stream<ModelEvent> s) async {
  final events = <ModelEvent>[];
  try {
    await for (final e in s) {
      events.add(e);
    }
    return (events, null);
  } on Object catch (e) {
    return (events, e);
  }
}

/// Compact, comparable rendering of an event (golden expectations).
String describe(ModelEvent e) => switch (e) {
      TextDelta(:final text) => 'Text($text)',
      ReasoningDelta(:final text) => 'Reasoning($text)',
      ReasoningSignature(:final signature, :final redactedData) =>
        'Signature(${signature ?? ''}${redactedData == null ? '' : ', redacted'})',
      ToolCallStart(:final index, :final id, :final name) => 'ToolCallStart($index, $id, $name)',
      ToolCallArgsDelta(:final index, :final fragment) => 'ToolCallArgsDelta($index, $fragment)',
      ToolCallComplete(:final index, :final call) =>
        'ToolCallComplete($index, ${call.id}, ${call.name}, ${jsonEncode(call.arguments)}'
            '${call.repaired ? ', repaired' : ''}${call.argumentsError == null ? '' : ', error'})',
      UsageUpdate(:final usage) => 'Usage(in ${usage.inputTokens}, cached ${usage.cacheReadTokens}, '
          'out ${usage.outputTokens}, reasoning ${usage.reasoningTokens})',
      ProviderNotice(:final code) => 'Notice($code)',
      PerfSample(:final promptTokens, :final cachedPromptTokens) => 'Perf($promptTokens, $cachedPromptTokens)',
      Finish(:final reason) => 'Finish(${reason.name})',
    };

List<String> describeAll(Iterable<ModelEvent> events) => [for (final e in events) describe(e)];

const weatherTool = ToolDefinition(
  name: 'get_weather',
  description: 'Current weather for a city.',
  inputSchema: {
    'type': 'object',
    'properties': {
      'city': {'type': 'string'},
    },
    'required': ['city'],
  },
);

const timeTool = ToolDefinition(
  name: 'get_time',
  description: 'Current time in a timezone.',
  inputSchema: {
    'type': 'object',
    'properties': {
      'timezone': {'type': 'string'},
    },
  },
);

final DateTime t0 = DateTime.utc(2026, 10, 18);

Message userText(String text, {String id = 'u1'}) =>
    Message(id: id, role: Role.user, content: [TextPart(text)], createdAt: t0);

ModelRequest weatherRequest({
  String model = 'test-model',
  List<ToolDefinition> tools = const [weatherTool, timeTool],
  GenerationParams params = const GenerationParams(),
  List<Message>? messages,
  String? systemPrompt = 'You are Sherpa.',
}) =>
    ModelRequest(
      modelId: model,
      systemPrompt: systemPrompt,
      messages: messages ?? [userText('Weather in Paris and the time in Tokyo?')],
      tools: tools,
      params: params,
    );

/// Waits for [condition] with a deadline (for server-side observations).
Future<void> eventually(bool Function() condition, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
