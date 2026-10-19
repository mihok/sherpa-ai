import 'dart:convert';
import 'dart:typed_data';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:test/test.dart';

Uint8List _pdf(String body) => Uint8List.fromList(latin1.encode('%PDF-1.4\n$body\n%%EOF\n'));

Message _user(List<ContentPart> content) =>
    Message(id: 'u', role: Role.user, content: content, createdAt: DateTime.utc(2026, 10, 19));

void main() {
  group('pdfPageCount', () {
    test('reads the page tree root /Count (the largest node)', () {
      final pdf = _pdf('1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n'
          '2 0 obj << /Type /Pages /Kids [3 0 R 9 0 R] /Count 10 >> endobj\n'
          '3 0 obj << /Type /Pages /Parent 2 0 R /Kids [4 0 R] /Count 4 >> endobj\n'
          '4 0 obj << /Type /Page /Parent 3 0 R /MediaBox [0 0 612 792] >> endobj');
      expect(pdfPageCount(pdf), 10);
    });

    test('falls back to counting page objects, then to the linearization dictionary', () {
      // /Resources nested inside the Pages node hides its /Count from the scan.
      final leaves = _pdf('2 0 obj << /Type /Pages /Resources << /Font << >> >> /Count 3 >> endobj\n'
          '3 0 obj << /Type /Page >> endobj 4 0 obj <</Type/Page>> endobj 5 0 obj << /Type /Page /Rotate 90 >> endobj');
      expect(pdfPageCount(leaves), 3);
      final linearized = _pdf('1 0 obj << /Linearized 1 /L 48211 /H [ 655 160 ] /O 4 /E 33116 /N 12 /T 47828 >> endobj\n'
          '7 0 obj << /Type /ObjStm /N 40 /First 300 /Filter /FlateDecode /Length 900 >> stream\nxx\nendstream');
      expect(pdfPageCount(linearized), 12);
    });

    test('is null when the page tree is compressed', () {
      final compressed = _pdf('5 0 obj << /Type /ObjStm /N 3 /First 20 /Filter /FlateDecode /Length 64 >> stream\n'
          '${String.fromCharCodes(List.generate(64, (i) => (i * 37) % 256))}\nendstream');
      expect(pdfPageCount(compressed), isNull);
    });
  });

  group('PDF token estimate', () {
    final counter = HeuristicTokenCounter();
    int pdfCost(EmbeddedResourcePart p) => counter.countMessage(_user([p])) - counter.countMessage(_user(const []));
    const uri = 'file:///chats/s1/att1-report.pdf';
    final overhead = counter.countText(uri) + 4;

    test('a file-referenced PDF is priced from its recorded pages, else its size, never 0', () {
      expect(pdfCost(const EmbeddedResourcePart(uri: uri, mimeType: 'application/pdf', pages: 7)),
          overhead + 7 * pdfTokensPerPage);
      expect(pdfCost(const EmbeddedResourcePart(uri: uri, mimeType: 'application/pdf', size: 100 * 1024)),
          overhead + 5 * pdfTokensPerPage, reason: '~20 KB per page');
      expect(pdfCost(const EmbeddedResourcePart(uri: uri, mimeType: 'application/pdf')), greaterThan(overhead),
          reason: 'an older reference with no size is still counted');
      expect(pdfTokensPerPage, greaterThanOrEqualTo(1500), reason: "at least Anthropic's documented text cost");
    });

    test('an inline PDF is priced from the pages it declares; size-only estimates are capped', () {
      final threePages = _pdf('2 0 obj << /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >> endobj');
      final inline = EmbeddedResourcePart(uri: uri, mimeType: 'application/pdf', blob: threePages);
      expect(pdfCost(inline), overhead + 3 * pdfTokensPerPage);
      expect(pdfCost(inline), overhead + 3 * pdfTokensPerPage, reason: 'cached per blob');
      final scan = EmbeddedResourcePart(uri: uri, mimeType: 'application/pdf', blob: Uint8List(10 * 1024 * 1024));
      expect(pdfCost(scan), overhead + 100 * pdfTokensPerPage, reason: 'unknown pages: size-based, at most 100 pages');
      expect(HeuristicTokenCounter.pdfTokens(pages: 2), 2 * pdfTokensPerPage);
    });

    test('PDFs inside tool results count too', () {
      final result = ToolResultPart(callId: 'c', toolName: 'fetch', content: [
        EmbeddedResourcePart(uri: uri, mimeType: 'application/pdf', blob: _pdf('<< /Type /Pages /Count 2 >>')),
      ]);
      final m = Message(id: 't', role: Role.tool, content: [result], createdAt: DateTime.utc(2026, 10, 19));
      expect(counter.countMessage(m), greaterThan(2 * pdfTokensPerPage));
    });
  });

  test('size and pages survive JSON; pdfInput is a capability', () {
    const part = EmbeddedResourcePart(uri: 'file:///a.pdf', mimeType: 'application/pdf', size: 2048, pages: 3);
    final back = ContentPart.fromJson(jsonDecode(jsonEncode(part.toJson())) as JsonMap) as EmbeddedResourcePart;
    expect((back.size, back.pages, back.mimeType), (2048, 3, 'application/pdf'));
    expect(const EmbeddedResourcePart(uri: 'x', text: 't').toJson().containsKey('size'), isFalse);

    const caps = ModelCapabilities(contextLength: 1000, pdfInput: true);
    expect(ModelCapabilities.fromJson(caps.toJson()).pdfInput, isTrue);
    expect(ModelCapabilities.fromJson(const {}).pdfInput, isFalse);
    expect(caps.copyWith(contextLength: 5).pdfInput, isTrue);
    expect(caps.copyWith(pdfInput: false).pdfInput, isFalse);
  });
}
