import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:path/path.dart' as p;

import 'transfer_backend.dart';

/// [TransferBackend] over background_downloader 9.6 (iOS background
/// `URLSession`, Android WorkManager / user-initiated data transfer jobs).
///
/// Why segments: the plugin's own pause/resume keeps the redirect target in
/// native resume data, and the Hub's signed CDN URL dies after an hour
/// (R08 §5.5 step 7). So each transfer is a series of bounded `Range`
/// requests (`bytes=a-b`, [segmentBytes] each) into a staging `.seg` file
/// that is appended to the `.part` file when it completes. A stop, kill or
/// expiry loses at most one segment, and the next segment always starts
/// from bytes that are durably in the `.part` file with whatever URL the
/// manager just resolved.
///
/// The plugin has no checksum support (R09 §6); the manager verifies.
///
/// Known limits:
/// - Chaining segments needs the Dart isolate; while iOS suspends the app
///   only the current segment continues in the background session.
/// - Progress inside a segment is reported optimistically (offset +
///   received); a stop mid-segment drops back to the last full segment.
final class BackgroundTransferBackend implements TransferBackend {
  BackgroundTransferBackend({FileDownloader? downloader, this.segmentBytes = 256 << 20, this.group = 'sherpa-models'})
      : _downloader = downloader;

  FileDownloader? _downloader;

  /// Created on first use: constructing the plugin singleton touches
  /// platform channels, which a refused request never needs.
  FileDownloader get _fd => _downloader ??= FileDownloader();

  /// Bytes per Range request: bounds loss on stop/kill/expiry and the
  /// staging file's size.
  final int segmentBytes;
  final String group;

  @override
  int get transientBytes => segmentBytes;

  @override
  Future<void> recover() async {
    // Tasks from a previous process carry a URL that may have expired and a
    // destination the manager no longer tracks; it resumes from disk.
    await _fd.cancelAll(group: group);
  }

  @override
  TransferHandle start(TransferRequest request) {
    // The plugin persists every task (headers, URL) in its own storage, so
    // nothing that may need the Hub token is accepted here.
    if (request.hubOrigin) return _Refused('Hub-origin files are fetched in-process, never in the background.');
    return _SegmentedTransfer(this, request)..run();
  }
}

final class _Refused implements TransferHandle {
  _Refused(this.reason);

  final String reason;

  @override
  Stream<TransferProgress> get progress => const Stream.empty();

  @override
  Future<TransferOutcome> get done => Future.value(TransferFailed(reason));

  @override
  Future<void> stop() async {}
}

final class _SegmentedTransfer implements TransferHandle {
  _SegmentedTransfer(this._backend, this._r);

  final BackgroundTransferBackend _backend;
  final TransferRequest _r;
  final StreamController<TransferProgress> _progress = StreamController.broadcast();
  final Completer<TransferOutcome> _done = Completer();
  DownloadTask? _task;
  bool _stopped = false;

  FileDownloader get _fd => _backend._fd;

  @override
  Stream<TransferProgress> get progress => _progress.stream;

  @override
  Future<TransferOutcome> get done => _done.future;

  @override
  Future<void> stop() async {
    _stopped = true;
    final t = _task;
    if (t != null) await _fd.cancel(t);
  }

  void _finish(TransferOutcome o) {
    if (!_done.isCompleted) _done.complete(o);
    unawaited(_progress.close());
  }

  String get _segPath => p.setExtension(_r.partPath, '.seg');

  Future<void> run() async {
    try {
      final part = File(_r.partPath);
      await part.parent.create(recursive: true);
      var offset = part.existsSync() ? await part.length() : 0;
      if (offset != _r.offset) offset = math.min(offset, _r.offset);
      while (offset < _r.expectedBytes) {
        if (_stopped) return _finish(const TransferStopped());
        final end = math.min(offset + _backend.segmentBytes, _r.expectedBytes) - 1;
        final outcome = await _segment(offset, end);
        if (outcome != null) return _finish(outcome);
        offset = await part.length();
        _progress.add(TransferProgress(bytesOnDisk: offset));
      }
      _finish(const TransferCompleted());
    } on Object catch (e) {
      _finish(TransferFailed('Download failed: ${e.runtimeType}.'));
    }
  }

  /// One Range request; null when the bytes were appended.
  Future<TransferOutcome?> _segment(int start, int end) async {
    final seg = File(_segPath);
    if (seg.existsSync()) await seg.delete();
    final (base, dir, name) = await Task.split(filePath: seg.path);
    final task = DownloadTask(
      taskId: '${_r.id}@$start',
      url: _r.url.toString(),
      headers: {..._r.headers, 'Range': 'bytes=$start-$end'},
      baseDirectory: base,
      directory: dir,
      filename: name,
      group: _backend.group,
      updates: Updates.statusAndProgress,
      requiresWiFi: _r.requiresWiFi,
      // Retries re-use the same (maybe expired) URL; the manager re-resolves.
      retries: 0,
      displayName: _r.displayName ?? '',
    );
    _task = task;
    if (_stopped) return const TransferStopped();
    final transfer = await _fd.transfers.start(task);
    final length = end - start + 1;
    void onProgress() {
      final v = transfer.progress;
      if (v == null || v < 0) return;
      final speed = transfer.networkSpeed;
      _progress.add(TransferProgress(
        bytesOnDisk: start + (v * length).round(),
        bytesPerSecond: speed > 0 ? speed * 1000 * 1000 : null,
      ));
    }

    void onHold() {
      if (transfer.isWaitingForWiFi && !_stopped) unawaited(_fd.cancel(task));
    }

    final ValueListenable<double?> pn = transfer.progressNotifier;
    pn.addListener(onProgress);
    transfer.holdReasonNotifier.addListener(onHold);
    final TaskStatusUpdate result;
    try {
      result = await transfer.result;
    } finally {
      pn.removeListener(onProgress);
      transfer.holdReasonNotifier.removeListener(onHold);
      _task = null;
    }
    switch (result.status) {
      case TaskStatus.complete:
        return _append(seg, start, length, fullFile: result.responseStatusCode == 200);
      case TaskStatus.canceled:
        if (seg.existsSync()) await seg.delete();
        return transfer.isWaitingForWiFi && !_stopped ? const TransferWaitingForWifi() : const TransferStopped();
      case TaskStatus.notFound:
        return const TransferHttpError(404);
      case TaskStatus.failed:
        return switch (result.exception) {
          final TaskHttpException e => TransferHttpError(e.httpResponseCode, message: result.responseBody),
          final TaskConnectionException e => TransferNetworkError(e.description),
          final TaskFileSystemException e => TransferFailed('Could not write the file: ${e.description}'),
          final e => TransferNetworkError(e?.description ?? 'transfer failed'),
        };
      case TaskStatus.enqueued || TaskStatus.running || TaskStatus.waitingToRetry || TaskStatus.paused:
        return const TransferNetworkError('transfer ended unexpectedly');
    }
  }

  /// Appends the segment to the `.part` file. A `200` means the server
  /// ignored Range and sent the file from byte 0: skip to [start].
  Future<TransferOutcome?> _append(File seg, int start, int length, {required bool fullFile}) async {
    if (!seg.existsSync()) return const TransferFailed('The downloaded segment is missing.');
    final got = await seg.length();
    final int skip;
    if (got == length && !(fullFile && start > 0)) {
      skip = 0;
    } else if (got >= start + length && (fullFile || got == _r.expectedBytes)) {
      skip = start;
    } else {
      await seg.delete();
      return TransferFailed('The server sent $got bytes for a $length-byte range.');
    }
    final sink = File(_r.partPath).openWrite(mode: FileMode.append);
    try {
      await sink.addStream(seg.openRead(skip, skip + length));
      await sink.flush();
    } finally {
      await sink.close();
    }
    await seg.delete();
    return null;
  }
}
