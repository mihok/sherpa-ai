import 'dart:convert';
import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import 'model_traits.dart';
import 'tool_names.dart';

/// A rendered Messages API request plus what decoding its reply needs.
@immutable
final class AnthropicWireRequest {
  const AnthropicWireRequest({
    required this.body,
    required this.toolNames,
    required this.traits,
    this.notices = const [],
  });

  /// The JSON body, in a fixed key order (Dart maps keep insertion order),
  /// so equal inputs always encode to equal bytes.
  final JsonMap body;

  /// Maps wire tool names in the reply back to Sherpa names.
  final AnthropicToolNames toolNames;
  final AnthropicModelTraits traits;

  /// Adjustments made while rendering (downgraded tool choice, dropped
  /// sampling params, omitted attachments). Emitted before the stream.
  final List<ProviderNotice> notices;

  String encode() => jsonEncode(body);

  /// Body for `POST /v1/messages/count_tokens`, which takes the same
  /// prompt-shaping fields but no generation settings.
  JsonMap get countTokensBody => {
        for (final k in const ['model', 'system', 'messages', 'tools', 'tool_choice', 'thinking'])
          if (body.containsKey(k)) k: body[k],
      };
}

/// Renders a [ModelRequest] as an Anthropic Messages API body.
///
/// Design rule: the rendering of a message depends only on that message
/// and what came before it, never on what follows. Anthropic's preserved
/// thinking (R10 §7.9) rejects a replayed thinking block unless `system`,
/// `tools` and every earlier message are byte-identical to the request
/// that produced it, so any "look-ahead" formatting (e.g. choosing a role
/// for a message based on its successor) would turn an append into an
/// edit. Concretely:
/// * consecutive same-role turns are merged forward (an append only ever
///   adds blocks to the last turn);
/// * replayed blocks are emitted verbatim and in stored order; thinking is
///   replayed only when it was produced by this provider id and is signed;
/// * nothing transient (reminders, downgrade instructions) is injected into
///   messages, because dropping it on the next request would be an edit;
/// * `cache_control` markers move freely — the API documents that moving
///   them is not an edit.
final class AnthropicRequestBuilder {
  const AnthropicRequestBuilder({required this.providerId, this.eagerInputStreaming = false});

  /// Reasoning parts stamped with another provider id are never replayed:
  /// signatures are model/account bound (R10 §7.9.4–5).
  final String providerId;

  /// Adds `eager_input_streaming: true` to client tools so large tool
  /// inputs stream incrementally. Off for proxies, which may reject it.
  final bool eagerInputStreaming;

  /// The API allows at most four `cache_control` breakpoints.
  static const int maxCacheBreakpoints = 4;

  /// `max_tokens` when the caller sets none (streaming makes large values
  /// safe from HTTP timeouts; the model's own cap still applies).
  static const int defaultMaxTokens = 64000;

  static const JsonMap _ephemeral = {'type': 'ephemeral'};

  static const Map<ReasoningEffort, int> _budgets = {
    ReasoningEffort.low: 2048,
    ReasoningEffort.medium: 8192,
    ReasoningEffort.high: 24576,
  };

  static const Set<String> _imageTypes = {'image/jpeg', 'image/png', 'image/gif', 'image/webp'};

  AnthropicWireRequest build(
    ModelRequest request, {
    AnthropicModelTraits? traits,
    int? modelMaxOutputTokens,
    bool stream = true,
  }) {
    final t = traits ?? AnthropicModelTraits.forModel(request.modelId);
    final notices = <ProviderNotice>[];
    final params = request.params;

    final tools = request.tools.where((d) => d.modelVisible).toList();
    final names = AnthropicToolNames(tools.map((d) => d.name));
    final toolsJson = <JsonMap>[
      for (final d in tools)
        {
          'name': names.toWire(d.name),
          if (d.description.isNotEmpty) 'description': d.description,
          'input_schema': _schema(d.inputSchema),
          if (eagerInputStreaming) 'eager_input_streaming': true,
        },
    ];

    final systemText = request.systemPrompt;
    final system = systemText == null || systemText.isEmpty
        ? null
        : <JsonMap>[
            {'type': 'text', 'text': systemText},
          ];

    final rendered = _MessageRenderer(providerId: providerId, names: names, notices: notices)
      ..renderAll(request.messages);
    final turns = rendered.turns;

    // Breakpoints, in render order: tools → system → stable prefix → tail.
    var breakpoints = 0;
    if (toolsJson.isNotEmpty) {
      toolsJson.last['cache_control'] = _ephemeral;
      breakpoints++;
    }
    if (system != null) {
      system.last['cache_control'] = _ephemeral;
      breakpoints++;
    }
    final marked = <(int, int)>{};
    final stable = request.cache.stablePrefixMessages;
    if (stable > 0) {
      final pos = rendered.lastEligibleUpTo(math.min(stable, request.messages.length) - 1);
      if (pos != null) marked.add(pos);
    }
    final tail = rendered.lastEligibleInLastTurn();
    if (tail != null) marked.add(tail);
    for (final (ti, bi) in marked) {
      if (breakpoints >= maxCacheBreakpoints) break;
      turns[ti].blocks[bi] = {...turns[ti].blocks[bi], 'cache_control': _ephemeral};
      breakpoints++;
    }

    final cap = modelMaxOutputTokens ?? t.maxOutputTokens;
    final requested = params.maxOutputTokens;
    var maxTokens = requested ?? math.min(cap, defaultMaxTokens);
    if (maxTokens > cap) {
      notices.add(ProviderNotice(
        'anthropic.max_tokens_clamped',
        'max output tokens lowered from $maxTokens to the model limit $cap',
        data: {'requested': maxTokens, 'limit': cap},
      ));
      maxTokens = cap;
    }
    if (maxTokens < 1) maxTokens = 1;

    final (thinking, effort) = _thinking(params.reasoning, t, maxTokens, notices);
    final thinkingActive = switch (thinking?['type']) {
      'adaptive' || 'enabled' || 'between_tools' => true,
      _ => false,
    };

    final toolChoice = toolsJson.isEmpty ? null : _toolChoice(params, t, names, tools, thinkingActive, notices);
    final sampling = _sampling(params, t, thinkingActive, notices);

    final outputConfig = <String, Object?>{
      if (effort != null) 'effort': effort.name,
      if (params.jsonSchema != null) 'format': {'type': 'json_schema', 'schema': params.jsonSchema},
    };

    final body = <String, Object?>{
      'model': request.modelId,
      'max_tokens': maxTokens,
      if (stream) 'stream': true,
      if (system != null) 'system': system,
      'messages': [
        for (final turn in turns) {'role': turn.role, 'content': turn.blocks},
      ],
      if (toolsJson.isNotEmpty) 'tools': toolsJson,
      if (toolChoice != null) 'tool_choice': toolChoice,
      if (thinking != null) 'thinking': thinking,
      if (outputConfig.isNotEmpty) 'output_config': outputConfig,
      if (params.stop.isNotEmpty) 'stop_sequences': params.stop,
      ...sampling,
    };
    _deepMerge(body, params.extra);
    return AnthropicWireRequest(body: body, toolNames: names, traits: t, notices: notices);
  }

  /// `input_schema` must be an object schema; MCP servers occasionally omit
  /// `type`. Adding it is deterministic, so it does not break the prefix.
  static JsonMap _schema(JsonMap schema) =>
      schema['type'] == null ? {'type': 'object', ...schema} : schema;

  (JsonMap?, AnthropicEffort?) _thinking(
    ReasoningEffort? r,
    AnthropicModelTraits t,
    int maxTokens,
    List<ProviderNotice> notices,
  ) {
    final JsonMap adaptive = t.displayDefaultsToOmitted
        // 4.7+/5.x hide reasoning text unless asked; the UI shows it.
        ? {'type': 'adaptive', 'display': 'summarized'}
        : {'type': 'adaptive'};
    AnthropicEffort? effortFor(ReasoningEffort level) {
      final e = AnthropicEffort.values.byName(level.name);
      return t.effortLevels.contains(e) ? e : null;
    }

    final off = r == ReasoningEffort.off;
    switch (t.thinking) {
      case AnthropicThinkingStyle.alwaysOn:
        if (off) {
          notices.add(const ProviderNotice(
            'anthropic.thinking_always_on',
            'This model always thinks; using the lowest effort instead of turning reasoning off.',
          ));
          return (adaptive, t.effortLevels.contains(AnthropicEffort.low) ? AnthropicEffort.low : null);
        }
        return (adaptive, r == null ? null : effortFor(r));
      case AnthropicThinkingStyle.betweenToolsOff:
        // `between_tools` takes no other field and needs effort ≤ high; the
        // model default (high) satisfies that, so effort is left unset.
        if (off) return (const {'type': 'between_tools'}, null);
        return (adaptive, r == null ? null : effortFor(r));
      case AnthropicThinkingStyle.adaptive:
        if (off) return (const {'type': 'disabled'}, null);
        return (adaptive, r == null ? null : effortFor(r));
      case AnthropicThinkingStyle.adaptiveOptIn:
        // Omitting `thinking` is "off" here, and always accepted.
        if (off) return (null, null);
        return (adaptive, r == null ? null : effortFor(r));
      case AnthropicThinkingStyle.budget:
        if (r == null || off) return (null, null);
        if (maxTokens <= 1024) {
          notices.add(const ProviderNotice(
            'anthropic.thinking_skipped',
            'max output tokens are too small for a thinking budget (needs more than 1024).',
          ));
          return (null, effortFor(r));
        }
        final budget = math.max(1024, math.min(_budgets[r]!, maxTokens - 1));
        return ({'type': 'enabled', 'budget_tokens': budget}, effortFor(r));
      case AnthropicThinkingStyle.none:
        return (null, null);
    }
  }

  JsonMap? _toolChoice(
    GenerationParams params,
    AnthropicModelTraits t,
    AnthropicToolNames names,
    List<ToolDefinition> tools,
    bool thinkingActive,
    List<ProviderNotice> notices,
  ) {
    JsonMap auto() => {
          'type': 'auto',
          if (!params.parallelToolCalls) 'disable_parallel_tool_use': true,
        };
    JsonMap forced(JsonMap choice, String what) {
      final reason = t.rejectsForcedToolChoice
          ? 'this model rejects forced tool choice'
          : thinkingActive
              ? 'forced tool choice is not allowed while thinking is on'
              : null;
      if (reason == null) {
        return {...choice, if (!params.parallelToolCalls) 'disable_parallel_tool_use': true};
      }
      // No instruction is injected into the prompt: it would have to be
      // removed again next turn, which preserved thinking treats as an edit.
      notices.add(ProviderNotice(
        'anthropic.tool_choice_downgraded',
        'Requested $what, but $reason; using automatic tool choice.',
        data: {'requested': choice['type'], 'reason': reason},
      ));
      return auto();
    }

    return switch (params.toolChoice) {
      ToolChoiceAuto() => auto(),
      ToolChoiceNone() => const {'type': 'none'},
      ToolChoiceRequired() => forced(const {'type': 'any'}, 'a tool call'),
      ToolChoiceSpecific(:final name) => tools.any((d) => d.name == name)
          ? forced({'type': 'tool', 'name': names.toWire(name)}, 'the tool "$name"')
          : () {
              notices.add(ProviderNotice(
                'anthropic.tool_choice_downgraded',
                'Requested tool "$name" is not offered this turn; using automatic tool choice.',
                data: {'requested': 'tool', 'reason': 'unknown tool'},
              ));
              return auto();
            }(),
    };
  }

  JsonMap _sampling(GenerationParams p, AnthropicModelTraits t, bool thinkingActive, List<ProviderNotice> notices) {
    final wanted = {
      if (p.temperature != null) 'temperature': p.temperature,
      if (p.topP != null) 'top_p': p.topP,
      if (p.topK != null) 'top_k': p.topK,
    };
    if (wanted.isEmpty) return const {};
    final reason = t.rejectsSampling
        ? 'this model rejects sampling parameters'
        : thinkingActive
            ? 'sampling parameters are not compatible with thinking'
            : null;
    if (reason != null) {
      notices.add(ProviderNotice(
        'anthropic.sampling_dropped',
        'Ignored ${wanted.keys.join(', ')}: $reason.',
        data: {'dropped': wanted.keys.toList(), 'reason': reason},
      ));
      return const {};
    }
    if (wanted.containsKey('temperature') && wanted.containsKey('top_p')) {
      notices.add(const ProviderNotice(
        'anthropic.sampling_dropped',
        'Ignored top_p: Anthropic rejects temperature and top_p together.',
        data: {
          'dropped': ['top_p'],
        },
      ));
      wanted.remove('top_p');
    }
    return wanted;
  }

  /// `GenerationParams.extra` is merged last; nested maps merge so callers
  /// can add e.g. `output_config.effort: "max"` without losing `format`.
  static void _deepMerge(JsonMap into, JsonMap extra) {
    for (final e in extra.entries) {
      final existing = into[e.key];
      final value = e.value;
      if (existing is Map && value is Map) {
        final merged = <String, Object?>{...existing.cast<String, Object?>()};
        _deepMerge(merged, value.cast<String, Object?>());
        into[e.key] = merged;
      } else {
        into[e.key] = value;
      }
    }
  }

  /// Maps one user-side content part to Anthropic blocks (shared by user
  /// turns and tool results).
  static List<JsonMap> userBlocks(ContentPart p, List<ProviderNotice> notices, {bool inToolResult = false}) {
    switch (p) {
      case TextPart(:final text):
        return text.isEmpty ? const [] : [_text(text)];
      case ImagePart():
        final img = _image(p);
        if (img != null) return [img];
        notices.add(ProviderNotice(
          'anthropic.content_omitted',
          'An image (${p.mimeType}) could not be sent and was replaced by a note.',
          data: {'mimeType': p.mimeType},
        ));
        return [_text('[image omitted: ${p.mimeType} ${p.uri ?? ''}]'.trim())];
      case AudioPart():
        notices.add(const ProviderNotice('anthropic.content_omitted', 'Audio is not supported by Anthropic models.'));
        return [_text('[audio omitted: ${p.mimeType}]')];
      case ResourceLinkPart(:final uri, :final name, :final title):
        return [_text('[resource: ${title ?? name ?? uri} <$uri>]')];
      case EmbeddedResourcePart(:final uri, :final mimeType, :final text, :final blob):
        if (text != null) return [_text('[resource $uri]\n$text')];
        if (blob != null && mimeType == 'application/pdf') {
          return [
            {
              'type': 'document',
              'source': {'type': 'base64', 'media_type': 'application/pdf', 'data': base64Encode(blob)},
            },
          ];
        }
        if (blob != null && mimeType != null && _imageTypes.contains(_mime(mimeType))) {
          return [
            {
              'type': 'image',
              'source': {'type': 'base64', 'media_type': _mime(mimeType), 'data': base64Encode(blob)},
            },
          ];
        }
        return [_text('[resource $uri (${mimeType ?? 'binary'}) omitted]')];
      case ReasoningPart() || ToolCallPart() || ToolResultPart() || UiResourcePart() || UnknownPart():
        return const [];
    }
  }

  static JsonMap _text(String text) => {'type': 'text', 'text': text};

  static String _mime(String m) {
    final lower = m.toLowerCase();
    return lower == 'image/jpg' ? 'image/jpeg' : lower;
  }

  static JsonMap? _image(ImagePart p) {
    final mime = _mime(p.mimeType);
    if (!_imageTypes.contains(mime)) return null;
    final data = p.data;
    if (data != null) {
      return {
        'type': 'image',
        'source': {'type': 'base64', 'media_type': mime, 'data': base64Encode(data)},
      };
    }
    final uri = p.uri;
    if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
      return {
        'type': 'image',
        'source': {'type': 'url', 'url': uri.toString()},
      };
    }
    // file:// attachments must be inlined by the app before sending; the
    // provider does no file IO so rendering stays pure and deterministic.
    return null;
  }
}

final class _Turn {
  _Turn(this.role);
  final String role;
  final List<JsonMap> blocks = [];
}

/// Converts the core transcript into alternating Anthropic turns.
final class _MessageRenderer {
  _MessageRenderer({required this.providerId, required this.names, required this.notices});

  final String providerId;
  final AnthropicToolNames names;
  final List<ProviderNotice> notices;
  final List<_Turn> turns = [];

  /// Per core message: the (turn, block) of its last cacheable block.
  final List<(int, int)?> _lastBlock = [];

  /// Tool-use ids of the latest assistant turn, in call order, that still
  /// expect a result.
  List<String> _pending = const [];
  final Set<String> _answered = {};

  void renderAll(List<Message> messages) {
    for (final (i, m) in messages.indexed) {
      _lastBlock.add(null);
      switch (m.role) {
        case Role.assistant:
          // A refused turn is discarded (R10 §7.6): its partial output is
          // never replayed. Applied on every request, so it is stable.
          if (m.finishReason == FinishReason.refusal.name) continue;
          _flushMissing();
          _push('assistant', _assistant(m), i);
        case Role.tool:
          _push('user', _results(m), i);
        case Role.user || Role.system:
          // Mid-conversation `role: system` messages are only valid when
          // followed by an assistant turn, which depends on the future; a
          // user text block renders the same whatever comes next.
          final results = _results(m);
          _push('user', results, i);
          _flushMissing();
          _push('user', [for (final p in m.content) ...AnthropicRequestBuilder.userBlocks(p, notices)], i);
      }
    }
    // A trailing assistant turn keeps its calls pending: the next request
    // will carry their results.
  }

  (int, int)? lastEligibleUpTo(int messageIndex) {
    for (var i = math.min(messageIndex, _lastBlock.length - 1); i >= 0; i--) {
      final pos = _lastBlock[i];
      if (pos != null) return pos;
    }
    return null;
  }

  (int, int)? lastEligibleInLastTurn() {
    if (turns.isEmpty) return null;
    final ti = turns.length - 1;
    final blocks = turns[ti].blocks;
    for (var bi = blocks.length - 1; bi >= 0; bi--) {
      if (_cacheable(blocks[bi])) return (ti, bi);
    }
    return null;
  }

  /// Thinking blocks cannot carry `cache_control`.
  static bool _cacheable(JsonMap block) => switch (block['type']) {
        'thinking' || 'redacted_thinking' => false,
        _ => true,
      };

  void _push(String role, List<JsonMap> blocks, int? messageIndex) {
    if (blocks.isEmpty) return;
    if (turns.isEmpty || turns.last.role != role) turns.add(_Turn(role));
    final turn = turns.last;
    final start = turn.blocks.length;
    turn.blocks.addAll(blocks);
    if (messageIndex == null) return;
    for (var bi = turn.blocks.length - 1; bi >= start; bi--) {
      if (_cacheable(turn.blocks[bi])) {
        _lastBlock[messageIndex] = (turns.length - 1, bi);
        return;
      }
    }
  }

  List<JsonMap> _assistant(Message m) {
    final out = <JsonMap>[];
    final calls = <String>[];
    for (final p in m.content) {
      switch (p) {
        case ReasoningPart(:final text, :final signature, :final redactedData, providerId: final pid):
          // Foreign or legacy reasoning is dropped; so is unsigned thinking
          // (a cancelled block), which the API would reject anyway.
          if (pid != providerId) continue;
          if (redactedData != null) {
            out.add({'type': 'redacted_thinking', 'data': redactedData});
          } else if (signature != null && signature.isNotEmpty) {
            out.add({'type': 'thinking', 'thinking': text, 'signature': signature});
          }
        case TextPart(:final text):
          if (text.isNotEmpty) out.add({'type': 'text', 'text': text});
        case ToolCallPart(:final call):
          final id = AnthropicToolNames.sanitizeId(call.id);
          calls.add(id);
          out.add({'type': 'tool_use', 'id': id, 'name': names.toWire(call.name), 'input': call.arguments});
        default:
          // Images, UI resources, results: not valid in assistant turns.
          break;
      }
    }
    _pending = calls;
    _answered.clear();
    return out;
  }

  /// Tool results of [m], ordered as the assistant issued the calls (the
  /// parallel pool may finish them in any order).
  List<JsonMap> _results(Message m) {
    final results = m.content.whereType<ToolResultPart>().toList();
    if (results.isEmpty) return const [];
    final byId = <String, ToolResultPart>{};
    for (final r in results) {
      final id = AnthropicToolNames.sanitizeId(r.callId);
      if (!_pending.contains(id) || _answered.contains(id) || byId.containsKey(id)) {
        notices.add(ProviderNotice(
          'anthropic.orphan_tool_result',
          'Dropped a tool result with no matching call in the previous assistant turn.',
          data: {'callId': r.callId, 'tool': r.toolName},
        ));
        continue;
      }
      byId[id] = r;
    }
    return [
      for (final id in _pending)
        if (byId[id] case final r?) ...[_answer(id, r)],
    ];
  }

  JsonMap _answer(String id, ToolResultPart r) {
    _answered.add(id);
    final blocks = [
      for (final p in r.content) ...AnthropicRequestBuilder.userBlocks(p, notices, inToolResult: true),
    ];
    if (blocks.isEmpty && r.structured != null) {
      blocks.add({'type': 'text', 'text': jsonEncode(r.structured)});
    }
    final Object? content = switch (blocks) {
      [] => null,
      [{'type': 'text', 'text': final String text}] => text,
      _ => blocks,
    };
    return {
      'type': 'tool_result',
      'tool_use_id': id,
      if (content != null) 'content': content,
      if (r.isError) 'is_error': true,
    };
  }

  /// Every `tool_use` needs a `tool_result` in the next user turn or the API
  /// returns 400. The runner guarantees answers; this is a safety net for
  /// imported or damaged transcripts.
  void _flushMissing() {
    final missing = [for (final id in _pending) if (!_answered.contains(id)) id];
    _pending = const [];
    _answered.clear();
    if (missing.isEmpty) return;
    notices.add(ProviderNotice(
      'anthropic.missing_tool_result',
      'Added an error result for ${missing.length} unanswered tool call(s).',
      data: {'callIds': missing},
    ));
    _push('user', [
      for (final id in missing)
        {
          'type': 'tool_result',
          'tool_use_id': id,
          'content': 'No result was recorded for this tool call.',
          'is_error': true,
        },
    ], null);
  }
}
