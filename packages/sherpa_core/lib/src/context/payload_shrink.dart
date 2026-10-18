import 'dart:convert';

import '../common/json.dart';
import 'digest.dart';
import 'text.dart';

/// Builds the replacement text for elided and truncated payloads.
///
/// Elision and truncation keep the *shape* the model needs to recover: the
/// tool name, size and call id (so it can call again), the first and last
/// lines (Gemini keeps the tail, Codex the head and tail), and for JSON the
/// keys and structure with only big values elided (R11 §9.3).
abstract final class PayloadShrink {
  /// The stage-1 stub (R11 §9.3):
  /// `[tool result elided: <tool>, <n> tokens, call <id>; call the tool again if needed]`
  /// followed by the first and last [keepLines] lines.
  static String elisionStub({
    required String toolName,
    required int tokens,
    required String callId,
    required String text,
    int keepLines = 5,
    int maxLineChars = 160,
  }) {
    final head = '[tool result elided: $toolName, ${groupDigits(tokens)} tokens, call $callId; '
        'call the tool again if needed]';
    final excerpt = headTailLines(text, keepLines: keepLines, maxLineChars: maxLineChars);
    return excerpt.isEmpty ? head : '$head\n$excerpt';
  }

  /// First and last [keepLines] non-empty lines with a marker between them;
  /// the whole text (lines clipped) when it is short.
  static String headTailLines(String text, {int keepLines = 5, int maxLineChars = 160}) {
    final lines = [for (final l in text.split('\n')) if (l.trim().isNotEmpty) clipText(l.trimRight(), maxLineChars)];
    if (lines.length <= keepLines * 2) return lines.join('\n');
    final omitted = lines.length - keepLines * 2;
    return [
      ...lines.take(keepLines),
      '… [$omitted lines omitted] …',
      ...lines.skip(lines.length - keepLines),
    ].join('\n');
  }

  /// Head and tail of [text] within [maxChars], cut at line boundaries when
  /// possible.
  static String headTail(String text, {required int maxChars}) {
    if (text.length <= maxChars) return text;
    final half = (maxChars ~/ 2).clamp(16, 1 << 30);
    var head = text.substring(0, half.clamp(0, text.length));
    var tail = text.substring((text.length - half).clamp(0, text.length));
    final nl = head.lastIndexOf('\n');
    if (nl > half ~/ 2) head = head.substring(0, nl);
    final tl = tail.indexOf('\n');
    if (tl >= 0 && tl < half ~/ 2) tail = tail.substring(tl + 1);
    final omitted = text.length - head.length - tail.length;
    return '$head\n… [${groupDigits(omitted)} chars omitted] …\n$tail';
  }

  /// A JSON value with its keys and structure kept and big values elided:
  /// long strings keep a head plus a size/digest marker, long lists keep
  /// their first items and a count, deep nesting is cut.
  static Object? shrinkJson(Object? value, {int maxStringChars = 120, int maxListItems = 6, int maxDepth = 6}) {
    Object? walk(Object? v, int depth) {
      switch (v) {
        case String() when v.length > maxStringChars:
          final keep = (maxStringChars ~/ 2).clamp(8, 1 << 20);
          return '${clipText(v, keep)} [${groupDigits(v.length)} chars elided, digest ${Digest.fnv64(v).substring(0, 8)}]';
        case Map<Object?, Object?>():
          if (depth >= maxDepth) return '[object with ${v.length} keys elided]';
          return {for (final e in v.entries) e.key.toString(): walk(e.value, depth + 1)};
        case List<Object?>():
          if (depth >= maxDepth) return '[list of ${v.length} items elided]';
          if (v.length <= maxListItems) return [for (final e in v) walk(e, depth + 1)];
          return [
            for (final e in v.take(maxListItems)) walk(e, depth + 1),
            '[${v.length - maxListItems} more items elided]',
          ];
        default:
          return v;
      }
    }

    return walk(value, 0);
  }

  /// [shrinkJson] tightened step by step until it encodes within [maxChars];
  /// falls back to [headTail] of the encoding.
  static String shrinkJsonToFit(Object? value, {required int maxChars}) {
    const steps = [(200, 8, 6), (120, 6, 5), (64, 4, 4), (32, 2, 3), (16, 1, 2)];
    var encoded = jsonEncode(value);
    if (encoded.length <= maxChars) return encoded;
    for (final (s, l, d) in steps) {
      encoded = jsonEncode(shrinkJson(value, maxStringChars: s, maxListItems: l, maxDepth: d));
      if (encoded.length <= maxChars) return encoded;
    }
    return headTail(encoded, maxChars: maxChars);
  }

  /// Stage-2 tool-input clearing (Anthropic `clear_tool_inputs`, R11 §9.3
  /// rule 3): arguments keep their keys; big values are elided and the
  /// digest of the original arguments is kept so the call stays identifiable.
  static JsonMap shrinkArguments(JsonMap arguments, {int maxStringChars = 80}) {
    final shrunk = shrinkJson(arguments, maxStringChars: maxStringChars, maxListItems: 4, maxDepth: 4);
    return {
      ...((shrunk as Map<Object?, Object?>?) ?? const {}).cast<String, Object?>(),
      '_sherpa': 'inputs elided to save context; argsDigest ${Digest.args(arguments)}',
    };
  }

  /// Stage-2 truncation of a tool result: JSON keeps its shape, text keeps
  /// head and tail; both behind a one-line marker.
  static String truncatedResult({
    required String toolName,
    required String callId,
    required int tokens,
    required String text,
    JsonMap? structured,
    required int maxChars,
  }) {
    final marker = '[tool result truncated: $toolName, ${groupDigits(tokens)} tokens, call $callId; '
        'call the tool again with a narrower request if you need the rest]';
    final budget = (maxChars - marker.length - 1).clamp(64, 1 << 30);
    final json = structured ?? _jsonOrNull(text);
    final body = json != null ? shrinkJsonToFit(json, maxChars: budget) : headTail(text, maxChars: budget);
    return '$marker\n$body';
  }

  static Object? _jsonOrNull(String text) {
    final t = text.trim();
    if (!(t.startsWith('{') || t.startsWith('['))) return null;
    try {
      return jsonDecode(t);
    } on FormatException {
      return null;
    }
  }
}
