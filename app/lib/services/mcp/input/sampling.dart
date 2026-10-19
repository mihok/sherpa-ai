/// Runs an approved `sampling/createMessage` on the user's model, within
/// the limits the user set: the capped `maxTokens`, no tools ever, no
/// conversation context, and on-device models at background priority so a
/// server's request never delays the user's own reply.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart' show InferencePriority, LlamaCppProvider;
import 'package:sherpa_mcp/sherpa_mcp.dart';

import '../../../state/services.dart';
import '../../inference/local_model_provider.dart';

/// The provider a sampling request runs on, and at which priority.
typedef SamplingProviderView = (ModelProvider provider, InferencePriority? priority) Function(ModelProvider provider);

/// On-device providers at [InferencePriority.background]; remote ones as
/// they are.
(ModelProvider, InferencePriority?) backgroundSamplingView(ModelProvider p) => switch (p) {
      LocalModelProvider() => (p.withPriority(InferencePriority.background), InferencePriority.background),
      LlamaCppProvider() => (p.withPriority(InferencePriority.background), InferencePriority.background),
      _ => (p, null),
    };

/// What the approval sheet shows about the cost.
@immutable
final class SamplingEstimate {
  const SamplingEstimate({required this.inputTokens, required this.maxOutputTokens});

  /// Heuristic count of the messages and system prompt.
  final int inputTokens;
  final int maxOutputTokens;

  int get totalTokens => inputTokens + maxOutputTokens;
}

/// The finished completion.
@immutable
final class SamplingCompletion {
  const SamplingCompletion({
    required this.text,
    required this.model,
    required this.stopReason,
    required this.outputTokens,
    this.priority,
    this.location,
  });

  final String text;
  final ModelChoice model;

  /// MCP wire value: `endTurn`, `maxTokens`, `stopSequence` or another.
  final String stopReason;
  final int outputTokens;

  /// The scheduling priority the provider ran at (on-device: background).
  final InferencePriority? priority;
  final ExecutionLocation? location;
}

final class SamplingException implements Exception {
  const SamplingException(this.message);

  final String message;

  @override
  String toString() => 'SamplingException: $message';
}

/// The user's model for MCP sampling.
final class McpSamplingService {
  McpSamplingService({
    required ProviderRegistry registry,
    required ModelChoice? Function() defaultModel,
    SamplingProviderView view = backgroundSamplingView,
    TokenCounter? counter,
    Clock clock = const SystemClock(),
    IdGenerator? ids,
  })  : _registry = registry,
        _defaultModel = defaultModel,
        _view = view,
        _counter = counter ?? HeuristicTokenCounter(),
        _clock = clock,
        _ids = ids ?? RandomIdGenerator();

  final ProviderRegistry _registry;
  final ModelChoice? Function() _defaultModel;
  final SamplingProviderView _view;
  final TokenCounter _counter;
  final Clock _clock;
  final IdGenerator _ids;

  /// The model a request runs on: the server's chosen model, else the
  /// chat's current one, else the app default. Null: none configured.
  ModelChoice? modelFor({ModelChoice? serverChoice, ModelChoice? chatModel}) =>
      serverChoice ?? chatModel ?? _defaultModel();

  /// Index of the message the approval sheet lets the user edit: the last
  /// user message with text. Null when there is none.
  static int? editableIndex(McpSamplingRequest r) {
    for (var i = r.messages.length - 1; i >= 0; i--) {
      final m = r.messages[i];
      if (m.role == 'user' && m.content.any((c) => c is McpTextContent)) return i;
    }
    return null;
  }

  /// The text of message [i].
  static String textOf(McpSamplingMessage m) => [for (final c in m.content) if (c is McpTextContent) c.text].join('\n');

  SamplingEstimate estimate(McpSamplingRequest r, {required int maxTokens, String? editedPrompt}) {
    final edit = editableIndex(r);
    var tokens = r.systemPrompt == null ? 0 : _counter.countText(r.systemPrompt!);
    for (final (i, m) in r.messages.indexed) {
      if (i == edit && editedPrompt != null) {
        tokens += _counter.countText(editedPrompt) + 4;
        continue;
      }
      tokens += _counter.countMessage(_message(m, i));
    }
    return SamplingEstimate(inputTokens: tokens, maxOutputTokens: maxTokens);
  }

  Message _message(McpSamplingMessage m, int i, {String? replaceText}) => Message(
        id: 'sampling-$i-${_ids.next('m')}',
        role: m.role == 'assistant' ? Role.assistant : Role.user,
        content: replaceText != null
            ? [TextPart(replaceText), for (final c in m.content) if (c is! McpTextContent) c.toContentPart()]
            : [for (final c in m.content) c.toContentPart()],
        createdAt: _clock.now(),
      );

  /// Runs [request] on [model].
  ///
  /// * The completion gets `maxOutputTokens: maxTokens` and NO tools
  ///   (sampling tools are never declared); the model's own tool calls, if
  ///   any, are ignored.
  /// * `temperature`, `stopSequences` and `metadata` are ignored (the spec
  ///   lets clients; several current models reject sampling parameters),
  ///   and `includeContext` is never honoured: only the server's messages
  ///   are sent.
  /// * [editedPrompt] replaces the text of the editable user message.
  /// * Output beyond [maxTokens] (by the local estimate) is cut off.
  Future<SamplingCompletion> run({
    required McpSamplingRequest request,
    required ModelChoice model,
    required int maxTokens,
    String? editedPrompt,
    String? systemPrompt,
    CancellationToken? cancel,
  }) async {
    final ModelProvider base;
    try {
      base = await _registry.resolve(model.providerId);
    } on Object catch (e) {
      throw SamplingException('The model is not available ($e).');
    }
    final (provider, priority) = _view(base);
    final edit = editableIndex(request);
    final messages = [
      for (final (i, m) in request.messages.indexed) _message(m, i, replaceText: i == edit ? editedPrompt : null),
    ];
    final token = (cancel ?? CancellationToken()).child();
    final buffer = StringBuffer();
    var reason = 'endTurn';
    int? reported;
    try {
      await for (final e in provider.stream(
        ModelRequest(
          modelId: model.modelId,
          messages: messages,
          systemPrompt: systemPrompt ?? request.systemPrompt,
          params: GenerationParams(maxOutputTokens: maxTokens),
        ),
        cancel: token,
      )) {
        switch (e) {
          case TextDelta(:final text):
            buffer.write(text);
            if (_counter.countText(buffer.toString()) > maxTokens + 8) {
              reason = 'maxTokens';
              token.cancel('max tokens');
            }
          case UsageUpdate(:final usage):
            reported = usage.outputTokens;
          case Finish(reason: final r, :final rawReason):
            if (reason != 'maxTokens') {
              reason = switch (r) {
                FinishReason.stop || FinishReason.toolCalls => 'endTurn',
                FinishReason.length => 'maxTokens',
                FinishReason.cancelled => (cancel?.isCancelled ?? false) ? 'cancelled' : reason,
                _ => rawReason ?? r.name,
              };
            }
          default:
            break;
        }
      }
    } on ProviderException catch (e) {
      throw SamplingException(e.message);
    } finally {
      token.detach();
    }
    if (cancel?.isCancelled ?? false) throw const CancelledException('sampling cancelled');
    var text = buffer.toString();
    if (reason == 'maxTokens' && _counter.countText(text) > maxTokens + 8) {
      // Trim to roughly the cap (heuristic counter: ~4 chars a token).
      final keep = (maxTokens * 4).clamp(0, text.length);
      text = text.substring(0, keep);
    }
    return SamplingCompletion(
      text: text,
      model: model,
      stopReason: reason,
      outputTokens: reported ?? _counter.countText(text),
      priority: priority,
      location: provider.info.location,
    );
  }
}

/// Requests per minute per server (a sliding one-minute window).
final class SamplingRateLimiter {
  SamplingRateLimiter({Clock clock = const SystemClock()}) : _clock = clock;

  final Clock _clock;
  final Map<String, List<DateTime>> _recent = {};

  /// Takes a slot for [serverId]; false when [perMinute] were used in the
  /// last minute.
  bool tryAcquire(String serverId, int perMinute) {
    final now = _clock.now();
    final list = _recent.putIfAbsent(serverId, () => []);
    list.removeWhere((t) => now.difference(t) >= const Duration(minutes: 1));
    if (list.length >= perMinute) return false;
    list.add(now);
    return true;
  }
}
