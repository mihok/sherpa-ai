import 'dart:convert';

import '../model/content.dart';
import '../model/message.dart';
import '../model/tool.dart';
import '../provider/model_provider.dart';

/// Calibrated chars-per-token ratios by tokenizer family. Values are
/// deliberately on the low (pessimistic) side of measured English/code
/// averages; CJK and other dense scripts are counted per code unit.
const Map<String, double> _charsPerToken = {
  'cl100k': 3.8,
  'o200k': 4.0,
  'claude': 3.5,
  'llama3': 3.8,
  'qwen': 3.6,
  'gemma': 3.9,
  'mistral': 3.4,
  'phi': 3.6,
  'default': 3.3,
};

/// Fixed per-message cost for role markers / chat-template scaffolding.
const int _perMessageOverhead = 6;

/// Image tokens are provider specific; this is a conservative flat cost.
const int _perImageTokens = 1100;

/// Token counter used when no native tokenizer is available.
///
/// Estimates are corrected by [calibrate] whenever a provider reports true
/// usage for a request we estimated, so drift shrinks over a session.
final class HeuristicTokenCounter implements TokenCounter {
  HeuristicTokenCounter({String? family})
      : _ratio = _charsPerToken[family] ?? _charsPerToken['default']!;

  double _ratio;
  double get charsPerToken => _ratio;

  @override
  bool get isExact => false;

  @override
  int countText(String text) {
    if (text.isEmpty) return 0;
    var dense = 0;
    for (final r in text.runes) {
      // CJK, Hangul, Kana and emoji usually cost ≥ 1 token each.
      if (r >= 0x2E80) dense++;
    }
    final sparse = text.length - dense;
    return (sparse / _ratio).ceil() + dense;
  }

  @override
  int countMessage(Message message) {
    var n = _perMessageOverhead;
    for (final p in message.content) {
      n += switch (p) {
        TextPart(:final text) => countText(text),
        ReasoningPart(:final text) => countText(text),
        ToolCallPart(:final call) => countText(call.name) + countText(jsonEncode(call.arguments)) + 4,
        ToolResultPart() => countText(p.text) +
            (p.structured == null ? 0 : countText(jsonEncode(p.structured))) +
            p.content.whereType<ImagePart>().length * _perImageTokens +
            4,
        ImagePart() => _perImageTokens,
        AudioPart() => 600,
        ResourceLinkPart(:final uri, :final description) =>
          countText(uri) + countText(description ?? ''),
        EmbeddedResourcePart(:final text) => countText(text ?? ''),
        UiResourcePart() => 0,
        UnknownPart(:final raw) => countText(jsonEncode(raw)),
        _ => 0,
      };
    }
    return n;
  }

  @override
  int countTools(List<ToolDefinition> tools) {
    var n = 0;
    for (final t in tools) {
      n += countText(t.name) + countText(t.description) + countText(jsonEncode(t.inputSchema)) + 8;
    }
    return n;
  }

  /// Nudges the ratio toward observed truth. [estimated] is what we
  /// predicted for the input, [actual] what the provider billed.
  void calibrate({required int estimated, required int actual}) {
    if (estimated <= 0 || actual <= 0) return;
    final observed = _ratio * estimated / actual;
    // Exponential moving average, clamped to sane bounds so one odd
    // request (e.g. a huge image) can't wreck the estimator.
    _ratio = (_ratio * 0.7 + observed * 0.3).clamp(2.0, 5.0);
  }
}
