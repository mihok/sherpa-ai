import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa/services/downloads/downloads.dart';

/// background_downloader as it behaves on a device, minus the native side:
/// `start` drops the native enqueue result (transfers.dart: `await
/// downloader.enqueue(task); return transfer;`), `startAll` marks a refused
/// task failed, and both set the hold reason before they return.
final class _FakeTransfers implements Transfers {
  _FakeTransfers(this._fd);

  final _FakeDownloader _fd;
  final List<Transfer> started = [];

  /// What the native `enqueue` answers.
  bool nativeAccepts = true;

  /// The plugin's Dart-side guess at start (`waitingForWiFi` when it thinks
  /// the phone is not on Wi-Fi and the task requires it).
  TransferHoldReason holdAtStart = TransferHoldReason.none;

  /// The native side running an accepted task.
  void Function(Transfer t)? run;

  /// Completed when `startAll` is called; [enqueueGate] then holds it before
  /// the native enqueue (the plugin JSON-encodes tasks in an isolate first).
  final Completer<void> enqueueing = Completer();
  Completer<void>? enqueueGate;

  Transfer _make(Task task) {
    final t = Transfer(task, _fd, TaskStatus.enqueued, null, null, holdAtStart);
    started.add(t);
    return t;
  }

  @override
  Future<Transfer> start(Task task) async {
    final t = _make(task);
    if (nativeAccepts) run?.call(t);
    return t;
  }

  @override
  Future<List<Transfer>> startAll(List<Task> tasks, {void Function(int succeeded, int failed)? onProgress}) async {
    if (!enqueueing.isCompleted) enqueueing.complete();
    await enqueueGate?.future;
    return [for (final task in tasks) _startOne(task)];
  }

  Transfer _startOne(Task task) {
    final t = _make(task);
    if (!nativeAccepts) {
      t.updateStatus(TaskStatusUpdate(task, TaskStatus.failed, TaskException('Failed to batch enqueue task on native platform')));
    } else {
      run?.call(t);
    }
    return t;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeDownloader implements FileDownloader {
  late final _FakeTransfers fake = _FakeTransfers(this);
  final List<String> cancelled = [];

  @override
  Transfers get transfers => fake;

  @override
  Future<bool> cancel(Task task) async {
    cancelled.add(task.taskId);
    for (final t in fake.started.where((t) => t.taskId == task.taskId)) {
      if (!t.status.isFinalState) t.updateStatus(TaskStatusUpdate(t.task, TaskStatus.canceled));
    }
    return true;
  }

  @override
  Future<bool> cancelAll({Iterable<Task>? tasks, String? group}) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory dir;
  late _FakeDownloader fd;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sherpa_bg_backend_');
    fd = _FakeDownloader();
  });
  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  BackgroundTransferBackend backend({Duration grace = const Duration(milliseconds: 50), int segmentBytes = 1 << 20}) =>
      BackgroundTransferBackend(
        downloader: fd,
        segmentBytes: segmentBytes,
        wifiHoldGrace: grace,
        splitPath: (path) async => (BaseDirectory.root, p.dirname(path), p.basename(path)),
      );

  TransferRequest request({int size = 1000, bool wifiOnly = true}) => TransferRequest(
        id: 'rec1',
        url: Uri.parse('https://us.aws.cdn.hf.co/xet-bridge-us/abc/def?Expires=1&Signature=s&Key-Pair-Id=k'),
        partPath: p.join(dir.path, 'partial', 'rec1.part'),
        offset: 0,
        expectedBytes: size,
        headers: const {'accept-encoding': 'identity'},
        requiresWiFi: wifiOnly,
        displayName: 'Qwen3 1.7B Q4_K_M',
      );

  test('segment tasks may pause, so Android resumes them at its 9-minute job limit instead of failing them', () {
    final task = buildSegmentTask(request(), 0, 268435455,
        baseDirectory: BaseDirectory.root, directory: '/data/x', filename: 'rec1.seg', group: 'sherpa-models');
    expect(task.allowPause, isTrue);
    expect(task.retries, 0, reason: 'a retry would re-use a signed URL that may have expired');
    expect(task.headers['Range'], 'bytes=0-268435455');
    expect(task.requiresWiFi, isTrue);
    expect(task.headers.keys.map((k) => k.toLowerCase()), isNot(contains('authorization')));
  });

  test('a task the phone refuses to schedule fails with a reason instead of waiting forever', () async {
    fd.fake.nativeAccepts = false;
    final handle = backend().start(request());
    final outcome = await handle.done.timeout(const Duration(seconds: 5));
    expect(outcome, isA<TransferFailed>().having((o) => o.message, 'message', contains('refused the download')));
  });

  test('a task the plugin already holds for Wi-Fi when start returns comes back as waiting for Wi-Fi', () async {
    // On mobile data with a Wi-Fi-only task: the OS keeps it queued and
    // nothing ever runs.
    fd.fake.holdAtStart = TransferHoldReason.waitingForWiFi;
    final handle = backend().start(request());
    final outcome = await handle.done.timeout(const Duration(seconds: 5));
    expect(outcome, isA<TransferWaitingForWifi>());
    expect(fd.cancelled, ['rec1@0']);
  });

  test('a hold the OS overrides (the task starts running) is not cancelled; the segment completes', () async {
    fd.fake.holdAtStart = TransferHoldReason.waitingForWiFi;
    fd.fake.run = (t) => scheduleMicrotask(() async {
          t.updateStatus(TaskStatusUpdate(t.task, TaskStatus.running));
          // Where the plugin writes the segment (the backend's `.seg` file).
          await File(p.setExtension(request().partPath, '.seg')).writeAsBytes(List<int>.filled(1000, 7));
          t.updateStatus(TaskStatusUpdate(t.task, TaskStatus.complete, null, null, null, 206));
        });
    final handle = backend(grace: const Duration(milliseconds: 200)).start(request());
    final outcome = await handle.done.timeout(const Duration(seconds: 5));
    expect(outcome, isA<TransferCompleted>());
    expect(fd.cancelled, isEmpty);
    expect(File(request().partPath).lengthSync(), 1000);
  });

  test('a stop that arrives while the task is being enqueued still cancels it', () async {
    // The cancel reaches the plugin before the task does, so there is
    // nothing to cancel yet; without a second cancel the segment runs on.
    fd.fake
      ..enqueueGate = Completer<void>()
      ..run = (t) => t.updateStatus(TaskStatusUpdate(t.task, TaskStatus.running));
    final handle = backend().start(request(wifiOnly: false));
    await fd.fake.enqueueing.future.timeout(const Duration(seconds: 5));
    await handle.stop();
    expect(fd.fake.started, isEmpty, reason: 'nothing was enqueued when stop() cancelled');
    fd.fake.enqueueGate!.complete();
    final outcome = await handle.done.timeout(const Duration(seconds: 5));
    expect(outcome, isA<TransferStopped>());
    expect(fd.fake.started.single.status, TaskStatus.canceled);
  });

  group('watchWifiHold', () {
    Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

    test('sees a hold that was set before it started watching', () async {
      final hold = ValueNotifier(TransferHoldReason.waitingForWiFi);
      final status = ValueNotifier(TaskStatus.enqueued);
      var held = 0;
      final stop = watchWifiHold(hold: hold, status: status, grace: const Duration(milliseconds: 100), onHeld: () => held++);
      await wait(30);
      expect(held, 0, reason: 'not before the grace');
      await wait(150);
      expect(held, 1);
      await wait(150);
      expect(held, 1, reason: 'once');
      stop();
    });

    test('a task that starts running within the grace is left alone; a later hold is caught', () async {
      final hold = ValueNotifier(TransferHoldReason.waitingForWiFi);
      final status = ValueNotifier(TaskStatus.enqueued);
      var held = 0;
      final stop = watchWifiHold(hold: hold, status: status, grace: const Duration(milliseconds: 100), onHeld: () => held++);
      await wait(30);
      status.value = TaskStatus.running;
      hold.value = TransferHoldReason.none;
      await wait(200);
      expect(held, 0);
      status.value = TaskStatus.waitingToRetry;
      hold.value = TransferHoldReason.waitingForWiFi;
      await wait(200);
      expect(held, 1);
      stop();
    });
  });
}
