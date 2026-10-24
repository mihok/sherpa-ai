import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa/features/models/state/models_providers.dart' show transferBackendProvider;
import 'package:sherpa/services/downloads/downloads.dart';

/// background_downloader as it behaves on a device, minus the native side:
/// `start` drops the native enqueue result (transfers.dart: `await
/// downloader.enqueue(task); return transfer;`), `startAll` marks a refused
/// task failed, and both set the hold reason before they return. An
/// accepted task then gets progress 0 while it is still only queued (the
/// plugin's database record of an enqueued task carries progress 0, and
/// `Transfers` replays records to their transfers).
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
    if (nativeAccepts) _accepted(t);
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
      _accepted(t);
    }
    return t;
  }

  void _accepted(Transfer t) {
    scheduleMicrotask(() {
      if (t.status == TaskStatus.enqueued) t.updateProgress(TaskProgressUpdate(t.task, 0.0));
    });
    run?.call(t);
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

  BackgroundTransferBackend backend({
    Duration grace = const Duration(milliseconds: 50),
    Duration? unstartedGrace,
    ValueNotifier<bool>? foreground,
    int segmentBytes = 1 << 20,
  }) =>
      BackgroundTransferBackend(
        downloader: fd,
        segmentBytes: segmentBytes,
        wifiHoldGrace: grace,
        unstartedGrace: unstartedGrace,
        foreground: foreground,
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

  /// The native side running a task to completion: writes the segment where
  /// the backend expects it.
  Future<void> runToCompletion(Transfer t, {int bytes = 1000}) async {
    t.updateStatus(TaskStatusUpdate(t.task, TaskStatus.running));
    await File(p.setExtension(request().partPath, '.seg')).writeAsBytes(List<int>.filled(bytes, 7));
    t.updateStatus(TaskStatusUpdate(t.task, TaskStatus.complete, null, null, null, 206));
  }

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
    expect(outcome, isA<TransferFailed>().having((o) => o.message, 'message', contains('refused to schedule')));
  });

  test('a real failure that arrives before startAll returns is mapped, not reported as a refusal', () async {
    // The worker can run and fail (an expired signed URL) before the native
    // enqueue result reaches Dart: the transfer is already failed, with a
    // typed exception, when `startAll` returns. A 403 has to reach the
    // manager as one so it resolves a fresh URL.
    fd.fake.run = (t) => t.updateStatus(TaskStatusUpdate(
        t.task, TaskStatus.failed, TaskHttpException('Not authorized', 403), 'Auth failed: credentials expired', null, 403));
    final outcome = await backend().start(request()).done.timeout(const Duration(seconds: 5));
    expect(outcome, isA<TransferHttpError>().having((o) => o.statusCode, 'statusCode', 403).having((o) => o.isExpired, 'isExpired', isTrue));
  });

  test('only the plugin\'s own enqueue failure counts as a refusal', () {
    expect(isEnqueueRefusal(TaskException('Failed to batch enqueue task on native platform')), isTrue);
    expect(isEnqueueRefusal(TaskHttpException('Failed to batch enqueue task on native platform', 403)), isFalse);
    expect(isEnqueueRefusal(TaskException('Task timed out')), isFalse);
    expect(isEnqueueRefusal(null), isFalse);
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

  test('a Wi-Fi-only task Android never starts, with no hold reason, comes back as not started', () async {
    // The phone is on Wi-Fi as far as the plugin knows (no hold reason),
    // but Android does not count the connection (a VPN carries the default
    // network): the WorkManager job stays enqueued and nothing ever runs.
    final handle = backend(unstartedGrace: const Duration(milliseconds: 100)).start(request());
    final outcome = await handle.done.timeout(const Duration(seconds: 5));
    expect(outcome, isA<TransferWaitingForWifi>().having((o) => o.notStarted, 'notStarted', isTrue));
    expect(fd.cancelled, ['rec1@0']);
  });

  test('in the background Android may defer any work: "not started" is judged only on screen', () async {
    // Doze or battery saver hold work back whatever the connection; that
    // must not read as "Android doesn't count this connection as Wi-Fi".
    final onScreen = ValueNotifier(false);
    var ended = false;
    final handle = backend(unstartedGrace: const Duration(milliseconds: 100), foreground: onScreen).start(request());
    unawaited(handle.done.then((_) => ended = true));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(ended, isFalse, reason: 'three graces in the background');
    expect(fd.cancelled, isEmpty);

    onScreen.value = true;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(ended, isFalse, reason: 'the grace starts over on screen');
    final outcome = await handle.done.timeout(const Duration(seconds: 5));
    expect(outcome, isA<TransferWaitingForWifi>().having((o) => o.notStarted, 'notStarted', isTrue));
    expect(fd.cancelled, ['rec1@0']);
  });

  test("the app's backend is told when Sherpa leaves the screen and when it comes back", () {
    final binding = TestWidgetsFlutterBinding.ensureInitialized()
      ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final onScreen = (container.read(transferBackendProvider) as BackgroundTransferBackend).foreground;
    expect(onScreen?.value, isTrue);
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      binding.handleAppLifecycleStateChanged(s);
    }
    expect(onScreen?.value, isFalse);
    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      binding.handleAppLifecycleStateChanged(s);
    }
    expect(onScreen?.value, isTrue);
  });

  test('a slow start is not "not started": a task that runs before the grace completes', () async {
    fd.fake.run = (t) => Timer(const Duration(milliseconds: 60), () => unawaited(runToCompletion(t)));
    final handle = backend(unstartedGrace: const Duration(milliseconds: 150)).start(request());
    final outcome = await handle.done.timeout(const Duration(seconds: 5));
    expect(outcome, isA<TransferCompleted>());
    expect(fd.cancelled, isEmpty);
  });

  test('a task that is not Wi-Fi-only is never flipped to waiting for Wi-Fi', () async {
    fd.fake.run = (t) => Timer(const Duration(milliseconds: 250), () => unawaited(runToCompletion(t)));
    final handle = backend(unstartedGrace: const Duration(milliseconds: 50)).start(request(wifiOnly: false));
    final outcome = await handle.done.timeout(const Duration(seconds: 5));
    expect(outcome, isA<TransferCompleted>());
    expect(fd.cancelled, isEmpty);
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

  group('watchUnstarted', () {
    Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

    test('fires once when the task is still enqueued with no progress after the grace', () async {
      final status = ValueNotifier(TaskStatus.enqueued);
      final progress = ValueNotifier<double?>(null);
      var fired = 0;
      final stop = watchUnstarted(status: status, progress: progress, grace: const Duration(milliseconds: 100), onUnstarted: () => fired++);
      await wait(30);
      expect(fired, 0, reason: 'not before the grace');
      await wait(150);
      expect(fired, 1);
      await wait(150);
      expect(fired, 1, reason: 'once');
      stop();
    });

    test('a task that started (running, or any progress) is left alone, even if it is enqueued again later', () async {
      final status = ValueNotifier(TaskStatus.enqueued);
      final progress = ValueNotifier<double?>(0.4);
      var fired = 0;
      final stop = watchUnstarted(status: status, progress: progress, grace: const Duration(milliseconds: 100), onUnstarted: () => fired++);
      await wait(30);
      status.value = TaskStatus.running;
      status.value = TaskStatus.enqueued;
      await wait(200);
      expect(fired, 0);
      stop();

      final quiet = ValueNotifier(TaskStatus.enqueued);
      final stop2 = watchUnstarted(status: quiet, progress: progress, grace: const Duration(milliseconds: 100), onUnstarted: () => fired++);
      await wait(30);
      progress.value = 0.5;
      await wait(200);
      expect(fired, 0, reason: 'progress is a sign of life even while the status lags');
      stop2();
    });

    test('stopping the watch cancels it', () async {
      final status = ValueNotifier(TaskStatus.enqueued);
      var fired = 0;
      final stop = watchUnstarted(
          status: status, progress: ValueNotifier<double?>(null), grace: const Duration(milliseconds: 50), onUnstarted: () => fired++);
      stop();
      await wait(120);
      expect(fired, 0);
    });

    test('the grace counts only while Sherpa is on screen, and starts over when it comes back', () async {
      final status = ValueNotifier(TaskStatus.enqueued);
      final onScreen = ValueNotifier(true);
      var fired = 0;
      final stop = watchUnstarted(
        status: status,
        progress: ValueNotifier<double?>(null),
        grace: const Duration(milliseconds: 100),
        foreground: onScreen,
        onUnstarted: () => fired++,
      );
      await wait(70);
      onScreen.value = false;
      await wait(200);
      expect(fired, 0, reason: 'not in the background');
      onScreen.value = true;
      await wait(70);
      expect(fired, 0, reason: 'a full grace again, not what was left of the first');
      await wait(100);
      expect(fired, 1);
      stop();

      // Started in the background: nothing until Sherpa is on screen.
      final hidden = ValueNotifier(false);
      final stop2 = watchUnstarted(
        status: ValueNotifier(TaskStatus.enqueued),
        progress: ValueNotifier<double?>(null),
        grace: const Duration(milliseconds: 50),
        foreground: hidden,
        onUnstarted: () => fired++,
      );
      await wait(150);
      expect(fired, 1);
      stop2();
    });
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
