import 'dart:typed_data';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:test/test.dart';

void main() {
  test('small results pass through untouched', () {
    final r = ToolResult.text('hello');
    expect(identical(limitToolResult(r, const ToolResultLimits()), r), isTrue);
  });

  test('huge text keeps head and tail with a clear note; structured and ui uri survive', () {
    final text = 'START ${'x' * 50000} END';
    final r = limitToolResult(
      ToolResult(content: [TextPart(text)], structured: const {'ok': true}, uiResourceUri: 'ui://a/b'),
      const ToolResultLimits(maxTextChars: 2000),
    );
    final out = (r.content.first as TextPart).text;
    expect(out.length, lessThanOrEqualTo(2000));
    expect(out, startsWith('START'));
    expect(out, endsWith('END'));
    expect(out, contains('truncated by Sherpa'));
    expect(r.structured, {'ok': true});
    expect(r.uiResourceUri, 'ui://a/b');
    expect(r.meta['ai.sherpa/truncated'], isTrue);
  });

  test('the text budget is shared across parts; later parts are dropped with a note', () {
    final r = limitToolResult(
      ToolResult(content: [TextPart('a' * 900), TextPart('b' * 900), const TextPart('c')]),
      const ToolResultLimits(maxTextChars: 1000),
    );
    final texts = [for (final p in r.content) (p as TextPart).text];
    expect(texts.first, 'a' * 900);
    expect(texts, isNot(contains('c')));
    expect(texts.last, contains('more characters of text omitted'));
  });

  test('images are capped by count and size; parts by count', () {
    final img = ImagePart(mimeType: 'image/png', data: Uint8List(10));
    final big = ImagePart(mimeType: 'image/png', data: Uint8List(2000));
    final r = limitToolResult(
      ToolResult(content: [img, big, img, img]),
      const ToolResultLimits(maxImages: 2, maxImageBytes: 1000),
    );
    expect(r.content.whereType<ImagePart>(), hasLength(2));
    final note = (r.content.last as TextPart).text;
    expect(note, contains('over the'));
    expect(note, contains('at most 2 images'));

    final many = limitToolResult(
      ToolResult(content: [for (var i = 0; i < 10; i++) TextPart('$i')]),
      const ToolResultLimits(maxParts: 3),
    );
    expect(many.content, hasLength(4));
    expect((many.content.last as TextPart).text, contains('7 more content parts omitted'));
  });

  test('oversized structured content is dropped with a note; embedded text resources are cut', () {
    final r = limitToolResult(
      ToolResult(
        content: [EmbeddedResourcePart(uri: 'file:///a', text: 'z' * 5000)],
        structured: {'blob': 'y' * 5000},
      ),
      const ToolResultLimits(maxTextChars: 1000, maxStructuredChars: 100),
    );
    expect(r.structured, isNull);
    expect((r.content.first as EmbeddedResourcePart).text!.length, lessThanOrEqualTo(1000));
    expect((r.content.last as TextPart).text, contains('structured content'));
  });
}
