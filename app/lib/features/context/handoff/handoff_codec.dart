import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_core/sherpa_core.dart';

/// Moves handoff bundles in and out of the app: the QR payload, and the
/// decoding of anything a user brings in (a file, pasted text, a scanned
/// code) *before* `HandoffBundle.parse` sees it.
///
/// Everything inbound is untrusted. Size is checked before decoding,
/// compressed input is inflated in small chunks against a hard cap (a gzip
/// bomb stops at [HandoffLimits.maxBytes] instead of filling memory), and
/// every failure becomes a [HandoffBundleException] with a message the
/// import screen can show as is.
abstract final class HandoffCodec {
  /// Marks a QR payload: `sherpa-handoff:1:` + base64url(gzip(bundle JSON)).
  /// The prefix lets the scanner ignore unrelated codes and keeps a pasted
  /// payload recognisable.
  static const String qrPrefix = 'sherpa-handoff:1:';

  /// Byte-mode capacity of the largest QR code (version 40) at error
  /// correction level L, the level used for on-screen codes: a screen has
  /// no print damage to recover from, so capacity matters more.
  static const int qrCapacityBytes = 2953;

  /// The QR payload for [bundle] (compact JSON, gzip, unpadded base64url:
  /// QR byte mode, no characters that need escaping in a URL or text).
  static String qrPayload(HandoffBundle bundle) {
    final zipped = GZipCodec(level: ZLibOption.maxLevel).encode(utf8.encode(bundle.encode()));
    return '$qrPrefix${base64Url.encode(zipped).replaceAll('=', '')}';
  }

  /// UTF-8 size of [payload] as a QR code stores it.
  static int qrBytes(String payload) => utf8.encode(payload).length;

  static bool fitsQr(String payload) => qrBytes(payload) <= qrCapacityBytes;

  /// The file the share sheet and "Save to Files" write: indented JSON so a
  /// curious user can read it in any text editor.
  static Uint8List fileBytes(HandoffBundle bundle) =>
      utf8.encode(const JsonEncoder.withIndent('  ').convert(bundle.toJson()));

  /// `sherpa-trip-to-porto-2026-10-19.sherpa-handoff.json`.
  static String fileName(HandoffBundle bundle) {
    final slug = bundle.task
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final short = slug.length > 40 ? slug.substring(0, 40).replaceAll(RegExp(r'-+$'), '') : slug;
    final d = bundle.createdAt.toUtc();
    final date = '${d.year}-${_two(d.month)}-${_two(d.day)}';
    return 'sherpa-${short.isEmpty ? 'handoff' : short}-$date$fileSuffix';
  }

  static const String fileSuffix = '.sherpa-handoff.json';

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// Parses pasted or scanned [input]: a QR payload or bundle JSON.
  static HandoffBundle parseText(String input, {HandoffLimits limits = const HandoffLimits()}) =>
      HandoffBundle.parse(decodeText(input, limits: limits), limits: limits);

  /// Parses file [bytes]: JSON, or gzip-compressed JSON.
  static HandoffBundle parseBytes(List<int> bytes, {HandoffLimits limits = const HandoffLimits()}) {
    if (bytes.isEmpty) throw const HandoffBundleException('the file is empty');
    final isGzip = bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
    if (!isGzip && bytes.length > limits.maxBytes) {
      throw HandoffBundleException('the file is larger than ${limits.maxBytes ~/ 1024} KB');
    }
    final raw = isGzip ? _inflate(bytes, limits.maxBytes) : bytes;
    return parseText(_utf8(raw), limits: limits);
  }

  /// The bundle JSON inside [input] (decompressing a QR payload).
  static String decodeText(String input, {HandoffLimits limits = const HandoffLimits()}) {
    final text = input.trim();
    if (text.isEmpty) throw const HandoffBundleException('there is nothing to import');
    if (text.length > limits.maxBytes * 2) {
      throw HandoffBundleException('the text is larger than ${limits.maxBytes ~/ 1024} KB');
    }
    if (text.startsWith(qrPrefix)) {
      final List<int> zipped;
      try {
        final b64 = text.substring(qrPrefix.length).replaceAll(RegExp(r'\s'), '');
        zipped = base64Url.decode(b64.padRight((b64.length + 3) ~/ 4 * 4, '='));
      } on FormatException {
        throw const HandoffBundleException('the code is damaged or incomplete');
      }
      return _utf8(_inflate(zipped, limits.maxBytes));
    }
    if (text.startsWith('{')) return text;
    throw const HandoffBundleException('this is not a Sherpa handoff');
  }

  static String _utf8(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const HandoffBundleException('the content is not text');
    }
  }

  /// Inflates [data] 1 KB at a time, refusing more than [max] bytes out.
  static List<int> _inflate(List<int> data, int max) {
    final sink = _CappedSink(max);
    try {
      final inflater = gzip.decoder.startChunkedConversion(sink);
      for (var i = 0; i < data.length; i += 1024) {
        inflater.add(data.sublist(i, math.min(i + 1024, data.length)));
      }
      inflater.close();
    } on HandoffBundleException {
      rethrow;
    } on Object {
      throw const HandoffBundleException('the compressed data is damaged');
    }
    return sink.bytes.takeBytes();
  }

  /// A calm, specific sentence for an import failure.
  static String explain(HandoffBundleException e) {
    final m = e.message;
    if (m.contains('newer Sherpa')) return 'It was made by a newer version of Sherpa. Update the app, then try again.';
    if (m.startsWith('not a Sherpa') || m == 'this is not a Sherpa handoff') {
      return 'This is not a Sherpa handoff. Check that you picked the right file or code.';
    }
    if (m.contains('larger than') || m.contains('too long') || m.contains('too many') || m.contains('deeper')) {
      return 'It is too large to be a handoff (${_sentence(m)}). Nothing was imported.';
    }
    return 'It failed a safety check, so nothing was imported: ${_sentence(m)}.';
  }

  static String _sentence(String m) => m.endsWith('.') ? m.substring(0, m.length - 1) : m;
}

final class _CappedSink implements Sink<List<int>> {
  _CappedSink(this.max);

  final int max;
  final BytesBuilder bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > max) {
      throw HandoffBundleException('it expands to more than ${max ~/ 1024} KB');
    }
    bytes.add(chunk);
  }

  @override
  void close() {}
}
