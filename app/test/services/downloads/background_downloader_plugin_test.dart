// BackgroundTransferBackend over background_downloader's real Dart side
// (FileDownloader, Transfers, its database and status plumbing), with only
// the platform channels faked the way BDPlugin.kt answers for a Wi-Fi-only
// task whose WorkManager constraint is never met: `enqueueAll` succeeds and
// posts the `enqueued` status, and the task never runs.
//
// The fakes in background_transfer_backend_test.dart can't show what the
// plugin itself does with those updates; this file can.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa/services/downloads/downloads.dart';

/// The plugin's task database, in memory.
final class _MemStorage implements PersistentStorage {
  final Map<String, TaskRecord> records = {};
  final Map<String, Task> paused = {};
  final Map<String, ResumeData> resume = {};

  @override
  (String, int) get currentDatabaseVersion => ('Mem', 1);

  @override
  Future<(String, int)> get storedDatabaseVersion async => ('Mem', 1);

  @override
  Future<void> initialize() async {}

  @override
  Future<void> storeTaskRecord(TaskRecord record) async {
    // A real write takes a moment.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    records[record.taskId] = record;
  }

  @override
  Future<TaskRecord?> retrieveTaskRecord(String taskId) async => records[taskId];

  @override
  Future<List<TaskRecord>> retrieveAllTaskRecords() async => records.values.toList();

  @override
  Future<void> removeTaskRecord(String? taskId) async => taskId == null ? records.clear() : records.remove(taskId);

  @override
  Future<void> storePausedTask(Task task) async => paused[task.taskId] = task;

  @override
  Future<Task?> retrievePausedTask(String taskId) async => paused[taskId];

  @override
  Future<List<Task>> retrieveAllPausedTasks() async => paused.values.toList();

  @override
  Future<void> removePausedTask(String? taskId) async => taskId == null ? paused.clear() : paused.remove(taskId);

  @override
  Future<void> storeResumeData(ResumeData resumeData) async => resume[resumeData.taskId] = resumeData;

  @override
  Future<ResumeData?> retrieveResumeData(String taskId) async => resume[taskId];

  @override
  Future<List<ResumeData>> retrieveAllResumeData() async => resume.values.toList();

  @override
  Future<void> removeResumeData(String? taskId) async => taskId == null ? resume.clear() : resume.remove(taskId);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();
  final taskJsonById = <String, String>{};
  late FileDownloader fd;

  Future<void> postBackground(String method, List<Object?> args) {
    final c = Completer<void>();
    messenger.handlePlatformMessage(
      'com.bbflight.background_downloader.background',
      codec.encodeMethodCall(MethodCall(method, args)),
      (_) => c.complete(),
    );
    return c.future;
  }

  setUpAll(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async => call.method == 'check' ? <String>['wifi'] : null,
    );
    messenger.setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/connectivity_status'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('com.bbflight.background_downloader'), (call) async {
      switch (call.method) {
        case 'enqueueAll':
          final tasks = jsonDecode((call.arguments as List)[0] as String) as List;
          for (final t in tasks) {
            final json = jsonEncode(t);
            taskJsonById[(t as Map)['taskId'] as String] = json;
            // BDPlugin.doEnqueue -> processStatusUpdate(task, enqueued).
            unawaited(postBackground('statusUpdate', [json, TaskStatus.enqueued.index]));
          }
          // WorkManager took the work; its Wi-Fi network request is never met.
          return [for (final _ in tasks) true];
        case 'cancelTasksWithIds':
          for (final id in (call.arguments as List).cast<String>()) {
            final json = taskJsonById[id];
            if (json == null) continue;
            // BDPlugin.cancelActiveTaskWithId: progress -2, then canceled.
            unawaited(postBackground('progressUpdate', [json, -2.0, -1, -1.0, 0]));
            unawaited(postBackground('statusUpdate', [json, TaskStatus.canceled.index]));
          }
          return true;
        default:
          return null;
      }
    });
    fd = FileDownloader(persistentStorage: _MemStorage());
    await fd.ready;
  });

  tearDownAll(() => debugDefaultTargetPlatformOverride = null);

  test('a Wi-Fi-only segment Android never starts comes back as not started', () async {
    final dir = await Directory.systemTemp.createTemp('sherpa_bd_plugin_');
    addTearDown(() => dir.delete(recursive: true));
    final backend = BackgroundTransferBackend(
      downloader: fd,
      segmentBytes: 1 << 20,
      wifiHoldGrace: const Duration(seconds: 10),
      unstartedGrace: const Duration(milliseconds: 300),
      splitPath: (path) async => (BaseDirectory.root, p.dirname(path), p.basename(path)),
    );
    final handle = backend.start(TransferRequest(
      id: 'rec1',
      url: Uri.parse('https://cdn.example/x.gguf'),
      partPath: p.join(dir.path, 'rec1.part'),
      offset: 0,
      expectedBytes: 4000,
      requiresWiFi: true,
    ));
    final progress = <int>[];
    final sub = handle.progress.listen((e) => progress.add(e.bytesOnDisk));
    addTearDown(sub.cancel);

    final outcome = await handle.done.timeout(const Duration(seconds: 5));
    expect(outcome, isA<TransferWaitingForWifi>().having((o) => o.notStarted, 'notStarted', isTrue));
    expect(progress, isEmpty, reason: 'no bytes arrived, so no progress (the notice must not clear)');
  });

  test('the plugin reports progress 0 for a task it only queued; the not-started watch still fires', () async {
    final task = DownloadTask(
      taskId: 'probe@0',
      url: 'https://cdn.example/y',
      baseDirectory: BaseDirectory.root,
      directory: Directory.systemTemp.path,
      filename: 'sherpa_probe.seg',
      group: 'sherpa-models',
      requiresWiFi: true,
      updates: Updates.statusAndProgress,
      allowPause: true,
    );
    final t = (await fd.transfers.startAll([task])).single;
    final progressWhileQueued = <double?>[];
    void record() {
      if (t.status == TaskStatus.enqueued) progressWhileQueued.add(t.progress);
    }

    t.progressNotifier.addListener(record);
    var fired = 0;
    final stop = watchUnstarted(
      status: t.statusNotifier,
      progress: t.progressNotifier,
      grace: const Duration(milliseconds: 300),
      onUnstarted: () => fired++,
    );
    await Future<void>.delayed(const Duration(milliseconds: 800));
    stop();
    t.progressNotifier.removeListener(record);
    await fd.cancel(task);

    expect(t.status, isNot(TaskStatus.running));
    expect(progressWhileQueued, contains(0.0), reason: "the plugin's echo this watch has to ignore");
    expect(fired, 1);
  });
}
