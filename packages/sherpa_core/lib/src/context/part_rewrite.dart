import 'dart:convert';

import '../common/json.dart';
import '../model/content.dart';
import '../model/tool.dart';

/// Helpers for rewriting content parts in the context view without losing
/// the structure providers rely on (tool_result ↔ tool_call pairing).
abstract final class PartRewrite {
  /// Replaces a part's payload with [replacement] text. Tool results keep
  /// their call id, name and error flag so pairing stays valid. Tool calls
  /// keep their id and name; [replacement] is then the JSON object of the
  /// reduced arguments (stage-2 input clearing), or plain text that is
  /// wrapped as `{"_sherpa": text}` so the arguments stay an object.
  static ContentPart replacePayload(ContentPart part, String replacement) => switch (part) {
    ToolResultPart() => part.copyWith(content: [TextPart(replacement)], structured: const {}),
    ToolCallPart(:final call) => ToolCallPart(
      ToolCall(id: call.id, name: call.name, arguments: _argumentsFrom(replacement), repaired: call.repaired),
    ),
    _ => TextPart(replacement),
  };

  static String? callIdOf(ContentPart part) => part is ToolResultPart ? part.callId : null;

  /// A tool result's payload as providers render it as text: text parts,
  /// embedded resource text as `[resource <uri>]` plus its text, resource
  /// links as one line. Elision excerpts and truncation work on this, so
  /// they act on what the model actually reads (for text-only results it
  /// equals [ToolResultPart.text]).
  static String resultText(ToolResultPart r) {
    final lines = <String>[];
    for (final c in r.content) {
      switch (c) {
        case TextPart(:final text):
          lines.add(text);
        case EmbeddedResourcePart(:final uri, :final text?):
          lines.add('[resource $uri]\n$text');
        case EmbeddedResourcePart(:final uri, :final mimeType, blob: _?):
          lines.add('[resource $uri (${mimeType ?? 'binary'})]');
        case ResourceLinkPart(:final uri, :final name, :final title, :final description):
          final label = title ?? name;
          lines.add('[resource link${label == null ? '' : ' "$label"'}: $uri]${description == null ? '' : ' $description'}');
        default:
          break;
      }
    }
    return lines.join('\n');
  }

  static JsonMap _argumentsFrom(String replacement) {
    try {
      final decoded = jsonDecode(replacement);
      if (decoded is Map<Object?, Object?>) return normalizeJson(decoded)! as JsonMap;
    } on FormatException {
      // Not JSON: fall through to the wrapper.
    }
    return {'_sherpa': replacement};
  }
}
