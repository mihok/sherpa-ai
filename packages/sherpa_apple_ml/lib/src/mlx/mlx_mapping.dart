import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../common/errors.dart';
import '../common/think_splitter.dart';
import '../common/wire.dart';
import '../messages.pigeon.dart';
import 'mlx_config.dart';
import 'mlx_model_dir.dart';

/// A model loaded natively, with what Dart knows about it.
@immutable
final class MlxLoadedModel {
  const MlxLoadedModel({required this.spec, required this.dir, required this.info, required this.maxKVSize});

  final MlxModelSpec spec;
  final MlxModelDirectory dir;
  final AmMlxModelInfo info;
  final int? maxKVSize;

  /// Tool calls are parsed natively when mlx-swift-lm resolved a format for
  /// the model; a template that renders `tools` without a known format still
  /// gets them (the json parser is the fallback).
  bool get canCallTools => spec.toolCalling && (info.toolCallFormat != null || dir.templateMentionsTools);

  bool get hasReasoning => info.reasoningStart != null && info.reasoningEnd != null;

  ModelCapabilities get capabilities => ModelCapabilities(
    contextLength: maxKVSize ?? dir.contextLength ?? spec.preferredContext,
    // Template-rendered tools, parsed by mlx-swift-lm's format parsers;
    // no grammar constrains the output (unlike llama.cpp's lazy grammar).
    toolCallFormat: canCallTools ? ToolCallFormat.prompted : ToolCallFormat.none,
    parallelToolCalls: false,
    reasoning: !hasReasoning
        ? ReasoningSupport.none
        : info.reasoningAlwaysOn
        ? ReasoningSupport.always
        : ReasoningSupport.optional,
    quantization: dir.quantBits == null ? null : '${dir.quantBits}-bit',
    ramEstimateBytes: info.weightsBytes > 0 ? info.weightsBytes : dir.weightsBytes,
    tokenizerFamily: info.modelType ?? dir.modelType,
    supportsPromptCache: true,
    historyPolicy: HistoryPolicy.appendOnly,
  );
}

/// A request in the shape `mlxGenerate` takes, minus the history plan.
@immutable
final class MlxMappedRequest {
  const MlxMappedRequest({
    required this.instructions,
    required this.messages,
    required this.toolsJson,
    required this.sampling,
    required this.kv,
    required this.thinkingKey,
    required this.thinkingEnabled,
    required this.primedReasoning,
    required this.notices,
  });

  final String? instructions;
  final List<AmWireMessage> messages;
  final String? toolsJson;
  final AmSampling sampling;
  final AmKvConfig kv;
  final String? thinkingKey;
  final bool? thinkingEnabled;

  /// Start the [ThinkSplitter] inside a reasoning span.
  final bool primedReasoning;
  final List<ProviderNotice> notices;
}

/// Maps a core [ModelRequest] for MLX.
///
/// * The system prompt is `ChatSession.instructions` (re-rendered every
///   turn, so changing it keeps the session).
/// * Tools: OpenAI function shape (`ToolSpec`), schemas cleaned of
///   annotation-only keywords. `ToolChoice.none` sends none; `required` and
///   a specific tool cannot be forced (ChatSession has no tool_choice) and
///   produce a notice.
/// * `jsonSchema` is not applied (MLXGuidedGeneration is not wired) and stop
///   strings are not supported by `GenerateParameters`: both give notices.
/// * Reasoning: `ReasoningEffort.off` turns the template switch off
///   (`enable_thinking` for Qwen3); any other effort turns it on. Budgets are
///   not mapped (mlx-swift-lm's thinking budget needs a per-model
///   transition, R06 §2.7).
MlxMappedRequest mapMlxRequest(ModelRequest request, MlxLoadedModel model) {
  final notices = <ProviderNotice>[];
  final messages = const WireMapper().map(request.messages, notices: notices);
  final p = request.params;

  String? toolsJson;
  if (request.tools.isNotEmpty && p.toolChoice is! ToolChoiceNone) {
    if (!model.canCallTools) {
      notices.add(ProviderNotice('tools_dropped', '${model.spec.label} cannot call tools; none were offered.'));
    } else {
      toolsJson = jsonEncode([
        for (final t in request.tools)
          {
            'type': 'function',
            'function': {
              'name': t.name,
              'description': t.description,
              'parameters': normalizeToolSchema(t.inputSchema),
            },
          },
      ]);
      if (p.toolChoice is ToolChoiceRequired || p.toolChoice is ToolChoiceSpecific) {
        notices.add(
          const ProviderNotice(
            'tool_choice_unsupported',
            'MLX cannot force a tool call; the model decides whether to call one.',
          ),
        );
      }
    }
  }
  if (p.jsonSchema != null) {
    notices.add(
      const ProviderNotice(
        'json_schema_unsupported',
        'Structured output is not applied on MLX models; the reply is free text.',
      ),
    );
  }
  if (p.stop.isNotEmpty) {
    notices.add(const ProviderNotice('stop_unsupported', 'Stop sequences are not supported on MLX models.'));
  }

  final info = model.info;
  String? thinkingKey;
  bool? thinkingEnabled;
  var thinking = false;
  if (model.hasReasoning) {
    final effort = p.reasoning;
    if (info.reasoningAlwaysOn) {
      thinking = true;
      if (effort == ReasoningEffort.off) {
        notices.add(const ProviderNotice('reasoning_always_on', 'This model always reasons before answering.'));
      }
    } else if (info.reasoningToggleKey != null) {
      thinkingKey = info.reasoningToggleKey;
      thinkingEnabled = effort == null ? null : effort != ReasoningEffort.off;
      thinking = thinkingEnabled ?? info.reasoningToggleDefaultOn ?? false;
    }
  }
  // The stream starts inside reasoning only when thinking is on AND the
  // template pre-fills the opening delimiter (measured natively at load).
  final primedReasoning = thinking && info.reasoningPrimed;

  final extra = p.extra;
  final sampling = AmSampling()
    ..temperature = p.temperature
    ..topP = p.topP
    ..topK = p.topK
    ..minP = p.minP
    ..repetitionPenalty = p.repeatPenalty
    ..presencePenalty = (extra['presencePenalty'] as num?)?.toDouble()
    ..frequencyPenalty = (extra['frequencyPenalty'] as num?)?.toDouble()
    ..maxTokens = p.maxOutputTokens
    ..seed = p.seed;
  final s = model.spec.kv;
  final kv = AmKvConfig()
    ..kvBits = s.kvBits
    ..kvGroupSize = s.kvGroupSize
    ..quantizedKVStart = s.quantizedKVStart
    ..kvScheme = s.kvScheme
    ..maxKVSize = model.maxKVSize
    ..prefillStepSize = s.prefillStepSize;

  final system = request.systemPrompt?.trim() ?? '';
  return MlxMappedRequest(
    instructions: system.isEmpty ? null : request.systemPrompt,
    messages: messages,
    toolsJson: toolsJson,
    sampling: sampling,
    kv: kv,
    thinkingKey: thinkingKey,
    thinkingEnabled: thinkingEnabled,
    primedReasoning: primedReasoning,
    notices: notices,
  );
}

/// Drops annotation-only keywords (`$schema`, `title`, `examples`, …) that
/// cost prompt tokens; never renames keys, so validation still holds.
/// Deterministic, so the rendered tool block stays byte-stable.
JsonMap normalizeToolSchema(JsonMap schema) => _normalize(schema)! as JsonMap;

const Set<String> _dropKeys = {r'$schema', r'$id', r'$comment', 'title', 'examples'};

Object? _normalize(Object? v) {
  if (v is Map) {
    return <String, Object?>{
      for (final e in v.entries)
        if (!_dropKeys.contains(e.key))
          '${e.key}': e.key == 'properties' && e.value is Map
              ? {for (final p in (e.value as Map).entries) '${p.key}': _normalize(p.value)}
              : _normalize(e.value),
    };
  }
  if (v is List) return [for (final x in v) _normalize(x)];
  return v;
}

/// How a native generation ended.
sealed class NativeTerminal {
  const NativeTerminal();
}

final class NativeFinished extends NativeTerminal {
  const NativeFinished(this.code);
  final String code;
}

final class NativePaused extends NativeTerminal {
  const NativePaused(this.reason);
  final String reason;
}

final class NativeFailed extends NativeTerminal {
  const NativeFailed(this.error);
  final ProviderException error;
}

/// Stateful translation of one MLX generation's [AmEvent]s.
///
/// * text → [ThinkSplitter] → [TextDelta] / [ReasoningDelta];
/// * toolCall → [ToolCallStart] + [ToolCallArgsDelta] at once, and the
///   [ToolCallComplete] when the generation ends, because only the final
///   `info` says whether mlx-swift-lm *recovered* a call from a malformed or
///   foreign-dialect payload; then every call of the reply is marked
///   `repaired` (which forces approval of non-read-only tools, R11 §9.6.7);
/// * rejectedToolCall → a notice, plus (when the tool is known) a call
///   with `argumentsError`, so the loop tells the model what was wrong
///   instead of running anything;
/// * info → [UsageUpdate] (core normalization: inputTokens = prefilled,
///   cacheReadTokens = reused KV prefix) and [PerfSample];
/// * finished/paused/error → [terminal].
final class MlxEventMapper {
  MlxEventMapper({required this.providerId, required this.generationId, required ThinkSplitter splitter})
    : _splitter = splitter;

  final String providerId;
  final String generationId;
  final ThinkSplitter _splitter;
  final StringBuffer _answer = StringBuffer();
  final List<ToolCall> _calls = [];
  final List<int> _callIndexes = [];
  var _nextIndex = 0;
  var _recovered = 0;
  var _rejected = false;
  Usage? usage;
  NativeTerminal? terminal;

  bool get sawToolCalls => _calls.isNotEmpty;
  bool get rejectedToolCall => _rejected;

  /// The reply as the native ChatSession recorded it, in wire form (null
  /// when it did not record one: rejected call, or nothing produced).
  AmWireMessage? get produced {
    if (_rejected) return null;
    if (_answer.isEmpty && _calls.isEmpty && !_splitter.sawReasoning) return null;
    return AmWireMessage(role: 'assistant', content: _answer.toString())
      ..toolCalls = _calls.isEmpty
          ? null
          : [
              for (final c in _calls)
                AmToolCallWire(id: c.id, name: c.name, argumentsJson: WireMapper.argumentsForHistory(_final(c))),
            ];
  }

  ToolCall _final(ToolCall c) => _recovered > 0
      ? ToolCall(
          id: c.id,
          name: c.name,
          arguments: c.arguments,
          rawArguments: c.rawArguments,
          argumentsError: c.argumentsError,
          repaired: true,
        )
      : c;

  List<ModelEvent> map(AmEvent e) {
    switch (e.kind) {
      case AmEventKind.text:
        return _text(_splitter.add(e.text ?? ''));
      case AmEventKind.toolCall:
        final out = _text(_splitter.closeOnToolCall());
        final index = _nextIndex++;
        final id = (e.callId?.isNotEmpty ?? false) ? e.callId! : 'call_${generationId}_$index';
        final name = e.toolName ?? '';
        final raw = e.argumentsJson ?? '{}';
        out
          ..add(ToolCallStart(index: index, id: id, name: name))
          ..add(ToolCallArgsDelta(index: index, fragment: raw));
        _calls.add(_parse(id, name, raw));
        _callIndexes.add(index);
        return out;
      case AmEventKind.rejectedToolCall:
        _rejected = true;
        final out = <ModelEvent>[
          ProviderNotice(
            'tool_call_rejected',
            'The model produced a tool call that could not be used (${e.code}).',
            data: {'reason': e.code, 'tool': e.toolName, 'detail': e.message},
          ),
        ];
        final name = e.toolName;
        if (name != null && name.isNotEmpty) {
          final index = _nextIndex++;
          final id = (e.callId?.isNotEmpty ?? false) ? e.callId! : 'call_${generationId}_$index';
          out.add(ToolCallStart(index: index, id: id, name: name));
          _calls.add(
            ToolCall(
              id: id,
              name: name,
              arguments: const {},
              rawArguments: e.text,
              argumentsError:
                  'rejected by the tool-call parser (${e.code})${e.message == null ? '' : ': ${e.message}'}',
            ),
          );
          _callIndexes.add(index);
        }
        return out;
      case AmEventKind.info:
        _recovered = e.recoveredToolCalls ?? 0;
        final prefilled = e.promptTokens ?? 0;
        final cached = e.cachedPromptTokens ?? 0;
        final u = Usage(
          inputTokens: prefilled,
          outputTokens: e.generationTokens ?? 0,
          cacheReadTokens: cached,
          reasoningTokens: e.reasoningTokens ?? 0,
        );
        usage = u;
        final pt = e.promptTimeSec, gt = e.generateTimeSec;
        final proposed = e.proposedDraftTokens;
        return [
          UsageUpdate(u),
          PerfSample(
            timeToFirstTokenMs: pt == null ? null : pt * 1000,
            prefillTokensPerSec: pt == null || pt <= 0 ? null : prefilled / pt,
            decodeTokensPerSec: gt == null || gt <= 0 ? null : (e.generationTokens ?? 0) / gt,
            promptTokens: prefilled + cached,
            cachedPromptTokens: cached,
            draftAcceptRate: proposed == null || proposed == 0 ? null : (e.acceptedDraftTokens ?? 0) / proposed,
            backend: 'mlx-metal',
          ),
        ];
      case AmEventKind.waiting:
        return [
          ProviderNotice(
            'waiting_for_foreground',
            'On-device generation waits until Sherpa is back on screen (the GPU is unavailable in the background).',
            data: {'reason': e.code},
          ),
        ];
      case AmEventKind.notice:
        return [ProviderNotice(e.code ?? 'notice', e.message ?? '')];
      case AmEventKind.finished:
        terminal = NativeFinished(e.code ?? 'stop');
        return _end();
      case AmEventKind.paused:
        terminal = NativePaused(e.code ?? 'app_inactive');
        return _end();
      case AmEventKind.error:
        terminal = NativeFailed(appleMlException(e.code, e.message, providerId: providerId));
        return _text(_splitter.flush());
      case AmEventKind.toolRequest || AmEventKind.memoryWarning || AmEventKind.lifecycle:
        return const [];
    }
  }

  /// Flushes held text and completes the tool calls.
  List<ModelEvent> _end() {
    final out = _text(_splitter.flush());
    for (var i = 0; i < _calls.length; i++) {
      out.add(ToolCallComplete(index: _callIndexes[i], call: _final(_calls[i])));
    }
    return out;
  }

  List<ModelEvent> _text(List<ModelEvent> events) {
    for (final e in events) {
      if (e is TextDelta) _answer.write(e.text);
    }
    return [...events]; // growable: callers append
  }

  static ToolCall _parse(String id, String name, String raw) {
    try {
      final v = jsonDecode(raw.trim().isEmpty ? '{}' : raw);
      if (v is Map) return ToolCall(id: id, name: name, arguments: v.cast<String, Object?>(), rawArguments: raw);
      return ToolCall(
        id: id,
        name: name,
        arguments: const {},
        rawArguments: raw,
        argumentsError: 'arguments must be a JSON object',
      );
    } on FormatException catch (e) {
      final repaired = JsonRepair.decodeObject(raw);
      if (repaired != null) return ToolCall(id: id, name: name, arguments: repaired, rawArguments: raw, repaired: true);
      return ToolCall(
        id: id,
        name: name,
        arguments: const {},
        rawArguments: raw,
        argumentsError: 'malformed JSON (${e.message})',
      );
    }
  }
}
