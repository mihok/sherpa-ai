import '../model/content.dart';

/// Helpers for rewriting content parts in the context view without losing
/// the structure providers rely on (tool_result ↔ tool_call pairing).
abstract final class PartRewrite {
  /// Replaces a part's payload with [replacement] text. Tool results keep
  /// their call id, name and error flag so pairing stays valid.
  static ContentPart replacePayload(ContentPart part, String replacement) => switch (part) {
        ToolResultPart() => part.copyWith(content: [TextPart(replacement)], structured: const {}),
        _ => TextPart(replacement),
      };

  static String? callIdOf(ContentPart part) => part is ToolResultPart ? part.callId : null;
}
