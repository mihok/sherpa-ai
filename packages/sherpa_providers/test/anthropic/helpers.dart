import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';
// Imported directly (not via the package barrel) so these tests do not
// depend on the OpenAI/common sources other work streams are editing.
import 'package:sherpa_providers/src/anthropic/anthropic.dart';
import 'package:sherpa_providers/src/config.dart';

const String providerId = 'anthropic-test';

/// Reads `test/anthropic/fixtures/<name>.sse` (tests run from the package root).
String fixture(String name) => File('test/anthropic/fixtures/$name.sse').readAsStringSync();

/// Decodes a whole SSE text through [AnthropicStreamDecoder], splitting the
/// UTF-8 bytes into [chunks] (byte offsets) to exercise boundary handling.
/// A stream failure is returned as the last element.
Future<List<Object>> decode(
  String sse, {
  AnthropicToolNames names = AnthropicToolNames.empty,
  List<int> splitAt = const [],
  String? requestedModel,
}) async {
  final bytes = utf8.encode(sse);
  final cuts = [0, ...splitAt.where((c) => c > 0 && c < bytes.length), bytes.length];
  final chunks = [for (var i = 0; i + 1 < cuts.length; i++) bytes.sublist(cuts[i], cuts[i + 1])];
  final decoder = AnthropicStreamDecoder(providerId: providerId, toolNames: names, requestedModel: requestedModel);
  final out = <Object>[];
  try {
    await for (final e in Stream<List<int>>.fromIterable(chunks).transform(const SseDecoder())) {
      out.addAll(decoder.add(e));
    }
    out.addAll(decoder.close());
  } on AnthropicStreamFailure catch (f) {
    out
      ..addAll(f.before)
      ..add(f.error);
  }
  return out;
}

/// Compact, diff-friendly rendering of model events for golden asserts.
String describe(Object e) => switch (e) {
      TextDelta(:final text) => 'text:$text',
      ReasoningDelta(:final text) => 'reasoning:$text',
      ReasoningSignature(:final signature?, redactedData: null) => 'signature:$signature',
      ReasoningSignature(:final redactedData?) => 'redacted:$redactedData',
      ReasoningSignature() => 'signature:<none>',
      ToolCallStart(:final index, :final id, :final name) => 'start:$index:$id:$name',
      ToolCallArgsDelta(:final index, :final fragment) => 'args:$index:$fragment',
      ToolCallComplete(:final index, :final call) =>
        'complete:$index:${call.id}:${call.name}:${jsonEncode(call.arguments)}'
            '${call.argumentsError == null ? '' : '!${call.argumentsError}'}',
      UsageUpdate(:final usage) => 'usage:in=${usage.inputTokens},out=${usage.outputTokens},'
          'cr=${usage.cacheReadTokens},cw=${usage.cacheWriteTokens},r=${usage.reasoningTokens}',
      ProviderNotice(:final code) => 'notice:$code',
      Finish(:final reason, :final rawReason) => 'finish:${reason.name}:$rawReason',
      ProviderException(:final kind) => 'error:${kind.name}',
      _ => e.toString(),
    };

ProviderConfig testConfig({Uri? baseUrl, bool allowLocal = true, Map<String, String> headers = const {}}) =>
    ProviderConfig(
      id: providerId,
      flavor: ApiFlavor.anthropic,
      displayName: 'Anthropic (test)',
      baseUrl: baseUrl ?? Uri.parse('https://api.anthropic.com'),
      allowLocalNetwork: allowLocal,
      headers: headers,
    );

final DateTime t0 = DateTime.utc(2026, 10, 18, 12);

Message user(String id, String text) =>
    Message(id: id, role: Role.user, content: [TextPart(text)], createdAt: t0);

Message assistant(String id, List<ContentPart> content, {String? finishReason}) => Message(
      id: id,
      role: Role.assistant,
      content: content,
      createdAt: t0,
      providerId: providerId,
      finishReason: finishReason,
    );

Message toolMessage(String id, List<ToolResultPart> results) =>
    Message(id: id, role: Role.tool, content: results, createdAt: t0);

ReasoningPart thinking(String text, String signature, {String? provider = providerId}) =>
    ReasoningPart(text: text, signature: signature, providerId: provider);

ToolResultPart result(String callId, String text, {String tool = 'tool', bool isError = false}) =>
    ToolResultPart(callId: callId, toolName: tool, content: [TextPart(text)], isError: isError);

ToolDefinition tool(String name, {JsonMap? schema}) => ToolDefinition(
      name: name,
      description: 'Test tool $name.',
      inputSchema: schema ?? const {'type': 'object', 'properties': {}},
    );

/// Deep copy of a request fragment without `cache_control` markers, which
/// the API allows to move between requests.
Object? stripCache(Object? v) => switch (v) {
      Map<Object?, Object?>() => {
          for (final e in v.entries)
            if (e.key != 'cache_control') e.key.toString(): stripCache(e.value),
        },
      List<Object?>() => [for (final e in v) stripCache(e)],
      _ => v,
    };

/// Encodes a JSON fragment canonically for byte comparisons.
String bytesOf(Object? v) => jsonEncode(v);

/// Collects every `cache_control` location as a path string.
List<String> cachePaths(Object? v, [String path = r'$']) {
  final out = <String>[];
  if (v is Map) {
    if (v.containsKey('cache_control')) out.add(path);
    for (final e in v.entries) {
      out.addAll(cachePaths(e.value, '$path.${e.key}'));
    }
  } else if (v is List) {
    for (final (i, e) in v.indexed) {
      out.addAll(cachePaths(e, '$path[$i]'));
    }
  }
  return out;
}

/// Waits for [condition] with a deadline (tests that depend on sockets).
Future<void> eventually(bool Function() condition, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition not met', timeout);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
