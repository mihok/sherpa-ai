import 'dart:convert';
import 'dart:typed_data';

import '../model/content.dart';
import '../model/message.dart';
import '../model/tool.dart';
import '../provider/model_provider.dart';

/// Chars-per-token ratios by tokenizer family, on the pessimistic side of
/// the measurements in docs/research/11 (English 3.8–4.4, code 3.85–5.0).
/// Newer Claude tokenizers produce ~30% more tokens than older ones.
const Map<String, double> _charsPerToken = {
  'cl100k': 3.8,
  'o200k': 4.0,
  'claude': 2.6,
  'llama3': 3.8,
  'qwen': 3.6,
  'gemma': 3.5,
  'mistral': 3.4,
  'phi': 3.8,
  'lfm2': 3.6,
  'granite': 3.8,
  'default': 3.3,
};

/// Dense scripts (CJK, Hangul, Kana, emoji) measured at 0.46–1.24 tokens
/// per character; count the high end.
const double _denseTokensPerChar = 1.25;

/// First code point counted as dense script (CJK Radicals Supplement).
const int _denseStart = 0x2E80;

/// Fixed per-message cost for role markers / chat-template scaffolding.
const int _perMessageOverhead = 6;

/// Image tokens are provider specific; this is a conservative flat cost.
const int _perImageTokens = 1100;

/// Audio clips: a flat cost (providers that take audio bill per second).
const int _perAudioTokens = 600;

/// Tokens per PDF page. Both APIs that read PDFs send each page's text AND
/// an image of the page:
/// * Anthropic: "Each page typically uses 1,500–3,000 tokens per page
///   depending on content density", plus image tokens because "each page is
///   converted into an image" (platform.claude.com/docs/en/build-with-claude/
///   pdf-support, "Estimate your costs", read 2026-10-19);
/// * OpenAI: "the API extracts both text and page images and sends both to
///   the model" (developers.openai.com/api/docs/guides/pdf-files), no
///   per-page figure.
/// So a page is the documented low end of the text (1,500) plus one page
/// image at this estimator's flat image cost.
const int pdfTokensPerPage = 1500 + _perImageTokens;

/// When the page count is unknown (compressed page tree): pages from the
/// size at roughly 20 KB per page, capped at Anthropic's 100-page request
/// limit (for windows under 1M tokens) so a large scan is not priced as
/// thousands of pages.
const int _bytesPerPdfPage = 20 * 1024;
const int _maxPdfPages = 100;

/// A PDF referenced by file with no recorded size or page count (older
/// transcripts): assume a short document rather than nothing.
const int _unknownPdfPages = 5;

/// Token counter used when no native tokenizer is available.
///
/// Estimates are corrected by [calibrate] whenever a provider reports true
/// usage for a request we estimated, so drift shrinks over a session.
final class HeuristicTokenCounter implements TokenCounter {
  HeuristicTokenCounter({String? family})
      : _ratio = _charsPerToken[family] ?? _charsPerToken['default']!;

  double _ratio;
  int _calibrations = 0;
  double get charsPerToken => _ratio;

  /// How many usage reports have corrected the ratio. The context manager
  /// keeps a 20% safety margin until this reaches 3 (R11 §9.2).
  int get calibrationCount => _calibrations;

  /// Share of characters in [text] that are dense-script (CJK, Hangul,
  /// Kana, emoji). Above 25% the estimate is unreliable and the context
  /// manager widens its margin (R11 §9.2: 0.46–1.24 tokens per CJK char).
  static double denseShare(String text) {
    if (text.isEmpty) return 0;
    var dense = 0;
    var total = 0;
    for (final r in text.runes) {
      total++;
      if (r >= _denseStart) dense++;
    }
    return dense / total;
  }

  @override
  bool get isExact => false;

  @override
  int countText(String text) {
    if (text.isEmpty) return 0;
    var dense = 0;
    for (final r in text.runes) {
      // CJK, Hangul, Kana and emoji usually cost ≥ 1 token each.
      if (r >= _denseStart) dense++;
    }
    final sparse = text.length - dense;
    return (sparse / _ratio).ceil() + (dense * _denseTokensPerChar).ceil();
  }

  @override
  int countMessage(Message message) {
    var n = _perMessageOverhead;
    for (final p in message.content) {
      n += switch (p) {
        ReasoningPart(:final text) => countText(text),
        ToolCallPart(:final call) => countText(call.name) + countText(jsonEncode(call.arguments)) + 4,
        // Every nested part counts: providers send embedded resources
        // (`[resource <uri>]` + text, PDFs as documents), links and media
        // inside tool results, not just the text parts.
        ToolResultPart() => countText(p.text) +
            (p.structured == null ? 0 : countText(jsonEncode(p.structured))) +
            p.content.where((c) => c is! TextPart).fold<int>(0, (n, c) => n + _countPart(c)) +
            4,
        _ => _countPart(p),
      };
    }
    return n;
  }

  int _countPart(ContentPart p) => switch (p) {
        TextPart(:final text) => countText(text),
        ImagePart() => _perImageTokens,
        AudioPart() => _perAudioTokens,
        ResourceLinkPart(:final uri, :final name, :final title, :final description) =>
          countText(uri) + countText(title ?? name ?? '') + countText(description ?? '') + 4,
        EmbeddedResourcePart(:final uri, :final text) =>
          countText(uri) + 4 + (text != null ? countText(text) : _binaryTokens(p)),
        UiResourcePart() => 0,
        UnknownPart(:final raw) => countText(jsonEncode(raw)),
        // Nested messages-in-results do not exist; count anything else as JSON.
        _ => countText(jsonEncode(p.toJson())),
      };

  /// A binary resource: inline ([EmbeddedResourcePart.blob]) or a file
  /// reference the app inlines at send time (only size and pages known).
  static int _binaryTokens(EmbeddedResourcePart p) {
    final mime = (p.mimeType ?? '').toLowerCase();
    final blob = p.blob;
    if (mime == 'application/pdf') return pdfTokens(pages: p.pages ?? _pages(blob), bytes: p.size ?? blob?.length);
    if (blob == null && p.size == null) return 0; // nothing behind it: providers send a short note
    if (mime.startsWith('image/')) return _perImageTokens;
    if (mime.startsWith('audio/')) return _perAudioTokens;
    // Other binary content is replaced by a one-line note.
    return 12;
  }

  /// Page counts of inline PDFs, so a transcript re-counted on every turn
  /// does not rescan the bytes.
  static final Expando<int> _pageCache = Expando('pdfPages');

  static int? _pages(Uint8List? blob) {
    if (blob == null) return null;
    final cached = _pageCache[blob];
    if (cached != null) return cached < 0 ? null : cached;
    final n = pdfPageCount(blob);
    _pageCache[blob] = n ?? -1;
    return n;
  }

  /// Estimated tokens of a PDF with [pages] pages (else [bytes] bytes, else
  /// unknown): [pdfTokensPerPage] per page.
  static int pdfTokens({int? pages, int? bytes}) {
    final n = pages != null && pages > 0
        ? pages
        : bytes != null && bytes > 0
            ? (bytes / _bytesPerPdfPage).ceil().clamp(1, _maxPdfPages)
            : _unknownPdfPages;
    return n * pdfTokensPerPage;
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
    _calibrations++;
  }
}
