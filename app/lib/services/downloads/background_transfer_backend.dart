import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart' show ValueListenable, visibleForTesting;
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
/// Android runs each segment as a WorkManager job, which the system stops
/// after about 9 minutes. Segments therefore allow pausing
/// ([buildSegmentTask]): the plugin then pauses at the time limit and
/// resumes with a Range from the bytes it already has, instead of failing
/// a slow segment over and over.
///
/// Known limits:
/// - Chaining segments needs the Dart isolate; while iOS suspends the app
///   only the current segment continues in the background session.
/// - Progress inside a segment is reported optimistically (offset +
///   received); a stop mid-segment drops back to the last full segment.
final class BackgroundTransferBackend implements TransferBackend {
  BackgroundTransferBackend({
    FileDownloader? downloader,
    this.segmentBytes = 256 << 20,
    this.group = 'sherpa-models',
    this.wifiHoldGrace = const Duration(seconds: 10),
    Future<(BaseDirectory, String, String)> Function(String path)? splitPath,
  })  : _downloader = downloader,
        _split = splitPath ?? ((path) => Task.split(filePath: path));

  FileDownloader? _downloader;

  /// Created on first use: constructing the plugin singleton touches
  /// platform channels, which a refused request never needs.
  FileDownloader get _fd => _downloader ??= FileDownloader();

  /// Bytes per Range request: bounds loss on stop/kill/expiry and the
  /// staging file's size.
  final int segmentBytes;
  final String group;

  /// How long a segment the plugin holds for Wi-Fi may stay unstarted
  /// before it comes back as [TransferWaitingForWifi] (see [watchWifiHold]).
  final Duration wifiHoldGrace;
  final Future<(BaseDirectory, String, String)> Function(String path) _split;

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
    final (base, dir, name) = await _backend._split(seg.path);
    final task = buildSegmentTask(_r, start, end, baseDirectory: base, directory: dir, filename: name, group: _backend.group);
    _task = task;
    if (_stopped) return const TransferStopped();
    // `startAll`, not `start`: `start` drops the native enqueue result, so a
    // task Android refused (URL validation, WorkManager) would wait forever
    // at "Downloading: 0 B". `startAll` marks it failed instead.
    final transfer = (await _fd.transfers.startAll([task])).single;
    if (transfer.status == TaskStatus.failed) {
      _task = null;
      if (seg.existsSync()) await seg.delete();
      return TransferFailed("This phone's download service refused the download "
          '(${transfer.exception?.description ?? 'not scheduled'}). Tap Retry; if it keeps failing, restart Sherpa.');
    }
    // A stop() during `startAll` reached the plugin before the task did
    // (it encodes tasks in an isolate first), so it cancelled nothing; the
    // segment would run to its end. Cancel it now that it exists.
    if (_stopped) unawaited(_fd.cancel(task));
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

    // The plugin sets the hold reason inside `startAll`, before it returns,
    // so the watch has to look at the value it already has.
    var heldForWifi = false;
    final ValueListenable<double?> pn = transfer.progressNotifier;
    pn.addListener(onProgress);
    final unwatch = watchWifiHold(
      hold: transfer.holdReasonNotifier,
      status: transfer.statusNotifier,
      grace: _backend.wifiHoldGrace,
      onHeld: () {
        if (_stopped) return;
        heldForWifi = true;
        unawaited(_fd.cancel(task));
      },
    );
    final TaskStatusUpdate result;
    try {
      result = await transfer.result;
    } finally {
      pn.removeListener(onProgress);
      unwatch();
      _task = null;
    }
    switch (result.status) {
      case TaskStatus.complete:
        return _append(seg, start, length, fullFile: result.responseStatusCode == 200);
      case TaskStatus.canceled:
        if (seg.existsSync()) await seg.delete();
        // The plugin clears the hold reason when the task ends, so the
        // flag says why it was cancelled.
        return heldForWifi && !_stopped ? const TransferWaitingForWifi() : const TransferStopped();
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

/// The plugin task for bytes [start]..[end] of [r], written to
/// [directory]/[filename] under [baseDirectory].
///
/// - `allowPause`: Android stops a WorkManager job after about 9 minutes; a
///   pausable task is resumed by the plugin with `Range` from the bytes it
///   has (the CDN's ETag is strong and the same for every range), while a
///   non-pausable one fails with "Task timed out". Without it, a segment
///   that needs more than 9 minutes (256 MiB below ~0.5 MB/s) could never
///   finish.
/// - `retries: 0`: retries would re-use the same (maybe expired) signed URL;
///   the manager re-resolves instead.
@visibleForTesting
DownloadTask buildSegmentTask(
  TransferRequest r,
  int start,
  int end, {
  required BaseDirectory baseDirectory,
  required String directory,
  required String filename,
  required String group,
}) =>
    DownloadTask(
      taskId: '${r.id}@$start',
      url: r.url.toString(),
      headers: {...r.headers, 'Range': 'bytes=$start-$end'},
      baseDirectory: baseDirectory,
      directory: directory,
      filename: filename,
      group: group,
      updates: Updates.statusAndProgress,
      requiresWiFi: r.requiresWiFi,
      retries: 0,
      allowPause: true,
      displayName: r.displayName ?? '',
    );

/// Calls [onHeld] once when [hold] says the transfer waits for Wi-Fi and
/// [status] has not reached running for [grace]. Returns a function that
/// stops watching.
///
/// It looks at the current values too: background_downloader sets the hold
/// reason inside `Transfers.start`/`startAll`, before they return, and a
/// `ValueNotifier` does not replay it to a listener added afterwards. A
/// missed hold left a Wi-Fi-only task queued by the OS on mobile data with
/// nothing on screen but "Downloading: 0 B".
///
/// The grace absorbs the plugin's own guess, made from its Dart-side view
/// of connectivity (a VPN-only link counts as "not Wi-Fi"): when the OS
/// starts the task anyway, the status turns running and the hold clears.
@visibleForTesting
void Function() watchWifiHold({
  required ValueListenable<TransferHoldReason> hold,
  required ValueListenable<TaskStatus> status,
  required Duration grace,
  required void Function() onHeld,
}) {
  Timer? timer;
  var fired = false;
  bool held() => hold.value == TransferHoldReason.waitingForWiFi && status.value != TaskStatus.running;
  void check() {
    if (fired) return;
    if (!held()) {
      timer?.cancel();
      timer = null;
      return;
    }
    timer ??= Timer(grace, () {
      timer = null;
      if (fired || !held()) return;
      fired = true;
      onHeld();
    });
  }

  hold.addListener(check);
  status.addListener(check);
  check();
  return () {
    timer?.cancel();
    hold.removeListener(check);
    status.removeListener(check);
  };
}
