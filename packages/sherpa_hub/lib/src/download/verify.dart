import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Streams a file through SHA-256 and compares with `lfs.oid`.
///
/// The CDN `ETag` is the Xet hash, not SHA-256 (R08 §0.9), and resumes
/// can't rely on `If-Range`, so this end-of-download check is the integrity
/// guarantee. Byte-split parts are verified one by one against their own
/// `lfs.oid` before they are joined.
Future<bool> verifySha256(Stream<List<int>> content, String expectedHex) async =>
    (await sha256Of(content)) == expectedHex.toLowerCase();

Future<String> sha256Of(Stream<List<int>> content) async {
  final out = _DigestSink();
  final input = sha256.startChunkedConversion(out);
  await for (final chunk in content) {
    input.add(chunk);
  }
  input.close();
  return out.value.toString();
}

/// Git blob sha1 (`sha1("blob <len>\0" + bytes)`) — the integrity id of
/// small non-LFS files (tree `oid`, `X-Linked-ETag` on 307s, R08 §5.3).
String gitBlobSha1(Uint8List bytes) {
  final header = utf8.encode('blob ${bytes.length}\u0000');
  return sha1.convert([...header, ...bytes]).toString();
}

final class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value!;

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}
