import 'package:sherpa_core/sherpa_core.dart';

import '../common/hashing.dart';
import '../common/openai_messages.dart';
import '../common/tool_names.dart';
import '../config.dart';
import 'quirks.dart';

/// A Chat Completions request body plus notices about anything that could
/// not be expressed for this server (surfaced as [ProviderNotice]s so the
/// user learns that e.g. a forced tool choice was downgraded).
final class ChatRequestBody {
  const ChatRequestBody(this.body, this.notices);

  final JsonMap body;
  final List<ProviderNotice> notices;
}

/// The `reasoning_effort` value for [e] (`off` disables thinking where the
/// server supports `none`).
String effortValue(ReasoningEffort e) => switch (e) {
      ReasoningEffort.off => 'none',
      ReasoningEffort.low => 'low',
      ReasoningEffort.medium => 'medium',
      ReasoningEffort.high => 'high',
    };

/// The tool definitions the model may see (MCP Apps app-only tools are
/// callable by their view but never offered to the model).
List<ToolDefinition> visibleTools(ModelRequest r) => [for (final t in r.tools) if (t.modelVisible) t];

/// Builds a streaming Chat Completions body for [quirks]'s server.
///
/// [GenerationParams.extra] is merged last so users can reach server knobs
/// Sherpa does not model; a `null` value there removes a field Sherpa set.
ChatRequestBody buildChatRequest({
  required ModelRequest request,
  required ServerQuirks quirks,
  required ToolNameMapper names,
  required String providerId,
  bool includeUsage = true,
}) {
  final notices = <ProviderNotice>[];
  final params = request.params;
  var tools = visibleTools(request);
  final replay = quirks.replayReasoningOnlyWithTools && tools.isEmpty ? ReasoningReplay.none : quirks.reasoningReplay;
  final mapped = OpenAiChatMessageMapper(
    providerId: providerId,
    names: names,
    reasoningReplay: replay,
    pdfUnsupportedReason: quirks.pdfRefusal(request.modelId),
  ).map(systemPrompt: request.systemPrompt, messages: request.messages);
  notices.addAll(mapped.notices);

  final body = <String, Object?>{
    'model': request.modelId,
    'messages': mapped.messages,
    'stream': true,
  };
  if (includeUsage && quirks.includeUsage) {
    body['stream_options'] = {'include_usage': true, if (quirks.disableObfuscation) 'include_obfuscation': false};
  }

  if (tools.isNotEmpty) {
    final choice = _toolChoice(params.toolChoice, quirks, names, tools, notices);
    tools = choice.tools;
    if (choice.value != null) body['tool_choice'] = choice.value;
  }
  if (tools.isNotEmpty) {
    body['tools'] = [for (final t in tools) _toolJson(t, names)];
    if (!params.parallelToolCalls) {
      if (quirks.sendParallelToolCalls) {
        body['parallel_tool_calls'] = false;
      } else {
        notices.add(_notice('parallel_tool_calls_unsupported',
            'This server cannot be told to avoid parallel tool calls; the model may still make several.'));
      }
    }
  }

  _addSampling(body, params, quirks, notices);
  _addReasoning(body, params.reasoning, quirks, notices);

  if (params.maxOutputTokens case final max?) {
    body[quirks.maxTokensField == MaxTokensField.maxCompletionTokens ? 'max_completion_tokens' : 'max_tokens'] = max;
  }
  if (params.stop.isNotEmpty) body['stop'] = params.stop;
  if (params.seed case final seed?) body['seed'] = seed;
  if (params.jsonSchema case final schema?) {
    final title = schema['title'];
    body['response_format'] = {
      'type': 'json_schema',
      'json_schema': {
        'name': title is String ? ToolNameMapper.sanitize(title) : 'response',
        'schema': schema,
      },
    };
  }
  if (quirks.promptCacheKey) {
    if (request.cache.sessionId case final sid?) body['prompt_cache_key'] = 'sherpa-${fnv1a32Hex(sid)}';
  }

  for (final e in params.extra.entries) {
    if (e.value == null) {
      body.remove(e.key);
    } else {
      body[e.key] = e.value;
    }
  }
  return ChatRequestBody(body, notices);
}

JsonMap _toolJson(ToolDefinition t, ToolNameMapper names) => {
      'type': 'function',
      'function': {
        'name': names.toWire(t.name),
        if (t.description.isNotEmpty) 'description': t.description,
        'parameters': t.inputSchema,
      },
    };

/// `tool_choice` per server support. Unsupported forms are downgraded to
/// the nearest thing the server honours and announced, never sent
/// blindly: llama.cpp ignores the object form and Ollama the whole field,
/// so a forced call would silently not be forced (R10 Risks).
({Object? value, List<ToolDefinition> tools}) _toolChoice(
  ToolChoice choice,
  ServerQuirks quirks,
  ToolNameMapper names,
  List<ToolDefinition> tools,
  List<ProviderNotice> notices,
) {
  final support = quirks.toolChoice;
  void unsupported(String what) => notices.add(_notice('tool_choice_unsupported',
      'This server ignores tool_choice "$what"; the model decides whether to call a tool.'));
  switch (choice) {
    case ToolChoiceAuto():
      // Omitted rather than sent: `auto` is the default with tools, and an
      // explicit "auto" makes vLLM demand --enable-auto-tool-choice.
      return (value: null, tools: tools);
    case ToolChoiceNone():
      if (support != ToolChoiceSupport.none) return (value: 'none', tools: tools);
      notices.add(_notice('tool_choice_emulated', 'Tools were not offered because this server ignores tool_choice "none".'));
      return (value: null, tools: const []);
    case ToolChoiceRequired():
      if (support == ToolChoiceSupport.full || support == ToolChoiceSupport.stringOnly) {
        return (value: 'required', tools: tools);
      }
      unsupported('required');
      return (value: null, tools: tools);
    case ToolChoiceSpecific(:final name):
      final target = tools.where((t) => t.name == name).firstOrNull;
      if (support == ToolChoiceSupport.full && target != null) {
        return (
          value: {
            'type': 'function',
            'function': {'name': names.toWire(name)},
          },
          tools: tools,
        );
      }
      if (support == ToolChoiceSupport.full || support == ToolChoiceSupport.stringOnly) {
        // R10 §10: emulate a named choice with `required` over that tool only.
        notices.add(_notice('tool_choice_emulated',
            'This server cannot force a named tool; offering only "$name" with tool_choice "required".'));
        return (value: 'required', tools: target == null ? tools : [target]);
      }
      unsupported(name);
      return (value: null, tools: tools);
  }
}

void _addSampling(JsonMap body, GenerationParams p, ServerQuirks quirks, List<ProviderNotice> notices) {
  // OpenAI's latest-model guide: with reasoning on, sampling params must be
  // removed (they 400).
  final reasoningOn = p.reasoning != null && p.reasoning != ReasoningEffort.off;
  final dropSampling = quirks.profile == ServerProfile.openAi && reasoningOn;
  if (dropSampling && (p.temperature != null || p.topP != null)) {
    notices.add(_notice('param_dropped', 'temperature/top_p are not accepted together with reasoning; not sent.'));
  } else {
    if (p.temperature case final t?) body['temperature'] = t;
    if (p.topP case final t?) body['top_p'] = t;
  }
  void extended(String label, Object? value, String? field) {
    if (value == null) return;
    if (field == null) {
      notices.add(_notice('param_unsupported', '$label is not supported by this server; not sent.'));
    } else {
      body[field] = value;
    }
  }

  extended('top_k', p.topK, quirks.topKField);
  extended('min_p', p.minP, quirks.minPField);
  extended('repeat_penalty', p.repeatPenalty, quirks.repeatPenaltyField);
}

void _addReasoning(JsonMap body, ReasoningEffort? effort, ServerQuirks quirks, List<ProviderNotice> notices) {
  if (effort == null) return;
  switch (quirks.effort) {
    case EffortStyle.reasoningEffort:
      body['reasoning_effort'] = effortValue(effort);
    case EffortStyle.openRouterObject:
      body['reasoning'] = {'effort': effortValue(effort)};
    case EffortStyle.deepSeekThinking:
      // R10 §4.6: thinking on/off plus low|high (medium maps to high).
      if (effort == ReasoningEffort.off) {
        body['thinking'] = {'type': 'disabled'};
      } else {
        body['thinking'] = {'type': 'enabled'};
        body['reasoning_effort'] = effort == ReasoningEffort.low ? 'low' : 'high';
      }
    case EffortStyle.unsupported:
      notices.add(_notice('reasoning_effort_unsupported',
          'This server has no known reasoning-effort control; the model uses its default.'));
  }
}

ProviderNotice _notice(String code, String message) => ProviderNotice(code, message);
