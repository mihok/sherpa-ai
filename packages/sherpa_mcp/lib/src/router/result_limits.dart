/// Size limits for tool results before they enter the context.
library;

import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart'
    show AudioPart, ContentPart, EmbeddedResourcePart, ImagePart, TextPart, ToolResult;

/// Caps on one tool result.
///
/// Why here and not only in the context manager: a single MCP result can be
/// megabytes (a file dump, a base64 image burst) and would otherwise be
/// stored, rendered and counted in full before any pruning runs; a small
/// local model's whole window is a few thousand tokens. Text is cut with a
/// visible note so the model knows to ask for less instead of believing it
/// saw everything. `structuredContent` and the MCP Apps `uiResourceUri`
/// survive (the UI needs them), unless the structured payload alone is
/// absurdly large.
@immutable
final class ToolResultLimits {
  const ToolResultLimits({
    this.maxTextChars = 40000,
    this.maxParts = 32,
    this.maxImages = 4,
    this.maxImageBytes = 5 << 20,
    this.maxAudioBytes = 5 << 20,
    this.maxBlobBytes = 1 << 20,
    this.maxStructuredChars = 200000,
  });

  /// ≈ 2K tokens of text: what fits a 4–8K local window next to history.
  static const ToolResultLimits local =
      ToolResultLimits(maxTextChars: 8000, maxParts: 16, maxImages: 2, maxStructuredChars: 50000);

  static const ToolResultLimits tiny =
      ToolResultLimits(maxTextChars: 4000, maxParts: 8, maxImages: 1, maxStructuredChars: 20000);

  /// Total characters of text (text parts + embedded text resources).
  final int maxTextChars;

  /// Content parts kept (later ones are summarized in a note).
  final int maxParts;
  final int maxImages;

  /// Anthropic's per-image limit is 5 MB.
  final int maxImageBytes;
  final int maxAudioBytes;

  /// Embedded binary resources.
  final int maxBlobBytes;

  /// A larger `structuredContent` is dropped with a note (the text content
  /// carries its serialization for the model anyway).
  final int maxStructuredChars;
}

/// Applies [limits] to [result]. Returns [result] itself when nothing had
/// to change.
ToolResult limitToolResult(ToolResult result, ToolResultLimits limits) {
  final notes = <String>[];
  final parts = <ContentPart>[];
  var textLeft = limits.maxTextChars;
  var images = 0;
  var droppedParts = 0;
  var droppedText = 0;
  var changed = false;

  for (final (i, p) in result.content.indexed) {
    if (i >= limits.maxParts) {
      droppedParts = result.content.length - limits.maxParts;
      changed = true;
      break;
    }
    switch (p) {
      case TextPart(:final text):
        final cut = _cut(text, textLeft);
        textLeft -= cut.length;
        if (!identical(cut, text)) changed = true;
        if (cut.isNotEmpty) {
          parts.add(identical(cut, text) ? p : TextPart(cut));
        } else if (text.isNotEmpty) {
          droppedText += text.length;
        }
      case EmbeddedResourcePart(:final text, :final blob, :final uri, :final mimeType):
        if (text != null) {
          final cut = _cut(text, textLeft);
          textLeft -= cut.length;
          if (identical(cut, text)) {
            parts.add(p);
          } else if (cut.isEmpty) {
            changed = true;
            droppedText += text.length;
          } else {
            changed = true;
            parts.add(EmbeddedResourcePart(uri: uri, mimeType: mimeType, text: cut));
          }
        } else if (blob != null && blob.length > limits.maxBlobBytes) {
          changed = true;
          notes.add('[resource $uri (${_size(blob.length)}) omitted: over the ${_size(limits.maxBlobBytes)} limit]');
        } else {
          parts.add(p);
        }
      case ImagePart(:final data):
        final bytes = data?.length ?? 0;
        if (images >= limits.maxImages) {
          changed = true;
          notes.add('[image omitted: at most ${limits.maxImages} image${limits.maxImages == 1 ? '' : 's'} per result]');
        } else if (bytes > limits.maxImageBytes) {
          changed = true;
          notes.add('[image (${_size(bytes)}) omitted: over the ${_size(limits.maxImageBytes)} limit]');
        } else {
          images++;
          parts.add(p);
        }
      case AudioPart(:final data):
        final bytes = data?.length ?? 0;
        if (bytes > limits.maxAudioBytes) {
          changed = true;
          notes.add('[audio (${_size(bytes)}) omitted: over the ${_size(limits.maxAudioBytes)} limit]');
        } else {
          parts.add(p);
        }
      default:
        parts.add(p);
    }
  }
  if (droppedText > 0) {
    notes.add('[$droppedText more characters of text omitted: over the ${limits.maxTextChars}-character limit]');
  }
  if (droppedParts > 0) notes.add('[$droppedParts more content part${droppedParts == 1 ? '' : 's'} omitted]');

  var structured = result.structured;
  if (structured != null) {
    final size = jsonEncode(structured).length;
    if (size > limits.maxStructuredChars) {
      changed = true;
      structured = null;
      notes.add('[structured content (${_size(size)}) omitted: too large]');
    }
  }
  if (!changed) return result;
  return ToolResult(
    content: [...parts, if (notes.isNotEmpty) TextPart(notes.join('\n'))],
    structured: structured,
    isError: result.isError,
    uiResourceUri: result.uiResourceUri,
    meta: {...result.meta, 'ai.sherpa/truncated': true},
  );
}

/// Keeps the head (¾) and the tail (¼) of [text] within [budget] chars,
/// with a note in the middle: the tail often holds the error or the total.
String _cut(String text, int budget) {
  if (text.length <= budget) return text;
  if (budget <= 0) return '';
  // The note's length depends on the numbers in it; size it first so the
  // result never exceeds [budget].
  String note(int omitted) => '\n[… $omitted of ${text.length} characters truncated by Sherpa; '
      'ask for a narrower query or a specific range if you need the rest …]\n';
  final probe = note(text.length).length;
  if (budget <= probe * 2) {
    final short = '\n[… truncated, ${text.length} characters in total]';
    final keep = budget - short.length;
    return keep <= 0 ? text.substring(0, budget) : '${text.substring(0, keep)}$short';
  }
  final keep = budget - probe;
  final head = (keep * 3) ~/ 4;
  final tail = keep - head;
  return '${text.substring(0, head)}${note(text.length - head - tail)}${text.substring(text.length - tail)}';
}

String _size(int bytes) => bytes >= 1 << 20
    ? '${(bytes / (1 << 20)).toStringAsFixed(1)} MB'
    : bytes >= 1024
        ? '${(bytes / 1024).toStringAsFixed(0)} KB'
        : '$bytes bytes';
