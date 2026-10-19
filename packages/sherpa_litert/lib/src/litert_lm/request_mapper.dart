import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../common/fingerprint.dart';
import '../common/prompted_tools.dart';
import '../messages.pigeon.dart';
import 'model_spec.dart';

/// Thinking budgets for [ReasoningEffort] levels (tokens; -1 = unlimited).
/// Same policy as the llama.cpp provider: decode is the expensive part on a
/// phone, so `low`/`medium` cap it.
const Map<ReasoningEffort, int> kThinkingBudgets = {
  ReasoningEffort.low: 512,
  ReasoningEffort.medium: 2048,
  ReasoningEffort.high: -1,
};

/// Sent in place of a "continue" API, which LiteRT-LM does not have, when a
/// request ends with a (paused) assistant message.
const String kContinueNudge = '[Your previous reply was interrupted. Continue it exactly where it stopped, '
    'without repeating anything you already wrote.]';

/// Sampler values for `SamplerConfig` (all four, or none).
@immutable
final class LiteRtSampler {
  const LiteRtSampler({required this.topK, required this.topP, required this.temperature, required this.seed});

  final int topK;
  final double topP;
  final double temperature;
  final int seed;

  JsonMap toJson() => {'topK': topK, 'topP': topP, 'temperature': temperature, 'seed': seed};
}

/// A request in LiteRT-LM's conversation shape: what the native
/// `Conversation` must hold ([history]) and the one message to send
/// ([tail]), plus fingerprints for the conversation cache.
@immutable
final class MappedLiteRtTurn {
  const MappedLiteRtTurn({
    required this.systemInstruction,
    required this.toolsJson,
    required this.sampler,
    required this.enableResponseFormat,
    required this.history,
    required this.historyKeys,
    required this.tail,
    required this.tailKey,
    required this.configKey,
    required this.continuation,
    required this.promptedTools,
    required this.toolNames,
    required this.notices,
    this.maxOutputTokens,
    this.enableThinking,
    this.thinkingBudget,
    this.responseSchemaJson,
  });

  final String? systemInstruction;

  /// OpenAPI function descriptions (native tool calling only).
  final List<String> toolsJson;
  final LiteRtSampler? sampler;
  final bool enableResponseFormat;

  /// `initialMessages` for a rebuilt conversation.
  final List<ChatMessageMsg> history;
  final List<String> historyKeys;
  final ChatMessageMsg tail;
  final String tailKey;

  /// Fingerprint of everything fixed at conversation creation: system
  /// instruction, tools, sampler, response-format flag.
  final String configKey;

  /// [tail] is [kContinueNudge] (the request ended with an assistant message).
  final bool continuation;

  /// Tools are described in the system prompt and parsed from text.
  final bool promptedTools;
  final Set<String> toolNames;
  final List<ProviderNotice> notices;
  final int? maxOutputTokens;
  final bool? enableThinking;
  final int? thinkingBudget;
  final String? responseSchemaJson;

  ConversationSpecMsg spec(String conversationId) => ConversationSpecMsg(
        conversationId: conversationId,
        systemInstruction: systemInstruction,
        history: history,
        toolsJson: toolsJson,
        topK: sampler?.topK,
        topP: sampler?.topP,
        temperature: sampler?.temperature,
        seed: sampler?.seed,
        enableResponseFormat: enableResponseFormat,
      );
}

/// Maps core [ModelRequest]s onto LiteRT-LM conversation messages.
///
/// Rules (and why):
/// * Leading system messages join the system prompt (`systemInstruction`);
///   later ones become user turns marked "[System note]", because chat
///   templates such as Gemma's have no mid-conversation system role.
/// * Native tool calling (the chat template renders tools, see
///   [usesNativeTools]): tools become
///   `OpenApiTool` schemas with `automaticToolCalling = false`; earlier calls
///   are model messages with `toolCalls`, results are `tool` messages of
///   `ToolResponse(name, text)`, ordered like the calls (LiteRT-LM pairs by
///   position: its calls have no ids).
/// * Prompted tool calling: tools are described in the system prompt
///   ([PromptedToolFormat]); calls are replayed as the JSON envelope; results
///   are user turns with untrusted-data wrapping.
/// * Arguments are always re-encoded from the parsed map, so history renders
///   byte-identically across turns (stable fingerprints, reusable KV).
/// * Reasoning is not replayed: LiteRT-LM keeps it in the `thought` channel
///   of the live conversation, and a rebuilt one does not need old thinking.
/// * Images go along only when the spec enables vision and the file has a
///   vision encoder; otherwise they (and audio) are dropped with a notice.
/// * Consecutive messages of one role are merged (templates expect turns to
///   alternate).
/// * A request ending with an assistant message (a paused reply) is answered
///   by sending [kContinueNudge] after it.
/// * Tools plus a JSON schema cannot be combined (LiteRT-LM ignores the
///   response format while tools are active): the schema is dropped.
final class LiteRtRequestMapper {
  LiteRtRequestMapper({required this.providerId, required this.spec, required this.info, this.templateRendersTools});

  final String providerId;
  final LiteRtModelSpec spec;
  final LiteRtModelInfo info;

  /// The load-time template probe (`LoadResultMsg.templateRendersTools`);
  /// null before a load or when the probe failed.
  final bool? templateRendersTools;

  /// Native function calling when the chat template renders tools (see
  /// [usesNativeTools]).
  bool get nativeTools => usesNativeTools(info, templateRendersTools);

  bool get _vision => spec.vision && info.vision;

  MappedLiteRtTurn map(ModelRequest request) {
    final notices = <ProviderNotice>[];
    final p = request.params;
    final toolsActive = spec.toolCalling && request.tools.isNotEmpty && p.toolChoice is! ToolChoiceNone;
    final prompted = toolsActive && !nativeTools;

    // System instruction.
    final system = <String>[];
    final base = request.systemPrompt?.trim() ?? '';
    if (base.isNotEmpty) system.add(base);
    var i = 0;
    while (i < request.messages.length && request.messages[i].role == Role.system) {
      final t = request.messages[i].text.trim();
      if (t.isNotEmpty) system.add(t);
      i++;
    }
    if (prompted) {
      system.add(PromptedToolFormat.instructions(request.tools, p.toolChoice));
    } else if (toolsActive) {
      final must = PromptedToolFormat.choiceInstruction(p.toolChoice);
      if (must != null) system.add(must);
    }
    final systemInstruction = system.isEmpty ? null : system.join('\n\n');

    // Messages.
    final out = <ChatMessageMsg>[];
    List<String> lastCallOrder = const [];
    for (final m in request.messages.skip(i)) {
      switch (m.role) {
        case Role.system:
          final t = m.text.trim();
          if (t.isNotEmpty) _append(out, ChatMessageMsg(role: 'user', text: '[System note]\n$t'));
        case Role.user:
          if (m.toolResults.isNotEmpty) _appendResults(out, m.toolResults, lastCallOrder, prompted);
          final user = _user(m, notices);
          if (user != null) _append(out, user);
        case Role.assistant:
          final model = assistantMessage(m.text, m.toolCalls, prompted: prompted);
          if (model != null) _append(out, model);
          if (m.toolCalls.isNotEmpty) lastCallOrder = [for (final c in m.toolCalls) c.id];
        case Role.tool:
          _appendResults(out, m.toolResults, lastCallOrder, prompted);
      }
    }

    // History + tail.
    ChatMessageMsg tail;
    var continuation = false;
    if (out.isEmpty) {
      tail = ChatMessageMsg(role: 'user', text: '');
    } else if (out.last.role == 'model') {
      tail = ChatMessageMsg(role: 'user', text: kContinueNudge);
      continuation = true;
      notices.add(const ProviderNotice('continue_prompted',
          'LiteRT-LM cannot continue a reply in place; asked the model to continue where it stopped.'));
    } else {
      tail = out.removeLast();
    }

    // Generation options.
    String? schema;
    if (p.jsonSchema != null) {
      if (toolsActive) {
        notices.add(const ProviderNotice('json_schema_dropped',
            'Structured output was not applied because tools are offered in the same request.'));
      } else {
        schema = jsonEncode(p.jsonSchema);
      }
    }
    bool? thinking;
    int? budget;
    final effort = p.reasoning;
    if (info.supportsThinking && effort != null) {
      thinking = effort != ReasoningEffort.off;
      budget = effort == ReasoningEffort.off ? 0 : kThinkingBudgets[effort];
    }
    if (p.stop.isNotEmpty) {
      notices.add(const ProviderNotice('stop_ignored', 'LiteRT-LM has no stop sequences; they were not applied.'));
    }
    if (request.tools.isNotEmpty && !spec.toolCalling) {
      notices.add(const ProviderNotice('tools_disabled', 'Tool calling is turned off for this on-device model.'));
    }

    final toolsJson = toolsActive && !prompted
        ? [
            for (final t in request.tools)
              jsonEncode({
                'name': t.name,
                'description': t.description,
                'parameters': PromptedToolFormat.normalizeSchema(t.inputSchema),
              }),
          ]
        : const <String>[];
    final sampler = _sampler(p);
    final enableResponseFormat = schema != null;
    return MappedLiteRtTurn(
      systemInstruction: systemInstruction,
      toolsJson: toolsJson,
      sampler: sampler,
      enableResponseFormat: enableResponseFormat,
      history: out,
      historyKeys: [for (final m in out) keyOf(m)],
      tail: tail,
      tailKey: keyOf(tail),
      configKey: fingerprint({
        'system': systemInstruction,
        'tools': toolsJson,
        'sampler': sampler?.toJson(),
        'responseFormat': enableResponseFormat,
      }),
      continuation: continuation,
      promptedTools: prompted,
      toolNames: toolsActive ? {for (final t in request.tools) t.name} : const {},
      notices: notices,
      maxOutputTokens: p.maxOutputTokens,
      enableThinking: thinking,
      thinkingBudget: budget,
      responseSchemaJson: schema,
    );
  }

  /// The model message for an assistant reply with [text] and [calls] (also
  /// used to fingerprint a reply this provider just produced). Null when
  /// empty.
  ChatMessageMsg? assistantMessage(String text, List<ToolCall> calls, {required bool prompted}) {
    if (text.isEmpty && calls.isEmpty) return null;
    if (prompted) {
      final env = calls.isEmpty ? '' : PromptedToolFormat.envelope(calls);
      final body = [if (text.isNotEmpty) text, if (env.isNotEmpty) env].join('\n');
      return ChatMessageMsg(role: 'model', text: body);
    }
    return ChatMessageMsg(
      role: 'model',
      text: text.isEmpty ? null : text,
      toolCalls: calls.isEmpty
          ? null
          : [for (final c in calls) ToolCallMsg(name: c.name, argumentsJson: jsonEncode(c.isValid ? c.arguments : {}))],
    );
  }

  /// Fingerprint of a conversation message (role, text, calls, results,
  /// media).
  static String keyOf(ChatMessageMsg m) => fingerprint({
        'role': m.role,
        'text': m.text ?? '',
        'calls': [for (final c in m.toolCalls ?? const <ToolCallMsg>[]) [c.name, c.argumentsJson]],
        'results': [for (final r in m.toolResponses ?? const <ToolResponseMsg>[]) [r.name, r.responseJson]],
        'images': m.images ?? const <Uint8List>[],
        'imagePaths': m.imagePaths ?? const <String>[],
      });

  LiteRtSampler? _sampler(GenerationParams p) {
    if (p.temperature == null && p.topK == null && p.topP == null && p.seed == null) return null;
    return LiteRtSampler(
      topK: p.topK ?? info.defaultTopK ?? 40,
      topP: p.topP ?? info.defaultTopP ?? 0.95,
      temperature: p.temperature ?? info.defaultTemperature ?? 0.8,
      seed: p.seed ?? 0,
    );
  }

  ChatMessageMsg? _user(Message m, List<ProviderNotice> notices) {
    final lines = <String>[];
    final images = <Uint8List>[];
    final paths = <String>[];
    for (final c in m.content) {
      switch (c) {
        case TextPart(:final text):
          lines.add(text);
        case EmbeddedResourcePart(:final uri, :final text?):
          lines.add('[resource $uri]\n$text');
        case ResourceLinkPart(:final uri, :final name):
          lines.add('[resource link${name == null ? '' : ' "$name"'}: $uri]');
        case ImagePart(:final data, :final uri, :final mimeType) when _vision:
          if (data != null) {
            images.add(data);
          } else if (uri != null && uri.isScheme('file')) {
            paths.add(uri.toFilePath());
          } else {
            notices.add(ProviderNotice('content_dropped', 'An image ($mimeType) was not sent: only inline or file images work.',
                data: {'kind': mimeType}));
          }
        case MediaPart(:final mimeType):
          notices.add(ProviderNotice(
              'content_dropped',
              'An attachment ($mimeType) was not sent: ${c is ImagePart ? 'vision is not enabled for this model' : 'this on-device model takes text only'}.',
              data: {'kind': mimeType}));
        default:
          break;
      }
    }
    if (lines.isEmpty && images.isEmpty && paths.isEmpty) return null;
    return ChatMessageMsg(
      role: 'user',
      text: lines.join('\n'),
      images: images.isEmpty ? null : images,
      imagePaths: paths.isEmpty ? null : paths,
    );
  }

  void _appendResults(List<ChatMessageMsg> out, List<ToolResultPart> results, List<String> callOrder, bool prompted) {
    if (results.isEmpty) return;
    final ordered = [...results]..sort((a, b) {
        final ia = callOrder.indexOf(a.callId);
        final ib = callOrder.indexOf(b.callId);
        return (ia < 0 ? 1 << 20 : ia).compareTo(ib < 0 ? 1 << 20 : ib);
      });
    if (prompted) {
      _append(out, ChatMessageMsg(role: 'user', text: PromptedToolFormat.results(ordered)));
      return;
    }
    _append(
      out,
      ChatMessageMsg(role: 'tool', toolResponses: [
        for (final r in ordered)
          ToolResponseMsg(name: r.toolName, responseJson: jsonEncode(PromptedToolFormat.toolResultText(r))),
      ]),
    );
  }

  /// Appends [m], merging it into the previous message of the same role.
  static void _append(List<ChatMessageMsg> out, ChatMessageMsg m) {
    final last = out.isEmpty ? null : out.last;
    if (last == null || last.role != m.role || m.role == 'system') {
      out.add(m);
      return;
    }
    final text = [if ((last.text ?? '').isNotEmpty) last.text!, if ((m.text ?? '').isNotEmpty) m.text!].join('\n\n');
    out[out.length - 1] = ChatMessageMsg(
      role: m.role,
      text: text.isEmpty ? null : text,
      toolCalls: _join(last.toolCalls, m.toolCalls),
      toolResponses: _join(last.toolResponses, m.toolResponses),
      images: _join(last.images, m.images),
      imagePaths: _join(last.imagePaths, m.imagePaths),
    );
  }

  static List<T>? _join<T>(List<T>? a, List<T>? b) {
    if ((a == null || a.isEmpty) && (b == null || b.isEmpty)) return null;
    return [...?a, ...?b];
  }
}
