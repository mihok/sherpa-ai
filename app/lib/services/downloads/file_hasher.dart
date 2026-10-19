import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Hashes files for the end-of-download integrity check.
///
/// The CDN `ETag` is the Xet hash, not SHA-256, and resumes can't rely on
/// `If-Range` (R08 §0.9), so streaming the finished file through SHA-256
/// and comparing with `lfs.oid` is the only real integrity guarantee.
/// background_downloader has no checksum support at all (R09 §6), so Sherpa
/// does it itself.
abstract interface class FileHasher {
  /// Lower-case hex SHA-256 of the file at [path]. [onProgress] receives
  /// bytes hashed so far.
  Future<String> sha256(String path, {void Function(int bytesHashed)? onProgress});
}

/// [FileHasher] that reads and hashes on a background isolate.
///
/// package:crypto is pure Dart (~150–300 MB/s on a phone core), so a 5 GB
/// file takes 15–30 s; on the UI isolate (merged with the platform thread
/// since Flutter 3.29, R12 §1.6) that would freeze the app. The isolate
/// reads with synchronous IO in [chunkBytes] blocks and posts progress
/// every [progressEvery] bytes.
final class IsolateFileHasher implements FileHasher {
  const IsolateFileHasher({this.chunkBytes = 4 << 20, this.progressEvery = 32 << 20});

  final int chunkBytes;
  final int progressEvery;

  @override
  Future<String> sha256(String path, {void Function(int bytesHashed)? onProgress}) async {
    final port = ReceivePort();
    final done = Completer<String>();
    final sub = port.listen((Object? msg) {
      switch (msg) {
        case final int bytes:
          onProgress?.call(bytes);
        case final String hex:
          if (!done.isCompleted) done.complete(hex);
        case [final Object error, _]:
          // onError delivers [error, stackTrace] as strings.
          if (!done.isCompleted) done.completeError(FileSystemException('hashing failed: $error', path));
        case null:
          // onExit without a result: the isolate died.
          if (!done.isCompleted) done.completeError(FileSystemException('hashing isolate exited', path));
      }
    });
    try {
      await Isolate.spawn<_HashJob>(
        _hashEntry,
        _HashJob(path, port.sendPort, chunkBytes, progressEvery),
        onError: port.sendPort,
        onExit: port.sendPort,
        debugName: 'sha256',
      );
      return await done.future;
    } finally {
      await sub.cancel();
      port.close();
    }
  }
}

final class _HashJob {
  const _HashJob(this.path, this.port, this.chunkBytes, this.progressEvery);

  final String path;
  final SendPort port;
  final int chunkBytes;
  final int progressEvery;
}

void _hashEntry(_HashJob job) {
  final out = _DigestSink();
  final input = sha256.startChunkedConversion(out);
  final raf = File(job.path).openSync();
  try {
    final buf = Uint8List(job.chunkBytes);
    var total = 0;
    var nextReport = job.progressEvery;
    while (true) {
      final n = raf.readIntoSync(buf);
      if (n <= 0) break;
      input.add(Uint8List.sublistView(buf, 0, n));
      total += n;
      if (total >= nextReport) {
        job.port.send(total);
        nextReport += job.progressEvery;
      }
    }
    input.close();
    job.port.send(total);
    job.port.send(out.value.toString());
  } finally {
    raf.closeSync();
  }
}

/// In-process hasher for small files and hosts without isolates.
final class InlineFileHasher implements FileHasher {
  const InlineFileHasher();

  @override
  Future<String> sha256(String path, {void Function(int bytesHashed)? onProgress}) async {
    final out = _DigestSink();
    final input = sha256Converter.startChunkedConversion(out);
    var total = 0;
    await for (final chunk in File(path).openRead()) {
      input.add(chunk);
      total += chunk.length;
      onProgress?.call(total);
    }
    input.close();
    return out.value.toString();
  }
}

/// `package:crypto`'s converter under a name that does not clash with the
/// interface method.
final Hash sha256Converter = sha256;

final class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value!;

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}

/// Git blob sha1 (`sha1("blob <len>\0" + bytes)`): the integrity id of small
/// non-LFS files (tree `oid`, `X-Linked-ETag` on 307s, R08 §5.3).
Future<String> gitBlobSha1OfFile(String path) async {
  final f = File(path);
  final len = await f.length();
  final out = _DigestSink();
  final input = sha1.startChunkedConversion(out)..add('blob $len\u0000'.codeUnits);
  await for (final chunk in f.openRead()) {
    input.add(chunk);
  }
  input.close();
  return out.value.toString();
}
