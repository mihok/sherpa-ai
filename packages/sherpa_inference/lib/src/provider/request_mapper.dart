import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import 'model_info.dart';

/// Reasoning budgets for [ReasoningEffort] levels, in tokens (-1 =
/// unlimited). POLICY: thinking tokens are the most expensive tokens on a
/// phone (decode is ~10× slower than prefill), so `low`/`medium` cap them;
/// the engine's reasoning-budget sampler closes the think block at the cap.
const Map<ReasoningEffort, int> kReasoningBudgets = {
  ReasoningEffort.low: 512,
  ReasoningEffort.medium: 2048,
  ReasoningEffort.high: -1,
};

/// A mapped request plus what had to be left out.
@immutable
final class MappedEngineRequest {
  const MappedEngineRequest(this.body, this.notices, this.messages);

  /// The `se_generate_start` JSON object.
  final JsonMap body;
  final List<ProviderNotice> notices;

  /// `body['messages']`, one entry per engine message, in order. Kept
  /// separately because the prefix cache fingerprints them.
  final List<JsonMap> messages;

  String encode() => jsonEncode(body);
}

/// Maps a core [ModelRequest] onto the OpenAI-shaped chat JSON that
/// `se_generate_start` accepts (header se_generate_start comment), which
/// llama.cpp's `common_chat_msgs_parse_oaicompat` renders through the
/// model's own Jinja template.
///
/// Mapping rules (and why):
/// * The system prompt is the first `system` message; the template decides
///   where it goes (Qwen3 merges tool schemas into it).
/// * Assistant tool calls keep the exact argument text the model produced
///   (`rawArguments`) unless it was repaired or invalid: re-rendering
///   history byte-identically keeps the KV prefix reusable, and invalid
///   JSON would fail the template's parser.
/// * `reasoning_content` is replayed only for replies this provider
///   produced ([ReasoningPart.providerId]); another provider's reasoning is
///   meaningless to this model. Templates that drop old reasoning (Qwen3
///   keeps only the current tool loop's) do so themselves.
/// * Every [ToolResultPart] becomes its own `tool` message with
///   `tool_call_id` and `name`, in order.
/// * Images/audio need a vision build (mmproj, `SHERPA_ENGINE_MTMD`); until
///   then they are dropped with a [ProviderNotice].
/// * `parallel_tool_calls` is sent only true for models ≥ 8B whose template
///   supports it (R11 §9.6.2); `enable_thinking` follows
///   [GenerationParams.reasoning]; unset sampling parameters fall back to
///   the GGUF's `general.sampling.*` recommendations.
/// * Tools and a JSON schema cannot be combined (the engine rejects it,
///   common/chat.cpp "Cannot specify grammar with tools"): with active tools
///   the schema is dropped with a notice.
/// * A request that ends with an assistant message continues it
///   (`continue_final_message`): that is how a reply paused at a token
///   boundary (iOS backgrounding) resumes.
/// * `cache_prompt` is always true (longest-common-prefix KV reuse).
final class EngineRequestMapper {
  EngineRequestMapper({required this.providerId, required this.model})
      : messageMapper = EngineMessageMapper(providerId);

  final String providerId;
  final EngineModelInfo model;
  final EngineMessageMapper messageMapper;

  MappedEngineRequest map(ModelRequest request) {
    final notices = <ProviderNotice>[];
    final messages = <JsonMap>[];
    final system = request.systemPrompt?.trim() ?? '';
    if (system.isNotEmpty) messages.add({'role': 'system', 'content': request.systemPrompt});
    for (final m in request.messages) {
      messages.addAll(messageMapper.mapMessage(m, notices: notices));
    }
    if (messages.isEmpty) messages.add({'role': 'user', 'content': ''});

    final p = request.params;
    final body = <String, Object?>{'messages': messages};
    final toolsActive = request.tools.isNotEmpty && p.toolChoice is! ToolChoiceNone;
    if (request.tools.isNotEmpty) {
      body['tools'] = [for (final t in request.tools) EngineMessageMapper.mapTool(t)];
      body['tool_choice'] = switch (p.toolChoice) {
        ToolChoiceAuto() => 'auto',
        ToolChoiceNone() => 'none',
        ToolChoiceRequired() => 'required',
        ToolChoiceSpecific(:final name) => {
            'type': 'function',
            'function': {'name': name},
          },
      };
      body['parallel_tool_calls'] = p.parallelToolCalls && model.allowParallelToolCalls;
    }
    if (model.thinkingSupported && p.reasoning != null) {
      final effort = p.reasoning!;
      body['enable_thinking'] = effort != ReasoningEffort.off;
      final budget = kReasoningBudgets[effort];
      if (budget != null && budget >= 0) body['reasoning_budget_tokens'] = budget;
    }
    _sampling(p, body);
    if (p.maxOutputTokens != null) body['max_tokens'] = p.maxOutputTokens;
    if (p.stop.isNotEmpty) body['stop'] = p.stop;
    if (p.jsonSchema != null) {
      if (toolsActive) {
        notices.add(const ProviderNotice('json_schema_dropped',
            'Structured output was not applied because tools are offered in the same request.'));
      } else {
        body['json_schema'] = p.jsonSchema;
      }
    }
    if (request.messages.isNotEmpty && request.messages.last.role == Role.assistant) {
      body['continue_final_message'] = true;
    }
    body['cache_prompt'] = true;
    for (final e in p.extra.entries) {
      body[e.key] = e.value;
    }
    return MappedEngineRequest(body, notices, messages);
  }

  void _sampling(GenerationParams p, JsonMap body) {
    final rec = model.recommendedSampling;
    double? recD(String key) => double.tryParse(rec['general.sampling.$key'] ?? '');
    int? recI(String key) => int.tryParse(rec['general.sampling.$key'] ?? '');
    final temp = p.temperature ?? recD('temp');
    final topP = p.topP ?? recD('top_p');
    final topK = p.topK ?? recI('top_k');
    final minP = p.minP ?? recD('min_p');
    if (temp != null) body['temperature'] = temp;
    if (topP != null) body['top_p'] = topP;
    if (topK != null) body['top_k'] = topK;
    if (minP != null) body['min_p'] = minP;
    if (p.repeatPenalty != null) body['repeat_penalty'] = p.repeatPenalty;
    if (p.seed != null) body['seed'] = p.seed;
  }

}

/// Message- and tool-level mapping (independent of the loaded model, so the
/// token counter can use it before and across model loads). See
/// [EngineRequestMapper] for the rules.
final class EngineMessageMapper {
  const EngineMessageMapper(this.providerId);

  final String providerId;

  /// One core message as zero or more engine messages.
  List<JsonMap> mapMessage(Message m, {List<ProviderNotice>? notices}) {
    switch (m.role) {
      case Role.system:
        final text = m.text;
        return text.isEmpty ? const [] : [{'role': 'system', 'content': text}];
      case Role.user:
        return [
          ..._toolResults(m.toolResults),
          if (m.toolResults.isEmpty || m.content.any((c) => c is! ToolResultPart))
            {'role': 'user', 'content': _userText(m, notices)},
        ];
      case Role.assistant:
        return [_assistant(m)];
      case Role.tool:
        return _toolResults(m.toolResults);
    }
  }

  JsonMap _assistant(Message m) {
    final text = m.text;
    final calls = m.toolCalls;
    final out = <String, Object?>{'role': 'assistant', 'content': text.isEmpty && calls.isNotEmpty ? null : text};
    if (calls.isNotEmpty) {
      out['tool_calls'] = [
        for (final c in calls)
          {
            'id': c.id,
            'type': 'function',
            'function': {'name': c.name, 'arguments': argumentsForHistory(c)},
          },
      ];
    }
    final reasoning = m.reasoning.where((r) => r.providerId == providerId).map((r) => r.text).join();
    if (reasoning.isNotEmpty) out['reasoning_content'] = reasoning;
    return out;
  }

  String _userText(Message m, List<ProviderNotice>? notices) {
    final lines = <String>[];
    for (final c in m.content) {
      switch (c) {
        case TextPart(:final text):
          lines.add(text);
        case EmbeddedResourcePart(:final uri, :final text?):
          lines.add('[resource $uri]\n$text');
        case ResourceLinkPart(:final uri, :final name):
          lines.add('[resource link${name == null ? '' : ' "$name"'}: $uri]');
        case MediaPart(:final mimeType):
          notices?.add(ProviderNotice('content_dropped',
              'An attachment ($mimeType) was not sent: this on-device model has no vision/audio projector loaded.',
              data: {'kind': mimeType}));
        default:
          break;
      }
    }
    return lines.join('\n');
  }

  List<JsonMap> _toolResults(List<ToolResultPart> results) => [
        for (final r in results)
          {'role': 'tool', 'tool_call_id': r.callId, 'name': r.toolName, 'content': toolResultText(r)},
      ];

  /// OpenAI function-tool shape; the template renders it.
  static JsonMap mapTool(ToolDefinition t) => {
        'type': 'function',
        'function': {
          'name': t.name,
          'description': t.description,
          'parameters': normalizeSchema(t.inputSchema),
        },
      };

  /// The argument text to send back for a call already in history.
  static String argumentsForHistory(ToolCall call) {
    final raw = call.rawArguments;
    if (raw == null || call.repaired || !call.isValid) return jsonEncode(call.arguments);
    return raw.trim().isEmpty ? '{}' : raw;
  }

  /// Tool-result text the model sees; errors are flagged in-band because
  /// chat templates have no error field.
  static String toolResultText(ToolResultPart r) {
    final lines = <String>[];
    for (final c in r.content) {
      switch (c) {
        case TextPart(:final text):
          lines.add(text);
        case EmbeddedResourcePart(:final uri, :final text?):
          lines.add('[resource $uri]\n$text');
        case ResourceLinkPart(:final uri, :final name, :final title, :final description):
          final label = title ?? name;
          lines.add('[resource link${label == null ? '' : ' "$label"'}: $uri]'
              '${description == null ? '' : ' $description'}');
        default:
          break;
      }
    }
    var text = lines.join('\n');
    if (text.isEmpty && r.structured != null) text = jsonEncode(r.structured);
    return r.isError ? '[tool error] $text' : text;
  }

  /// Conservative schema clean-up for local templates and llama.cpp's
  /// JSON-schema-to-grammar (R11 §9.6.5): annotation-only keywords that
  /// cost prompt tokens and confuse small models are dropped. Keys are
  /// never renamed and constraints are kept, so validation against the
  /// original schema still holds. Deterministic, which keeps the rendered
  /// tool block (and so the KV prefix) byte-stable across turns.
  static JsonMap normalizeSchema(JsonMap schema) => _normalize(schema) as JsonMap;

  static const Set<String> _dropKeys = {r'$schema', r'$id', r'$comment', 'title', 'examples'};

  static Object? _normalize(Object? v) {
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
}
