import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';

import '../common/hashing.dart';
import '../common/openai_messages.dart';
import '../common/tool_names.dart';
import '../config.dart';
import 'chat_request.dart';
import 'known_models.dart';
import 'quirks.dart';

/// A Responses request body plus notices about unsupported settings.
final class ResponsesRequestBody {
  const ResponsesRequestBody(this.body, this.notices);

  final JsonMap body;
  final List<ProviderNotice> notices;
}

/// Optional request fields that may be stripped (once each) when the
/// server rejects them, in the order they are checked.
const List<String> responsesOptionalParams = [
  'reasoning.summary',
  'include',
  'temperature',
  'top_p',
  'prompt_cache_key',
];

/// Removes [param] (a dotted path) from [body]; drops a parent object that
/// becomes empty. Returns whether anything was removed.
bool removeParam(JsonMap body, String param) {
  final parts = param.split('.');
  if (parts.length == 1) return body.remove(param) != null;
  final parent = body[parts.first];
  if (parent is! Map || !parent.containsKey(parts[1])) return false;
  final copy = {...parent.cast<String, Object?>()}..remove(parts[1]);
  if (copy.isEmpty) {
    body.remove(parts.first);
  } else {
    body[parts.first] = copy;
  }
  return true;
}

/// Whether [param] is present in [body] (dotted path).
bool hasParam(JsonMap body, String param) {
  final parts = param.split('.');
  if (parts.length == 1) return body.containsKey(param);
  final parent = body[parts.first];
  return parent is Map && parent.containsKey(parts[1]);
}

/// Builds a stateless (`store: false`) streaming Responses body.
///
/// Reasoning state survives across tool calls by asking for
/// `reasoning.encrypted_content` and replaying it (R10 §8): the stateless
/// equivalent of Anthropic thinking signatures, matching Sherpa's
/// local-first transcript. [rejected] lists optional fields the server
/// already refused for this model.
ResponsesRequestBody buildResponsesRequest({
  required ModelRequest request,
  required ToolNameMapper names,
  required String providerId,
  Set<String> rejected = const {},
}) {
  final notices = <ProviderNotice>[];
  final params = request.params;
  final tools = visibleTools(request);
  final input = ResponsesInputMapper(
    providerId: providerId,
    names: names,
    pdfUnsupportedReason: ServerQuirks.of(ServerProfile.openAi).pdfRefusal(request.modelId),
  ).map(request.messages, notices);

  final body = <String, Object?>{
    'model': request.modelId,
    'input': input,
    'stream': true,
    'store': false,
  };
  final system = request.systemPrompt?.trim() ?? '';
  if (system.isNotEmpty) body['instructions'] = request.systemPrompt;

  // Known non-reasoning models reject the `reasoning` object; for unknown
  // ids it is sent and stripped on rejection.
  final known = lookupKnownModel(request.modelId);
  final mayReason = known == null || known.reasoning != ReasoningSupport.none;
  if (mayReason) {
    body['include'] = ['reasoning.encrypted_content'];
    body['reasoning'] = {
      if (params.reasoning case final e?) 'effort': effortValue(e),
      'summary': 'auto',
    };
  } else if (params.reasoning != null) {
    notices.add(const ProviderNotice('reasoning_effort_unsupported', 'This model does not reason; effort ignored.'));
  }

  if (tools.isNotEmpty) {
    body['tools'] = [
      for (final t in tools)
        {
          'type': 'function',
          'name': names.toWire(t.name),
          if (t.description.isNotEmpty) 'description': t.description,
          'parameters': t.inputSchema,
          // Strict mode demands closed schemas with every property
          // required, which MCP tool schemas rarely are; it would 400.
          'strict': false,
        },
    ];
    switch (params.toolChoice) {
      case ToolChoiceAuto():
        break;
      case ToolChoiceNone():
        body['tool_choice'] = 'none';
      case ToolChoiceRequired():
        body['tool_choice'] = 'required';
      case ToolChoiceSpecific(:final name):
        body['tool_choice'] = {'type': 'function', 'name': names.toWire(name)};
    }
    if (!params.parallelToolCalls) body['parallel_tool_calls'] = false;
  }

  if (params.maxOutputTokens case final max?) body['max_output_tokens'] = max;
  if (params.temperature case final t?) body['temperature'] = t;
  if (params.topP case final t?) body['top_p'] = t;
  for (final (label, value) in [
    ('top_k', params.topK),
    ('min_p', params.minP),
    ('repeat_penalty', params.repeatPenalty),
    ('seed', params.seed),
    ('stop', params.stop.isEmpty ? null : params.stop),
  ]) {
    if (value != null) {
      notices.add(ProviderNotice('param_unsupported', '$label is not supported by the Responses API; not sent.'));
    }
  }
  if (params.jsonSchema case final schema?) {
    final title = schema['title'];
    body['text'] = {
      'format': {
        'type': 'json_schema',
        'name': title is String ? ToolNameMapper.sanitize(title) : 'response',
        'schema': schema,
        'strict': false,
      },
    };
  }
  if (request.cache.sessionId case final sid?) body['prompt_cache_key'] = 'sherpa-${fnv1a32Hex(sid)}';

  for (final e in params.extra.entries) {
    if (e.value == null) {
      body.remove(e.key);
    } else {
      body[e.key] = e.value;
    }
  }
  for (final r in rejected) {
    removeParam(body, r);
  }
  return ResponsesRequestBody(body, notices);
}

/// Maps core [Message]s to Responses `input` items.
///
/// Replayed items carry no `id`: with `store: false` nothing is persisted
/// server-side, so an id refers to nothing and can be rejected as "not
/// found"; the encrypted reasoning content carries the state instead.
///
/// Reasoning storage contract (shared with [ResponsesStreamParser]): a
/// Responses reasoning item is stored as one [ReasoningPart] whose
/// [ReasoningPart.signature] is the item's `encrypted_content`, verbatim,
/// and whose [ReasoningPart.text] is the concatenated summary text. Only
/// parts whose [ReasoningPart.providerId] is this provider are replayed.
///
/// PDFs go out as `{type: input_file, filename, file_data}` with a
/// `data:application/pdf;base64,` URL (developers.openai.com/api/docs/guides/
/// pdf-files), in user content and inside `function_call_output`, unless
/// [pdfUnsupportedReason] says the model cannot read them.
final class ResponsesInputMapper {
  const ResponsesInputMapper({required this.providerId, required this.names, this.pdfUnsupportedReason});

  final String providerId;
  final ToolNameMapper names;

  /// Why PDFs cannot be sent to this model; null when they can.
  final String? pdfUnsupportedReason;

  /// The `input_file` part for a PDF, or null (with a notice).
  JsonMap? pdfPart(EmbeddedResourcePart p, List<ProviderNotice> notices) {
    final why = pdfUnsupportedReason;
    final blob = p.blob;
    if (why != null || blob == null) {
      notices.add(pdfDropped(p.uri, why ?? 'the file could not be read'));
      return null;
    }
    return {'type': 'input_file', 'filename': pdfFileName(p.uri), 'file_data': pdfDataUrl(blob)};
  }

  List<JsonMap> map(List<Message> messages, List<ProviderNotice> notices) {
    final out = <JsonMap>[];
    for (final m in messages) {
      switch (m.role) {
        case Role.system:
          if (m.text.isNotEmpty) out.add({'role': 'developer', 'content': m.text});
        case Role.user:
          out.addAll(_toolOutputs(m.toolResults, notices));
          final content = _userContent(m, notices);
          if (content != null) out.add({'role': 'user', 'content': content});
        case Role.assistant:
          out.addAll(_assistant(m));
        case Role.tool:
          out.addAll(_toolOutputs(m.toolResults, notices));
      }
    }
    return out;
  }

  Object? _userContent(Message m, List<ProviderNotice> notices) {
    final parts = <JsonMap>[];
    for (final c in m.content) {
      switch (c) {
        case TextPart(:final text):
          parts.add({'type': 'input_text', 'text': text});
        case ImagePart():
          final url = mediaUrl(c);
          if (url == null) {
            notices.add(_dropped('image'));
          } else {
            parts.add({'type': 'input_image', 'image_url': url});
          }
        case EmbeddedResourcePart(:final uri, :final text?):
          parts.add({'type': 'input_text', 'text': '[resource $uri]\n$text'});
        case EmbeddedResourcePart(:final mimeType) when isPdf(mimeType):
          final part = pdfPart(c, notices);
          if (part != null) parts.add(part);
        case EmbeddedResourcePart(:final mimeType, :final blob?) when (mimeType ?? '').startsWith('image/'):
          parts.add({'type': 'input_image', 'image_url': 'data:$mimeType;base64,${base64Encode(blob)}'});
        case ResourceLinkPart(:final uri, :final name):
          parts.add({'type': 'input_text', 'text': '[resource link${name == null ? '' : ' "$name"'}: $uri]'});
        case MediaPart() || EmbeddedResourcePart():
          notices.add(_dropped(c.type));
        case ReasoningPart() || ToolCallPart() || ToolResultPart() || UiResourcePart() || UnknownPart():
          break;
      }
    }
    if (parts.isEmpty) return m.toolResults.isEmpty ? '' : null;
    if (parts.every((p) => p['type'] == 'input_text')) return parts.map((p) => p['text']).join('\n');
    return parts;
  }

  List<JsonMap> _assistant(Message m) {
    final items = <JsonMap>[];
    final text = StringBuffer();
    void flushText() {
      if (text.isEmpty) return;
      items.add({'role': 'assistant', 'content': text.toString()});
      text.clear();
    }

    for (final c in m.content) {
      switch (c) {
        case ReasoningPart(:final signature?, :final providerId) when providerId == this.providerId:
          flushText();
          items.add({
            'type': 'reasoning',
            'summary': [
              if (c.text.isNotEmpty) {'type': 'summary_text', 'text': c.text},
            ],
            'encrypted_content': signature,
          });
        case TextPart(text: final t):
          text.write(t);
        case ToolCallPart(:final call):
          flushText();
          items.add({
            'type': 'function_call',
            'call_id': call.id,
            'name': names.toWire(call.name),
            'arguments': argumentsForHistory(call),
          });
        default:
          break;
      }
    }
    flushText();
    // A reasoning item must be followed by the item it produced; a turn
    // that ended after reasoning (cancelled, refused) would 400.
    while (items.isNotEmpty && items.last['type'] == 'reasoning') {
      items.removeLast();
    }
    return items;
  }

  List<JsonMap> _toolOutputs(List<ToolResultPart> results, List<ProviderNotice> notices) => [
        for (final r in results) {'type': 'function_call_output', 'call_id': r.callId, 'output': _output(r, notices)},
      ];

  /// Plain text when possible; a content list when the result has images
  /// or PDFs (Responses accepts `input_image` and `input_file` inside
  /// `function_call_output`).
  Object _output(ToolResultPart r, List<ProviderNotice> notices) {
    final text = toolResultText(r);
    final images = toolResultImages(r);
    final pdfs = toolResultPdfs(r);
    if (images.isEmpty && pdfs.isEmpty) return text;
    final parts = <JsonMap>[
      if (text.isNotEmpty) {'type': 'input_text', 'text': text},
    ];
    for (final img in images) {
      final url = mediaUrl(img);
      if (url == null) {
        notices.add(_dropped('image'));
      } else {
        parts.add({'type': 'input_image', 'image_url': url});
      }
    }
    for (final pdf in pdfs) {
      final part = pdfPart(pdf, notices);
      if (part != null) parts.add(part);
    }
    return parts.isEmpty ? text : parts;
  }

  static ProviderNotice _dropped(String what) =>
      ProviderNotice('content_dropped', 'Some $what content was not sent to the Responses API.', data: {'kind': what});
}
