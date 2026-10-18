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
        ToolCallPart(:final call) => ToolCallPart(ToolCall(
            id: call.id,
            name: call.name,
            arguments: _argumentsFrom(replacement),
            repaired: call.repaired,
          )),
        _ => TextPart(replacement),
      };

  static String? callIdOf(ContentPart part) => part is ToolResultPart ? part.callId : null;

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
